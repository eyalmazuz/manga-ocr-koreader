use std::{
    cmp::{self, Ordering},
    collections::BTreeMap,
    fmt,
    io::Cursor,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use chrome_lens_ocr::{GeometryData, LensClient, Paragraph};
use image::{DynamicImage, ImageFormat, ImageReader};

use crate::model::{MOKURO_FORMAT_VERSION, MokuroBlock, MokuroPage, Point, Polygon};

const MAX_CHUNK_HEIGHT: u32 = 3_000;
const MAX_REQUEST_RETRIES: usize = 3;

#[derive(Clone, Debug, PartialEq)]
pub struct DetectedGeometry {
    pub center_x: f32,
    pub center_y: f32,
    pub width: f32,
    pub height: f32,
    pub rotation: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DetectedLine {
    pub text: String,
    pub geometry: Option<DetectedGeometry>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DetectedParagraph {
    pub text: String,
    pub geometry: Option<DetectedGeometry>,
    pub lines: Vec<DetectedLine>,
}

#[derive(Debug)]
pub enum PageOcrError {
    Local(anyhow::Error),
    Service(anyhow::Error),
}

impl PageOcrError {
    #[must_use]
    pub fn local(error: anyhow::Error) -> Self {
        Self::Local(error)
    }

    #[must_use]
    pub fn service(error: anyhow::Error) -> Self {
        Self::Service(error)
    }

    #[must_use]
    pub fn is_service(&self) -> bool {
        matches!(self, Self::Service(_))
    }

    #[must_use]
    pub fn details(&self) -> String {
        match self {
            Self::Local(error) | Self::Service(error) => format!("{error:#}"),
        }
    }
}

impl fmt::Display for PageOcrError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Local(error) | Self::Service(error) => write!(formatter, "{error:#}"),
        }
    }
}

/// Decode and OCR one image page, chunking very tall pages as needed.
///
/// # Errors
///
/// Returns an error when the image cannot be decoded/encoded or a Lens chunk
/// still fails after all request attempts.
pub async fn recognize_page(
    client: &LensClient,
    image_bytes: &[u8],
    image_path: &str,
    language: &str,
) -> std::result::Result<MokuroPage, PageOcrError> {
    let page_started = Instant::now();
    let dimensions_started = Instant::now();
    let (image_width, image_height) = image_dimensions(image_bytes).map_err(|error| {
        PageOcrError::local(error.context(format!(
            "failed to read image dimensions for page {image_path}"
        )))
    })?;
    let dimensions_elapsed = dimensions_started.elapsed();
    if image_width == 0 || image_height == 0 {
        return Err(PageOcrError::local(anyhow!(
            "image page {image_path} has zero dimensions"
        )));
    }

    // Normal manga pages can be sent directly to the Lens client, which does
    // its own decode/resize. Decode here only when a tall page must be cropped
    // into chunks, avoiding a redundant full image decode on the usual path.
    let image = if image_height > MAX_CHUNK_HEIGHT {
        Some(image::load_from_memory(image_bytes).map_err(|error| {
            PageOcrError::local(
                anyhow::Error::new(error)
                    .context(format!("failed to decode tall image page {image_path}")),
            )
        })?)
    } else {
        None
    };

    let mut blocks = Vec::new();
    let mut request_elapsed = Duration::ZERO;
    let mut chunk_count = 0_u32;
    let mut chunk_y = 0;
    while chunk_y < image_height {
        chunk_count += 1;
        let chunk_height = cmp::min(MAX_CHUNK_HEIGHT, image_height - chunk_y);
        let encoded_chunk;
        let request_bytes = if chunk_y == 0 && chunk_height == image_height {
            image_bytes
        } else {
            let source_image = image.as_ref().ok_or_else(|| {
                PageOcrError::local(anyhow!(
                    "missing decoded source while chunking image page {image_path}"
                ))
            })?;
            encoded_chunk = encode_chunk(source_image, chunk_y, chunk_height).map_err(|error| {
                PageOcrError::local(
                    error.context(format!("failed to prepare OCR chunk for {image_path}")),
                )
            })?;
            &encoded_chunk
        };

        let request_started = Instant::now();
        let response = request_with_retry(client, request_bytes, language)
            .await
            .map_err(|error| {
                PageOcrError::service(error.context(format!(
                    "Google Lens OCR failed for {image_path} at vertical offset {chunk_y}"
                )))
            })?;
        request_elapsed += request_started.elapsed();
        let paragraphs: Vec<_> = response.paragraphs.iter().map(detected_paragraph).collect();
        blocks.extend(blocks_from_paragraphs(
            &paragraphs,
            image_width,
            chunk_height,
            chunk_y,
            image_height,
            language,
        ));

        chunk_y += chunk_height;
    }

    let grouping_started = Instant::now();
    let blocks = group_nearby_blocks(blocks, language);
    let grouping_elapsed = grouping_started.elapsed();
    eprintln!(
        "Manga OCR timing: page={image_path:?} dimensions_ms={} lens_pipeline_ms={} grouping_ms={} chunks={chunk_count} blocks={} total_ms={}",
        dimensions_elapsed.as_millis(),
        request_elapsed.as_millis(),
        grouping_elapsed.as_millis(),
        blocks.len(),
        page_started.elapsed().as_millis(),
    );

    Ok(MokuroPage {
        version: MOKURO_FORMAT_VERSION.to_owned(),
        img_path: image_path.to_owned(),
        img_width: image_width,
        img_height: image_height,
        // Lens paragraph boundaries are not reliable text-region boundaries:
        // manga columns or rows that belong together are often returned as
        // separate one-line paragraphs. Group after every chunk has been
        // converted to absolute page coordinates, including across a chunk
        // seam.
        blocks,
    })
}

fn image_dimensions(image_bytes: &[u8]) -> Result<(u32, u32)> {
    ImageReader::new(Cursor::new(image_bytes))
        .with_guessed_format()
        .context("failed to identify image format")?
        .into_dimensions()
        .context("failed to read image header")
}

/// Convert Lens paragraph/line geometry into upstream Mokuro blocks.
#[must_use]
pub fn blocks_from_paragraphs(
    paragraphs: &[DetectedParagraph],
    image_width: u32,
    chunk_height: u32,
    chunk_y: u32,
    image_height: u32,
    language: &str,
) -> Vec<MokuroBlock> {
    paragraphs
        .iter()
        .filter_map(|paragraph| {
            let mut dropped_nonempty_line = false;
            let lines: Vec<_> = paragraph
                .lines
                .iter()
                .filter_map(|line| {
                    let text = clean_text(&line.text, language);
                    if text.is_empty() {
                        return None;
                    }
                    let Some(geometry) = line.geometry.as_ref() else {
                        dropped_nonempty_line = true;
                        return None;
                    };
                    let Some(polygon) = geometry_polygon(
                        geometry,
                        image_width,
                        chunk_height,
                        chunk_y,
                        image_height,
                    ) else {
                        dropped_nonempty_line = true;
                        return None;
                    };
                    Some((text, polygon))
                })
                .collect();

            let paragraph_fallback = || {
                let text = clean_text(&paragraph.text, language);
                let geometry = paragraph.geometry.as_ref()?;
                let polygon =
                    geometry_polygon(geometry, image_width, chunk_height, chunk_y, image_height)?;
                (!text.is_empty())
                    .then(|| block_from_lines(vec![(text, polygon)], language))
                    .flatten()
            };

            // If any recognized line lacks usable geometry, prefer the complete
            // paragraph-level text and box over silently returning only the
            // siblings that happened to have line geometry.
            if dropped_nonempty_line && let Some(block) = paragraph_fallback() {
                return Some(block);
            }
            if !lines.is_empty() {
                return block_from_lines(lines, language);
            }

            paragraph_fallback()
        })
        .collect()
}

fn block_from_lines(lines: Vec<(String, Polygon)>, language: &str) -> Option<MokuroBlock> {
    if lines.is_empty() {
        return None;
    }

    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    let mut vertical_votes = 0;
    let mut horizontal_votes = 0;
    let mut font_sizes = Vec::with_capacity(lines.len());
    let mut line_text = Vec::with_capacity(lines.len());
    let mut line_polygons = Vec::with_capacity(lines.len());

    for (text, polygon) in lines {
        let [line_min_x, line_min_y, line_max_x, line_max_y] = polygon_bounds(&polygon);
        min_x = min_x.min(line_min_x);
        min_y = min_y.min(line_min_y);
        max_x = max_x.max(line_max_x);
        max_y = max_y.max(line_max_y);

        let width = (line_max_x - line_min_x).unsigned_abs();
        let height = (line_max_y - line_min_y).unsigned_abs();
        if height > width {
            vertical_votes += 1;
        } else if width > height {
            horizontal_votes += 1;
        }
        font_sizes.push(width.min(height).max(1));
        line_text.push(text);
        line_polygons.push(polygon);
    }

    font_sizes.sort_unstable();
    let font_size = font_sizes[font_sizes.len() / 2];
    let vertical = vertical_votes > horizontal_votes
        || (vertical_votes == horizontal_votes && language_prefers_vertical(language));

    Some(MokuroBlock::new(
        [min_x, min_y, max_x, max_y],
        vertical,
        font_size,
        line_polygons,
        line_text,
    ))
}

// The dynamic main/cross-axis grouping model below adapts Manatan's MIT-licensed
// OCR merge logic to Mokuro blocks. See THIRD_PARTY_NOTICES.md and
// licenses/Manatan-MIT.txt in the repository root.
#[derive(Clone, Copy, Debug)]
struct BlockAxes {
    vertical: bool,
    font_size: f64,
    main_min: f64,
    main_max: f64,
    cross_min: f64,
    cross_max: f64,
}

impl BlockAxes {
    fn from_block(block: &MokuroBlock) -> Self {
        let [min_x, min_y, max_x, max_y] = block.box_;
        let mut line_thicknesses: Vec<_> = block
            .lines_coords
            .iter()
            .map(polygon_bounds)
            .map(|[line_min_x, line_min_y, line_max_x, line_max_y]| {
                if block.vertical {
                    (line_max_x - line_min_x).unsigned_abs()
                } else {
                    (line_max_y - line_min_y).unsigned_abs()
                }
            })
            .filter(|thickness| *thickness > 0)
            .collect();
        line_thicknesses.sort_unstable();
        // Lens includes small reading annotations in the same paragraph as
        // main text. A lower median can make two adjacent columns appear to
        // have incompatible font sizes, so use the upper quartile as the
        // representative main-text thickness for grouping only.
        let representative_font = if line_thicknesses.is_empty() {
            block.font_size.max(1)
        } else {
            line_thicknesses[((line_thicknesses.len() * 3 - 1) / 4).min(line_thicknesses.len() - 1)]
        };
        let (main_min, main_max, cross_min, cross_max) = if block.vertical {
            (min_y, max_y, min_x, max_x)
        } else {
            (min_x, max_x, min_y, max_y)
        };
        Self {
            vertical: block.vertical,
            font_size: f64::from(representative_font),
            main_min: f64::from(main_min),
            main_max: f64::from(main_max),
            cross_min: f64::from(cross_min),
            cross_max: f64::from(cross_max),
        }
    }
}

fn interval_gap(first_min: f64, first_max: f64, second_min: f64, second_max: f64) -> f64 {
    (second_min - first_max)
        .max(first_min - second_max)
        .max(0.0)
}

fn is_annotation_punctuation(character: char) -> bool {
    character.is_whitespace()
        || character.is_ascii_punctuation()
        || matches!(
            u32::from(character),
            0x2026 | 0x22EF | 0x3001..=0x303F | 0x30FB..=0x30FC | 0xFF01..=0xFF65
        )
}

fn is_katakana_annotation_character(character: char) -> bool {
    matches!(
        u32::from(character),
        0x30A0..=0x30FF | 0x31F0..=0x31FF | 0xFF66..=0xFF9D
    )
}

fn is_katakana_annotation_modifier(character: char) -> bool {
    matches!(u32::from(character), 0x3099..=0x309C | 0xFF9E..=0xFF9F)
}

fn block_looks_like_short_katakana_annotation(block: &MokuroBlock) -> bool {
    let mut character_count = 0;
    for character in block.lines.iter().flat_map(|line| line.chars()) {
        if is_annotation_punctuation(character) || is_katakana_annotation_modifier(character) {
            continue;
        }
        if !is_katakana_annotation_character(character) {
            return false;
        }
        character_count += 1;
        if character_count > 3 {
            return false;
        }
    }
    (2..=3).contains(&character_count)
}

fn blocks_are_nearby(first: BlockAxes, second: BlockAxes) -> bool {
    if first.vertical != second.vertical {
        return false;
    }

    let smaller_font = first.font_size.min(second.font_size);
    let larger_font = first.font_size.max(second.font_size);
    let font_ratio = larger_font / smaller_font;
    if font_ratio > 1.8 {
        return false;
    }

    let raw_main_overlap =
        first.main_max.min(second.main_max) - first.main_min.max(second.main_min);
    if raw_main_overlap < -smaller_font * 0.5 {
        return false;
    }

    let cross_gap = interval_gap(
        first.cross_min,
        first.cross_max,
        second.cross_min,
        second.cross_max,
    );
    if cross_gap < smaller_font * 0.2 {
        return true;
    }

    let first_length = (first.main_max - first.main_min).max(1.0);
    let second_length = (second.main_max - second.main_min).max(1.0);
    let overlap_ratio = raw_main_overlap.max(0.0) / first_length.max(second_length);

    let mut allowed_cross_gap: f64 = if font_ratio < 1.25 {
        if overlap_ratio > 0.8 {
            1.8
        } else if overlap_ratio > 0.4 {
            0.9
        } else {
            1.1
        }
    } else if overlap_ratio >= 0.5 {
        0.8
    } else {
        0.0
    };

    let length_ratio = first_length.max(second_length) / first_length.min(second_length);
    if length_ratio > 2.5 {
        allowed_cross_gap = allowed_cross_gap.min(0.8);
    }
    if cross_gap > smaller_font * 1.2 && font_ratio > 1.15 {
        return false;
    }
    if cross_gap > smaller_font * allowed_cross_gap {
        return false;
    }

    raw_main_overlap > 0.0
        || interval_gap(
            first.main_min,
            first.main_max,
            second.main_min,
            second.main_max,
        ) <= smaller_font * 0.5
}

struct UnionFind {
    parent: Vec<usize>,
}

impl UnionFind {
    fn new(length: usize) -> Self {
        Self {
            parent: (0..length).collect(),
        }
    }

    fn find(&mut self, index: usize) -> usize {
        if self.parent[index] != index {
            self.parent[index] = self.find(self.parent[index]);
        }
        self.parent[index]
    }

    fn union(&mut self, first: usize, second: usize) {
        let first_root = self.find(first);
        let second_root = self.find(second);
        let (root, child) = if first_root <= second_root {
            (first_root, second_root)
        } else {
            (second_root, first_root)
        };
        self.parent[child] = root;
    }
}

fn line_reading_order(
    first: &(usize, String, Polygon),
    second: &(usize, String, Polygon),
    vertical: bool,
) -> Ordering {
    let first_bounds = polygon_bounds(&first.2);
    let second_bounds = polygon_bounds(&second.2);

    if vertical {
        let first_center_x = i64::from(first_bounds[0]) + i64::from(first_bounds[2]);
        let second_center_x = i64::from(second_bounds[0]) + i64::from(second_bounds[2]);
        let first_width = i64::from((first_bounds[2] - first_bounds[0]).max(1));
        let second_width = i64::from((second_bounds[2] - second_bounds[0]).max(1));
        let same_column_tolerance = first_width.min(second_width) / 2;

        if (first_center_x - second_center_x).abs() > same_column_tolerance {
            return second_center_x
                .cmp(&first_center_x)
                .then_with(|| first_bounds[1].cmp(&second_bounds[1]))
                .then_with(|| first.0.cmp(&second.0));
        }
        first_bounds[1]
            .cmp(&second_bounds[1])
            .then_with(|| second_center_x.cmp(&first_center_x))
            .then_with(|| first.0.cmp(&second.0))
    } else {
        let first_center_y = i64::from(first_bounds[1]) + i64::from(first_bounds[3]);
        let second_center_y = i64::from(second_bounds[1]) + i64::from(second_bounds[3]);
        let first_height = i64::from((first_bounds[3] - first_bounds[1]).max(1));
        let second_height = i64::from((second_bounds[3] - second_bounds[1]).max(1));
        let same_row_tolerance = first_height.min(second_height) / 2;

        if (first_center_y - second_center_y).abs() > same_row_tolerance {
            return first_center_y
                .cmp(&second_center_y)
                .then_with(|| first_bounds[0].cmp(&second_bounds[0]))
                .then_with(|| first.0.cmp(&second.0));
        }
        first_bounds[0]
            .cmp(&second_bounds[0])
            .then_with(|| first_center_y.cmp(&second_center_y))
            .then_with(|| first.0.cmp(&second.0))
    }
}

fn group_nearby_blocks(blocks: Vec<MokuroBlock>, language: &str) -> Vec<MokuroBlock> {
    if blocks.len() < 2 {
        return blocks;
    }

    let axes: Vec<_> = blocks.iter().map(BlockAxes::from_block).collect();
    let short_annotations: Vec<_> = blocks
        .iter()
        .map(block_looks_like_short_katakana_annotation)
        .collect();
    let mut groups = UnionFind::new(blocks.len());
    for first in 0..blocks.len() {
        for second in (first + 1)..blocks.len() {
            // Keep short standalone annotations separate from neighboring
            // text regions while allowing related regions to group.
            if short_annotations[first] != short_annotations[second] {
                continue;
            }
            if blocks_are_nearby(axes[first], axes[second]) {
                groups.union(first, second);
            }
        }
    }

    let mut grouped_indices = BTreeMap::<usize, Vec<usize>>::new();
    for index in 0..blocks.len() {
        let root = groups.find(index);
        grouped_indices.entry(root).or_default().push(index);
    }

    let mut output = Vec::with_capacity(grouped_indices.len());
    for indices in grouped_indices.into_values() {
        if indices.len() == 1 {
            output.push(blocks[indices[0]].clone());
            continue;
        }

        let vertical = blocks[indices[0]].vertical;
        let mut ordered_lines = Vec::new();
        let mut source_order = 0;
        for index in indices {
            let block = &blocks[index];
            for (text, polygon) in block
                .lines
                .iter()
                .cloned()
                .zip(block.lines_coords.iter().copied())
            {
                ordered_lines.push((source_order, text, polygon));
                source_order += 1;
            }
        }
        ordered_lines.sort_by(|first, second| line_reading_order(first, second, vertical));

        let lines = ordered_lines
            .into_iter()
            .map(|(_, text, polygon)| (text, polygon))
            .collect();
        if let Some(mut block) = block_from_lines(lines, language) {
            block.vertical = vertical;
            output.push(block);
        }
    }
    output
}

fn geometry_polygon(
    geometry: &DetectedGeometry,
    image_width: u32,
    chunk_height: u32,
    chunk_y: u32,
    image_height: u32,
) -> Option<Polygon> {
    if ![
        geometry.center_x,
        geometry.center_y,
        geometry.width,
        geometry.height,
        geometry.rotation,
    ]
    .iter()
    .all(|value| value.is_finite())
        || geometry.width <= 0.0
        || geometry.height <= 0.0
    {
        return None;
    }

    let center_x = f64::from(geometry.center_x) * f64::from(image_width);
    let center_y = f64::from(geometry.center_y) * f64::from(chunk_height);
    let half_width = f64::from(geometry.width) * f64::from(image_width) / 2.0;
    let half_height = f64::from(geometry.height) * f64::from(chunk_height) / 2.0;
    let rotation = f64::from(geometry.rotation);
    let cosine = rotation.cos();
    let sine = rotation.sin();
    let local_corners = [
        (-half_width, -half_height),
        (half_width, -half_height),
        (half_width, half_height),
        (-half_width, half_height),
    ];

    Some(local_corners.map(|(local_x, local_y)| {
        let x = local_x.mul_add(cosine, -local_y * sine) + center_x;
        let y = local_x.mul_add(sine, local_y * cosine) + center_y + f64::from(chunk_y);
        [
            rounded_coordinate(x, image_width),
            rounded_coordinate(y, image_height),
        ]
    }))
}

#[allow(clippy::cast_possible_truncation)]
fn rounded_coordinate(value: f64, maximum: u32) -> i32 {
    // Values are finite, rounded, and explicitly bounded to the output type.
    let maximum = maximum.min(i32::MAX as u32);
    value.clamp(0.0, f64::from(maximum)).round() as i32
}

fn polygon_bounds(polygon: &Polygon) -> [i32; 4] {
    polygon.iter().fold(
        [i32::MAX, i32::MAX, i32::MIN, i32::MIN],
        |[min_x, min_y, max_x, max_y], point: &Point| {
            [
                min_x.min(point[0]),
                min_y.min(point[1]),
                max_x.max(point[0]),
                max_y.max(point[1]),
            ]
        },
    )
}

fn clean_text(text: &str, language: &str) -> String {
    if language_prefers_no_spaces(language) {
        text.chars()
            .filter(|character| !character.is_whitespace())
            .collect()
    } else {
        text.split_whitespace().collect::<Vec<_>>().join(" ")
    }
}

fn language_prefers_no_spaces(language: &str) -> bool {
    matches!(primary_language(language), "ja" | "zh" | "yue")
}

fn language_prefers_vertical(language: &str) -> bool {
    matches!(primary_language(language), "ja" | "zh" | "yue")
}

fn primary_language(language: &str) -> &str {
    language.split(['-', '_']).next().unwrap_or(language)
}

fn detected_paragraph(paragraph: &Paragraph) -> DetectedParagraph {
    DetectedParagraph {
        text: paragraph.text.clone(),
        geometry: paragraph.geometry.as_ref().map(detected_geometry),
        lines: paragraph
            .lines
            .iter()
            .map(|line| DetectedLine {
                text: line.text.clone(),
                geometry: line.geometry.as_ref().map(detected_geometry),
            })
            .collect(),
    }
}

fn detected_geometry(geometry: &GeometryData) -> DetectedGeometry {
    DetectedGeometry {
        center_x: geometry.center_x,
        center_y: geometry.center_y,
        width: geometry.width,
        height: geometry.height,
        rotation: geometry.rotation_z,
    }
}

fn encode_chunk(image: &DynamicImage, chunk_y: u32, chunk_height: u32) -> Result<Vec<u8>> {
    let chunk = image.crop_imm(0, chunk_y, image.width(), chunk_height);
    let mut cursor = Cursor::new(Vec::new());
    chunk
        .write_to(&mut cursor, ImageFormat::Png)
        .context("failed to encode image chunk as PNG")?;
    Ok(cursor.into_inner())
}

async fn request_with_retry(
    client: &LensClient,
    image_bytes: &[u8],
    language: &str,
) -> Result<chrome_lens_ocr::LensResult> {
    let mut last_error = None;
    for retry in 0..=MAX_REQUEST_RETRIES {
        let attempt_started = Instant::now();
        match client
            .process_image_bytes(image_bytes, Some(language))
            .await
        {
            Ok(response) => return Ok(response),
            Err(error) => {
                eprintln!(
                    "Manga OCR Lens attempt {}/{} failed after {} ms: {error:#}",
                    retry + 1,
                    MAX_REQUEST_RETRIES + 1,
                    attempt_started.elapsed().as_millis(),
                );
                last_error = Some(error);
                if retry < MAX_REQUEST_RETRIES {
                    let backoff_multiplier = u64::try_from(retry + 1).unwrap_or(1);
                    tokio::time::sleep(Duration::from_millis(500 * backoff_multiplier)).await;
                }
            }
        }
    }

    Err(last_error.unwrap_or_else(|| anyhow!("OCR request failed without an error")))
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use image::{DynamicImage, ImageFormat};
    use serde_json::json;

    use super::{
        DetectedGeometry, DetectedLine, DetectedParagraph,
        block_looks_like_short_katakana_annotation, blocks_from_paragraphs, group_nearby_blocks,
        image_dimensions,
    };
    use crate::model::{MOKURO_FORMAT_VERSION, MokuroBlock, MokuroPage, Polygon};

    fn polygon(points: [[i32; 2]; 4]) -> Polygon {
        points
    }

    fn one_line_paragraph(
        text: &str,
        center_x: f32,
        center_y: f32,
        width: f32,
        height: f32,
    ) -> DetectedParagraph {
        DetectedParagraph {
            text: text.to_owned(),
            geometry: None,
            lines: vec![DetectedLine {
                text: text.to_owned(),
                geometry: Some(DetectedGeometry {
                    center_x,
                    center_y,
                    width,
                    height,
                    rotation: 0.0,
                }),
            }],
        }
    }

    #[test]
    fn reads_page_dimensions_from_the_image_header() {
        let image = DynamicImage::new_rgb8(37, 53);
        let mut encoded = Cursor::new(Vec::new());
        image
            .write_to(&mut encoded, ImageFormat::Png)
            .expect("encode test image");

        assert_eq!(
            image_dimensions(encoded.get_ref()).expect("read dimensions"),
            (37, 53)
        );
        assert!(image_dimensions(b"not an image").is_err());
    }

    #[test]
    fn groups_lens_lines_into_one_upstream_mokuro_block() {
        let paragraph = DetectedParagraph {
            text: "日 本 語\nです".to_owned(),
            geometry: None,
            lines: vec![
                DetectedLine {
                    text: "日 本 語".to_owned(),
                    geometry: Some(DetectedGeometry {
                        center_x: 0.8,
                        center_y: 0.3,
                        width: 0.1,
                        height: 0.3,
                        rotation: 0.0,
                    }),
                },
                DetectedLine {
                    text: "で す".to_owned(),
                    geometry: Some(DetectedGeometry {
                        center_x: 0.68,
                        center_y: 0.3,
                        width: 0.1,
                        height: 0.25,
                        rotation: 0.0,
                    }),
                },
            ],
        };

        let blocks = blocks_from_paragraphs(&[paragraph], 1_000, 2_000, 0, 2_000, "ja");
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].lines, vec!["日本語", "です"]);
        assert_eq!(blocks[0].lines_coords.len(), 2);
        assert!(blocks[0].vertical);

        let page = MokuroPage {
            version: MOKURO_FORMAT_VERSION.to_owned(),
            img_path: "pages/001.jpg".to_owned(),
            img_width: 1_000,
            img_height: 2_000,
            blocks,
        };
        let value = serde_json::to_value(page).expect("serialize page");
        assert_eq!(value["img_path"], json!("pages/001.jpg"));
        assert!(value["blocks"][0].get("box").is_some());
        assert!(value["blocks"][0].get("box_").is_none());
        assert_eq!(
            value["blocks"][0]["lines_coords"].as_array().map(Vec::len),
            Some(2)
        );
    }

    #[test]
    fn preserves_complete_paragraph_when_one_line_lacks_geometry() {
        let paragraph = DetectedParagraph {
            text: "右列\n左列".to_owned(),
            geometry: Some(DetectedGeometry {
                center_x: 0.5,
                center_y: 0.3,
                width: 0.2,
                height: 0.3,
                rotation: 0.0,
            }),
            lines: vec![
                DetectedLine {
                    text: "右列".to_owned(),
                    geometry: Some(DetectedGeometry {
                        center_x: 0.55,
                        center_y: 0.3,
                        width: 0.08,
                        height: 0.2,
                        rotation: 0.0,
                    }),
                },
                DetectedLine {
                    text: "左列".to_owned(),
                    geometry: None,
                },
            ],
        };

        let blocks = blocks_from_paragraphs(&[paragraph], 1_000, 2_000, 0, 2_000, "ja");

        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].lines, ["右列左列"]);
        assert_eq!(blocks[0].box_, [400, 300, 600, 900]);
    }

    #[test]
    fn applies_chunk_offset_to_line_coordinates() {
        let paragraph = DetectedParagraph {
            text: "text".to_owned(),
            geometry: Some(DetectedGeometry {
                center_x: 0.5,
                center_y: 0.5,
                width: 0.2,
                height: 0.2,
                rotation: 0.0,
            }),
            lines: Vec::new(),
        };

        let blocks = blocks_from_paragraphs(&[paragraph], 1_000, 1_000, 3_000, 4_000, "en");
        assert_eq!(blocks[0].box_, [400, 3_400, 600, 3_600]);
    }

    #[test]
    fn groups_nearby_vertical_paragraphs_in_right_to_left_order() {
        let paragraphs = [
            one_line_paragraph("左", 0.64, 0.35, 0.08, 0.25),
            one_line_paragraph("右", 0.76, 0.35, 0.08, 0.25),
        ];
        let raw = blocks_from_paragraphs(&paragraphs, 1_000, 2_000, 0, 2_000, "ja");
        assert_eq!(raw.len(), 2);

        let grouped = group_nearby_blocks(raw, "ja");
        assert_eq!(grouped.len(), 1);
        assert_eq!(grouped[0].lines, ["右", "左"]);
        assert_eq!(grouped[0].lines.len(), grouped[0].lines_coords.len());
        assert!(grouped[0].vertical);
    }

    #[test]
    fn recognizes_short_katakana_annotations_by_structure() {
        let block = |text: &str| {
            MokuroBlock::new([0, 0, 10, 10], true, 10, Vec::new(), vec![text.to_owned()])
        };

        assert!(block_looks_like_short_katakana_annotation(&block(
            "\u{30A2}\u{30A4}"
        )));
        assert!(block_looks_like_short_katakana_annotation(&block(
            "\u{30A2}\u{30A4}\u{30A6}"
        )));
        assert!(!block_looks_like_short_katakana_annotation(&block(
            "\u{30A2}"
        )));
        assert!(!block_looks_like_short_katakana_annotation(&block(
            "\u{30A2}\u{30A4}\u{30A6}\u{30A8}"
        )));
        assert!(!block_looks_like_short_katakana_annotation(&block(
            "\u{30A2}\u{7532}"
        )));
    }

    #[test]
    fn groups_adjacent_vertical_blocks_with_irregular_geometry() {
        let blocks = vec![
            MokuroBlock::new(
                [82, 10, 102, 185],
                true,
                20,
                vec![polygon([[82, 10], [101, 10], [102, 185], [82, 185]])],
                vec!["一".to_owned()],
            ),
            MokuroBlock::new(
                [8, 5, 67, 198],
                true,
                25,
                vec![
                    polygon([[42, 9], [66, 9], [67, 198], [42, 198]]),
                    polygon([[8, 5], [29, 5], [29, 56], [8, 56]]),
                ],
                vec!["二".to_owned(), "三".to_owned()],
            ),
        ];

        let grouped = group_nearby_blocks(blocks, "ja");

        assert_eq!(grouped.len(), 1);
        assert_eq!(grouped[0].lines, ["一", "二", "三"]);
        assert_eq!(grouped[0].box_, [8, 5, 102, 198]);
    }

    #[test]
    fn groups_multiple_vertical_blocks_in_reading_order() {
        let blocks = vec![
            MokuroBlock::new(
                [67, 17, 200, 425],
                true,
                22,
                vec![
                    polygon([[178, 201], [200, 201], [200, 278], [178, 278]]),
                    polygon([[181, 326], [195, 326], [195, 342], [181, 342]]),
                    polygon([[141, 22], [178, 22], [181, 425], [144, 425]]),
                    polygon([[86, 22], [125, 22], [126, 313], [87, 313]]),
                    polygon([[71, 17], [90, 17], [90, 59], [71, 59]]),
                    polygon([[67, 249], [86, 249], [86, 317], [67, 317]]),
                ],
                vec![
                    "一".to_owned(),
                    "二".to_owned(),
                    "三".to_owned(),
                    "四".to_owned(),
                    "五".to_owned(),
                    "六".to_owned(),
                ],
            ),
            MokuroBlock::new(
                [32, 18, 68, 313],
                true,
                36,
                vec![polygon([[32, 18], [68, 18], [68, 313], [32, 313]])],
                vec!["七".to_owned()],
            ),
        ];

        let grouped = group_nearby_blocks(blocks, "ja");

        assert_eq!(grouped.len(), 1);
        assert_eq!(grouped[0].lines, ["一", "二", "三", "四", "五", "六", "七"]);
        assert_eq!(grouped[0].box_, [32, 17, 200, 425]);
    }

    #[test]
    fn groups_adjacent_columns_using_main_text_thickness() {
        let blocks = vec![
            MokuroBlock::new(
                [80, 20, 140, 170],
                true,
                26,
                vec![
                    polygon([[128, 20], [140, 20], [140, 45], [128, 45]]),
                    polygon([[105, 20], [130, 20], [130, 165], [105, 165]]),
                    polygon([[92, 65], [104, 65], [104, 105], [92, 105]]),
                    polygon([[80, 20], [106, 20], [106, 145], [80, 145]]),
                ],
                vec![
                    "よみ".to_owned(),
                    "本文一".to_owned(),
                    "かな".to_owned(),
                    "本文二".to_owned(),
                ],
            ),
            MokuroBlock::new(
                [40, 22, 80, 200],
                true,
                12,
                vec![
                    polygon([[68, 22], [80, 22], [80, 45], [68, 45]]),
                    polygon([[69, 140], [79, 140], [79, 165], [69, 165]]),
                    polygon([[40, 25], [68, 25], [68, 200], [40, 200]]),
                ],
                vec!["よみ".to_owned(), "かな".to_owned(), "本文三".to_owned()],
            ),
        ];

        let grouped = group_nearby_blocks(blocks, "ja");

        assert_eq!(grouped.len(), 1);
        assert_eq!(
            grouped[0].lines,
            ["よみ", "本文一", "かな", "本文二", "よみ", "かな", "本文三"]
        );
    }

    #[test]
    fn keeps_short_annotation_separate_while_grouping_nearby_text() {
        let blocks = vec![
            MokuroBlock::new(
                [0, 0, 42, 84],
                true,
                42,
                vec![polygon([[41, 0], [42, 84], [1, 84], [0, 0]])],
                vec!["アア".to_owned()],
            ),
            MokuroBlock::new(
                [0, 83, 43, 241],
                true,
                43,
                vec![polygon([[42, 83], [43, 241], [1, 241], [0, 83]])],
                vec!["本文二".to_owned()],
            ),
            MokuroBlock::new(
                [53, 105, 79, 184],
                true,
                26,
                vec![polygon([[53, 105], [79, 105], [79, 184], [53, 184]])],
                vec!["本文一".to_owned()],
            ),
        ];

        let grouped = group_nearby_blocks(blocks, "ja");

        assert_eq!(grouped.len(), 2);
        assert!(grouped.iter().any(|block| block.lines == ["アア"]));
        assert!(
            grouped
                .iter()
                .any(|block| block.lines == ["本文一", "本文二"])
        );
    }

    #[test]
    fn groups_nearby_horizontal_paragraphs_in_top_to_bottom_order() {
        let paragraphs = [
            one_line_paragraph("world", 0.5, 0.42, 0.4, 0.05),
            one_line_paragraph("Hello", 0.5, 0.34, 0.4, 0.05),
        ];
        let raw = blocks_from_paragraphs(&paragraphs, 1_000, 1_000, 0, 1_000, "en");
        assert_eq!(raw.len(), 2);

        let grouped = group_nearby_blocks(raw, "en");
        assert_eq!(grouped.len(), 1);
        assert_eq!(grouped[0].lines, ["Hello", "world"]);
        assert!(!grouped[0].vertical);
    }

    #[test]
    fn leaves_distant_and_mixed_orientation_text_separate() {
        let distant_vertical = [
            one_line_paragraph("右", 0.82, 0.3, 0.08, 0.25),
            one_line_paragraph("左", 0.42, 0.3, 0.08, 0.25),
        ];
        let raw = blocks_from_paragraphs(&distant_vertical, 1_000, 2_000, 0, 2_000, "ja");
        assert_eq!(group_nearby_blocks(raw, "ja").len(), 2);

        let mixed = [
            one_line_paragraph("縦", 0.55, 0.4, 0.07, 0.2),
            one_line_paragraph("horizontal", 0.55, 0.4, 0.25, 0.04),
        ];
        let raw = blocks_from_paragraphs(&mixed, 1_000, 1_000, 0, 1_000, "ja");
        assert_eq!(group_nearby_blocks(raw, "ja").len(), 2);
    }

    #[test]
    fn leaves_small_furigana_sized_text_separate() {
        let paragraphs = [
            one_line_paragraph("漢字", 0.70, 0.35, 0.10, 0.30),
            one_line_paragraph("かんじ", 0.76, 0.35, 0.04, 0.25),
        ];
        let raw = blocks_from_paragraphs(&paragraphs, 1_000, 2_000, 0, 2_000, "ja");
        assert_eq!(group_nearby_blocks(raw, "ja").len(), 2);
    }

    #[test]
    fn groups_same_column_fragments_across_chunk_boundary() {
        let upper = blocks_from_paragraphs(
            &[one_line_paragraph("前半", 0.7, 0.99, 0.08, 0.02)],
            1_000,
            3_000,
            0,
            6_000,
            "ja",
        );
        let lower = blocks_from_paragraphs(
            &[one_line_paragraph("後半", 0.7, 0.01, 0.08, 0.02)],
            1_000,
            3_000,
            3_000,
            6_000,
            "ja",
        );
        let grouped = group_nearby_blocks(upper.into_iter().chain(lower).collect(), "ja");

        assert_eq!(grouped.len(), 1);
        assert_eq!(grouped[0].lines, ["前半", "後半"]);
        assert_eq!(grouped[0].box_, [660, 2_940, 740, 3_060]);
    }
}

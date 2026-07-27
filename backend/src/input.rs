use std::{
    collections::HashSet,
    fs,
    io::Cursor,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use image::{ImageFormat, ImageReader};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use zip::ZipArchive;

use crate::archive::{self, ArchiveManifest};

pub const ZIP_FINGERPRINT_ALGORITHM: &str = "sha256:zip-image-manifest-v1";
pub const RASTER_FINGERPRINT_ALGORITHM: &str = "sha256:raster-image-v1";
pub const RENDERED_FINGERPRINT_ALGORITHM: &str = "koreader:partial-md5:fixed-layout-render-v1";

const RENDERED_MANIFEST_VERSION: u32 = 1;
const MAX_RENDERED_PAGE_COUNT: usize = 10_000;
const MAX_RENDERED_MANIFEST_SIZE: u64 = 1_048_576;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageEntry {
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputManifest {
    pub source_size: u64,
    pub fingerprint_algorithm: String,
    pub fingerprint: String,
    pub entries: Vec<PageEntry>,
}

pub struct InputSource {
    manifest: InputManifest,
    reader: PageReader,
}

enum PageReader {
    Archive {
        archive: ZipArchive<fs::File>,
        entries: Vec<archive::ImageEntry>,
    },
    SingleImage(Vec<u8>),
    Rendered(Vec<Option<PathBuf>>),
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RenderedPagesManifest {
    version: u32,
    source_fingerprint: String,
    source_size: u64,
    page_count: usize,
    pages: Vec<RenderedPage>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RenderedPage {
    index: usize,
    path: PathBuf,
}

/// Open an archive, a directly supported raster image, or a rendered-page
/// manifest while keeping the original document as the cache identity.
///
/// # Errors
///
/// Returns an error when the input is unreadable, unsupported, or inconsistent
/// with the rendered-page manifest.
pub fn open_input(input: &Path, rendered_pages: Option<&Path>) -> Result<InputSource> {
    if let Some(manifest_path) = rendered_pages {
        return open_rendered_input(input, manifest_path);
    }

    if let Some(source) = open_direct_image(input)? {
        return Ok(source);
    }

    let (archive, archive_manifest) = archive::open_archive(input).with_context(|| {
        format!(
            "{} is neither a supported raster image nor a readable CBZ/ZIP archive; \
             other document formats require --rendered-pages",
            input.display()
        )
    })?;
    Ok(from_archive(archive, archive_manifest))
}

impl InputSource {
    #[must_use]
    pub fn manifest(&self) -> &InputManifest {
        &self.manifest
    }

    #[must_use]
    pub(crate) fn rendered_page_paths(&self) -> Option<&[Option<PathBuf>]> {
        match &self.reader {
            PageReader::Rendered(paths) => Some(paths),
            PageReader::Archive { .. } | PageReader::SingleImage(_) => None,
        }
    }

    /// Ensure every pending zero-based page has an available source image.
    ///
    /// # Errors
    ///
    /// Returns an error for an out-of-range page, a sparse rendered manifest
    /// that omits a requested page, or a mapped path that is not a regular
    /// file.
    pub fn ensure_pages_available(&self, pages: &[usize]) -> Result<()> {
        for &index in pages {
            let entry = self
                .manifest
                .entries
                .get(index)
                .ok_or_else(|| anyhow::anyhow!("page {} is outside the input", index + 1))?;
            if let PageReader::Rendered(paths) = &self.reader {
                let path = paths.get(index).and_then(Option::as_ref).ok_or_else(|| {
                    anyhow::anyhow!(
                        "rendered-page manifest has no image for requested page {}",
                        index + 1
                    )
                })?;
                let metadata = fs::metadata(path).with_context(|| {
                    format!(
                        "failed to inspect rendered image for page {} at {}",
                        index + 1,
                        path.display()
                    )
                })?;
                if !metadata.is_file() {
                    bail!(
                        "rendered image for page {} is not a regular file: {}",
                        index + 1,
                        path.display()
                    );
                }
            }
            debug_assert!(!entry.path.is_empty());
        }
        Ok(())
    }

    /// Read one zero-based page into memory.
    ///
    /// # Errors
    ///
    /// Returns an error when the page is unavailable, unreadable, cannot be
    /// extracted, or is not a raster format supported by the worker.
    pub fn read_page(&mut self, index: usize) -> Result<Vec<u8>> {
        match &mut self.reader {
            PageReader::Archive { archive, entries } => {
                let entry = entries
                    .get(index)
                    .ok_or_else(|| anyhow::anyhow!("page {} is outside the archive", index + 1))?;
                archive::read_image_entry(archive, entry)
            }
            PageReader::SingleImage(bytes) => {
                if index != 0 {
                    bail!("page {} is outside the single-image input", index + 1);
                }
                Ok(bytes.clone())
            }
            PageReader::Rendered(paths) => {
                let path = paths.get(index).and_then(Option::as_ref).ok_or_else(|| {
                    anyhow::anyhow!(
                        "rendered-page manifest has no image for requested page {}",
                        index + 1
                    )
                })?;
                let bytes = fs::read(path).with_context(|| {
                    format!(
                        "failed to read rendered image for page {} at {}",
                        index + 1,
                        path.display()
                    )
                })?;
                ensure_supported_raster(&bytes).with_context(|| {
                    format!(
                        "rendered image for page {} is not a supported raster image: {}",
                        index + 1,
                        path.display()
                    )
                })?;
                Ok(bytes)
            }
        }
    }
}

fn from_archive(archive: ZipArchive<fs::File>, archive_manifest: ArchiveManifest) -> InputSource {
    let entries = archive_manifest
        .entries
        .iter()
        .map(|entry| PageEntry {
            path: entry.path.clone(),
        })
        .collect();
    InputSource {
        manifest: InputManifest {
            source_size: archive_manifest.archive_size,
            fingerprint_algorithm: ZIP_FINGERPRINT_ALGORITHM.to_owned(),
            fingerprint: archive_manifest.fingerprint,
            entries,
        },
        reader: PageReader::Archive {
            archive,
            entries: archive_manifest.entries,
        },
    }
}

fn open_direct_image(path: &Path) -> Result<Option<InputSource>> {
    let reader = ImageReader::open(path)
        .with_context(|| format!("failed to open input document {}", path.display()))?
        .with_guessed_format()
        .with_context(|| format!("failed to identify input format {}", path.display()))?;
    let Some(format) = reader.format() else {
        return Ok(None);
    };
    if !supported_raster_format(format) {
        return Ok(None);
    }

    let bytes =
        fs::read(path).with_context(|| format!("failed to read input image {}", path.display()))?;
    ensure_supported_raster(&bytes)
        .with_context(|| format!("failed to identify input image {}", path.display()))?;
    let source_size = u64::try_from(bytes.len()).context("input image is too large")?;
    let path_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("page-000001.png")
        .to_owned();

    let mut hasher = Sha256::new();
    hasher.update(b"mangaocr:raster-image:v1\0");
    hasher.update(&bytes);

    Ok(Some(InputSource {
        manifest: InputManifest {
            source_size,
            fingerprint_algorithm: RASTER_FINGERPRINT_ALGORITHM.to_owned(),
            fingerprint: hex_digest(hasher.finalize().as_slice()),
            entries: vec![PageEntry { path: path_name }],
        },
        reader: PageReader::SingleImage(bytes),
    }))
}

fn open_rendered_input(input: &Path, manifest_path: &Path) -> Result<InputSource> {
    let input_metadata = fs::metadata(input)
        .with_context(|| format!("failed to inspect input document {}", input.display()))?;
    if !input_metadata.is_file() {
        bail!("input document is not a regular file: {}", input.display());
    }

    let manifest_metadata = fs::metadata(manifest_path).with_context(|| {
        format!(
            "failed to inspect rendered-page manifest {}",
            manifest_path.display()
        )
    })?;
    if !manifest_metadata.is_file() {
        bail!(
            "rendered-page manifest is not a regular file: {}",
            manifest_path.display()
        );
    }
    if manifest_metadata.len() > MAX_RENDERED_MANIFEST_SIZE {
        bail!("rendered-page manifest exceeds the {MAX_RENDERED_MANIFEST_SIZE}-byte size limit");
    }

    let bytes = fs::read(manifest_path).with_context(|| {
        format!(
            "failed to read rendered-page manifest {}",
            manifest_path.display()
        )
    })?;
    let rendered: RenderedPagesManifest = serde_json::from_slice(&bytes).with_context(|| {
        format!(
            "failed to parse rendered-page manifest {}",
            manifest_path.display()
        )
    })?;

    if rendered.version != RENDERED_MANIFEST_VERSION {
        bail!(
            "unsupported rendered-page manifest version {}; expected {}",
            rendered.version,
            RENDERED_MANIFEST_VERSION
        );
    }
    if !(1..=MAX_RENDERED_PAGE_COUNT).contains(&rendered.page_count) {
        bail!("rendered-page manifest page_count must be in 1..={MAX_RENDERED_PAGE_COUNT}");
    }
    if rendered.source_size != input_metadata.len() {
        bail!(
            "rendered-page manifest source_size {} does not match input size {}",
            rendered.source_size,
            input_metadata.len()
        );
    }
    if rendered.source_fingerprint.is_empty()
        || rendered.source_fingerprint.len() > 256
        || rendered.source_fingerprint.chars().any(char::is_control)
    {
        bail!("rendered-page manifest source_fingerprint is invalid");
    }

    let base_directory = manifest_path.parent().unwrap_or_else(|| Path::new("."));
    let mut seen = HashSet::new();
    let mut paths = vec![None; rendered.page_count];
    for page in rendered.pages {
        if !(1..=rendered.page_count).contains(&page.index) {
            bail!(
                "rendered-page index {} is outside 1..={}",
                page.index,
                rendered.page_count
            );
        }
        if !seen.insert(page.index) {
            bail!("rendered-page index {} appears more than once", page.index);
        }
        if page.path.as_os_str().is_empty() {
            bail!("rendered-page index {} has an empty path", page.index);
        }
        let resolved = if page.path.is_absolute() {
            page.path
        } else {
            base_directory.join(page.path)
        };
        paths[page.index - 1] = Some(resolved);
    }

    let entries = (1..=rendered.page_count)
        .map(|index| PageEntry {
            path: format!("page-{index:06}.png"),
        })
        .collect();
    Ok(InputSource {
        manifest: InputManifest {
            source_size: rendered.source_size,
            fingerprint_algorithm: RENDERED_FINGERPRINT_ALGORITHM.to_owned(),
            fingerprint: rendered.source_fingerprint,
            entries,
        },
        reader: PageReader::Rendered(paths),
    })
}

fn ensure_supported_raster(bytes: &[u8]) -> Result<ImageFormat> {
    let format = image::guess_format(bytes).context("failed to identify raster image format")?;
    if !supported_raster_format(format) {
        bail!("unsupported raster image format {format:?}");
    }
    // Validate the header without decoding the complete image.
    ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .context("failed to identify raster image format")?
        .into_dimensions()
        .context("failed to read raster image dimensions")?;
    Ok(format)
}

fn supported_raster_format(format: ImageFormat) -> bool {
    matches!(
        format,
        ImageFormat::Bmp | ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::Pnm
    )
}

fn hex_digest(bytes: &[u8]) -> String {
    use std::fmt::Write as _;

    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        io::{Cursor, Write},
    };

    use image::{DynamicImage, ImageFormat};
    use serde_json::json;
    use tempfile::tempdir;
    use zip::{ZipWriter, write::SimpleFileOptions};

    use crate::archive;

    use super::{
        RASTER_FINGERPRINT_ALGORITHM, RENDERED_FINGERPRINT_ALGORITHM, ZIP_FINGERPRINT_ALGORITHM,
        open_input,
    };

    fn png_bytes(width: u32, height: u32) -> Vec<u8> {
        let image = DynamicImage::new_luma8(width, height);
        let mut output = Cursor::new(Vec::new());
        image
            .write_to(&mut output, ImageFormat::Png)
            .expect("encode PNG");
        output.into_inner()
    }

    #[test]
    fn standalone_image_is_one_page_and_fingerprints_original_bytes() {
        let directory = tempdir().expect("temporary directory");
        let input = directory.path().join("page");
        let first_bytes = png_bytes(3, 5);
        fs::write(&input, &first_bytes).expect("write first image");

        let mut first = open_input(&input, None).expect("open direct image");
        assert_eq!(first.manifest().entries.len(), 1);
        assert_eq!(first.manifest().entries[0].path, "page");
        assert_eq!(
            first.manifest().fingerprint_algorithm,
            RASTER_FINGERPRINT_ALGORITHM
        );
        assert_eq!(first.read_page(0).expect("read image"), first_bytes);
        let first_fingerprint = first.manifest().fingerprint.clone();

        fs::write(&input, png_bytes(4, 5)).expect("replace image");
        let second = open_input(&input, None).expect("reopen direct image");
        assert_ne!(second.manifest().fingerprint, first_fingerprint);
    }

    #[test]
    fn rendered_manifest_preserves_sparse_ordinals_and_relative_paths() {
        let directory = tempdir().expect("temporary directory");
        let input = directory.path().join("document.pdf");
        fs::write(&input, b"source").expect("write source");
        let rendered_path = directory.path().join("middle.png");
        let rendered_bytes = png_bytes(4, 6);
        fs::write(&rendered_path, &rendered_bytes).expect("write rendered image");
        let manifest_path = directory.path().join("pages.json");
        fs::write(
            &manifest_path,
            serde_json::to_vec(&json!({
                "version": 1,
                "source_fingerprint": "stable-partial-digest",
                "source_size": 6,
                "page_count": 3,
                "pages": [{"index": 2, "path": "middle.png"}],
            }))
            .expect("encode manifest"),
        )
        .expect("write manifest");

        let mut source = open_input(&input, Some(&manifest_path)).expect("open rendered manifest");
        assert_eq!(source.manifest().entries.len(), 3);
        assert_eq!(source.manifest().entries[0].path, "page-000001.png");
        assert_eq!(source.manifest().entries[1].path, "page-000002.png");
        assert_eq!(source.manifest().entries[2].path, "page-000003.png");
        assert_eq!(
            source.manifest().fingerprint_algorithm,
            RENDERED_FINGERPRINT_ALGORITHM
        );
        source
            .ensure_pages_available(&[1])
            .expect("mapped page is available");
        assert!(source.ensure_pages_available(&[0]).is_err());
        assert_eq!(
            source.read_page(1).expect("read rendered page"),
            rendered_bytes
        );
    }

    #[test]
    fn rendered_identity_ignores_temporary_image_path() {
        let directory = tempdir().expect("temporary directory");
        let input = directory.path().join("document.pdf");
        fs::write(&input, b"source").expect("write source");
        fs::write(directory.path().join("first.png"), png_bytes(2, 3))
            .expect("write first rendered image");
        fs::write(directory.path().join("second.png"), png_bytes(3, 2))
            .expect("write second rendered image");

        let open_manifest = |name: &str, rendered_path: &str| {
            let path = directory.path().join(name);
            fs::write(
                &path,
                serde_json::to_vec(&json!({
                    "version": 1,
                    "source_fingerprint": "same-source",
                    "source_size": 6,
                    "page_count": 1,
                    "pages": [{"index": 1, "path": rendered_path}],
                }))
                .expect("encode manifest"),
            )
            .expect("write manifest");
            open_input(&input, Some(&path)).expect("open manifest")
        };

        let first = open_manifest("first.json", "first.png");
        let second = open_manifest("second.json", "second.png");
        assert_eq!(first.manifest(), second.manifest());
    }

    #[test]
    fn rendered_manifest_rejects_invalid_count_indices_duplicates_and_source_size() {
        let directory = tempdir().expect("temporary directory");
        let input = directory.path().join("document.pdf");
        fs::write(&input, b"source").expect("write source");

        for (name, value) in [
            (
                "zero.json",
                json!({
                    "version": 1,
                    "source_fingerprint": "digest",
                    "source_size": 6,
                    "page_count": 2,
                    "pages": [{"index": 0, "path": "page.png"}],
                }),
            ),
            (
                "duplicate.json",
                json!({
                    "version": 1,
                    "source_fingerprint": "digest",
                    "source_size": 6,
                    "page_count": 2,
                    "pages": [
                        {"index": 1, "path": "one.png"},
                        {"index": 1, "path": "two.png"}
                    ],
                }),
            ),
            (
                "range.json",
                json!({
                    "version": 1,
                    "source_fingerprint": "digest",
                    "source_size": 6,
                    "page_count": 2,
                    "pages": [{"index": 3, "path": "page.png"}],
                }),
            ),
            (
                "count.json",
                json!({
                    "version": 1,
                    "source_fingerprint": "digest",
                    "source_size": 6,
                    "page_count": 0,
                    "pages": [],
                }),
            ),
            (
                "oversized-count.json",
                json!({
                    "version": 1,
                    "source_fingerprint": "digest",
                    "source_size": 6,
                    "page_count": 10_001,
                    "pages": [],
                }),
            ),
            (
                "size.json",
                json!({
                    "version": 1,
                    "source_fingerprint": "digest",
                    "source_size": 7,
                    "page_count": 2,
                    "pages": [],
                }),
            ),
        ] {
            let manifest = directory.path().join(name);
            fs::write(
                &manifest,
                serde_json::to_vec(&value).expect("encode manifest"),
            )
            .expect("write manifest");
            assert!(open_input(&input, Some(&manifest)).is_err());
        }
    }

    #[test]
    fn zip_keeps_legacy_manifest_fingerprint_and_page_order() {
        let directory = tempdir().expect("temporary directory");
        let input = directory.path().join("volume.cbz");
        let file = fs::File::create(&input).expect("create ZIP");
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        for path in ["page10.jpg", "page2.jpg"] {
            writer.start_file(path, options).expect("start ZIP entry");
            writer.write_all(b"image bytes").expect("write ZIP entry");
        }
        writer.finish().expect("finish ZIP");

        let (_, legacy_manifest) = archive::open_archive(&input).expect("open legacy ZIP");
        let source = open_input(&input, None).expect("open ZIP");
        assert_eq!(
            source.manifest().fingerprint_algorithm,
            ZIP_FINGERPRINT_ALGORITHM
        );
        assert_eq!(source.manifest().source_size, legacy_manifest.archive_size);
        assert_eq!(source.manifest().fingerprint, legacy_manifest.fingerprint);
        assert_eq!(
            source
                .manifest()
                .entries
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            ["page2.jpg", "page10.jpg"]
        );
        assert_eq!(source.manifest().fingerprint.len(), 64);
    }
}

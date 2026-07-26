use std::{
    fmt::Write as _,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::archive::ArchiveManifest;

pub const MOKURO_FORMAT_VERSION: &str = "0.2.0";
pub const INTEGRATION_SCHEMA_VERSION: u32 = 1;
pub const OCR_ENGINE_NAME: &str = "chrome_lens_ocr";
pub const OCR_ENGINE_VERSION: &str = "0.3.0";

pub type Point = [i32; 2];
pub type Polygon = [Point; 4];

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct MokuroDocument {
    pub version: String,
    pub title: String,
    pub title_uuid: String,
    pub volume: String,
    pub volume_uuid: String,
    pub pages: Vec<Option<MokuroPage>>,
    pub mangaocr: MangaOcrMetadata,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct MokuroPage {
    pub version: String,
    pub img_path: String,
    pub img_width: u32,
    pub img_height: u32,
    pub blocks: Vec<MokuroBlock>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct MokuroBlock {
    #[serde(rename = "box")]
    pub box_: [i32; 4],
    pub vertical: bool,
    pub font_size: u32,
    pub lines_coords: Vec<Polygon>,
    pub lines: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct MangaOcrMetadata {
    pub schema_version: u32,
    pub source: SourceMetadata,
    pub engine: EngineMetadata,
    pub language: String,
    #[serde(default)]
    pub failed_pages: Vec<FailedPage>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct FailedPage {
    /// One-based index in the naturally sorted archive image list.
    pub index: usize,
    pub img_path: String,
    pub error: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct SourceMetadata {
    pub fingerprint_algorithm: String,
    pub fingerprint: String,
    pub archive_size: u64,
    pub image_count: usize,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct EngineMetadata {
    pub name: String,
    pub version: String,
}

impl MokuroDocument {
    #[must_use]
    pub fn empty(input: &Path, manifest: &ArchiveManifest, language: &str) -> Self {
        let volume = path_display_name(input);
        let title = input
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .filter(|name| !name.is_empty())
            .map_or_else(|| volume.clone(), ToOwned::to_owned);

        Self {
            version: MOKURO_FORMAT_VERSION.to_owned(),
            title_uuid: deterministic_uuid("title", &manifest.fingerprint),
            volume_uuid: deterministic_uuid("volume", &manifest.fingerprint),
            title,
            volume,
            pages: vec![None; manifest.entries.len()],
            mangaocr: MangaOcrMetadata {
                schema_version: INTEGRATION_SCHEMA_VERSION,
                source: SourceMetadata {
                    fingerprint_algorithm: "sha256:zip-image-manifest-v1".to_owned(),
                    fingerprint: manifest.fingerprint.clone(),
                    archive_size: manifest.archive_size,
                    image_count: manifest.entries.len(),
                },
                engine: EngineMetadata {
                    name: OCR_ENGINE_NAME.to_owned(),
                    version: OCR_ENGINE_VERSION.to_owned(),
                },
                language: language.to_owned(),
                failed_pages: Vec::new(),
            },
        }
    }
}

impl MokuroBlock {
    #[must_use]
    pub fn new(
        box_: [i32; 4],
        vertical: bool,
        font_size: u32,
        lines_coords: Vec<Polygon>,
        lines: Vec<String>,
    ) -> Self {
        Self {
            box_,
            vertical,
            font_size,
            lines_coords,
            lines,
        }
    }
}

fn path_display_name(path: &Path) -> String {
    path.file_stem()
        .or_else(|| path.file_name())
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map_or_else(|| "Manga".to_owned(), ToOwned::to_owned)
}

fn deterministic_uuid(namespace: &str, fingerprint: &str) -> String {
    let digest = Sha256::digest([namespace.as_bytes(), fingerprint.as_bytes()].concat());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    let mut output = String::with_capacity(36);
    for (index, byte) in bytes.iter().enumerate() {
        if matches!(index, 4 | 6 | 8 | 10) {
            output.push('-');
        }
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ScanState {
    Running,
    Complete,
    Error,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct ScanStatus {
    pub state: ScanState,
    pub current: usize,
    pub total: usize,
    pub succeeded: usize,
    pub failed: usize,
    pub failures: Vec<FailedPage>,
    pub page: Option<String>,
    pub error: Option<String>,
    pub output: PathBuf,
}

impl ScanStatus {
    #[must_use]
    pub fn new(output: PathBuf) -> Self {
        Self {
            state: ScanState::Running,
            current: 0,
            total: 0,
            succeeded: 0,
            failed: 0,
            failures: Vec::new(),
            page: None,
            error: None,
            output,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use serde_json::json;

    use crate::archive::{ArchiveManifest, ImageEntry};

    use super::{MokuroDocument, ScanStatus};

    #[test]
    fn serializes_top_level_schema_placeholders_and_status_contract() {
        let manifest = ArchiveManifest {
            archive_size: 123,
            fingerprint: "fingerprint".to_owned(),
            entries: vec![ImageEntry {
                archive_index: 0,
                path: "page1.jpg".to_owned(),
                uncompressed_size: 100,
                compressed_size: 80,
                crc32: 1,
            }],
        };
        let document = MokuroDocument::empty(Path::new("/Manga/Volume 1.cbz"), &manifest, "ja");
        let value = serde_json::to_value(document).expect("serialize document");

        assert_eq!(value["version"], json!("0.2.0"));
        assert_eq!(value["volume"], json!("Volume 1"));
        assert!(value["pages"][0].is_null());
        assert_eq!(
            value["mangaocr"]["engine"]["name"],
            json!("chrome_lens_ocr")
        );
        assert_eq!(value["mangaocr"]["language"], json!("ja"));
        assert_eq!(value["mangaocr"]["failed_pages"], json!([]));

        let status = ScanStatus::new(PathBuf::from("/cache/volume.mokuro"));
        let status_value = serde_json::to_value(status).expect("serialize status");
        assert_eq!(status_value["succeeded"], json!(0));
        assert_eq!(status_value["failed"], json!(0));
        assert_eq!(status_value["failures"], json!([]));
        assert_eq!(status_value["output"], json!("/cache/volume.mokuro"));
    }
}

use std::{
    fmt::Write as _,
    fs::File,
    io::{Read, Seek},
    path::Path,
};

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};
use zip::ZipArchive;

use crate::natural_sort::natural_cmp;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageEntry {
    pub archive_index: usize,
    pub path: String,
    pub uncompressed_size: u64,
    pub compressed_size: u64,
    pub crc32: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveManifest {
    pub archive_size: u64,
    pub fingerprint: String,
    pub entries: Vec<ImageEntry>,
}

/// Open a CBZ/ZIP read-only and enumerate its supported image entries.
///
/// # Errors
///
/// Returns an error when the input cannot be opened as ZIP, entry metadata
/// cannot be read, or the archive has no supported image pages.
pub fn open_archive(path: &Path) -> Result<(ZipArchive<File>, ArchiveManifest)> {
    let file = File::open(path)
        .with_context(|| format!("failed to open input archive {}", path.display()))?;
    let archive_size = file
        .metadata()
        .with_context(|| format!("failed to inspect input archive {}", path.display()))?
        .len();
    let mut archive = ZipArchive::new(file)
        .with_context(|| format!("failed to parse CBZ/ZIP archive {}", path.display()))?;
    let manifest = build_manifest(&mut archive, archive_size)?;
    Ok((archive, manifest))
}

/// Build a naturally sorted image manifest and stable source fingerprint.
///
/// # Errors
///
/// Returns an error when ZIP entry metadata is unreadable or no supported
/// image entries exist.
pub fn build_manifest<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    archive_size: u64,
) -> Result<ArchiveManifest> {
    let mut entries = Vec::new();

    for archive_index in 0..archive.len() {
        let file = archive
            .by_index(archive_index)
            .with_context(|| format!("failed to inspect ZIP entry {archive_index}"))?;
        if file.is_file() && is_koreader_image(file.name()) {
            entries.push(ImageEntry {
                archive_index,
                path: file.name().to_owned(),
                uncompressed_size: file.size(),
                compressed_size: file.compressed_size(),
                crc32: file.crc32(),
            });
        }
    }

    entries.sort_by(|left, right| {
        natural_cmp(&left.path, &right.path)
            .then_with(|| left.path.cmp(&right.path))
            .then_with(|| left.archive_index.cmp(&right.archive_index))
    });

    if entries.is_empty() {
        bail!("archive contains no image pages recognized by KOReader");
    }
    for pair in entries.windows(2) {
        if natural_cmp(&pair[0].path, &pair[1].path).is_eq() {
            bail!(
                "ambiguous KOReader page order: {:?} and {:?} compare equal; \
                 rename one page to avoid shifted OCR overlays",
                pair[0].path,
                pair[1].path
            );
        }
    }

    let fingerprint = fingerprint_manifest(archive_size, &entries);
    Ok(ArchiveManifest {
        archive_size,
        fingerprint,
        entries,
    })
}

/// Extract one previously enumerated image entry into memory.
///
/// # Errors
///
/// Returns an error when the ZIP entry cannot be opened, decompressed, or read.
pub fn read_image_entry<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    entry: &ImageEntry,
) -> Result<Vec<u8>> {
    let mut file = archive
        .by_index(entry.archive_index)
        .with_context(|| format!("failed to open image entry {}", entry.path))?;
    let capacity = usize::try_from(entry.uncompressed_size).unwrap_or(0);
    let mut bytes = Vec::with_capacity(capacity);
    file.read_to_end(&mut bytes)
        .with_context(|| format!("failed to extract image entry {}", entry.path))?;
    Ok(bytes)
}

fn is_koreader_image(path: &str) -> bool {
    path.rsplit_once('.').is_some_and(|(_, extension)| {
        matches!(
            extension.to_ascii_lowercase().as_str(),
            "bmp"
                | "gif"
                | "hdp"
                | "j2k"
                | "jb2"
                | "jbig2"
                | "jp2"
                | "jpeg"
                | "jpg"
                | "jpx"
                | "jxr"
                | "pam"
                | "pbm"
                | "pgm"
                | "pkm"
                | "png"
                | "pnm"
                | "ppm"
                | "tif"
                | "tiff"
                | "wdp"
                | "webp"
        )
    })
}

fn fingerprint_manifest(archive_size: u64, entries: &[ImageEntry]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"mangaocr:zip-image-manifest:v1\0");
    hasher.update(archive_size.to_le_bytes());

    for entry in entries {
        hasher.update((entry.path.len() as u64).to_le_bytes());
        hasher.update(entry.path.as_bytes());
        hasher.update(entry.uncompressed_size.to_le_bytes());
        hasher.update(entry.compressed_size.to_le_bytes());
        hasher.update(entry.crc32.to_le_bytes());
    }

    let digest = hasher.finalize();
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[cfg(test)]
mod tests {
    use std::io::{Cursor, Write};

    use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

    use super::{build_manifest, is_koreader_image};

    #[test]
    fn koreader_image_extension_matching_is_case_insensitive() {
        for extension in [
            "bmp", "gif", "hdp", "j2k", "jb2", "jbig2", "jp2", "jpeg", "jpg", "jpx", "jxr", "pam",
            "pbm", "pgm", "pkm", "png", "pnm", "ppm", "tif", "tiff", "wdp", "webp",
        ] {
            assert!(is_koreader_image(&format!("pages/001.{extension}")));
        }
        assert!(is_koreader_image("pages/001.JPG"));
        assert!(!is_koreader_image("ComicInfo.xml"));
        assert!(!is_koreader_image("image.avif"));
    }

    #[test]
    fn unsupported_decoder_page_keeps_its_koreader_index() {
        let cursor = Cursor::new(Vec::new());
        let mut writer = ZipWriter::new(cursor);
        let options = SimpleFileOptions::default();
        for path in ["page3.jpg", "page2.jp2", "page1.jpg"] {
            writer.start_file(path, options).expect("start ZIP entry");
            writer.write_all(b"not-an-image").expect("write ZIP entry");
        }
        let cursor = writer.finish().expect("finish ZIP");
        let archive_size = cursor.get_ref().len() as u64;
        let mut archive = ZipArchive::new(cursor).expect("open ZIP");

        let manifest = build_manifest(&mut archive, archive_size).expect("build manifest");
        let paths: Vec<_> = manifest
            .entries
            .iter()
            .map(|entry| entry.path.as_str())
            .collect();
        assert_eq!(paths, vec!["page1.jpg", "page2.jp2", "page3.jpg"]);
    }

    #[test]
    fn mupdf_equivalent_names_are_rejected_as_ambiguous() {
        let cursor = Cursor::new(Vec::new());
        let mut writer = ZipWriter::new(cursor);
        let options = SimpleFileOptions::default();
        for path in ["page1.jpg", "page01.jpg"] {
            writer.start_file(path, options).expect("start ZIP entry");
            writer.write_all(b"not-an-image").expect("write ZIP entry");
        }
        let cursor = writer.finish().expect("finish ZIP");
        let archive_size = cursor.get_ref().len() as u64;
        let mut archive = ZipArchive::new(cursor).expect("open ZIP");

        let error =
            build_manifest(&mut archive, archive_size).expect_err("ambiguous ordering must fail");
        assert!(error.to_string().contains("ambiguous KOReader page order"));
    }
}

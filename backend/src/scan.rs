use std::{
    env, fs,
    path::{Component, Path, PathBuf},
};

use anyhow::{Context, Result, anyhow, bail};
use chrome_lens_ocr::LensClient;

use crate::{
    archive::{open_archive, read_image_entry},
    atomic::write_json_atomic,
    model::{FailedPage, MokuroDocument, MokuroPage, ScanState, ScanStatus},
    ocr::{PageOcrError, recognize_page},
    resume::{ForceScope, prepare_document},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanOptions {
    pub input: PathBuf,
    pub output: PathBuf,
    pub status: PathBuf,
    pub language: String,
    pub force: bool,
    pub page: Option<usize>,
    pub retry_failed: bool,
}

/// Run one full-volume, single-page, or failed-page retry scan job.
///
/// # Errors
///
/// Returns an error for unsafe paths, invalid input/cache data, atomic-write
/// failures, or a likely service outage after consecutive page failures.
pub async fn run_scan(options: ScanOptions) -> Result<()> {
    validate_destinations(&options)?;

    let mut status = ScanStatus::new(options.output.clone());
    match scan_inner(&options, &mut status).await {
        Ok(()) => Ok(()),
        Err(error) => {
            status.state = ScanState::Error;
            status.error = Some(format!("{error:#}"));
            if let Err(status_error) = write_json_atomic(&options.status, &status) {
                return Err(error.context(format!(
                    "also failed to write error status {}: {status_error:#}",
                    options.status.display()
                )));
            }
            Err(error)
        }
    }
}

#[allow(clippy::too_many_lines)]
async fn scan_inner(options: &ScanOptions, status: &mut ScanStatus) -> Result<()> {
    let language = normalize_language(&options.language)?;
    let (mut archive, manifest) = open_archive(&options.input)?;
    if options.retry_failed && options.page.is_some() {
        bail!("--retry-failed and --page are mutually exclusive");
    }
    if options.retry_failed && options.force {
        bail!("--retry-failed preserves the existing cache and cannot be combined with --force");
    }
    // Validate a one-based page before converting it to a zero-based force
    // scope, avoiding underflow and ensuring errors identify the CLI value.
    if options.page.is_some() {
        let _ = select_pages(options.page, manifest.entries.len())?;
    }

    let expected = MokuroDocument::empty(&options.input, &manifest, &language);
    let force_scope = match (options.force, options.page) {
        (false, _) => ForceScope::None,
        (true, Some(page)) => ForceScope::Page(page - 1),
        (true, None) => ForceScope::WholeVolume,
    };
    let mut document = prepare_document(&options.output, expected, &manifest.entries, force_scope)?;
    let selected_pages = if options.retry_failed {
        failed_page_indices(&document)
    } else {
        select_pages(options.page, manifest.entries.len())?
    };

    status.total = selected_pages.len();
    status.succeeded = selected_pages
        .iter()
        .filter(|index| document.pages[**index].is_some())
        .count();
    status.failed = 0;
    status.failures.clear();
    status.current = status.succeeded;
    status.page = first_pending_page(&selected_pages, &document, &manifest.entries).or_else(|| {
        selected_pages
            .last()
            .map(|index| manifest.entries[*index].path.clone())
    });
    status.state = ScanState::Running;
    status.error = None;

    // Persist placeholders before contacting Lens. A killed worker can always
    // resume from a structurally valid, correctly indexed sidecar.
    write_json_atomic(&options.output, &document)?;
    write_json_atomic(&options.status, status)?;

    if status.current < status.total {
        let client = LensClient::new(None);
        let mut consecutive_failures = 0_usize;
        for index in &selected_pages {
            if document.pages[*index].is_some() {
                continue;
            }

            let entry = &manifest.entries[*index];
            status.page = Some(entry.path.clone());
            write_json_atomic(&options.status, status)?;

            let page_result: std::result::Result<MokuroPage, PageOcrError> =
                match read_image_entry(&mut archive, entry) {
                    Ok(image_bytes) => {
                        recognize_page(&client, &image_bytes, &entry.path, &language).await
                    }
                    Err(error) => Err(PageOcrError::local(error)),
                };

            match page_result {
                Ok(page) => {
                    document.pages[*index] = Some(page);
                    remove_failure(&mut document, *index);
                    consecutive_failures = 0;

                    // Output is committed first. If power is lost before the
                    // following status write, resume still observes the page.
                    write_json_atomic(&options.output, &document)?;
                    status.succeeded += 1;
                    status.current = status.succeeded + status.failed;
                    write_json_atomic(&options.status, status)?;
                }
                Err(error) => {
                    let is_service_failure = error.is_service();
                    let failure = FailedPage {
                        index: *index + 1,
                        img_path: entry.path.clone(),
                        error: error.details(),
                    };
                    upsert_failure(&mut document, failure.clone());
                    write_json_atomic(&options.output, &document)?;

                    status.failed += 1;
                    status.failures.push(failure);
                    status.current = status.succeeded + status.failed;
                    write_json_atomic(&options.status, status)?;

                    consecutive_failures =
                        next_service_failure_streak(consecutive_failures, is_service_failure);
                    if options.page.is_none() && consecutive_failures >= 3 {
                        bail!(
                            "stopped after {consecutive_failures} consecutive page failures; \
                             the OCR service or network may be unavailable"
                        );
                    }
                }
            }
        }
    }

    if status.current != status.total {
        bail!(
            "selected scan accounted for {} of {} requested pages",
            status.current,
            status.total
        );
    }

    status.state = ScanState::Complete;
    status.current = status.total;
    status.error = None;
    write_json_atomic(&options.status, status)?;
    Ok(())
}

fn select_pages(page: Option<usize>, page_count: usize) -> Result<Vec<usize>> {
    match page {
        Some(0) => bail!("--page is 1-based and must be at least 1"),
        Some(page) if page > page_count => {
            bail!("--page {page} is outside this archive's 1..={page_count} image-page range")
        }
        Some(page) => Ok(vec![page - 1]),
        None => Ok((0..page_count).collect()),
    }
}

fn first_pending_page(
    selected_pages: &[usize],
    document: &MokuroDocument,
    entries: &[crate::archive::ImageEntry],
) -> Option<String> {
    selected_pages
        .iter()
        .find(|index| document.pages[**index].is_none())
        .map(|index| entries[*index].path.clone())
}

fn failed_page_indices(document: &MokuroDocument) -> Vec<usize> {
    let mut indices: Vec<_> = document
        .mangaocr
        .failed_pages
        .iter()
        .filter_map(|failure| failure.index.checked_sub(1))
        .collect();
    indices.sort_unstable();
    indices.dedup();
    indices
}

fn upsert_failure(document: &mut MokuroDocument, failure: FailedPage) {
    document
        .mangaocr
        .failed_pages
        .retain(|existing| existing.index != failure.index);
    document.mangaocr.failed_pages.push(failure);
    document
        .mangaocr
        .failed_pages
        .sort_by_key(|failed_page| failed_page.index);
}

fn remove_failure(document: &mut MokuroDocument, zero_based_index: usize) {
    document
        .mangaocr
        .failed_pages
        .retain(|failure| failure.index != zero_based_index + 1);
}

fn next_service_failure_streak(current: usize, is_service_failure: bool) -> usize {
    if is_service_failure {
        current.saturating_add(1)
    } else {
        0
    }
}

fn normalize_language(language: &str) -> Result<String> {
    let normalized = language.trim().replace('_', "-").to_ascii_lowercase();
    if normalized.is_empty() {
        bail!("--language must not be empty");
    }
    if normalized.len() > 35
        || !normalized
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        bail!("--language must be a short BCP-47-style language tag such as ja or en");
    }
    Ok(normalized)
}

fn validate_destinations(options: &ScanOptions) -> Result<()> {
    let input = path_identity(&options.input)
        .with_context(|| format!("cannot resolve input path {}", options.input.display()))?;
    let output = path_identity(&options.output)
        .with_context(|| format!("cannot resolve output path {}", options.output.display()))?;
    let status = path_identity(&options.status)
        .with_context(|| format!("cannot resolve status path {}", options.status.display()))?;

    if input == output {
        bail!("refusing to use the input CBZ itself as --output");
    }
    if input == status {
        bail!("refusing to use the input CBZ itself as --status");
    }
    if output == status {
        bail!("--output and --status must be different paths");
    }
    Ok(())
}

fn path_identity(path: &Path) -> Result<PathBuf> {
    if path.exists() {
        return fs::canonicalize(path).map_err(Into::into);
    }

    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir()
            .context("failed to read current directory")?
            .join(path)
    };
    let normalized = lexical_normalize(&absolute)?;

    let mut existing_ancestor = normalized.as_path();
    let mut missing_components = Vec::new();
    while !existing_ancestor.exists() {
        let name = existing_ancestor
            .file_name()
            .ok_or_else(|| anyhow!("path has no existing ancestor: {}", normalized.display()))?;
        missing_components.push(name.to_os_string());
        existing_ancestor = existing_ancestor
            .parent()
            .ok_or_else(|| anyhow!("path has no existing ancestor: {}", normalized.display()))?;
    }

    let mut identity = fs::canonicalize(existing_ancestor)?;
    for component in missing_components.iter().rev() {
        identity.push(component);
    }
    Ok(identity)
}

fn lexical_normalize(path: &Path) -> Result<PathBuf> {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => {
                normalized.push(component.as_os_str());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    bail!("path escapes its filesystem root: {}", path.display());
                }
            }
        }
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use crate::{
        archive::{ArchiveManifest, ImageEntry},
        model::{FailedPage, MokuroDocument},
    };

    use super::{
        failed_page_indices, next_service_failure_streak, normalize_language, remove_failure,
        select_pages, upsert_failure,
    };

    #[test]
    fn selects_one_based_page_or_whole_volume() {
        assert_eq!(select_pages(Some(2), 3).expect("page selection"), vec![1]);
        assert_eq!(
            select_pages(None, 3).expect("volume selection"),
            vec![0, 1, 2]
        );
        assert!(select_pages(Some(0), 3).is_err());
        assert!(select_pages(Some(4), 3).is_err());
    }

    #[test]
    fn normalizes_language_tags() {
        assert_eq!(normalize_language(" JA_jp ").expect("language"), "ja-jp");
        assert!(normalize_language("../ja").is_err());
    }

    #[test]
    fn failure_records_are_selected_updated_and_removed_by_one_based_index() {
        let entries = vec![ImageEntry {
            archive_index: 0,
            path: "1.jpg".to_owned(),
            uncompressed_size: 1,
            compressed_size: 1,
            crc32: 1,
        }];
        let manifest = ArchiveManifest {
            archive_size: 1,
            fingerprint: "fingerprint".to_owned(),
            entries,
        };
        let mut document =
            MokuroDocument::empty(std::path::Path::new("volume.cbz"), &manifest, "ja");

        upsert_failure(
            &mut document,
            FailedPage {
                index: 1,
                img_path: "1.jpg".to_owned(),
                error: "first error".to_owned(),
            },
        );
        upsert_failure(
            &mut document,
            FailedPage {
                index: 1,
                img_path: "1.jpg".to_owned(),
                error: "updated error".to_owned(),
            },
        );

        assert_eq!(failed_page_indices(&document), vec![0]);
        assert_eq!(document.mangaocr.failed_pages.len(), 1);
        assert_eq!(document.mangaocr.failed_pages[0].error, "updated error");

        remove_failure(&mut document, 0);
        assert!(document.mangaocr.failed_pages.is_empty());
    }

    #[test]
    fn only_service_failures_advance_the_outage_streak() {
        let streak = next_service_failure_streak(0, true);
        assert_eq!(streak, 1);
        let streak = next_service_failure_streak(streak, true);
        assert_eq!(streak, 2);
        assert_eq!(next_service_failure_streak(streak, false), 0);
    }
}

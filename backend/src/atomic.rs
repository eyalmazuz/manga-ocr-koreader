use std::{fs, io::Write, path::Path};

use anyhow::{Context, Result};
use serde::Serialize;

/// Serialize JSON and replace the destination with one atomic rename.
///
/// The temporary file is created beside the destination so the final rename
/// cannot cross filesystem boundaries.
///
/// # Errors
///
/// Returns an error when serialization, directory creation, writing, syncing,
/// or the final rename fails.
pub fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let mut bytes = serde_json::to_vec_pretty(value).context("failed to serialize JSON")?;
    bytes.push(b'\n');
    write_bytes_atomic(path, &bytes)
}

fn write_bytes_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = nonempty_parent(path);
    fs::create_dir_all(parent)
        .with_context(|| format!("failed to create directory {}", parent.display()))?;

    let file_prefix = path.file_name().map_or_else(
        || ".mangaocr.".to_owned(),
        |name| format!(".{}.", name.to_string_lossy()),
    );
    let mut temp_file = tempfile::Builder::new()
        .prefix(&file_prefix)
        .tempfile_in(parent)
        .with_context(|| {
            format!(
                "failed to create a temporary file beside {}",
                path.display()
            )
        })?;
    temp_file
        .write_all(bytes)
        .with_context(|| format!("failed to write temporary data for {}", path.display()))?;
    temp_file
        .as_file()
        .sync_all()
        .with_context(|| format!("failed to sync temporary data for {}", path.display()))?;

    temp_file
        .persist(path)
        .map_err(|error| error.error)
        .with_context(|| format!("failed to atomically replace {}", path.display()))?;

    Ok(())
}

fn nonempty_parent(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::json;
    use tempfile::tempdir;

    use super::write_json_atomic;

    #[test]
    fn atomically_replaces_valid_json_without_leaving_temporary_files() {
        let directory = tempdir().expect("temporary directory");
        let path = directory.path().join("progress.json");

        write_json_atomic(&path, &json!({"current": 1})).expect("first write");
        write_json_atomic(&path, &json!({"current": 2})).expect("replacement write");

        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).expect("read output")).expect("valid JSON");
        assert_eq!(value, json!({"current": 2}));

        let names: Vec<_> = fs::read_dir(directory.path())
            .expect("read directory")
            .map(|entry| entry.expect("directory entry").file_name())
            .collect();
        assert_eq!(names, vec!["progress.json"]);
    }
}

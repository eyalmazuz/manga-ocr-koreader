use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use anyhow::{Context, Result, anyhow};
use serde::Serialize;

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

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

    let (temp_path, mut temp_file) = create_temp_file(path)?;
    let write_result = (|| -> Result<()> {
        temp_file
            .write_all(bytes)
            .with_context(|| format!("failed to write {}", temp_path.display()))?;
        temp_file
            .sync_all()
            .with_context(|| format!("failed to sync {}", temp_path.display()))?;
        Ok(())
    })();
    drop(temp_file);

    if let Err(error) = write_result {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }

    if let Err(error) = fs::rename(&temp_path, path) {
        let _ = fs::remove_file(&temp_path);
        return Err(error)
            .with_context(|| format!("failed to atomically replace {}", path.display()));
    }

    Ok(())
}

fn create_temp_file(path: &Path) -> Result<(PathBuf, fs::File)> {
    let parent = nonempty_parent(path);
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow!("output path has no filename: {}", path.display()))?
        .to_string_lossy();

    for _ in 0..32 {
        let sequence = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let temp_path = parent.join(format!(
            ".{file_name}.tmp.{}.{sequence}",
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
        {
            Ok(file) => return Ok((temp_path, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to create {}", temp_path.display()));
            }
        }
    }

    Err(anyhow!(
        "could not allocate a temporary file beside {}",
        path.display()
    ))
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

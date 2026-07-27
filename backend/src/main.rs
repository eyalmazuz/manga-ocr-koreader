use std::{path::PathBuf, process::ExitCode};

use clap::{Parser, Subcommand};
use mangaocr_worker::{ScanOptions, run_scan};

#[derive(Debug, Parser)]
#[command(
    name = "mangaocr-worker",
    version,
    about = "Create resumable Mokuro sidecars for paginated manga documents"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// OCR all image pages, or one page with --page.
    Scan {
        /// Original archive, raster image, or rendered document. It is opened read-only.
        #[arg(long, value_name = "PATH")]
        input: PathBuf,

        /// JSON v1 mapping of document page ordinals to rendered raster files.
        #[arg(long, value_name = "PATH")]
        rendered_pages: Option<PathBuf>,

        /// Mokuro-compatible JSON sidecar to create or resume.
        #[arg(long, value_name = "PATH")]
        output: PathBuf,

        /// Atomically updated progress/status JSON file.
        #[arg(long, value_name = "PATH")]
        status: PathBuf,

        /// OCR locale sent to Google Lens (BCP-47-style tag).
        #[arg(long, default_value = "ja")]
        language: String,

        /// Replace a full-volume cache, or rescan only --page when supplied.
        #[arg(long)]
        force: bool,

        /// Clear the whole cache before scanning --page (for chained scans).
        #[arg(long, requires = "page", conflicts_with = "retry_failed")]
        reset: bool,

        /// OCR only this 1-based document page ordinal.
        #[arg(long, value_name = "N")]
        page: Option<usize>,

        /// Retry only pages recorded in `mangaocr.failed_pages`.
        #[arg(long, conflicts_with = "page")]
        retry_failed: bool,
    },
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match cli.command {
        Command::Scan {
            input,
            rendered_pages,
            output,
            status,
            language,
            force,
            reset,
            page,
            retry_failed,
        } => {
            run_scan(ScanOptions {
                input,
                rendered_pages,
                output,
                status,
                language,
                force,
                reset,
                page,
                retry_failed,
            })
            .await
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("mangaocr-worker: {error:#}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use clap::Parser;

    use super::{Cli, Command};

    #[test]
    fn parses_sparse_rendered_page_scan() {
        let cli = Cli::try_parse_from([
            "mangaocr-worker",
            "scan",
            "--input",
            "volume.pdf",
            "--rendered-pages",
            "pages.json",
            "--output",
            "volume.mokuro",
            "--status",
            "volume.status.json",
            "--page",
            "7",
            "--reset",
        ])
        .expect("parse rendered-page scan");

        let Command::Scan {
            input,
            rendered_pages,
            reset,
            page,
            ..
        } = cli.command;
        assert_eq!(input, PathBuf::from("volume.pdf"));
        assert_eq!(rendered_pages, Some(PathBuf::from("pages.json")));
        assert!(reset);
        assert_eq!(page, Some(7));
    }
}

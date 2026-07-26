use std::{path::PathBuf, process::ExitCode};

use clap::{Parser, Subcommand};
use mangaocr_worker::{ScanOptions, run_scan};

#[derive(Debug, Parser)]
#[command(
    name = "mangaocr-worker",
    version,
    about = "Create resumable Mokuro sidecars for manga CBZ/ZIP archives"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// OCR all image pages, or one page with --page.
    Scan {
        /// Input CBZ/ZIP archive. It is always opened read-only.
        #[arg(long, value_name = "CBZ")]
        input: PathBuf,

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

        /// OCR only this 1-based naturally sorted image-page ordinal.
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
            output,
            status,
            language,
            force,
            page,
            retry_failed,
        } => {
            run_scan(ScanOptions {
                input,
                output,
                status,
                language,
                force,
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

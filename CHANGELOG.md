# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An optional enlarged OCR-region popup that keeps selectable text near the
  tapped region and lays out vertical Japanese columns right-to-left.

## [0.3.0] - 2026-07-27

### Added

- Direct OCR support for standalone raster images alongside CBZ and ZIP
  archives.
- Page-by-page OCR for fixed-layout formats handled by KOReader's MuPDF,
  Picture Document, and DjVu providers, including PDF, DjVu, CBR, CBT, and
  XPS, plus multi-page image containers.

### Changed

- Fixed-layout sources are rasterized at a deterministic OCR resolution
  through temporary per-page PNGs, leaving original files untouched and
  retaining current-page, full-scan, rescan, resume, and retry-only behavior.
- Rendered pages use a bounded buffer size. A resumable scan validates cache
  compatibility on its first page, then skips pages already present.
- OCR overlays scale rendered-page regions back into KOReader's native page
  coordinates; reflowable CRE documents remain excluded because their page
  geometry is not stable.

### Fixed

- Source-format detection now uses the final filename suffix, so files with
  additional dots in their names remain scannable.

## [0.2.3] - 2026-07-26

### Added

- KOReader file-browser and reader actions for Google Lens OCR of CBZ/ZIP
  manga.
- Resumable, atomic per-page Mokuro-compatible caches with isolated failure
  tracking, automatic retries, outage detection, and retry-only-failed-pages
  support.
- Tappable OCR regions with exact single-character and range selection for
  Japanese text through KOReader's dictionary and Wikipedia lookup flow.
- Nearby vertical-column and horizontal-row grouping with representative
  multi-region layout coverage.
- Checked-by-default, reversible furigana hiding that preserves ordinary
  hiragana and katakana text.
- Rakuyomi-origin cache identity and support for generated, adjacent, or
  embedded Mokuro data.
- Static Linux workers for x86_64, AArch64, Arm soft-float, and Arm
  hard-float, plus an Ubuntu-native desktop package.
- Native, ad-hoc-signed macOS packages for Intel and Apple Silicon KOReader.
- Rust quality checks and tests on Linux, Windows, Intel macOS, and Apple
  Silicon macOS.
- Native macOS package architecture, signature, and launch smoke tests.
- Explicit Windows/WSL guidance using the portable x86_64 Linux package.
- Separate quality, test, and tagged-release automation.
- Complete-text fallback when Lens returns geometry for only part of a
  recognized paragraph.
- Geometry-aware grouping that keeps isolated OCR regions separate while
  joining related columns across modest font-size differences.
- Cross-platform worker launching and atomic status/cache replacement.

[Unreleased]: https://github.com/eyalmazuz/manga-ocr-koreader/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/eyalmazuz/manga-ocr-koreader/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/eyalmazuz/manga-ocr-koreader/releases/tag/v0.2.3

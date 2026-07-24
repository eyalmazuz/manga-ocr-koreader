# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-24

### Added

- KOReader file-browser and reader actions for Google Lens OCR of CBZ/ZIP
  manga.
- Resumable, atomic per-page Mokuro-compatible caches.
- Automatic request retries, isolated failed-page tracking, outage detection,
  and retry-only-failed-pages support.
- Tappable OCR regions with KOReader dictionary and Wikipedia lookup.
- Nearby vertical-column and horizontal-row grouping, including regression
  coverage based on real manga page geometry.
- Checked-by-default, reversible furigana hiding that preserves ordinary
  hiragana and katakana dialogue.
- Rakuyomi-origin cache identity and support for adjacent or embedded Mokuro
  data.
- Static Linux workers for x86_64, AArch64, Arm soft-float, and Arm
  hard-float, plus an Ubuntu-native desktop package.
- Separate quality, test, and tagged-release automation.

[Unreleased]: https://github.com/eyalmazuz/manga-ocr-koreader/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/eyalmazuz/manga-ocr-koreader/releases/tag/v0.1.0

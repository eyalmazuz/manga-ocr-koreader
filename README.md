# Manga OCR for KOReader

[![Quality](https://github.com/eyalmazuz/manga-ocr-koreader/actions/workflows/quality.yml/badge.svg)](https://github.com/eyalmazuz/manga-ocr-koreader/actions/workflows/quality.yml)
[![Tests](https://github.com/eyalmazuz/manga-ocr-koreader/actions/workflows/tests.yml/badge.svg)](https://github.com/eyalmazuz/manga-ocr-koreader/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Manga OCR turns text in manga pages into tappable, dictionary-friendly regions
directly in [KOReader](https://github.com/koreader/koreader). It scans files
already on the device, so books do not need to be processed with
[Mokuro](https://github.com/kha-white/mokuro) on another computer first.

The plugin consists of:

- a Lua KOReader frontend for file-browser actions, reader overlays, and
  dictionary lookup;
- a small Rust worker that sends direct image inputs or pages rendered by
  KOReader to Google Lens for OCR; and
- a Mokuro-compatible JSON cache containing text and page coordinates.

Source files are always opened read-only. Manga OCR does not repack or modify
them, and generated OCR survives plugin upgrades.

> [!IMPORTANT]
> Scanning uploads each selected manga page to Google Lens through an
> unofficial, unsupported endpoint. Read [Privacy and service
> dependency](#privacy-and-service-dependency) before using it.

## Features

- Scan one page, a complete manga, or only previously failed pages.
- Resume interrupted scans without uploading successful pages again.
- Retry each failed Lens request three times, then record the failure and
  continue.
- Group nearby vertical columns or horizontal rows into useful tappable text
  regions.
- Open an enlarged selectable text view next to the tapped region, with
  vertical Japanese columns laid out right-to-left.
- Hide furigana while preserving ordinary hiragana and katakana dialogue.
- Use KOReader's normal dictionary and Wikipedia lookup flow.
- Read generated, adjacent, or archive-embedded `.mokuro` data.
- Share a stable OCR cache with chapters downloaded through Rakuyomi.
- Keep original files and Rakuyomi ZIP metadata untouched.

Manga OCR deliberately has no direct Anki integration. If another KOReader
plugin adds an **Add to Anki** action to the dictionary window, it continues
to work with text opened from Manga OCR.

## How it works

```text
CBZ/ZIP or standalone raster image ------------------\
                                                      +--> Rust worker
Fixed-layout document                                 |          |
    `-- KOReader renders one temporary page to PNG --/           v
                                                        Google Lens OCR
                                                                |
                                                                v
Nearby OCR rows/columns grouped into text regions
        |
        v
Mokuro-compatible cache in KOReader's data directory
        |
        v
Lua overlay -> native page coordinates -> selectable text -> dictionary
```

Temporary rendered pages are removed after processing. Keeping OCR outside the
source protects it if a scan is interrupted and preserves archive metadata.

## Requirements and supported formats

- A Unix-like KOReader target capable of launching the bundled worker.
- A matching worker package for the device's CPU and ABI.
- Wi-Fi for new Google Lens scans. Cached OCR works offline.

Manga OCR accepts these sources directly:

- CBZ and ZIP image archives; and
- standalone BMP, JPEG, PNG, and PAM/PBM/PGM/PNM/PPM images.

It also supports PDF, DjVu/DJV, CBR, CBT, XPS, GIF, TIFF, WebP, and the
fixed-layout image formats HDP, J2K/JP2, JXR, and WDP when the corresponding
KOReader provider is available. Multi-page or animated image containers use
this path so every page or frame keeps its KOReader ordinal. KOReader renders
these sources one page at a time to a temporary PNG at a bounded,
deterministic OCR resolution. This is document rasterization, not a
screenshot: it does not depend on the current screen size, zoom, crop, or
reader orientation. The temporary PNG is removed after the worker processes
it, and the original document remains untouched.

OCR boxes are stored in rendered-page coordinates and scaled back to
KOReader's native page coordinates for display. Normal reflowable EPUB and
other documents opened with KOReader's CRE provider are not supported because
their page geometry can change with typography and layout settings.

Japanese and English OCR presets are included. Local/offline OCR, translated
text rendering, and direct actions inside Rakuyomi's own chapter context
dialog are not currently implemented.

## Installation

### 1. Choose the correct ZIP

Open the [latest GitHub release](https://github.com/eyalmazuz/manga-ocr-koreader/releases/latest)
and download **one** archive:

| Release ZIP | CPU / ABI | Choose it for |
| --- | --- | --- |
| `mangaocr-arm-unknown-linux-musleabihf.zip` | 32-bit Arm, hard-float, static musl | Compatible 32-bit Arm Linux installations where KOReader uses the hard-float ABI. |
| `mangaocr-arm-unknown-linux-musleabi.zip` | 32-bit Arm, soft-float, static musl | Compatible 32-bit Arm Linux installations where KOReader uses the soft-float ABI. |
| `mangaocr-aarch64-unknown-linux-musl.zip` | 64-bit Arm, static musl | Compatible 64-bit Arm Linux KOReader devices. |
| `mangaocr-x86_64-unknown-linux-musl.zip` | 64-bit x86, static musl | Portable 64-bit Linux desktop KOReader builds. Also use this with KOReader's Debian/Linux build running through WSL on Windows. |
| `mangaocr-native.zip` | Native Ubuntu x86_64/glibc release runner | Development on compatible Ubuntu x86_64 hosts. It is not a universal package; prefer the x86_64 musl ZIP unless this native build is specifically needed. |
| `mangaocr-aarch64-apple-darwin.zip` | Apple Silicon macOS | Native Apple Silicon KOReader installations. |
| `mangaocr-x86_64-apple-darwin.zip` | Intel macOS | Native Intel KOReader installations. |

The Lua plugin and cache format are device-independent; only
`mangaocr-worker` differs between packages. A wrong CPU or float ABI normally
fails with `Exec format error`. Match the ABI used by the installed KOReader
package rather than relying only on the reader's model name. See
[`scripts/TARGETS.md`](scripts/TARGETS.md) for the complete target rationale.

The four Linux target-triple packages are static musl builds. The two macOS
workers are native, ad-hoc-signed Mach-O executables built separately on Intel
and Apple Silicon runners. KOReader does not provide a native Windows
application; its documented Windows setup runs Linux KOReader through WSL and
therefore uses the x86_64 Linux/musl package. No misleading Windows `.exe`
package is published. Android does not yet have a separately validated Android
release target.

### 2. Extract the plugin

Every ZIP contains one top-level directory named `mangaocr.koplugin`. Extract
that directory into KOReader's `plugins` directory:

| Platform | Typical destination |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/mangaocr.koplugin/` |
| Kobo | `.adds/koreader/plugins/mangaocr.koplugin/` |
| Android | `/sdcard/koreader/plugins/mangaocr.koplugin/` |
| Desktop development build | `<koreader>/plugins/mangaocr.koplugin/` |
| macOS app/emulator | The `plugins` directory inside the extracted KOReader installation |

The resulting layout must include both of these files at the same level:

```text
plugins/
└── mangaocr.koplugin/
    ├── main.lua
    ├── _meta.lua
    └── mangaocr-worker
```

Avoid an extra directory level such as
`plugins/mangaocr.koplugin/mangaocr.koplugin/`. Restart KOReader completely
after copying the plugin.

### Upgrading

1. Exit KOReader.
2. Remove only the old `plugins/mangaocr.koplugin` directory.
3. Extract the new package in its place.
4. Restart KOReader.

Do not merge a new package into an early development build: obsolete Lua files
can otherwise remain loaded or on disk. Generated OCR is stored outside the
plugin directory and is preserved.

The package records `mangaocr-worker` as executable. Some USB/SFTP clients do
not preserve that bit, and user-storage filesystems may be mounted `noexec`.
When necessary, the plugin copies the worker to an executable temporary
directory for that scan and removes the temporary copy afterward. A
read-only system partition does not prevent normal installation in writable
user storage.

## Usage

### Scan from KOReader's file browser

1. Long-press a supported archive, image, or fixed-layout document.
2. Select **Scan manga with Google Lens**.
3. Accept the privacy notice and connect Wi-Fi when prompted.
4. Wait for the scan to finish, then open the manga.
5. Tap a detected text region to open one enlarged selectable view and use
   KOReader's dictionary actions. The view follows the OCR orientation:
   horizontal text stays horizontal, while vertical Japanese columns are
   displayed top-to-bottom and right-to-left.

If a scan already exists, the long-press menu also offers **Rescan manga**,
**Retry failed pages**, and **Delete Manga OCR cache** when applicable.
For a standalone image, whole-manga actions operate on its single page.

### Scan while reading

Open the **Manga OCR** entry in KOReader's reader menu. It provides:

- **Scan current page** — always refresh the visible page, even if it is
  already cached;
- **Scan entire manga** — resumes compatible partial work and scans unfinished
  pages;
- **Rescan entire manga** — starts a fresh full-volume scan;
- **Retry failed pages** — scans only recorded failures;
- **Reload OCR data**;
- **Enable OCR hotspots**;
- **Show enlarged OCR text near the tapped region** — disable this to use the
  original bottom text panel;
- **Show OCR box outlines**;
- **Hide furigana (small kana readings)**;
- **OCR language** — Japanese or English; and
- **Delete OCR cache**.

These current-page, full-scan, rescan, and retry-only actions work the same
way for direct inputs and KOReader-rendered fixed-layout documents. Rendered
documents are processed one page at a time, so retrying failures does not
rasterize or upload successful pages again.

Furigana hiding is enabled by default. It hides only small hiragana or
katakana lines whose size and position identify them as ruby beside a kanji
line. Ordinary kana remains selectable. This is a reversible display setting:
the original OCR stays in the cache, and unchecking it restores the readings
immediately without uploading the page again.

### Manga downloaded by Rakuyomi

Open the downloaded chapter normally, then use **Manga OCR** in KOReader's
reader menu. No Rakuyomi download path is hard-coded. Chapters are identified
by the origin metadata Rakuyomi stores in the CBZ ZIP comment, allowing
persistent and RAM-backed downloads to share a cache. See
[Rakuyomi](https://github.com/tachibana-shin/rakuyomi) for its separate
installation and usage documentation.

### Existing Mokuro manga

No Google Lens scan is required. The loader checks, in order:

1. generated OCR in Manga OCR's cache;
2. an adjacent same-stem file such as `chapter.mokuro`; and
3. a `.mokuro` entry inside a CBZ or ZIP archive.

The worker is not needed merely to read existing Mokuro data.

## Failed pages and resume behavior

Progress is committed after every page. Each failed Lens request receives an
initial attempt plus three automatic retries with short backoff. If it still
fails, the worker records the original one-based page number and error, then
continues. The UI reports completed and failed counts without discarding
successful pages.

**Scan current page** can fill or refresh one page. **Retry failed pages**
processes only recorded failures. A normal scan resumes compatible partial
work without re-uploading successful pages.

A pass with isolated page failures finishes normally so all usable pages load
immediately. Three consecutive service/network page failures are treated as a
probable outage: the job stops, all completed pages and failure records remain
intact, and scanning can be resumed after connectivity returns. Corrupt or
locally unsupported individual pages do not trigger this service-outage guard.

## Storage

Generated OCR, job status, and logs are kept below KOReader's data directory:

```text
mangaocr/
├── cache/
├── status/
├── logs/
└── staging/
```

The cache contains Mokuro-compatible JSON plus small extension metadata for
the source fingerprint, OCR engine, language, and partial-scan state.
The staging directory is used only for temporary rendered-page data, which is
removed after processing. **Delete OCR cache** removes only generated data,
never the source file.

## Troubleshooting

### Manga OCR is absent from KOReader

- Confirm the directory is exactly `plugins/mangaocr.koplugin/`, with
  `main.lua` immediately inside it.
- Install the complete release ZIP, not the repository's `frontend` directory
  by itself.
- Fully restart KOReader; reopening a book is not sufficient after a plugin
  upgrade.
- File-browser and reader actions appear only for a direct input or a
  fixed-layout document handled by KOReader's MuPDF, Picture Document, or
  DjVu provider.
- Reflowable EPUB and other reflowable documents are intentionally unsupported
  because they do not have stable native page geometry.

### The worker is missing or is not executable

Confirm that `mangaocr-worker` is beside `main.lua` and that the package
matches the device. On systems with shell access, an optional manual repair is:

```sh
chmod 755 /path/to/koreader/plugins/mangaocr.koplugin/mangaocr-worker
```

Copying through SSH does not inherently remove executable permissions, but a
graphical SFTP client or extraction method may not preserve them. Manga OCR
normally handles this by staging a temporary executable. If both the plugin
directory and `/var/tmp` or `/tmp` disallow execution, scanning cannot start;
existing Mokuro data can still be read.

`Exec format error` indicates the wrong CPU or Arm float ABI, not a missing
permission. Reinstall the appropriate ZIP from the selection table.

On macOS, KOReader and the Manga OCR worker are not notarized. If Gatekeeper
blocks the verified worker, allow it under **System Settings → Privacy &
Security**. As a command-line fallback, after comparing the ZIP against the
published `SHA256SUMS`, remove quarantine only from this plugin directory:

```sh
xattr -dr com.apple.quarantine /path/to/mangaocr.koplugin
```

The plugin reports this case explicitly instead of silently bypassing macOS
security metadata.

### Scanning fails or stops after several pages

- Verify Wi-Fi and try **Retry failed pages**.
- Google may rate-limit or change the unofficial Lens endpoint.
- Unsupported or corrupt pages remain listed as individual failures.
- Consult the newest file below `mangaocr/logs/` and the matching JSON under
  `mangaocr/status/`.

Completed page data remains safe in all of these cases.

### OCR regions are still split after upgrading

Grouping is performed when OCR data is created. Use **Scan current page** to
regenerate an already cached page with the current grouping logic, or
**Rescan entire manga** for the whole book.

### Scanning feels slow

The dominant cost is page preparation, network upload, and Google Lens
response time. Fixed-layout documents must first be rasterized by KOReader at
a deterministic OCR resolution; this happens one page at a time and is not a
screen capture. Images taller than 3000 pixels are uploaded as multiple
vertical chunks, and retries add backoff after a failed request. Nearby-block
grouping is local and normally negligible. Scans are deliberately
single-worker to keep memory use and service load reasonable on e-readers.

## Privacy and service dependency

Google Lens OCR receives every page selected for scanning. Pages taller than
3000 pixels are uploaded as vertical chunks. The plugin performs no upload
until the user starts a scan and acknowledges the warning. No Google account
or API key is required.

The worker accesses an unofficial Google Lens endpoint through the
`chrome_lens_ocr` crate. Google may rate-limit, change, or disable it without
notice. Users are responsible for reviewing and complying with applicable
service terms. Existing cached OCR remains usable offline.

## Development and tests

The repository is split into:

```text
backend/                         Rust OCR worker
frontend/mangaocr.koplugin/      KOReader Lua plugin
scripts/                         build and packaging helpers
```

The Rust toolchain is pinned in `backend/rust-toolchain.toml`. Run the primary
Rust checks from the repository root:

```sh
cargo fmt --manifest-path backend/Cargo.toml --all --check
cargo clippy --manifest-path backend/Cargo.toml \
  --locked --workspace --all-targets --all-features -- -D warnings
cargo test --manifest-path backend/Cargo.toml \
  --locked --workspace --all-targets --all-features
cargo build --manifest-path backend/Cargo.toml --locked --release
```

Lua targets KOReader's LuaJIT 5.1 runtime. Validate its syntax with Lua 5.1 or
LuaJIT and run the plugin specs through the KOReader-compatible test harness.
Shell scripts are checked with `bash -n` and ShellCheck.

Build and package the current host:

```sh
scripts/build-release.sh native
```

Build all four portable musl targets with
[`cross`](https://github.com/cross-rs/cross) and Docker or Podman:

```sh
MANGAOCR_BUILDER=cross scripts/build-release.sh all
```

For desktop development,
`MANGAOCR_WORKER=/absolute/path/to/mangaocr-worker` overrides the executable
bundled beside the Lua plugin. Cross-compilation alternatives and target
aliases are documented in [`scripts/TARGETS.md`](scripts/TARGETS.md).

GitHub Actions separates responsibilities:

- `quality.yml` checks Rust on Linux, Windows, Intel macOS, and Apple Silicon
  macOS, plus Lua/shell linting and all release packages;
- `tests.yml` runs Rust tests on all four CI platforms and Lua tests on
  LuaJIT; and
- `release.yml` builds and publishes tagged releases.

## Release behavior

Pushing a tag matching `v*` starts the release workflow. It builds and
validates these seven ZIP assets:

```text
mangaocr-native.zip
mangaocr-x86_64-unknown-linux-musl.zip
mangaocr-aarch64-unknown-linux-musl.zip
mangaocr-arm-unknown-linux-musleabi.zip
mangaocr-arm-unknown-linux-musleabihf.zip
mangaocr-x86_64-apple-darwin.zip
mangaocr-aarch64-apple-darwin.zip
```

CI rejects a Linux/musl worker containing a dynamic ELF interpreter. It builds
each macOS worker natively on the matching architecture, ad-hoc signs it,
checks its Mach-O architecture and signature, and executes a CLI smoke test.
Package validation checks the executable, licenses and third-party notices,
and excludes development test specs. After all target builds succeed, GitHub
publishes every ZIP, `SHA256SUMS`, and generated release notes.

For maintainers, a typical release starts with:

```sh
git tag -a vX.Y.Z -m "Manga OCR vX.Y.Z"
git push origin vX.Y.Z
```

The `native` ZIP is built on GitHub's Ubuntu x86_64 runner and is therefore a
convenience desktop artifact, not a portable or cross-platform binary. A
locally built `mangaocr-native.zip` instead matches that local build host.
User-visible changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License and credits

Manga OCR for KOReader is available under the [MIT License](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the projects and
libraries that informed or support it and for their respective licenses.
Release ZIPs also include the preserved MIT notices for adapted Manatan and
mokuroreader-koreader code and a cargo-about report covering the Rust
dependencies linked into the worker.
Contributions are described in [CONTRIBUTING.md](CONTRIBUTING.md), and private
vulnerability reports follow [SECURITY.md](SECURITY.md).

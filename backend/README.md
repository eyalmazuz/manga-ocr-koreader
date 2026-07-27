# mangaocr-worker

`mangaocr-worker` is the standalone asynchronous OCR process used by the
KOReader Manga OCR plugin. It is a one-shot CLI, not a resident server.

It opens the original input read-only, sends page images to the unauthenticated
Google Lens endpoint through `chrome_lens_ocr`, and writes a Mokuro-compatible
JSON sidecar. Images taller than 3000 pixels are scanned in vertical chunks.
Source files are never repacked or modified.

CBZ/ZIP input is read directly with KOReader/MuPDF-compatible image ordering.
BMP, JPG/JPEG, PNG, and the PNM family (PAM/PBM/PGM/PPM) may also be supplied
directly as one-page documents. Potentially multi-page GIF, TIFF, and WebP
inputs, along with other paginated formats, are rendered by KOReader and
described to the worker with `--rendered-pages`; this keeps the worker
independent of any platform-specific document renderer.

Every extension in the worker's mirrored KOReader/MuPDF image-entry set is
kept in the manifest, even if the Rust image decoder cannot decode it. This
prevents a locally unsupported page from shifting every later OCR overlay.
HDP/JXR/WDP, JPEG 2000 (J2K/JP2/JPX), JBIG2 (JB2/JBIG2), and PKM entries remain
`null` and are recorded as structured page failures when they occur inside an
archive.

Archives containing names that MuPDF considers order-equivalent—such as
`page1.jpg` and `page01.jpg`, or case-only variants—are rejected with an
ambiguous-order error. MuPDF's sort order for such ties is platform-dependent,
so producing coordinates would not be safe.

## CLI

```sh
mangaocr-worker scan \
  --input volume.cbz \
  --output /path/to/cache/volume.mokuro \
  --status /path/to/cache/volume.status.json \
  --language ja
```

Add `--page N` to OCR only the 1-based page ordinal in natural filename order.
For rendered documents it is the original document ordinal. The sidecar still
contains a slot for every document page. A successful page job exits 0 with
status `complete`, `current: 1`, and `total: 1`; unrelated slots may remain
`null`. Add `--force --page N` to refresh that page without discarding other
compatible cached records.

An internal chained full-rescan controller may use `--reset --page N` for its
first page. This clears the whole old cache while still selecting only page
`N`; later chained pages use the normal page-local behavior. `--reset` requires
`--page` and cannot be combined with `--retry-failed`.

### Rendered-page manifest

For an input that is not a directly readable archive or raster image, keep
`--input` pointed at the original document and add a JSON v1 manifest:

```sh
mangaocr-worker scan \
  --input volume.pdf \
  --rendered-pages /path/to/staging/pages.json \
  --output /path/to/cache/volume.mokuro \
  --status /path/to/cache/volume.status.json \
  --page 2
```

```json
{
  "version": 1,
  "source_fingerprint": "opaque-stable-digest-from-koreader",
  "source_size": 123456,
  "page_count": 20,
  "pages": [
    {
      "index": 2,
      "path": "page-000002.png"
    }
  ]
}
```

`source_size` must match the original input file. `source_fingerprint` is the
stable partial digest supplied by KOReader and identifies the original
document, not a temporary render. Page indices are one-based and unique.
Relative raster paths are resolved from the manifest's directory.
Manifests are limited to 1 MiB and 10,000 document pages to keep malformed
input from exhausting memory on an e-reader.

The `pages` array may be sparse. It needs mappings only for pages that the
specific worker invocation will read, so a current-page or failed-page retry
does not need to render unrelated pages. The worker nevertheless creates
`page_count` sidecar slots with stable logical names such as
`page-000001.png`; regenerated temporary paths therefore do not invalidate
compatible cached pages. A fresh whole-document scan requires every page,
while resume requires every still-unfinished selected page.

Retry only failures recorded by an earlier pass:

```sh
mangaocr-worker scan \
  --input volume.cbz \
  --output /path/to/cache/volume.mokuro \
  --status /path/to/cache/volume.status.json \
  --retry-failed
```

`--retry-failed` is mutually exclusive with both `--page` and `--force`, and
preserves every successful page. A later success removes that page's failure
record; another failure updates it.

Without `--page` or `--retry-failed`, the worker resumes all unfinished slots.
`--force` instead starts a full-volume scan from a fresh sidecar.

Each Lens request gets one initial attempt plus three retries (four attempts
total) with short incremental backoff. A locally corrupt/unsupported page or
an isolated Lens failure is recorded and the scan continues. Three consecutive
pages that still fail specifically at the Lens/service layer stop a full or
retry-failed pass as a likely network/service outage. Local decode/extraction
failures do not advance that outage streak.

## Atomic progress and resume

Both files are replaced atomically. The sidecar is committed before the status
after each page, so interruption may make status lag by one page but cannot
lose the completed page or failure record.

Status has this stable shape:

```json
{
  "state": "running",
  "current": 3,
  "total": 20,
  "succeeded": 2,
  "failed": 1,
  "failures": [
    {
      "index": 3,
      "img_path": "pages/003.jp2",
      "error": "failed to decode image page pages/003.jp2",
      "service_failure": false
    }
  ],
  "page": "pages/004.jpg",
  "page_index": 4,
  "error": null,
  "output": "/path/to/cache/volume.mokuro"
}
```

`state` is `running`, `complete`, or `error`; `current` is
`succeeded + failed` for the selected job. `page_index`, when present, is the
one-based original document ordinal. Each failed-page record has
`service_failure: true` only for Lens/network failures; local input and decode
failures use `false`. These fields allow a controller that invokes one page per
worker process to retain correct ordinals and detect a service-wide outage.

A completed pass with isolated page failures uses `complete`, exits 0, and has
`failed > 0`, so the UI can report completed and failed counts. A likely
service outage or input/output-level failure uses `error` and exits nonzero. In
every case the partial sidecar is preserved.

The top-level `mangaocr` object records a source-specific fingerprint, source
size, page count, OCR engine/version, language, integration schema, and
persistent `failed_pages` records. ZIP inputs retain the original
`sha256:zip-image-manifest-v1` fingerprint and serialized `archive_size` field
so caches produced by earlier workers remain compatible. Resume compatibility
ignores the mutable failure list while validating the immutable fields and all
existing logical page paths.

## Privacy and service dependency

OCR requires network access and sends each manga page (or page chunk) to
Google Lens. It does not require a Google account or API key. This is an
unofficial endpoint, so availability and behavior are outside the plugin's
control; users are responsible for complying with applicable service terms.

## Development

```sh
cargo fmt --all --check
cargo test --locked
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo build --locked --release
```

The patched MIT-licensed `chrome_lens_ocr` 0.3 source under `vendor/` changes
only package feature selection and rustfmt layout: native TLS is disabled and
Rustls is used. This keeps static musl artifacts OS/device agnostic and avoids
OpenSSL runtime or cross-toolchain dependencies. Image features are limited to
the locally supported page formats above.

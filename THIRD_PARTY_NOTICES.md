# Third-party notices

This project uses or was informed by the following open-source projects:

- [KOReader](https://github.com/koreader/koreader), AGPL-3.0. The plugin uses
  KOReader's public Lua plugin and reader APIs.
- [mokuro](https://github.com/kha-white/mokuro), GPL-3.0. Generated OCR data
  follows Mokuro's JSON interchange format.
- [mokuroreader-koreader](https://github.com/Magyarapointe/mokuroreader-koreader),
  MIT. `MangaOCRTextPopup.lua` adapts its selectable-text popup, touch-event
  forwarding, and KOReader dictionary workflow. Its complete MIT notice is
  preserved in `licenses/mokuroreader-koreader-MIT.txt` and as
  `LICENSE.mokuroreader-koreader` in release packages.
- [Manatan](https://github.com/KolbyML/Manatan), MIT for the Rust application
  code. The nearby-text grouping and furigana-geometry heuristics adapt
  Manatan's OCR merge logic. Its complete MIT notice is preserved in
  `licenses/Manatan-MIT.txt` and as `LICENSE.Manatan` in release packages.
- [Rakuyomi](https://github.com/tachibana-shin/rakuyomi), AGPL-3.0. The optional
  cache-identity integration reads origin fields from Rakuyomi's CBZ ZIP
  comment; no Rakuyomi code is bundled.
- [`chrome_lens_ocr`](https://crates.io/crates/chrome_lens_ocr), MIT. The Rust
  worker uses this crate to communicate with Google Lens. Its published source
  contains Google's public Lens web-client identifier; this is not a project
  or contributor credential.

Each dependency remains subject to its own license. This notice is
informational and does not replace the license text shipped by a dependency.
Release packages include this notice, the Manga OCR MIT license, the preserved
Manatan and mokuroreader-koreader notices, the MIT license from the vendored
`chrome_lens_ocr` source, and a cargo-about report containing the applicable
license texts and notices for all Rust dependencies linked into the worker.

No source code from KOReader, mokuro, or Rakuyomi is bundled. Their entries
above document API, format, and optional integration relationships rather than
source-code reuse.

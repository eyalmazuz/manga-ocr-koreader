# Local portability patch

This directory contains the published `chrome_lens_ocr` 0.3.0 crate:

- source archive SHA-256:
  `475966513f43d650f645b97d395ef851819d3f393899f6225baa011b8df3a3a5`
- upstream repository: <https://github.com/KolbyML/chrome-lens-ocr>
- license: MIT (see `LICENSE`)

No functional Rust logic is changed (the workspace formatter only normalizes
layout). The package manifests disable Reqwest's native-TLS defaults and select
Rustls, preventing an otherwise unused OpenSSL/native-tls dependency in static
musl builds. Image features are restricted to the worker's local decoder set:
BMP, GIF, JPEG, PNG, PNM (including PAM/PBM/PGM/PPM), TIFF, and WebP.

The `DEFAULT_API_KEY` in the vendored constants is the same public Google Lens
web-client identifier present in the published upstream crate. It is not a
credential belonging to this project or one of its contributors.

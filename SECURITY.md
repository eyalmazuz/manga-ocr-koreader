# Security policy

## Supported versions

Security fixes are made against the latest published release and the `main`
branch. Older releases may not receive backports.

## Reporting a vulnerability

Please use this repository's **Security** tab to submit a private vulnerability
report. Do not open a public issue for a vulnerability that could put users,
their devices, or their data at risk.

Include the affected release, KOReader platform, reproduction steps, and the
impact you observed. Reports involving the Rust worker should also say whether
the issue occurs before or after a page is uploaded.

## Service boundary

Manga OCR sends user-selected manga pages to Google Lens through an unofficial
endpoint. This network transfer is intentional and disclosed in the plugin
before the first scan. Cached OCR can be read offline. The project does not
operate the Google service and cannot guarantee its availability, privacy
policy, or continued compatibility.

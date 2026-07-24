# Contributing

Bug reports, compatibility results, documentation improvements, and code
changes are welcome.

## Before opening an issue

- Use the newest release.
- Confirm the installed ZIP matches the device CPU and ABI.
- Remove private manga paths and OCR text from logs or screenshots.
- Include the KOReader version, device, release artifact, reproduction steps,
  and relevant worker/status logs.

Report security-sensitive problems privately as described in
[SECURITY.md](SECURITY.md).

## Development setup

Rust 1.90 is pinned in `backend/rust-toolchain.toml`. Lua code targets
KOReader's LuaJIT 5.1 runtime. The repository's CI is the reference for the
current Ubuntu package names and commands.

Run the Rust quality checks and tests from the repository root:

```sh
cargo fmt --manifest-path backend/Cargo.toml --all --check
cargo check --manifest-path backend/Cargo.toml \
  --locked --workspace --all-targets --all-features
cargo clippy --manifest-path backend/Cargo.toml \
  --locked --workspace --all-targets --all-features -- -D warnings
cargo test --manifest-path backend/Cargo.toml \
  --locked --workspace --all-targets --all-features
```

Run the Lua specs with LuaJIT, Busted, dkjson, and LuaFileSystem:

```sh
LUA_PATH="$PWD/frontend/mangaocr.koplugin/?.lua;;" \
luajit "$(command -v busted)" \
  --helper="$PWD/tests/lua/busted_helper.lua" \
  frontend/mangaocr.koplugin
```

Also run Lua 5.1 syntax checks, Luacheck, `bash -n`, and ShellCheck as shown in
`.github/workflows/quality.yml`.

When `backend/Cargo.lock` or Rust dependencies change, regenerate and verify
the checked-in dependency license report with the pinned cargo-about version:

```sh
cargo install --locked --version 0.9.1 --features cli cargo-about
scripts/generate-third-party-licenses.sh
scripts/generate-third-party-licenses.sh --check
scripts/check-third-party-licenses.sh native
```

The release packager runs the lightweight coverage check automatically for
its selected target. Keep adapted-code provenance and preserved upstream
notices in `THIRD_PARTY_NOTICES.md` and `licenses/` accurate when reusing
third-party code.

## Building packages

Build the current host package:

```sh
scripts/build-release.sh native
```

Build the four static Linux/musl workers with `cross` and Docker or Podman:

```sh
MANGAOCR_BUILDER=cross scripts/build-release.sh all
```

See [scripts/TARGETS.md](scripts/TARGETS.md) before changing platform claims.
Do not commit `dist/` or `backend/target/`.

## Pull requests

- Keep changes focused and explain user-visible behavior.
- Add regression tests for bug fixes.
- Preserve existing cache data and page ordinals.
- Avoid increasing Kindle memory or concurrency without device measurements.
- Update the README, target documentation, and changelog when behavior or
  release artifacts change.
- State which real devices or architecture targets were tested.

All three GitHub Actions workflows must pass before a release is tagged.

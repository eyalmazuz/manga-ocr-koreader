# Build targets

Release archives include the Rust target triple in the filename:

| Script name | Rust target / archive suffix | Intended use |
| --- | --- | --- |
| `desktop` | `x86_64-unknown-linux-musl` | 64-bit desktop Linux and KOReader development |
| `aarch64` | `aarch64-unknown-linux-musl` | 64-bit Arm Linux readers |
| `kindle` | `arm-unknown-linux-musleabi` | 32-bit Arm Linux, soft-float ABI |
| `kindlehf` | `arm-unknown-linux-musleabihf` | 32-bit Arm Linux, hard-float ABI |
| `macos-intel` | `x86_64-apple-darwin` | Intel macOS KOReader |
| `macos-arm64` | `aarch64-apple-darwin` | Apple Silicon macOS KOReader |
| `native` | `native` | The current host; GitHub releases build this on Ubuntu x86_64/glibc |

Choose the Arm artifact that matches the ABI of the installed KOReader
package:

```text
mangaocr-arm-unknown-linux-musleabi.zip    soft-float
mangaocr-arm-unknown-linux-musleabihf.zip  hard-float
```

A hard-float executable cannot be treated as a drop-in replacement for a
soft-float one, even when both packages target 32-bit Arm. Select by package
ABI rather than device model or operating-system version. Consult the
platform's KOReader packaging documentation when the ABI is unknown.

The musl builds are intended to be self-contained. Release CI rejects a worker
that contains an ELF program interpreter. Real-device validation is still
necessary on platforms with older kernels or uncommon runtime constraints.

Rust 1.90 still distributes both Arm targets. The soft-float target is therefore
retained alongside the hard-float target. Cross-compilation also needs a
matching C linker/sysroot:

- Plain `cargo` is the default and never starts a container. Install the target
  with `rustup target add TARGET` and configure the corresponding linker.
- `MANGAOCR_BUILDER=cross` uses
  [`cross`](https://github.com/cross-rs/cross), which requires Docker or Podman.
  Tagged GitHub releases use this documented containerized path.
- `MANGAOCR_BUILDER=zigbuild` uses `cargo-zigbuild` and Zig.

`native` builds and packages the current host without selecting a Rust target,
which is useful for development. Tagged CI builds this artifact on GitHub's
Ubuntu x86_64 runner, so the published `mangaocr-native.zip` is an
Ubuntu/glibc desktop convenience build, not a universal native package. Prefer
the x86_64 musl artifact for portable desktop Linux use.

Tagged CI also builds `x86_64-apple-darwin` on `macos-15-intel` and
`aarch64-apple-darwin` on `macos-15`. The workers are ad-hoc signed and smoke
tested on their matching architecture. Deployment targets are defined
explicitly in the release workflow. These signatures provide code integrity
but are not Apple Developer ID signatures or notarization, so Gatekeeper may
require user approval for a quarantined download.

KOReader has no native Windows runtime. Its documented Windows route uses the
Debian/Linux build inside WSL; that environment should install
`mangaocr-x86_64-unknown-linux-musl.zip`. Windows CI compiles and tests the Rust
backend to catch portability bugs, but the project does not publish a native
Windows worker that KOReader cannot launch.

The `all` script target intentionally remains the four Linux/musl packages.
Apple workers require the Apple SDK and are built explicitly on macOS:

```sh
scripts/build-release.sh macos-intel
scripts/build-release.sh macos-arm64
```

Examples:

```sh
scripts/build-release.sh native
MANGAOCR_BUILDER=cross scripts/build-release.sh kindle
MANGAOCR_BUILDER=cross scripts/build-release.sh all
```

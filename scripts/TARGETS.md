# Build targets

Release archives include the Rust target triple in the filename:

| Script name | Rust target / archive suffix | Intended use |
| --- | --- | --- |
| `desktop` | `x86_64-unknown-linux-musl` | 64-bit desktop Linux and KOReader development |
| `aarch64` | `aarch64-unknown-linux-musl` | 64-bit Arm Linux readers |
| `kindle` | `arm-unknown-linux-musleabi` | 32-bit Arm, legacy or soft-float Kindle ABI |
| `kindlehf` | `arm-unknown-linux-musleabihf` | 32-bit Arm, hard-float Kindle ABI |
| `native` | `native` | The current host; GitHub releases build this on Ubuntu x86_64/glibc |

As one concrete example, a Kindle Basic 10th generation / KT4 (2019) on Amazon
firmware 5.18.1.1.1 should use the hard-float artifact. KOReader's current
Kindle release guidance selects its hard-float package for Amazon firmware
5.16.3 and newer
([KOReader releases](https://github.com/koreader/koreader/releases)):

```text
mangaocr-arm-unknown-linux-musleabihf.zip
```

PW4/KT4-era Kindles use i.MX6/ARMv7-class processors, but older KOReader
firmware packages may still use soft-float. A hard-float executable cannot be
treated as a drop-in replacement for a soft-float one, so tagged releases
retain `arm-unknown-linux-musleabi` as a secondary, legacy artifact. This is
only a target-selection example; the plugin and packaging remain model-agnostic.

The musl builds are intended to be self-contained. Release CI rejects a worker
that contains an ELF program interpreter. For an older device whose firmware
ABI is unknown, try `arm-unknown-linux-musleabi`; for the confirmed KT4
firmware above, use `arm-unknown-linux-musleabihf`. Real-device validation is
still necessary, especially on older Kindle kernels.

Rust 1.90 still distributes both Arm targets. The soft-float target is therefore
not removed from the build, even though it mainly serves legacy devices.
Cross-compilation also needs a matching C linker/sysroot:

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
the x86_64 musl artifact for portable desktop Linux use. Native Windows and
macOS packaging is not yet claimed: the packaging environment and KOReader
worker-launch behavior would need to be validated before publishing either.

Examples:

```sh
scripts/build-release.sh native
MANGAOCR_BUILDER=cross scripts/build-release.sh kindle
MANGAOCR_BUILDER=cross scripts/build-release.sh all
```

# shellcheck shell=bash

# Resolve friendly package names to Rust target triples. Keep this list in sync
# with the supported-build and release workflow matrices.
mangaocr_target_triple() {
    case "${1:-}" in
        native)
            printf '%s\n' ""
            ;;
        desktop | desktop-musl | x86_64 | x86_64-unknown-linux-musl)
            printf '%s\n' "x86_64-unknown-linux-musl"
            ;;
        aarch64 | arm64 | aarch64-unknown-linux-musl)
            printf '%s\n' "aarch64-unknown-linux-musl"
            ;;
        kindle | kindle-softfloat | arm-unknown-linux-musleabi)
            printf '%s\n' "arm-unknown-linux-musleabi"
            ;;
        kindlehf | kindle-hardfloat | arm-unknown-linux-musleabihf)
            printf '%s\n' "arm-unknown-linux-musleabihf"
            ;;
        macos-intel | macos-x86_64 | x86_64-apple-darwin)
            printf '%s\n' "x86_64-apple-darwin"
            ;;
        macos-arm64 | macos-aarch64 | aarch64-apple-darwin)
            printf '%s\n' "aarch64-apple-darwin"
            ;;
        *)
            return 1
            ;;
    esac
}

mangaocr_target_name() {
    local triple

    triple="$(mangaocr_target_triple "${1:-}")" || return 1
    if [[ -n "$triple" ]]; then
        printf '%s\n' "$triple"
    else
        printf '%s\n' "native"
    fi
}

mangaocr_release_targets() {
    printf '%s\n' \
        "x86_64-unknown-linux-musl" \
        "aarch64-unknown-linux-musl" \
        "arm-unknown-linux-musleabi" \
        "arm-unknown-linux-musleabihf"
}

mangaocr_print_target_help() {
    cat <<'EOF'
Targets:
  native                    Current host (useful for local KOReader development)
  desktop                   x86_64-unknown-linux-musl
  aarch64, arm64            aarch64-unknown-linux-musl
  kindle                    arm-unknown-linux-musleabi (soft-float ABI)
  kindlehf                  arm-unknown-linux-musleabihf (hard-float ABI)
  macos-intel               x86_64-apple-darwin
  macos-arm64               aarch64-apple-darwin

The full Rust triples shown above are also accepted. Use `kindlehf` when the
installed KOReader package uses the hard-float ABI and `kindle` when it uses
the soft-float ABI. Choose by package ABI rather than device model or
operating-system version.
Windows users run KOReader through WSL and should use the `desktop` Linux
package; KOReader does not currently provide a native Windows runtime.
See scripts/TARGETS.md for compatibility and toolchain details.
EOF
}

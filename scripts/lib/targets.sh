# shellcheck shell=bash

# Resolve friendly release names to Rust target triples. Keep this list in sync
# with the release workflow matrix.
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
  kindle                    arm-unknown-linux-musleabi (legacy/soft-float ABI)
  kindlehf                  arm-unknown-linux-musleabihf (hard-float ABI)

The full Rust triples shown above are accepted too.
For example, a KT4 on firmware 5.18.1.1.1 uses `kindlehf`: KOReader's Kindle
packages for firmware 5.16.3 and newer use the hard-float ABI. Use `kindle`
for older soft-float firmware, or when testing an unknown legacy setup.
See scripts/TARGETS.md for compatibility and toolchain details.
EOF
}

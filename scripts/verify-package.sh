#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"

# shellcheck source=scripts/lib/targets.sh
source "$script_dir/lib/targets.sh"

usage() {
    cat <<'EOF'
Usage: scripts/verify-package.sh [TARGET]

Verify the packaged plugin archive and its worker architecture. TARGET defaults
to native and accepts the aliases documented by build-worker.sh.
EOF
    mangaocr_print_target_help
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if (( $# > 1 )); then
    usage >&2
    exit 2
fi

requested_target="${1:-native}"
if ! target_name="$(mangaocr_target_name "$requested_target")"; then
    printf 'error: unsupported target: %s\n\n' "$requested_target" >&2
    mangaocr_print_target_help >&2
    exit 2
fi

dist_dir="${MANGAOCR_DIST_DIR:-$project_root/dist}"
if [[ "$dist_dir" != /* ]]; then
    dist_dir="$project_root/$dist_dir"
fi
archive="$dist_dir/mangaocr-$target_name.zip"
unzip -tqq "$archive"

archive_entries="$(unzip -Z1 "$archive")"
for required_entry in \
    mangaocr.koplugin/mangaocr-worker \
    mangaocr.koplugin/LICENSE \
    mangaocr.koplugin/LICENSE.Manatan \
    mangaocr.koplugin/LICENSE.chrome_lens_ocr \
    mangaocr.koplugin/LICENSE.mokuroreader-koreader \
    mangaocr.koplugin/THIRD_PARTY_LICENSES.html \
    mangaocr.koplugin/THIRD_PARTY_NOTICES.md
do
    if ! grep -Fxq "$required_entry" <<<"$archive_entries"; then
        printf 'error: package is missing required entry: %s\n' \
            "$required_entry" >&2
        exit 1
    fi
done

if grep -Eq '_spec\.lua$' <<<"$archive_entries"; then
    printf 'error: test specs must not be included in release packages\n' >&2
    exit 1
fi

extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/mangaocr-verify.XXXXXX")"
cleanup() {
    rm -rf "$extract_dir"
}
trap cleanup EXIT
unzip -q "$archive" -d "$extract_dir"
worker="$extract_dir/mangaocr.koplugin/mangaocr-worker"

if [[ ! -x "$worker" ]]; then
    printf 'error: archived worker is missing or not executable: %s\n' \
        "$worker" >&2
    exit 1
fi

case "$target_name" in
    x86_64-apple-darwin)
        if [[ "$(lipo -archs "$worker")" != "x86_64" ]]; then
            printf 'error: macOS worker is not a single-architecture x86_64 binary\n' >&2
            exit 1
        fi
        codesign --verify --strict "$worker"
        "$worker" --version
        ;;
    aarch64-apple-darwin)
        if [[ "$(lipo -archs "$worker")" != "arm64" ]]; then
            printf 'error: macOS worker is not a single-architecture arm64 binary\n' >&2
            exit 1
        fi
        codesign --verify --strict "$worker"
        "$worker" --version
        ;;
    native)
        "$worker" --version
        ;;
    *-unknown-linux-musl)
        program_headers="$(readelf --program-headers "$worker")"
        if grep -q INTERP <<<"$program_headers"; then
            printf 'error: portable worker contains a dynamic program interpreter\n' >&2
            exit 1
        fi
        ;;
esac

printf 'Verified plugin package: %s\n' "$archive"

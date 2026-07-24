#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=scripts/lib/targets.sh
source "$script_dir/lib/targets.sh"

usage() {
    cat <<'EOF'
Usage: scripts/build-release.sh [TARGET|all]

Build mangaocr-worker and package mangaocr.koplugin. TARGET defaults to native.
The `all` target builds the four portable musl release targets.

Set MANGAOCR_BUILDER=cross for a containerized cross build, or
MANGAOCR_BUILDER=zigbuild for cargo-zigbuild. See build-worker.sh --help for
requirements.
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

build_one() {
    local target="$1"

    "$script_dir/build-worker.sh" "$target"
    "$script_dir/package-plugin.sh" "$target"
}

requested_target="${1:-native}"
if [[ "$requested_target" == "all" ]]; then
    while IFS= read -r release_target; do
        build_one "$release_target"
    done < <(mangaocr_release_targets)
else
    if ! mangaocr_target_triple "$requested_target" >/dev/null; then
        printf 'error: unsupported target: %s\n\n' "$requested_target" >&2
        mangaocr_print_target_help >&2
        exit 2
    fi
    build_one "$requested_target"
fi

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"

# shellcheck source=scripts/lib/targets.sh
source "$script_dir/lib/targets.sh"

usage() {
    cat <<'EOF'
Usage: scripts/package-plugin.sh [TARGET] [WORKER_PATH]

Assemble both:
  dist/TARGET/mangaocr.koplugin/
  dist/mangaocr-TARGET.zip

TARGET defaults to native. WORKER_PATH defaults to the matching release
artifact below backend/target.

Environment:
  MANGAOCR_TARGET_DIR  Cargo output directory (default: backend/target)
  MANGAOCR_DIST_DIR    Package output directory (default: dist)

Only the selected target's existing outputs are replaced. Source files and
other target outputs are left untouched.
EOF
    mangaocr_print_target_help
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (( $# > 2 )); then
    usage >&2
    exit 2
fi

requested_target="${1:-native}"
if ! target_triple="$(mangaocr_target_triple "$requested_target")"; then
    printf 'error: unsupported target: %s\n\n' "$requested_target" >&2
    mangaocr_print_target_help >&2
    exit 2
fi
target_name="$(mangaocr_target_name "$requested_target")"

frontend_dir="$project_root/frontend/mangaocr.koplugin"
if [[ ! -f "$frontend_dir/main.lua" || ! -f "$frontend_dir/_meta.lua" ]]; then
    printf 'error: incomplete plugin source directory: %s\n' "$frontend_dir" >&2
    exit 1
fi

"$script_dir/check-third-party-licenses.sh" "$requested_target"

target_dir="${MANGAOCR_TARGET_DIR:-$project_root/backend/target}"
if [[ "$target_dir" != /* ]]; then
    target_dir="$project_root/$target_dir"
fi

if (( $# == 2 )); then
    worker_path="$2"
    if [[ "$worker_path" != /* ]]; then
        worker_path="$PWD/$worker_path"
    fi
else
    artifact_dir="$target_dir"
    if [[ -n "$target_triple" ]]; then
        artifact_dir="$artifact_dir/$target_triple"
    fi
    worker_path="$artifact_dir/release/mangaocr-worker"
fi

if [[ ! -f "$worker_path" ]]; then
    printf 'error: worker binary not found: %s\n' "$worker_path" >&2
    printf 'hint: run scripts/build-worker.sh %s first\n' "$requested_target" >&2
    exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
    printf 'error: zip is required to create the KOReader plugin archive\n' >&2
    exit 1
fi

dist_dir="${MANGAOCR_DIST_DIR:-$project_root/dist}"
if [[ "$dist_dir" != /* ]]; then
    dist_dir="$project_root/$dist_dir"
fi
if [[ "$dist_dir" == "/" ]]; then
    printf 'error: refusing to use / as MANGAOCR_DIST_DIR\n' >&2
    exit 1
fi
if [[ -L "$dist_dir" ]]; then
    printf 'error: refusing to replace packages through a symlinked output directory: %s\n' \
        "$dist_dir" >&2
    exit 1
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/mangaocr-package.XXXXXX")"
cleanup() {
    if [[ -n "${temporary_dir:-}" && -d "$temporary_dir" ]]; then
        rm -rf "$temporary_dir"
    fi
}
trap cleanup EXIT HUP INT TERM

stage_root="$temporary_dir/stage"
staged_plugin="$stage_root/mangaocr.koplugin"
staged_archive="$temporary_dir/mangaocr-$target_name.zip"
mkdir -p "$staged_plugin"
cp -Rp "$frontend_dir/." "$staged_plugin/"
find "$staged_plugin" -type f -name '*_spec.lua' -delete
install -m 0755 "$worker_path" "$staged_plugin/mangaocr-worker"
install -m 0644 "$project_root/LICENSE" "$staged_plugin/LICENSE"
install -m 0644 "$project_root/THIRD_PARTY_NOTICES.md" \
    "$staged_plugin/THIRD_PARTY_NOTICES.md"
install -m 0644 \
    "$project_root/backend/vendor/chrome_lens_ocr-0.3.0/LICENSE" \
    "$staged_plugin/LICENSE.chrome_lens_ocr"
install -m 0644 "$project_root/licenses/Manatan-MIT.txt" \
    "$staged_plugin/LICENSE.Manatan"
install -m 0644 "$project_root/licenses/mokuroreader-koreader-MIT.txt" \
    "$staged_plugin/LICENSE.mokuroreader-koreader"
install -m 0644 \
    "$project_root/backend/licenses/THIRD_PARTY_LICENSES.html" \
    "$staged_plugin/THIRD_PARTY_LICENSES.html"

for required_file in \
    LICENSE \
    LICENSE.Manatan \
    LICENSE.chrome_lens_ocr \
    LICENSE.mokuroreader-koreader \
    THIRD_PARTY_LICENSES.html \
    THIRD_PARTY_NOTICES.md
do
    if [[ ! -s "$staged_plugin/$required_file" ]]; then
        printf 'error: release package is missing license file: %s\n' \
            "$required_file" >&2
        exit 1
    fi
done

(
    cd "$stage_root"
    zip -q -X -r "$staged_archive" mangaocr.koplugin
)

target_output_dir="$dist_dir/$target_name"
plugin_output="$target_output_dir/mangaocr.koplugin"
archive_output="$dist_dir/mangaocr-$target_name.zip"
if [[ -L "$target_output_dir" ]]; then
    printf 'error: refusing to replace packages through a symlinked target directory: %s\n' \
        "$target_output_dir" >&2
    exit 1
fi
mkdir -p "$target_output_dir"

# These are exact, target-scoped build outputs. Staging first keeps a failed
# copy or zip operation from damaging the previous package.
if [[ -e "$plugin_output" || -L "$plugin_output" ]]; then
    rm -rf "$plugin_output"
fi
mv "$staged_plugin" "$plugin_output"

if [[ -e "$archive_output" || -L "$archive_output" ]]; then
    rm -f "$archive_output"
fi
mv "$staged_archive" "$archive_output"

printf 'Plugin directory: %s\n' "$plugin_output"
printf 'Plugin archive:   %s\n' "$archive_output"

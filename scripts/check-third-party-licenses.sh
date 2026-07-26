#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"

# shellcheck source=scripts/lib/targets.sh
source "$script_dir/lib/targets.sh"

usage() {
    cat <<'EOF'
Usage: scripts/check-third-party-licenses.sh [TARGET]

Verify that the checked-in license report covers every normal Rust dependency
for TARGET. TARGET defaults to native and accepts the build-script aliases.
This lightweight check does not require cargo-about.
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
if ! target_triple="$(mangaocr_target_triple "$requested_target")"; then
    printf 'error: unsupported target: %s\n\n' "$requested_target" >&2
    mangaocr_print_target_help >&2
    exit 2
fi
if [[ -z "$target_triple" ]]; then
    target_triple="$(rustc -vV | sed -n 's/^host: //p')"
fi
if [[ -z "$target_triple" ]]; then
    printf 'error: could not determine the Rust host target\n' >&2
    exit 1
fi

report="$project_root/backend/licenses/THIRD_PARTY_LICENSES.html"
manatan_license="$project_root/licenses/Manatan-MIT.txt"
mokuroreader_license="$project_root/licenses/mokuroreader-koreader-MIT.txt"

for required_file in "$report" "$manatan_license" "$mokuroreader_license"; do
    if [[ ! -s "$required_file" ]]; then
        printf 'error: required license file is missing or empty: %s\n' \
            "$required_file" >&2
        exit 1
    fi
done

grep -Fq 'cargo-about 0.9.1' "$report"
grep -Fq 'Copyright (c) 2025 Kolby Moroz Liebl' "$manatan_license"
grep -Fq 'Copyright (c) 2025 [TON_NOM]' "$mokuroreader_license"

missing=0
if ! dependency_list="$(
    cargo tree \
        --manifest-path "$project_root/backend/Cargo.toml" \
        --locked \
        --target "$target_triple" \
        --edges normal \
        --prefix none \
        --format '{p}' |
        LC_ALL=C sort -u
)"; then
    printf 'error: could not resolve dependencies for %s\n' \
        "$target_triple" >&2
    exit 1
fi

while read -r package version _; do
    if [[ -z "$package" ]]; then
        continue
    fi
    version="${version#v}"
    if [[ "$package" == "mangaocr-worker" ]]; then
        continue
    fi
    marker="data-cargo-package=\"$package $version\""
    if ! grep -Fq "$marker" "$report"; then
        printf 'error: dependency is missing from the license report: %s %s\n' \
            "$package" "$version" >&2
        missing=1
    fi
done <<<"$dependency_list"

if (( missing != 0 )); then
    printf 'hint: regenerate with scripts/generate-third-party-licenses.sh\n' >&2
    exit 1
fi

printf 'Third-party license coverage is complete for %s\n' "$target_triple"

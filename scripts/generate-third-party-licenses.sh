#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"

usage() {
    cat <<'EOF'
Usage: scripts/generate-third-party-licenses.sh [--check]

Generate backend/licenses/THIRD_PARTY_LICENSES.html with cargo-about 0.9.1.
With --check, verify that the checked-in report is current without replacing it.

Set CARGO_ABOUT to an alternate cargo-about executable when needed.
EOF
}

mode="generate"
case "${1:-}" in
    "")
        ;;
    --check)
        mode="check"
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
if (( $# > 1 )); then
    usage >&2
    exit 2
fi

cargo_about="${CARGO_ABOUT:-cargo-about}"
if ! command -v "$cargo_about" >/dev/null 2>&1; then
    printf 'error: cargo-about 0.9.1 is required to generate license notices\n' >&2
    printf 'hint: cargo install --locked --version 0.9.1 --features cli cargo-about\n' >&2
    exit 1
fi

actual_version="$("$cargo_about" --version)"
if [[ "$actual_version" != "cargo-about 0.9.1" ]]; then
    printf 'error: expected cargo-about 0.9.1, got: %s\n' "$actual_version" >&2
    exit 1
fi

output="$project_root/backend/licenses/THIRD_PARTY_LICENSES.html"
temporary_output="$(mktemp "${TMPDIR:-/tmp}/mangaocr-licenses.XXXXXX")"
cleanup() {
    rm -f -- "$temporary_output"
}
trap cleanup EXIT HUP INT TERM

"$cargo_about" generate \
    --manifest-path "$project_root/backend/Cargo.toml" \
    --config "$project_root/backend/licenses/about.toml" \
    --locked \
    --fail \
    --output-file "$temporary_output" \
    "$project_root/backend/licenses/about.hbs"

# Upstream license files occasionally contain CRLF endings or insignificant
# trailing spaces. Normalize the generated report so repository whitespace
# checks remain deterministic without altering any license wording.
sed -i 's/\r$//; s/[[:blank:]]\+$//' "$temporary_output"

if [[ "$mode" == "check" ]]; then
    if ! cmp -s -- "$temporary_output" "$output"; then
        printf 'error: %s is stale; regenerate it with:\n' "$output" >&2
        printf '  scripts/generate-third-party-licenses.sh\n' >&2
        exit 1
    fi
    printf 'Third-party Rust license report is current: %s\n' "$output"
else
    mv -- "$temporary_output" "$output"
    temporary_output=""
    printf 'Generated third-party Rust license report: %s\n' "$output"
fi

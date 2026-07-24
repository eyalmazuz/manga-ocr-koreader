#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"

# shellcheck source=scripts/lib/targets.sh
source "$script_dir/lib/targets.sh"

usage() {
    cat <<'EOF'
Usage: scripts/build-worker.sh [TARGET]

Build the mangaocr-worker release binary. TARGET defaults to native.

Environment:
  MANGAOCR_BUILDER     cargo (default), cross, or zigbuild
  MANGAOCR_TARGET_DIR  Cargo output directory (default: backend/target)

The default cargo builder never starts a container. Cross-compiling with it
requires an installed Rust target plus a suitable C linker/sysroot.

The cross builder requires the `cross` command and a running Docker or Podman
container engine. The zigbuild builder requires `cargo-zigbuild` and Zig.
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

backend_dir="$project_root/backend"
manifest_path="$backend_dir/Cargo.toml"
if [[ ! -f "$manifest_path" ]]; then
    printf 'error: Rust manifest not found: %s\n' "$manifest_path" >&2
    exit 1
fi

target_dir="${MANGAOCR_TARGET_DIR:-$backend_dir/target}"
if [[ "$target_dir" != /* ]]; then
    target_dir="$project_root/$target_dir"
fi

builder="${MANGAOCR_BUILDER:-cargo}"
case "$builder" in
    cargo)
        build_command=(cargo build)
        ;;
    cross)
        build_command=(cross build)
        ;;
    zigbuild)
        build_command=(cargo zigbuild)
        ;;
    *)
        printf 'error: MANGAOCR_BUILDER must be cargo, cross, or zigbuild (got %s)\n' \
            "$builder" >&2
        exit 2
        ;;
esac

if ! command -v "${build_command[0]}" >/dev/null 2>&1; then
    printf 'error: required build command is not installed: %s\n' \
        "${build_command[*]}" >&2
    exit 1
fi

cd "$backend_dir"

if [[ -n "$target_triple" ]]; then
    known_targets="$(rustc --print target-list)"
    if ! grep -Fqx -- "$target_triple" <<<"$known_targets"; then
        printf 'error: Rust %s does not recognize target %s\n' \
            "$(rustc --version)" "$target_triple" >&2
        exit 1
    fi

    if [[ "$builder" == "cargo" ]] && command -v rustup >/dev/null 2>&1; then
        installed_targets="$(rustup target list --installed)"
        if ! grep -Fqx -- "$target_triple" <<<"$installed_targets"; then
            printf 'error: Rust target %s is not installed\n' "$target_triple" >&2
            printf 'hint: run: rustup target add %s\n' "$target_triple" >&2
            printf 'hint: a matching linker/sysroot is also required, or use MANGAOCR_BUILDER=cross\n' >&2
            exit 1
        fi
    fi
fi

build_args=(
    --manifest-path "$manifest_path"
    --target-dir "$target_dir"
    --locked
    --release
    --package mangaocr-worker
    --bin mangaocr-worker
)
if [[ -n "$target_triple" ]]; then
    build_args+=(--target "$target_triple")
fi

printf 'Building mangaocr-worker with %s for %s\n' \
    "$builder" "$(mangaocr_target_name "$requested_target")" >&2
"${build_command[@]}" "${build_args[@]}"

artifact_dir="$target_dir"
if [[ -n "$target_triple" ]]; then
    artifact_dir="$artifact_dir/$target_triple"
fi
artifact_path="$artifact_dir/release/mangaocr-worker"

if [[ ! -f "$artifact_path" ]]; then
    printf 'error: build succeeded but worker was not found: %s\n' "$artifact_path" >&2
    exit 1
fi

chmod +x -- "$artifact_path"
printf '%s\n' "$artifact_path"

#!/usr/bin/env bash
# Publish the same target/profile directory used by the Tauri compilation.
set -euo pipefail

args=("$@")
target_dir="src-tauri/target"
profile="release"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target|-t) target_dir="src-tauri/target/${2:?Missing target triple}"; shift ;;
    --target=*) target_dir="src-tauri/target/${1#*=}" ;;
    --debug|-d) profile="debug" ;;
  esac
  shift
done

bun run tauri build --no-bundle "${args[@]}"
echo "directory=$target_dir/$profile" >> "${GITHUB_OUTPUT:?Missing GITHUB_OUTPUT}"

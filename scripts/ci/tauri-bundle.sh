#!/usr/bin/env bash
# tauri-action appends "build". Compile in the earlier step, then only bundle here.
set -euo pipefail

if [ "${1:-}" != "build" ]; then
  echo "Expected tauri-action's build command; refusing to run another command." >&2
  exit 1
fi
shift
exec bun run tauri bundle "$@"

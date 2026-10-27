#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
CORE_MANIFEST="$REPOSITORY_ROOT/crates/yanyu-core/Cargo.toml"
IOS_DIRECTORY="$REPOSITORY_ROOT/ios"
CORE_OUTPUT_DIRECTORY="$REPOSITORY_ROOT/target/yanyu-core"
IOS_DEVICE_OUTPUT="$IOS_DIRECTORY/build/iphoneos"
IOS_SIMULATOR_OUTPUT="$IOS_DIRECTORY/build/iphonesimulator"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

export CARGO_TARGET_DIR="$CORE_OUTPUT_DIRECTORY"
# transcribe-cpp-sys currently forwards C++'s -std flag to CMake's C flags;
# clear that C-only flag and pin native objects to the app's deployment target.
export TRANSCRIBE_CMAKE_ARGS="-DCMAKE_C_FLAGS= -DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET"

CORE_DEPENDENCIES="$(
  cargo tree --locked --manifest-path "$CORE_MANIFEST" --all-features --target all \
    --edges normal,build,dev --prefix none --format '{p}'
)"
if grep -Eq '^tauri([_-][^[:space:]]*)?[[:space:]]+v[0-9]' <<<"$CORE_DEPENDENCIES"; then
  printf 'The iOS portable core must not depend on Tauri crates.\n' >&2
  exit 1
fi

cargo build --locked --manifest-path "$CORE_MANIFEST" --release --target aarch64-apple-ios --features inference
cargo build --locked --manifest-path "$CORE_MANIFEST" --release --target aarch64-apple-ios-sim --features inference

(
  cd "$REPOSITORY_ROOT/crates/yanyu-core"
  cargo run --locked --features bindgen --bin uniffi-bindgen -- generate \
    "$CORE_OUTPUT_DIRECTORY/aarch64-apple-ios/release/libyanyu_core.a" \
    --language swift \
    --out-dir "$IOS_DIRECTORY/Yanyu/Generated"
)

# UniFFI emits trailing spaces and an extra blank line at EOF in these files.
# Keep generated diffs clean after regeneration.
for generated_file in \
  "$IOS_DIRECTORY/Yanyu/Generated/yanyu_core.swift" \
  "$IOS_DIRECTORY/Yanyu/Generated/yanyu_coreFFI.h"
do
  perl -pi -e 's/[ \t]+$//' "$generated_file"
  perl -0777 -pi -e 's/\n+\z/\n/' "$generated_file"
done

mkdir -p "$IOS_DEVICE_OUTPUT" "$IOS_SIMULATOR_OUTPUT"
cp "$CORE_OUTPUT_DIRECTORY/aarch64-apple-ios/release/libyanyu_core.a" "$IOS_DEVICE_OUTPUT/"
cp "$CORE_OUTPUT_DIRECTORY/aarch64-apple-ios-sim/release/libyanyu_core.a" "$IOS_SIMULATOR_OUTPUT/"

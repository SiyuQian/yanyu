# Runtime and persistence

Status: verified 2026-10-10 by source inspection. Historical rationale is not recorded; the observations below describe current mechanisms.

## Command/event integration

[lib.rs](../../src-tauri/src/lib.rs) collects Rust commands and typed events with tauri-specta. Debug builds export [bindings.ts](../../src/bindings.ts). React stores call these commands and listen to runtime events. Backend managers remain responsible for hardware and persistence.

## Data ownership

[settings.rs](../../src-tauri/src/settings.rs) persists settings in a Tauri store and includes migrations and partial-store salvage. [history.rs](../../src-tauri/src/managers/history.rs) owns SQLite migrations and recording files. [portable.rs](../../src-tauri/src/portable.rs) handles portable paths.

The application identifier is `com.siyuqian.yanyu`. Handy data does not migrate automatically, as stated in [README](../../README.md).

## Inference and polishing

[Transcription](../../src-tauri/src/managers/transcription.rs) supports more than the inherited Whisper-only description. [Local polishing](../../src-tauri/src/managers/local_polishing.rs) downloads pinned artifacts with hashes and applies a bounded generation budget. [Remote LLM processing](../../src-tauri/src/llm_client.rs) sends text to configured providers. See [security](../SECURITY.md) before changing this boundary.

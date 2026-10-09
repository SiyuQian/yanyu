# Runtime reliability

## Topology

A desktop process hosts managers and platform integrations. [Startup](../src-tauri/src/lib.rs) creates windows and tray state according to settings and CLI arguments. Second-instance control commands reach the existing process. Startup is not unconditionally hidden.

The [coordinator](../src-tauri/src/transcription_coordinator.rs) serializes trigger events, uses 30 ms debounce and 50 ms release grace, and remembers presses during processing. Its tests run with `cargo test`.

## Failure behavior and budgets

[Local polishing](../src-tauri/src/managers/local_polishing.rs) defines a 500 ms output budget with cooperative cancellation and fallback behavior. Its downloader sets a 600 second HTTP timeout. These constants are local implementation budgets, not an application SLO.

[Settings](../src-tauri/src/settings.rs) salvages valid fields from partially invalid stores. [History](../src-tauri/src/managers/history.rs) applies SQLite migrations. Preserve data recovery behavior when editing these paths.

[ErrorBoundary](../src/components/ErrorBoundary.tsx) catches React failures. Rust modules use logging, and `--debug` enables verbose logging. No service health endpoint, on-call process or overall latency SLO is established by the inspected repository.

## Native verification

Exercise recording/cancellation, model load/unload, second-instance commands and paste behavior on the target OS after changing those paths. Browser suites do not cover actual devices or system permission state. Platform setup and overlay fallbacks are in [Development](DEVELOPMENT.md).

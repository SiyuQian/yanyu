# Security and data handling

Reviewed by static inspection on 2026-10-10. This is a control inventory, not a security certification.

## Personal data and secrets

[README](../README.md) requires personal recordings and training data to remain local and outside this public repository. [History](../src-tauri/src/managers/history.rs) stores transcripts in SQLite and recordings in files. Local recognition does not make every configured workflow offline: [LLM processing](../src-tauri/src/llm_client.rs) sends text to configured providers.

[Settings](../src-tauri/src/settings.rs) contains serializable `post_process_api_keys`. `SecretMap` redacts Debug output, but this does not encrypt the settings store. Treat settings backups as sensitive. The LLM client sanitizes URLs in error logging and includes sanitization tests. Preserve these controls. Check: `cargo test` for unit checks and review for data flows. See debt D4 and D6.

## Desktop trust boundary

[Tauri capabilities](../src-tauri/capabilities/default.json) authorize main and recording-overlay windows. The desktop capability file adds platform permissions. [Configuration](../src-tauri/tauri.conf.json) currently sets CSP to null and enables asset protocol with a broad scope. Do not describe this as a strict sandbox; debt D5 proposes review.

OS microphone/accessibility permissions are handled in [App](../src/App.tsx) and platform integrations. The desktop app has no server login layer in this architecture; provider API authentication is a separate boundary.

## Models and distribution

[Local polishing](../src-tauri/src/managers/local_polishing.rs) pins artifact URLs and SHA-256 values. Do not generalize this guarantee to every catalog artifact without inspecting its downloader.

`bun.lock` and `src-tauri/Cargo.lock` record dependency resolutions. CI uses frozen Bun installation in the code-quality workflow. No dedicated dependency audit job was identified in the inspected workflows.

[README](../README.md) states that Yanyu automatic updates are disabled until its own channel and signing keys exist. Current bundle configuration disables updater artifacts; macOS uses ad hoc signing and Windows has no configured publisher signature. These are distribution limits, not a release policy.

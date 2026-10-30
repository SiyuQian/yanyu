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

### Dependency remediation: 2026-10-31

The [Yanyu security report](https://security.siyu.co.nz/?repo=SiyuQian%2Fyanyu) scanned commit `cff9a67e7fe98f2302ca46e901c5e938b0ab0a70` and listed 29 Critical/High dependency findings. The updated lockfiles remove all 29. Updated packages include ZIP, Vite, Rollup, Zod, PostCSS, source-map-js, minimatch, brace-expansion, picomatch, nanoid, flatted, js-yaml, Browserslist and Lodash. The Nix Bun dependency expressions and lock hash are regenerated with the Bun lockfile.

ZIP resolves to 9.1.3 for both Candle and the updater, including non-macOS targets. Candle's published 0.11.0 release requires vulnerable ZIP 8.6; the related crates are temporarily pinned together to [upstream's ZIP security fix](https://github.com/huggingface/candle/commit/9515d410e3af803fd45efebfef8137f47d85a63d). Replace these patches when a compatible release includes the fix. The updater requires Tauri 2.12, so the Windows WebView2/Windows dependencies follow its versions. Tao 0.37.2 includes the previously patched Wayland decoration fix and uses `DefWindowProcW` for the event target; the obsolete Tao patches are removed.

The review also found two XML denial-of-service advisories rated CVSS 7.5 but displayed as UNKNOWN: `RUSTSEC-2026-0194` and `RUSTSEC-2026-0195`. Updating both `plist` and Linux's `wayland-scanner` removes the vulnerable quick-xml version. Compatible security updates also cover TLS roots, rustls, h2, Tokio, memmap2, anyhow, event-listener and rand 0.8.

Reproduce the dependency checks from the repository root:

```bash
bun audit --json
osv-scanner scan source --lockfile bun.lock --lockfile src-tauri/Cargo.lock \
  --lockfile crates/yanyu-core/Cargo.lock --format json --output-file osv-results.json
```

OSV-Scanner 2.7.0 reports zero Critical/High findings across these three lockfiles after remediation. Lower-severity and unmaintained/otherwise unrated dependencies remain; a nonzero scanner exit status is expected. The hosted tracker still needs a scan of the integrated commit before its findings disappear. Windows/Linux native builds, Nix builds and real-model inference require separate platform verification.

Validation on Apple Silicon macOS: frozen Bun installation, frontend build, lint, formatting, translation/model-language checks, keyboard assertions, 9 build-script tests, 7 recording-review tests (including its browser test), and 98 Playwright tests pass. Recording-review TypeScript checks also pass after Zod's major-version update. Rust library tests pass (334 passed, 25 ignored); clippy completes with warnings in unchanged application code. Rust commands used `env -u CFLAGS` because the host exports `CFLAGS=-std=c++17`, which is invalid for Objective-C compilation.

[README](../README.md) states that Yanyu automatic updates are disabled until its own channel and signing keys exist. Current bundle configuration disables updater artifacts; macOS uses ad hoc signing and Windows has no configured publisher signature. These are distribution limits, not a release policy.

# Architecture

Reviewed against repository source on 2026-10-10. This describes implementation, not the future training workflow.

## Overview

Yanyu embeds a React interface in a Tauri 2 desktop runtime. Rust owns microphone capture, model inference, history, settings persistence and OS input. Branding and data identity are independent from Handy ([configuration](src-tauri/tauri.conf.json)).

Recording flow: shortcut or CLI → coordinator → actions → audio capture/resampling/VAD → transcription manager → optional post-processing → history and clipboard/paste.

## Domains and layers

| Domain                    | Ownership and dependencies                                                                                                                                                                                                                              | Boundary                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| UI                        | [App](src/App.tsx), components, hooks and Zustand stores call typed Tauri commands and consume events                                                                                                                                                   | UI uses IPC instead of importing Rust implementation                            |
| IPC/runtime               | [lib.rs](src-tauri/src/lib.rs) registers commands/events, initializes managers and exports bindings in debug builds                                                                                                                                     | Runtime composes platform services and business managers                        |
| Recording control         | [Coordinator](src-tauri/src/transcription_coordinator.rs), [actions](src-tauri/src/actions.rs), [signals](src-tauri/src/signal_handle.rs) normalize triggers                                                                                            | Shared recording semantics belong here, not in each trigger                     |
| Audio                     | [Manager](src-tauri/src/managers/audio.rs) uses [audio toolkit](src-tauri/src/audio_toolkit/) for device access, resampling and VAD                                                                                                                     | Hardware handling stays below command/UI adapters                               |
| Inference/model lifecycle | [Transcription](src-tauri/src/managers/transcription.rs), [models](src-tauri/src/managers/model.rs), [supervisor](src-tauri/src/engine_supervisor/), [catalog](src-tauri/src/catalog/)                                                                  | transcribe-cpp serves Whisper-family engines; transcribe-rs serves ONNX engines |
| Post-processing           | [Local polishing](src-tauri/src/managers/local_polishing.rs), [LLM client](src-tauri/src/llm_client.rs), [Apple Intelligence](src-tauri/src/apple_intelligence.rs)                                                                                      | Local and remote processing have different privacy and failure properties       |
| Persistence/output        | [Settings](src-tauri/src/settings.rs) uses Tauri store; [history](src-tauri/src/managers/history.rs) uses SQLite and recording files; [clipboard](src-tauri/src/clipboard.rs) and [paste transactions](src-tauri/src/paste_tx/) integrate with OS input | Preserve stored settings/history compatibility and clipboard behavior           |

These are responsibility boundaries, not isolated packages. Managers use Tauri handles and emit events. No mechanical import-layer check exists; review.

## Invariants

1. UI text uses translation keys. Check: `bun run lint` for JSX, `bun run check:translations` for locale consistency. These do not prove all Rust messages are translated.
2. Runtime CLI overrides do not mutate persisted settings. Sources: [CLI](src-tauri/src/cli.rs), [startup](src-tauri/src/lib.rs). Check: none, review; debt D1.
3. Second-instance remote-control commands reach shared transcription input. Sources: [startup](src-tauri/src/lib.rs), [signal handler](src-tauri/src/signal_handle.rs). Check: none for end-to-end IPC, review; debt D1.
4. Settings migrations and history migrations preserve user data. Sources: [settings](src-tauri/src/settings.rs), [history](src-tauri/src/managers/history.rs). Settings unit tests provide partial coverage via `cargo test`; no complete upgrade-fixture check, review; debt D2.
5. Bindings derive from registered Rust commands/events. Source: debug export in [lib.rs](src-tauri/src/lib.rs). `bun run build` checks frontend usage, but no generated-drift check exists, review; debt D3.
6. Personal recordings/training data stay outside the public repository. Source: [README](README.md). Check: none, review; debt D4.

## Extension points

- Commands: implement under `src-tauri/src/commands/`, register in `lib.rs`, regenerate bindings through a debug desktop build.
- Models: inspect catalog, capability probes and model/transcription managers together; run `bun run check:model-languages`.
- Settings: inspect Rust defaults/migrations, registered setters, generated bindings and Zustand consumers together.
- UI: reuse shared UI components and translation keys; follow [Frontend](docs/FRONTEND.md).
- Trigger behavior: inspect the coordinator and every shortcut/CLI/signal consumer before changing semantics.

## Decisions

[Runtime and persistence](docs/design-docs/runtime-and-persistence.md) records implemented command/event and storage choices. [Product scope](docs/PRODUCT_SENSE.md) separates shipped behavior from intentions.

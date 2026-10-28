# Development reference

Migrated from AGENTS.md on 2026-10-10. Commands and inherited contributor rules remain available here. See the root architecture for the current implementation.

## Development Commands

**Prerequisites:**

- [Rust](https://rustup.rs/) (latest stable)
- [Bun](https://bun.sh/) package manager

**Core Development:**

```bash
# Install dependencies
bun install

# Run in development mode
bun run tauri dev
# If cmake error on macOS:
CMAKE_POLICY_VERSION_MINIMUM=3.5 bun run tauri dev

# Build for production
bun run tauri build

# Build for local testing (separate incremental cache; macOS app bundle only)
bun run build:fast

# Frontend only development
bun run dev        # Start Vite dev server
bun run build      # Build frontend (TypeScript + Vite)
bun run preview    # Preview built frontend
```

**Linting and Formatting (run before committing):**

```bash
bun run lint              # ESLint for frontend
bun run lint:fix          # ESLint with auto-fix
bun run format            # Prettier + cargo fmt
bun run format:check      # Check formatting without changes
bun run format:frontend   # Prettier only
bun run format:backend    # cargo fmt only
bun run test:build        # Fast-build isolation and CI bundling adapters
```

**Model Setup (Required for Development):**

```bash
mkdir -p src-tauri/resources/models
curl -o src-tauri/resources/models/silero_vad_v4.onnx https://blob.handy.computer/silero_vad_v4.onnx
```

For detailed platform-specific build setup, see [BUILD.md](../BUILD.md).

### Selection polishing verification

`polish_selection` defaults to `option+shift+p` on Apple Silicon Macs. It shares the translation popover and Qwen model worker with `translate_selection`, but uses separate editing rules and preserves the model's output writing system. Reading the selection uses Accessibility only. Preview, errors and dismissal do not access the clipboard; the explicit Copy action writes only the current completed result. Selection drafts are transient and never enter dictation history.

```bash
bunx playwright test tests/translation.spec.ts
cargo test --manifest-path src-tauri/Cargo.toml --lib selection
cargo test --manifest-path src-tauri/Cargo.toml --lib managers::translation::tests
# Opt-in real-model fixtures; never use private messages as fixtures.
LOCAL_POLISHING_SMOKE_DIR=/path/to/local-polishing/qwen3-0.6b \
  cargo test --manifest-path src-tauri/Cargo.toml --lib selection_polish_real_model -- --ignored --nocapture
```

These tests cover the shared state, fixed prompt/data boundary, shortcut migration, output parsing and preview/copy behavior. The opt-in test checks synthetic English, Simplified Chinese and Traditional Chinese messages. The language guard measures Han-character overlap; it can reject valid Chinese edits and cannot detect translation between languages using the same alphabet. These checks do not establish semantic fidelity or Accessibility compatibility with every application. Manually check first-use permissions, selection capture, the global shortcut, preview placement and cancellation in target apps before release.

### Native iOS app

The SwiftUI app lives in `ios/`. It requires macOS, Xcode, and XcodeGen. From the repository root:

```bash
node scripts/generate-ios-localizations.mjs
cargo test --manifest-path crates/yanyu-core/Cargo.toml
cargo clippy --manifest-path crates/yanyu-core/Cargo.toml --all-targets -- -D warnings
cd ios
xcodegen generate --spec project.yml
xcodebuild build -project Yanyu.xcodeproj -scheme Yanyu -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Yanyu.xcodeproj -scheme Yanyu -destination 'platform=iOS Simulator,name=iPhone 17' -test-timeouts-enabled YES -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 900 CODE_SIGNING_ALLOWED=NO
```

`src/i18n/locales/en` and `src/i18n/locales/zh` are the iOS translation sources; the generator produces the native string catalog and localized microphone-purpose strings. Run `node scripts/generate-ios-localizations.mjs --check` to verify they are current and `node --test scripts/generate-ios-localizations.test.mjs` for generator unit tests. `project.yml` is the project source of truth; the generated Xcode project is checked in for direct Xcode use. The Xcode target builds `crates/yanyu-core` for iPhone and Apple Silicon simulator and generates its UniFFI bindings; the first build requires Rust targets `aarch64-apple-ios` and `aarch64-apple-ios-sim`, CMake, and Cargo network access. The current deployment target is provisional until the Phase 0 device matrix is approved. Device installation and TestFlight builds require an Apple signing team.

An opt-in real-model simulator bridge test loads `model.gguf` and transcribes `fleurs-zh.wav` and `fleurs-en.wav` from the app's Documents directory. Stage files that way, then run the focused test:

```bash
SIMULATOR_UDID=your-booted-simulator-udid
APP_DATA="$(xcrun simctl get_app_container "$SIMULATOR_UDID" com.siyuqian.yanyu.ios data)"
mkdir -p "$APP_DATA/Documents/yanyu-inference-smoke"
cp /path/to/model.gguf "$APP_DATA/Documents/yanyu-inference-smoke/model.gguf"
cp /path/to/chinese.wav "$APP_DATA/Documents/yanyu-inference-smoke/fleurs-zh.wav"
cp /path/to/english.wav "$APP_DATA/Documents/yanyu-inference-smoke/fleurs-en.wav"
xcodebuild test -project ios/Yanyu.xcodeproj -scheme Yanyu \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:YanyuTests/TranscriberBridgeTests/testRealModelTranscribesProvidedAudioThroughSimulatorBridge \
  CODE_SIGNING_ALLOWED=NO
```

The focused test skips when the model is absent. Public FLEURS samples are licensed CC-BY-4.0; keep downloaded model/audio files outside the repository and retain attribution when redistributing them. [FLEURS dataset card](https://huggingface.co/datasets/google/fleurs).

#### Mixed Chinese-English corpus evaluation

The pinned ASCEND test subset can be prepared and checked with Python's standard library. The downloader refuses repository-local output and writes WAV hashes and attribution next to the manifest:

```bash
python3 scripts/test_prepare_ascend_evaluation.py
python3 scripts/prepare_ascend_evaluation.py \
  --output-dir /tmp/yanyu-ios-spike/ascend \
  --model-name 'Qwen3-ASR 0.6B Q4_K_M'
```

Keep the ASCEND audio, references, and Qwen model outside Git. To run the batch XCTest in a booted simulator, copy the manifest, WAV files, and chosen model into the app container, then run the focused test:

```bash
SIMULATOR_UDID=your-booted-simulator-udid
APP_DATA="$(xcrun simctl get_app_container "$SIMULATOR_UDID" com.siyuqian.yanyu.ios data)"
EVALUATION_DIR="$APP_DATA/Documents/ascend-evaluation"
mkdir -p "$EVALUATION_DIR"
cp /tmp/yanyu-ios-spike/ascend/evaluation-manifest.json /tmp/yanyu-ios-spike/ascend/*.wav "$EVALUATION_DIR/"
cp /tmp/yanyu-ios-spike/Qwen3-ASR-0.6B-Q4_K_M.gguf "$EVALUATION_DIR/model.gguf"
xcodebuild test -project ios/Yanyu.xcodeproj -scheme Yanyu \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:YanyuTests/TranscriberBridgeTests/testASCENDMixedTestSetWithLocalModel \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 600 \
  -maximum-test-execution-time-allowance 900 \
  CODE_SIGNING_ALLOWED=NO
```

The manifest pins dataset revision `737e9800ae31be9932ba8464c80366559bd28424` and labels its CC-BY-SA-4.0 license. Keep `ATTRIBUTION.txt` with the evaluation artifacts. The test writes a transcript-free report and progress checkpoint in the evaluation directory. Simulator memory, thermal, and timing results do not establish physical-device limits; see the current findings and limitations in the [iOS execution plan](exec-plans/ios-app.md#validation-plan).

#### Core ML candidate evaluation

The WhisperKit comparison is isolated to `YanyuTests`; the production app target does not link WhisperKit. The test expects the same 16-clip FLEURS manifest and WAVs used by the Qwen baseline, plus the `openai_whisper-small` Core ML model. Keep all artifacts outside Git. The model snapshot used for the recorded result is pinned below:

```bash
python3 scripts/test_prepare_fleurs_evaluation.py
python3 scripts/prepare_fleurs_evaluation.py \
  --output-dir /tmp/yanyu-ios-spike/fleurs-evaluation \
  --cache-dir /tmp/yanyu-ios-spike/fleurs-cache

uvx --from huggingface_hub hf download argmaxinc/whisperkit-coreml \
  --repo-type model \
  --revision 0f63a7800b00dd0226abd051b906c246e1907482 \
  --include 'openai_whisper-small/**' \
  --local-dir /tmp/yanyu-ios-spike/whisperkit-artifacts

SIMULATOR_UDID=your-booted-simulator-udid
APP_DATA="$(xcrun simctl get_app_container "$SIMULATOR_UDID" com.siyuqian.yanyu.ios data)"
EVALUATION_DIR="$APP_DATA/Documents/whisperkit-evaluation"
mkdir -p "$EVALUATION_DIR"
cp -R /tmp/yanyu-ios-spike/whisperkit-artifacts/openai_whisper-small "$EVALUATION_DIR/"
cp /tmp/yanyu-ios-spike/fleurs-evaluation/manifest.json \
  /tmp/yanyu-ios-spike/fleurs-evaluation/*.wav "$EVALUATION_DIR/"
xcodebuild test -project ios/Yanyu.xcodeproj -scheme Yanyu \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:YanyuTests/WhisperKitEvaluationTests/testCoreMLCandidateAgainstFleursFixtures \
  CODE_SIGNING_ALLOWED=NO
```

The focused test can also run `testForcedLanguageCandidateSmokeSamples` to compare explicit `zh`/`en` decoding with automatic detection. WhisperKit 1.1.1 is pinned in `ios/project.yml` and Swift Package Manager resolves its lockfile. iOS Simulator runs WhisperKit with CPU-only Core ML, so its transcription quality and timing are not a device acceptance result; use a physical iPhone for the Phase 0 engine gate. See the recorded comparison in the [iOS execution plan](exec-plans/ios-app.md#progress). [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) · [Core ML model](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small).

The FLEURS preparation script pins the [official dataset revision](https://huggingface.co/datasets/google/fleurs/tree/d7c758a6dceecd54a98cac43404d3d576e721f07), verifies source-file SHA-256 values, selects the same eight Chinese and eight English clips used in the recorded baseline, and writes each fixture hash plus attribution. The official dataset is licensed CC-BY-4.0. Keep source archives and prepared audio outside the repository.

#### Phase 0 on a physical iPhone

Connect and trust the iPhone, enable Developer Mode, and sign into Xcode with an Apple account that can create a development provisioning profile for the app. Confirm the device is available with `xcrun devicectl list devices`; use its connected UDID below. TestFlight signing is a later release gate.

Build and install the Debug app once so `devicectl` can access its Documents container:

```bash
DEVICE_UDID=your-connected-iphone-udid
APPLE_TEAM_ID=your-development-team-id
DERIVED_DATA=/tmp/yanyu-ios-device

xcodebuild build -project ios/Yanyu.xcodeproj -scheme Yanyu \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
xcrun devicectl device install app --device "$DEVICE_UDID" \
  "$DERIVED_DATA/Build/Products/Debug-iphoneos/Yanyu.app"
```

For the Rust/Qwen comparison, download both pinned catalog files and verify their hashes against `crates/yanyu-core/resources/catalog.json`. Prepare the pinned test split without `--model-name` so the same manifest can be reused for both quantizations; each report records the exact model size and SHA-256. Copy the manifest, WAVs, and Q4 model into the app's Documents directory, then run the focused XCTest:

```bash
mkdir -p /tmp/yanyu-ios-spike/qwen-models
uvx --from huggingface_hub hf download handy-computer/Qwen3-ASR-0.6B-gguf \
  Qwen3-ASR-0.6B-Q4_K_M.gguf --repo-type model \
  --revision e4e16599b900eb0cb36e524514756bb92eb092b7 \
  --local-dir /tmp/yanyu-ios-spike/qwen-models
uvx --from huggingface_hub hf download handy-computer/Qwen3-ASR-0.6B-gguf \
  Qwen3-ASR-0.6B-Q8_0.gguf --repo-type model \
  --revision e4e16599b900eb0cb36e524514756bb92eb092b7 \
  --local-dir /tmp/yanyu-ios-spike/qwen-models
Q4_MODEL=/tmp/yanyu-ios-spike/qwen-models/Qwen3-ASR-0.6B-Q4_K_M.gguf
Q8_MODEL=/tmp/yanyu-ios-spike/qwen-models/Qwen3-ASR-0.6B-Q8_0.gguf
shasum -a 256 "$Q4_MODEL" "$Q8_MODEL"

python3 scripts/prepare_ascend_evaluation.py \
  --output-dir /tmp/yanyu-ios-spike/ascend-device --split test
STAGING_DIR="$(mktemp -d /tmp/yanyu-ascend-device.XXXXXX)"
mkdir -p "$STAGING_DIR/ascend-evaluation"
cp /tmp/yanyu-ios-spike/ascend-device/evaluation-manifest.json \
  /tmp/yanyu-ios-spike/ascend-device/*.wav "$STAGING_DIR/ascend-evaluation/"
cp "$Q4_MODEL" "$STAGING_DIR/ascend-evaluation/model.gguf"
xcrun devicectl device copy to --device "$DEVICE_UDID" \
  --domain-type appDataContainer --domain-identifier com.siyuqian.yanyu.ios \
  --source "$STAGING_DIR/ascend-evaluation" --destination Documents

xcodebuild test -project ios/Yanyu.xcodeproj -scheme Yanyu \
  -destination "platform=iOS,id=$DEVICE_UDID" \
  -only-testing:YanyuTests/TranscriberBridgeTests/testASCENDMixedTestSetWithLocalModel \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 600 \
  -maximum-test-execution-time-allowance 900 \
  -resultBundlePath /tmp/yanyu-iphone-q4.xcresult \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
```

Copy the transcript-free report back, replace `model.gguf` with the Q8 model, and run the same test again with a different result-bundle path:

```bash
xcrun devicectl device copy from --device "$DEVICE_UDID" \
  --domain-type appDataContainer --domain-identifier com.siyuqian.yanyu.ios \
  --source Documents/ascend-evaluation/evaluation-report.json \
  --destination /tmp/yanyu-iphone-q4-report.json
xcrun devicectl device copy to --device "$DEVICE_UDID" \
  --domain-type appDataContainer --domain-identifier com.siyuqian.yanyu.ios \
  --source "$Q8_MODEL" \
  --destination Documents/ascend-evaluation/model.gguf
xcodebuild test -project ios/Yanyu.xcodeproj -scheme Yanyu \
  -destination "platform=iOS,id=$DEVICE_UDID" \
  -only-testing:YanyuTests/TranscriberBridgeTests/testASCENDMixedTestSetWithLocalModel \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 600 \
  -maximum-test-execution-time-allowance 900 \
  -resultBundlePath /tmp/yanyu-iphone-q8.xcresult \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
xcrun devicectl device copy from --device "$DEVICE_UDID" \
  --domain-type appDataContainer --domain-identifier com.siyuqian.yanyu.ios \
  --source Documents/ascend-evaluation/evaluation-report.json \
  --destination /tmp/yanyu-iphone-q8-report.json
```

Also repeat the Q4/Q8 runs with `--split validation`; it is disjoint from the test split and adds three speakers to the five-speaker evaluation set.

Stage `/tmp/yanyu-ios-spike/fleurs-evaluation` and `openai_whisper-small` under `Documents/whisperkit-evaluation` the same way, then run `YanyuTests/WhisperKitEvaluationTests/testCoreMLCandidateAgainstFleursFixtures`. The test validates the pinned manifest and all sixteen fixture hashes before inference. Save each `.xcresult` outside the repository; it contains candidate output needed to calculate language-specific CER and median RTF. Finally, launch Yanyu on the phone, install a catalog evaluation model, test foreground microphone capture, then repeat after enabling Airplane Mode. These real-device runs are the Phase 0 gate; simulator timing, memory, thermal, and microphone behavior do not substitute for them.

### Dependency update PRs

Dependabot checks Bun and Cargo dependencies on Tuesdays, GitHub Actions on
Wednesdays, and Nix flake inputs monthly. Security update PRs are raised when a
vulnerable dependency has a fix; they do not wait for those schedules. Review
major updates and security fixes individually, and merge only after relevant CI
checks pass.

For a Bun update, `bun.lock` and the generated Nix files must be committed
together. On the Dependabot branch, run `bun scripts/check-nix-deps.ts` and
commit `.nix/bun.nix` and `.nix/bun-lock-hash` if they change. The Nix CI check
rejects an update whose generated files are out of sync. Cargo and Nix flake
updates also need a passing Nix build because they can change native or
packaging dependencies.

## Architecture Overview

Handy is a cross-platform desktop speech-to-text application built with Tauri 2.x (Rust backend + React/TypeScript frontend).

### Backend Structure (src-tauri/src/)

- `lib.rs` - Main entry point, Tauri setup, manager initialization
- `managers/` - Core business logic:
  - `audio.rs` - Audio recording and device management
  - `model.rs` - Model downloading and management
  - `transcription.rs` - Speech-to-text processing pipeline
  - `history.rs` - Transcription history storage
- `audio_toolkit/` - Low-level audio processing:
  - `audio/` - Device enumeration, recording, resampling
  - `vad/` - Voice Activity Detection (Silero VAD)
- `commands/` - Tauri command handlers for frontend communication
- `cli.rs` - CLI argument definitions (clap derive)
- `shortcut.rs` - Global keyboard shortcut handling
- `settings.rs` - Application settings management
- `overlay.rs` - Recording overlay window (platform-specific)
- `signal_handle.rs` - `send_transcription_input()` reusable function
- `utils.rs` - Platform detection helpers

### Frontend Structure (src/)

- `App.tsx` - Main component with onboarding flow
- `components/` - React UI components:
  - `settings/` - Settings UI
  - `model-selector/` - Model management interface
  - `onboarding/` - First-run experience
  - `overlay/` - Recording overlay UI
  - `update-checker/` - App update notifications
  - `shared/`, `ui/`, `icons/`, `footer/` - Shared components
- `hooks/useSettings.ts` - Settings state management hook
- `stores/settingsStore.ts` - Zustand store for settings
- `bindings.ts` - Auto-generated Tauri type bindings (via tauri-specta)
- `overlay/` - Recording overlay window entry point
- `lib/types.ts` - Shared TypeScript type definitions

### Key Architecture Patterns

**Manager Pattern:** Core functionality organized into managers (Audio, Model, Transcription) initialized at startup and managed via Tauri state.

**Command-Event Architecture:** Frontend → Backend via Tauri commands; Backend → Frontend via events.

**Pipeline Processing:** Audio → VAD → Whisper/Parakeet → Text output → Clipboard/Paste

**State Flow:** Zustand → Tauri Command → Rust State → Persistence (tauri-plugin-store)

### Technology Stack

**Core Libraries:**

- `transcribe-cpp` - Local Whisper-family inference (GGML/GGUF) with GPU acceleration
- `transcribe-rs` - ONNX speech recognition (Parakeet, Moonshine, SenseVoice, etc.)
- `cpal` - Cross-platform audio I/O
- `vad-rs` - Voice Activity Detection
- `rdev` - Global keyboard shortcuts
- `rubato` - Audio resampling
- `rodio` - Audio playback for feedback sounds

### Application Flow

1. **Initialization:** App visibility follows settings and CLI flags; loads settings and initializes managers
2. **Model Setup:** First-run selects and downloads a supported model
3. **Recording:** Global shortcut triggers audio recording with VAD filtering
4. **Processing:** Audio sent to the selected inference engine for transcription
5. **Output:** Text pasted to active application via system clipboard

### Settings System

Settings are stored using Tauri's store plugin with reactive updates:

- Keyboard shortcuts (configurable, supports push-to-talk)
- Audio devices (microphone/output selection)
- Model preferences (Small/Medium/Turbo/Large Whisper variants)
- Audio feedback and translation options

### Single Instance Architecture

The app enforces single instance behavior — launching when already running brings the settings window to front rather than creating a new process. Remote control flags (`--toggle-transcription`, etc.) work by launching a second instance that sends args to the running instance via `tauri_plugin_single_instance`, then exits.

## Internationalization (i18n)

All user-facing strings must use i18next translations. ESLint enforces this (no hardcoded strings in JSX).

**Adding new text:**

1. Add key to `src/i18n/locales/en/translation.json`
2. Use in component: `const { t } = useTranslation(); t('key.path')`

**File structure:**

```
src/i18n/
├── index.ts           # i18n setup
├── languages.ts       # Language metadata
└── locales/
    ├── en/translation.json  # English (source)
    ├── de/, es/, fr/, ja/, ru/, zh/, ...
    └── ...
```

For translation contribution guidelines, see [CONTRIBUTING_TRANSLATIONS.md](../CONTRIBUTING_TRANSLATIONS.md).

## Code Style

**Rust:**

- Run `cargo fmt` and `cargo clippy` before committing
- Handle errors explicitly (avoid unwrap in production)
- Use descriptive names, add doc comments for public APIs

**TypeScript/React:**

- Strict TypeScript, avoid `any` types
- Functional components with hooks
- Tailwind CSS for styling
- Path aliases: `@/` → `./src/`

## CLI Parameters

Handy supports command-line parameters on all platforms for integration with scripts, window managers, and autostart configurations.

**Implementation:** `cli.rs` (definitions), `main.rs` (parsing), `lib.rs` (applying), `signal_handle.rs` (shared logic)

| Flag                     | Description                                                |
| ------------------------ | ---------------------------------------------------------- |
| `--toggle-transcription` | Toggle recording on/off on a running instance              |
| `--toggle-post-process`  | Toggle recording with post-processing on/off               |
| `--cancel`               | Cancel the current operation on a running instance         |
| `--start-hidden`         | Launch without showing the main window (tray icon visible) |
| `--no-tray`              | Launch without system tray (closing window quits the app)  |
| `--debug`                | Enable debug mode with verbose (Trace) logging             |

**Key design decisions:**

- CLI flags are runtime-only overrides — they do NOT modify persisted settings
- Remote control flags work via `tauri_plugin_single_instance`: second instance sends args, then exits
- `send_transcription_input()` in `signal_handle.rs` is shared between signal handlers and CLI

## Debug Mode

Access debug features: `Cmd+Shift+D` (macOS) or `Ctrl+Shift+D` (Windows/Linux)

## Platform Notes

- **macOS**: Metal acceleration, accessibility permissions required for keyboard shortcuts
- **Windows**: Vulkan acceleration, code signing. Implicit Vulkan layers (overlays, capture hooks) are disabled for the Handy process via `VK_LOADER_LAYERS_DISABLE=~implicit~` set in `main.rs`; opt out with `HANDY_KEEP_VULKAN_IMPLICIT_LAYERS=1` or by setting `VK_LOADER_LAYERS_DISABLE` yourself
- **Linux**: OpenBLAS + Vulkan, limited Wayland support, overlay uses GTK layer shell (disable with `HANDY_NO_GTK_LAYER_SHELL=1`)
- **Nix/NixOS**: the Nix package sets `HANDY_DISABLE_UPDATER=1` to force-disable the self-updater at runtime without touching the persisted setting (self-update can't work against an immutable `/nix/store`)

## Troubleshooting

See the [Troubleshooting](../README.upstream.md#troubleshooting) section in README.md.

## GitHub workflow for AI coding assistants

**MANDATORY. Before opening any PR, issue, or discussion in this repo: you MUST read the relevant template file and follow it strictly.** That includes sections that look "ceremonial" — checklists, AI Assistance disclosures, "Human Written Description". A generic Summary/Test-plan layout is not acceptable.

- **Opening a PR:** Read [`.github/PULL_REQUEST_TEMPLATE.md`](../.github/PULL_REQUEST_TEMPLATE.md). Every section listed there is mandatory. If a section requires a human-written paragraph (e.g. "Human Written Description"), leave a clear TODO placeholder and ask the human contributor to fill it in — do not invent their voice.
- **Opening an issue:** Read [`.github/ISSUE_TEMPLATE/`](../.github/ISSUE_TEMPLATE/). Blank issues are disabled; pick the right template (`bug_report.md` for bugs). Feature requests do not belong in issues — they go to [Discussions](https://github.com/cjpais/Handy/discussions) (see `.github/ISSUE_TEMPLATE/config.yml`).
- **Proposing a feature (inherited upstream rule):** Handy is under a feature freeze. The current local PR template differs from this inherited rule; clarify Yanyu applicability before feature submissions. New features require community support gathered in [Discussions](https://github.com/cjpais/Handy/discussions) before any PR is opened — see the PR template's "Community Feedback" section.
- **Translations:** Follow [CONTRIBUTING_TRANSLATIONS.md](../CONTRIBUTING_TRANSLATIONS.md).
- **Full contributor workflow:** [CONTRIBUTING.md](../CONTRIBUTING.md).

**Commits:** Use conventional commit prefixes (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`). Focus the message on _why_, not _what_.

## Meeting NoteTaker verification

Meeting capture requires Apple Silicon and macOS 13+. The application deployment target stays unchanged. Allow Microphone and Screen & System Audio Recording in System Settings → Privacy & Security; online mode must never be treated as successful microphone-only capture. Review recovered recordings before processing because unwritten audio cannot be restored. Raw float32 tracks use about 461 MB per source over two hours, plus about 230 MB for playback and temporary/window files. Disk exhaustion stops capture and retains committed material.

Explicitly install MOSS-Transcribe-Diarize using the existing Models page. Qwen3-0.6B uses the existing General → Local polishing download; enabling polishing is optional. Never substitute another model or download missing artifacts implicitly. The feature does not use dictation's remote text-processing route.

Focused storage, speaker matching and note validation tests:

```bash
cargo test --manifest-path src-tauri/Cargo.toml --lib meetings
xcrun swiftc -parse-as-library -target arm64-apple-macosx11.0 src-tauri/swift/meeting_capture.swift src-tauri/swift/meeting_capture_harness.swift -o /tmp/yanyu-meeting-capture-harness
/tmp/yanyu-meeting-capture-harness
cargo test --manifest-path src-tauri/Cargo.toml --lib meetings::experiments::two_hour_storage_recovery -- --ignored --nocapture
```

The native harness uses authored synthetic PCM and requests no microphone/screen access. The two-hour sparse-storage test exercises streamed recovery and beginning/middle/end samples, not voiced transcription quality. Never describe either as a successful live-device meeting.

Generate nonpersonal mixed-language speech with locally installed voices, retaining its timing/identity manifest. Missing voices fail rather than downloading:

```bash
python3 scripts/meeting-fixture.py --output /tmp/yanyu-meeting-fixture
# Optional voiced duration target, with uniquely numbered blocks:
python3 scripts/meeting-fixture.py --output /tmp/yanyu-meeting-two-hours --two-hours
```

Opt-in real-model experiments require explicit paths and never inspect user settings or recordings:

```bash
MEETING_QWEN_DIRECTORY='/path/to/local-polishing/qwen3-0.6b' MEETING_EVIDENCE_DIRECTORY=/tmp/yanyu-notes-evidence cargo test --manifest-path src-tauri/Cargo.toml --lib meetings::experiments::real_qwen_notes_fixture -- --ignored --nocapture
cargo build --manifest-path src-tauri/Cargo.toml
HANDY_TRANSCRIBE_WORKER_EXE="$PWD/src-tauri/target/debug/yanyu" MEETING_MOSS_MODEL=/path/to/installed/MOSS.gguf MEETING_FIXTURE_DIRECTORY=/tmp/yanyu-meeting-fixture MEETING_EVIDENCE_DIRECTORY=/tmp/yanyu-speaker-evidence cargo test --manifest-path src-tauri/Cargo.toml --lib meetings::experiments::real_moss_reference_reels -- --ignored --nocapture
```

Inspect actual source retention, rejected proposals, owner/deadline fidelity and citations in both languages. Speaker fixture windows change A/B order, introduce C and bring A back. Correct identity and timestamps within 500 ms are required; source-reference text must not enter body output. Add overlap and changed-device cases before accepting speaker quality. Live native start/pause/resume/stop, denied/regranted permissions, source failure, crash/mid-pause recovery and concurrent dictation with output mute require explicit hardware tests. A two-hour voiced native-capture/inference performance result remains unverified until executed and measured.

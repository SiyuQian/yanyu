# Remove Apple Intelligence Implementation Plan

> **For implementation agents** Use `superpowers:executing-plans` to work through the tasks in order. Check off a step after recording its verification.

**Status** Active. Implementation and automated checks are complete. Native UI verification is pending. Prepared on 2026-11-23 against `493389f8`.

**Goal** Remove Apple Intelligence as a Yanyu desktop post-processing provider and preserve safe dictation for users upgrading from a build that offered it.

**Architecture** Remove the Apple-specific runtime and build integration. Read the current provider choices through a shared lookup that excludes the retired provider. Keep saved configuration as-is and use the existing unavailable-provider path when the saved selection cannot be resolved.

**Tech stack** Rust, Tauri, Swift bridge removal, React, i18next, and Playwright.

**Spec** [Behavior contract](#behavior-contract).

## Behavior contract

| Starting state                                                                | Expected behavior                                                                                                                                                                                         |
| ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Apple Intelligence selected, Qwen dictation polishing off                     | Show the provider picker without a selection. Output the original transcript and show existing pending setup status if personalization is enabled. Wait for a user selection before any provider request. |
| Apple Intelligence selected, Qwen dictation polishing on                      | Continue the existing Qwen route. If Qwen skips or fails, output the original transcript.                                                                                                                 |
| Another provider selected, with an Apple Intelligence entry left in the store | Omit the retired entry from the picker and keep using the selected provider.                                                                                                                              |
| A saved provider ID is absent from the loaded provider list                   | Show the picker without a selection and use the normal unavailable-provider behavior.                                                                                                                     |
| User explicitly selects a supported provider                                  | Persist that choice through the existing settings command and resume usual processing when the provider is configured.                                                                                    |

The desktop build excludes the Apple provider, availability command, Swift bridge, and `FoundationModels` link. The only production reference to the retired ID is the read-only provider filter. The proposed removal accepts the loss of this system-managed option for long dictation. The Qwen dictation route retains its 200-character cutoff and 500 ms budget. Extending Qwen to longer input or other platforms is a separate product task.

## Global constraints

- Read [AGENTS.md](../../AGENTS.md) and follow its workflow routing when applicable. Use [Development](../DEVELOPMENT.md#development-commands) and [Build](../../BUILD.md) to prepare the ignored Silero VAD model and the target-specific dependencies.
- Exclude settings migration from this change. Keep the stored provider ID, rows, models, credentials, and schema version. Apply the filter to provider lookup and to the settings response sent to the frontend, without writing that response back to storage. Leave unrelated settings and files intact.
- A store that still selects the retired provider, with Qwen off, must produce zero provider requests for daily dictation, history retranscription, and personalization preview until the user makes a new selection. Use original transcription as the fallback. Gate provider-specific UI actions on a supported selection.
- Preserve existing request formatting, validation, and the 10-second generated-processing deadline for configured services. Preserve the Apple Silicon Metal path used by Qwen and the separate macOS meeting capture bridge.
- Add English source copy first, use i18next for UI strings, and update the generated iOS string catalog from the desktop sources. Use fabricated transcript/profile data and loopback test endpoints. Keep test recordings and settings outside the repository.

## Review focus

- A fully configured OpenAI or custom service is already saved alongside the retired selection. Task 1 verifies that the saved ID stays in place and the other service remains inactive until selected.
- The retired row has a model and a reachable URL. Task 1 verifies that the provider lookup still excludes it and daily dictation makes zero requests.
- Another provider is active while a retired row remains. Task 1 verifies that the active provider still resolves and the retired option is omitted.
- The saved ID has no eligible row. Task 1 covers an unselected picker, reload, and explicit recovery through the existing selection command.
- Qwen is on, but the transcript has 201 characters or the model is unavailable. Task 2 covers original-output fallback and zero provider calls.

## File map

| Task | Files and responsibility                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | `src-tauri/src/settings.rs` for provider lookup and `src-tauri/src/commands/mod.rs` for the settings response. `src-tauri/src/shortcut/mod.rs` for provider command validation. `src-tauri/src/actions.rs` for runtime coverage. `src/components/settings/PostProcessingSettingsApi/{usePostProcessProviderState.ts,ProviderSelect.tsx}` and `src/components/settings/post-processing/PostProcessingSettings.tsx` for the picker. `tests/post-processing-provider.spec.ts` for UI coverage. `src/i18n/locales/*/translation.json` and `ios/Yanyu/Resources/Localizable.xcstrings` for copy. |
| 2    | `src-tauri/src/{actions,personalization}.rs`, `src-tauri/src/commands/personalization.rs`, and `src-tauri/src/shortcut/mod.rs` for processing routes. `src-tauri/src/settings.rs` for obsolete defaults and the remaining read-only filter.                                                                                                                                                                                                                                                                                                                                                 |
| 3    | `src-tauri/build.rs`, `src-tauri/src/{apple_intelligence,lib}.rs`, `src-tauri/src/commands/mod.rs`, and `src-tauri/swift/apple_intelligence*` for the native integration. `src/bindings.ts` for the generated frontend API. `ARCHITECTURE.md` and the two ARM macOS workflow comments for accurate documentation.                                                                                                                                                                                                                                                                           |

## Tasks

At implementation start, update the status and the [Plans index](../PLANS.md) to Active. Record each verified step in the progress log. Keep the change on the implementation branch until the full behavior contract has been checked.

### Task 1. Exclude the retired provider from lookup and the picker

**Interfaces** Add `pub(crate) fn available_post_process_providers(&self) -> impl Iterator<Item = &PostProcessProvider>` to `AppSettings` in [settings.rs](../../src-tauri/src/settings.rs). Existing provider lookups and `get_app_settings` use this view. The picker resolves the saved ID only against the provider list returned by the backend.

- [x] Add `retired_apple_provider_is_ignored` in `settings.rs`. Insert an `apple_intelligence` row, model, and fake key explicitly so the fixture works on any host. Set that ID as active and assert `post_process_provider("apple_intelligence").is_none()` and `active_post_process_provider().is_none()`. Check the same active result when the row is absent. With `custom` selected, assert it resolves normally. Verify that the default provider list excludes the retired row and that calling lookup leaves the fixture's serialized selection, provider rows, models, and keys intact.
- [x] Add `retired_provider_never_sends_transcript` in `actions.rs`. Use generated mode, an enabled profile, the saved retired ID, and Qwen off. Configure a loopback listener as the URL of both a retired row and a different saved provider, each with a model and fake key. Call `process_output_with_local_polisher` with a fake polisher that panics if called. Assert `final_text == original`, `post_processed_text.is_none()`, `post_process_skip_reason == Some("unavailable")`, and `listener.accept()` returns `WouldBlock`. This pins the shared path for dictation and history retranscription.
- [x] Create `tests/post-processing-provider.spec.ts` using the Tauri invoke mock pattern in [personalization.spec.ts](../../tests/personalization.spec.ts). Mount `PostProcessingSettings` with the saved ID `apple_intelligence` and the filtered list containing `custom`. Assert the provider prompt appears, provider-specific controls stay hidden, and opening and reloading make zero `set_post_process_provider` or `fetch_post_process_models` invokes. Explicitly choose `Custom` and assert the UI shows its settings and reload remembers the selection.
- [x] Run the focused tests before changing behavior. Expect the Rust lookup and picker assertions to fail. The original-output case may already pass when the system model is unavailable.

  ```bash
  cargo test --manifest-path src-tauri/Cargo.toml --lib retired_apple_provider_is_ignored
  cargo test --manifest-path src-tauri/Cargo.toml --lib retired_provider_never_sends_transcript
  bunx playwright test tests/post-processing-provider.spec.ts
  ```

- [x] Remove the Apple row from `default_post_process_providers`. Filter the exact retired ID in `available_post_process_providers`. Use the filtered iterator in `post_process_provider` and call that method from `active_post_process_provider`, `validate_provider_exists`, and `fetch_post_process_models`. Return a filtered provider list in the `get_app_settings` response. Keep the saved selection ID available to the UI and use the existing settings write path only for explicit changes. Keep the startup migration and schema untouched.
- [x] Resolve `selectedProvider` by exact ID and use an empty picker value when that ID has no selectable row. Render the provider-specific fields only for a resolved provider. Pass an i18next placeholder through `ProviderSelect` to `Dropdown`. Add `settings.postProcessing.api.provider.placeholder` with English `Select a provider`, Simplified Chinese `选择提供商`, and the equivalent in each other desktop locale. Remove the Apple-only state, check, and alert branch, and remove `settings.postProcessing.api.appleIntelligence` from all locales. Regenerate `ios/Yanyu/Resources/Localizable.xcstrings` with `bun run generate:ios-localizations`.
- [x] Rerun the focused tests. Run `bun run check:translations` and `bun run check:ios-localizations`. Record the passing lookup, original-output, and picker results together.

### Task 2. Remove the Apple processing branches

**Interfaces** Change `service_ready(settings: &AppSettings) -> bool` in `src-tauri/src/personalization.rs` and `processing_readiness(settings: &AppSettings, local_ready: bool) -> (bool, bool)` in `src-tauri/src/commands/personalization.rs`. Use the existing `active_post_process_provider() -> Option<&PostProcessProvider>` to determine readiness of configured providers.

- [x] Add readiness assertions in the existing personalization tests. Assert `(false, false)` for a generated, enabled profile with an unavailable provider and Qwen off. When Qwen is enabled, assert `(true, true)` when the model is ready and `(false, false)` when it is unavailable. Keep a case with a configured non-Apple service to pin its readiness.
- [x] Extend `retired_provider_never_sends_transcript` with Qwen enabled. Inject an accepted short local result, `PolishSkip::Unavailable`, and a 201-character transcript that must bypass the polisher. Assert the accepted result or exact original text as applicable and zero loopback requests. Keep the existing coverage in `daily_generated_output_uses_service_and_profile_for_both_provider_paths` for sending transcript and profile context after selecting a configured provider.
- [x] Remove the Apple branch from both `post_process_transcription` and `generated_processing`, the `generated_apple_worker` helper, and its Apple-only timeout test. Retain the generic deadline, structured/legacy behavior and validation tests. Remove the Apple availability parameter and caller from service and trial readiness. Replace the Apple-specific readiness fixture with an unavailable-provider case.
- [x] Remove the retired provider's model discovery branch in `fetch_post_process_models` and its special value in `default_model_for_provider`. Keep existing API/provider validation and preserve blank model defaults for other providers. Keep the literal retired ID private to the provider filter after its last caller is removed.
- [x] Verify the processing modules. These commands must pass on a host with the documented native build prerequisites.

  ```bash
  cargo test --manifest-path src-tauri/Cargo.toml --lib actions::tests
  cargo test --manifest-path src-tauri/Cargo.toml --lib personalization::tests
  bunx playwright test tests/personalization.spec.ts tests/local-polishing.spec.ts tests/post-processing-provider.spec.ts
  ```

### Task 3. Delete the Swift integration and verify platform builds

**Interfaces** `command_builder()` becomes the source for regenerated `src/bindings.ts`. The desktop CLI, app identifier, build targets, and meeting bridge retain their existing contracts.

- [x] Remove `check_apple_intelligence_available` from `src-tauri/src/commands/mod.rs` and its registration and module declaration from `src-tauri/src/lib.rs`. Delete `src-tauri/src/apple_intelligence.rs` and `src-tauri/swift/{apple_intelligence.swift,apple_intelligence_stub.swift,apple_intelligence_bridge.h}`.
- [x] Delete `build_apple_intelligence_bridge` and its entry point from `src-tauri/build.rs`. Remove the now-unused CLT detection helper, `HANDY_FORCE_AI_STUB` handling, and the weak `FoundationModels` link. Check the meeting capture build and other Swift linker directives before pruning any shared code.
- [x] Regenerate Tauri bindings using the existing exporter. Inspect the generated diff for the removed capability and avoid unrelated binding churn. Update the post-processing row in [ARCHITECTURE.md](../../ARCHITECTURE.md) and the Apple-only SDK rationale in the comments in [Build Test](../../.github/workflows/build-test.yml) and [Release](../../.github/workflows/release.yml). Keep the runner labels and build targets.

  ```bash
  cargo test --manifest-path src-tauri/Cargo.toml --lib meeting_binding_tests::export_bindings -- --ignored --exact
  ```

- [x] Run the full desktop checks from the repository root. Save each exit status and attach the relevant CI result for other targets when available.

  ```bash
  bun run build
  bun run lint
  bun run format:check
  bun run check:translations
  bun run check:ios-localizations
  bun run test:ios-localizations
  bun run test:build
  bun run test:playwright
  cargo test --manifest-path src-tauri/Cargo.toml --lib
  cargo clippy --manifest-path src-tauri/Cargo.toml --lib --tests
  git diff --check
  ```

- [x] Check remaining references and build on an Apple Silicon Mac. Search hits may remain in the read-only filter and its tests. Expect no integration imports, bindings, Apple-only locale keys, or build flags. `otool -L` on the new app executable must succeed and list no `FoundationModels` entry. Verify Intel macOS, Windows, and Linux compilation using the existing build matrix when those runners are available. Record any target that still lacks evidence.

  ```bash
  git grep -inE 'apple.?intelligence|foundationmodels|handy_force_ai_stub|generated_apple_worker' -- src src-tauri ios .github ARCHITECTURE.md
  bun run tauri build --target aarch64-apple-darwin
  otool -L src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Yanyu.app/Contents/MacOS/yanyu
  ```

- [ ] Run a smoke test with existing provider settings on an isolated copy of the built app. Use [portable mode](../../src-tauri/src/portable.rs) with `Yanyu Portable Mode` in a `portable` marker next to the copied executable and a synthetic `Data/settings_store.json`. Stage the VAD resource, a speech recognition fixture, and the shared Qwen model. Configure `custom` to use a loopback test service, select Apple Intelligence in the fixture, enable generated personalization, and start with Qwen off. Check that the picker prompts for a provider, the optional recording preview is disabled, and synthetic dictation outputs only the recognized transcript with zero listener requests. After restart, compare the saved provider ID, row, model and key to the fixture. Explicitly pick `Custom` and verify it can process synthetic dictation. Enable Qwen and verify eligible short dictation, the selection shortcut, and the meeting capture entry point. Record native checks separately from mock-based results.

## Completion and rollback

- [x] Review the diff against the behavior contract. Confirm that the filter is the sole production reference to the retired ID and that reading an old selection causes no retirement-specific settings write. Note the lost long-dictation option and explicit reselection requirement in the change summary.
- [ ] Record verification evidence and implementation references below. When the work is accepted, move this document to `docs/exec-plans/completed/`, update its relative links, and move its [Plans index](../PLANS.md) entry.

Revert the implementation commits if release verification fails after integration. An older build can use the saved Apple Intelligence selection if it is still selected and the system model is available. An explicit replacement selection carries over as the current setting.

## Progress log

- 2026-11-23. Plan drafted from repository inspection and revised to remove settings migration. Implementation checks are pending.

- 2026-11-23. Task 1 complete. Rust provider lookup failed before the fix and both focused Rust tests passed after it. The Playwright picker test failed before the fix and passed after it. All locale checks passed.

- 2026-11-23. Task 2 complete. The Rust suite passed with 348 tests and 28 opt-in tests ignored by default. All 101 Playwright tests passed. The opt-in real Qwen selection polishing test and the Swift synthetic meeting capture harness passed separately.

- 2026-11-23. Apple Silicon release app bundled successfully. `otool -L` showed the Swift runtime and meeting capture frameworks, with no `FoundationModels` linkage. Frontend build, lint, formatting, desktop and iOS locale checks, build-script tests, and Rust Clippy finished successfully. Existing Clippy warnings remain.
- 2026-11-23. Portable fixture launches retained the saved provider ID, row, model, and key. Native ASR recognized the synthetic WAV. The locked desktop prevented access to the native settings window, so the live picker, paste, and provider reselection smoke checks remain pending. Intel macOS, Windows, and Linux builds were not run in this workspace.
- 2026-11-23. Independent code review found no issues requiring a code change. The Playwright fixture exercises the picker using the filtered response shape. Native UI verification still needs to cover the returned provider list end to end.

## Decision log

- 2026-11-23. Leave persisted configuration in place and filter the unavailable provider at read time. Retain the existing Qwen limits as part of this removal.
- 2026-11-23. Determine whether a provider is missing after loading the current provider list. Existing default initialization continues to restore supported provider metadata for older sparse stores. The retired Apple ID remains unavailable.

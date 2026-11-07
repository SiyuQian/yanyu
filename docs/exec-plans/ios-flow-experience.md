# iPhone dictation experience convergence

Status: In progress. The first implementation batch and continuity follow-up passed simulator, unsigned device-build and independent review checks; physical-device acceptance remains open. Authorized by the user on 2026-11-03 to iteratively bring Yanyu's iPhone workflow closer to Wispr Flow. This extends the existing [iOS plan](ios-app.md); it does not declare the physical-device/model feasibility or release gates complete.

## Outcome

A user can prepare local speech recognition, enable the keyboard, start a clearly indicated dictation, return to their text field, stop, receive text with as little repeated navigation as supported by iOS, and recover or undo without losing an existing draft. Sending remains an explicit action in the destination app. Audio and recognition remain local; no account or cloud fallback is added.

Match observed behavior rather than branding. The evidence checked on 2026-11-02 includes the [official keyboard guide](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone), [iOS 26.4 return behavior](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4), [Action Button guide](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone), and [recovery guide](https://docs.wisprflow.ai/articles/7971211038-Fix-text-not-pasting-after-dictation). The [KTLA video at 00:30 and 00:35](https://www.youtube.com/watch?v=HGZEvWWCc8E&t=30s) shows recording followed by insertion into a message draft, but is historical footage, not verification of the current app.

## Workspace and ownership

- Source and selected workspace: `/Users/siyu/.bb/plugins/environment-git-worktree/host-data/worktrees/thr_3ksetkiw85-1/yanyu`.
- Branch: `bb/wispr-flow-thr_3ksetkiw85`.
- Initial commit: `9e0833a3c798f9ada792aab0d672a5d93ab331cd`.
- Owner: external (existing BB worktree); created by this run: no.
- Initial working tree: clean. Preserve this workspace and unpublished work.
- Coordinator: current thread. Implementation agents receive bounded file ownership; review is independent and read-only. No automatic merge or publication.

## Delivery slices and acceptance

1. **First use and model preparation.** Make the existing verified-download pipeline reachable without developer controls, with explicit size, progress, cancellation, errors and retry. Keep evaluation tools separate. Explain local processing, the keyboard setup, and the difference between app-only and keyboard dictation. Denied permission must not block history/settings. A model candidate is not a validated production model merely because installation succeeds.
2. **Result delivery.** Insert a newly completed keyboard-session result automatically only when its intended field can still be identified safely. Preserve manual preview/insertion when the field changes or delivery cannot be established. Never insert again after polling, keyboard recreation or app switching. Add bounded undo only when the inserted text and insertion boundary still match; never delete unrelated text after typing or moving the cursor.
3. **Supported start shortcuts.** Research Apple-supported App Intents/Shortcuts and Action Button integration, including minimum OS and activity/permission requirements. Add the smallest verified path and clear manual return instructions. Do not use private APIs, responder-chain application opening, undocumented host-app identification, or promise universal automatic return. Keyboard extensions do not capture microphone audio.
4. **Continuity and recovery.** Keep recording, processing, cancellation, delivery and failed recovery distinct. Retain the existing recording cap and finite background-processing boundary until physical evidence supports a different policy. A second dictation must not overwrite an unfinished result or retained audio. In-app and keyboard controls must explain the next action.
5. **Verification and review.** Add behavior tests before nontrivial implementation. Run focused and complete iOS unit/UI suites, unsigned device Release build, localization drift and translation checks, Swift formatting, and diff checks. Resolve important review findings. Record exactly which simulator paths passed and which device paths are unverified.

## Physical-device acceptance remains open

- Sign and install both targets with the App Group on an actual supported iPhone.
- Verify recording/inference across app changes, Full Access on/off, permission denial/revocation, locking, calls, Bluetooth changes and iOS suspension.
- Test text delivery/undo in Notes, Messages and a third-party app with existing drafts, selected text, cursor moves, keyboard changes and long bilingual transcripts.
- Verify any Shortcut/Action Button and Live Activity behavior on its supported OS/device combinations.
- Complete the existing Chinese/English/mixed-language quality, memory, latency and thermal gate before promoting a model or claiming release readiness.

## Progress and verification ledger

- 2026-11-04: Verified the existing worktree/branch and clean baseline. Started the existing iOS unit suite on the iPhone 17 / iOS 27 simulator. A read-only agent is checking primary Apple documentation and local SDK support for cross-app starts. No completion claim is made for these running checks.
- 2026-11-04: Baseline unit suite passed: 125 tests, one optional model fixture skipped, zero failures. First-use/model preparation passed six focused unit tests and three UI tests; an actual Release UI run passed the model-entry/disclosure/size/accessibility and developer-tools exclusion check. The Release UI used an ignored UI-only user scheme because the ordinary test scheme also builds Debug-only unit fixtures.
- 2026-11-04: Implemented safe automatic insertion after an explicit stop in the same keyboard/field/context, manual fallback, and bounded Undo. Test-first review reproduced two Unicode deletion regressions: a suffix combining mark and regional-indicator merge/split. Both insertion positions must now be actual extended-grapheme boundaries, not merely produce matching character counts.
- 2026-11-04: Independent review found Retry could overlap saved-model restoration. Added a held-load retained-recording regression, a view-model preparation guard, and a disabled Retry button during preparation. The capture and recovery state survive the blocked retry and complete after loading.
- 2026-11-04: Added an explicitly selected foreground Shortcuts action through public App Intent APIs. It opens the existing app, uses one 30-second in-memory request, waits for restoration, rejects unmet setup/model/busy conditions without replaying later, and starts the existing keyboard controller. This does not register automatic Siri phrases, create a second recorder, or provide background capture/automatic return. Joint focused tests passed: 11 delivery, seven model lifecycle/recovery, and six request-gate tests (24 total, zero failures). Full scheme and device Release validation are still running.
- 2026-11-04: The first complete run exposed contrast failures in new model/setup copy and buttons. Changed the affected text to primary contrast and used an explicit high-contrast preparation-button tint; no audit exceptions were added. The final complete iPhone 17 / iOS 27 scheme passed: 144 unit tests (one optional fixture skipped) and all 15 UI tests, zero failures. This includes light/dark and accessibility text-size audits. The unsigned generic iPhone Release build passed. Swift formatting across handwritten app/shared/keyboard/tests, generated-localization drift, two generator tests, all 25 locale key checks, changed-document/JSON Prettier checks and `git diff --check` passed. Independent review accepted the recovery, Unicode boundary and foreground Shortcut changes with no remaining confirmed Critical/Important findings.

### Reproduce this batch

```sh
xcodebuild test -project ios/Yanyu.xcodeproj -scheme Yanyu -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ios/Yanyu.xcodeproj -scheme Yanyu -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcrun swift-format lint --strict ios/Yanyu/*.swift ios/Shared/*.swift ios/YanyuKeyboard/*.swift ios/YanyuTests/*.swift ios/YanyuUITests/*.swift
node scripts/generate-ios-localizations.mjs --check
node --test scripts/generate-ios-localizations.test.mjs
bun run check:translations
git diff --check
```

The full run used `/tmp/yanyu-flow-derived` and simulator UDID `7E409D5E-076F-4FEE-9767-C48CA8B43089`. Receipts/logs are retained under this thread's storage in `ios-flow-implementation/`; these are not personal recordings and are not added to Git. No signed phone was detected by `xcrun devicectl list devices` in this run.

## Next execution sequence

### Continuity software prerequisite (verified software batch)

The next hardware check again found only simulators and zero signing identities. While physical acceptance remains unavailable, the user requested continued execution. This continuation closes the plan's existing unfinished-result protection before starting any new background-recording experiment.

- Preserve a ready result until the keyboard records a handling attempt or the user explicitly clears the shared handoff; a new recording must not silently overwrite it.
- Store a protected UUID-only receipt, validate the current unexpired session, reject stale IDs/corruption, and avoid rewriting a matching receipt during polling. This is not destination-confirmed paste.
- Show the pending text in Yanyu with explicit copy and keep-in-history/clear actions, including without a loaded model. Clearing is ID-checked, leaves history untouched, and cannot interrupt an active recording.
- Consume a Shortcut request once and route to pending-result recovery. Recovery never starts a later recording automatically.
- 2026-11-04: Preserved the first batch in thread-storage baseline copies and passed 26 focused baseline tests. Added 15 core regressions; behavioral RED exposed overwritten handoffs, missing receipts, stale/corrupt acknowledgement and dismissal gaps. Separate RED confirmed repeated acknowledgement rewrote the file and corruption was silently replaced. The corrected 41 core tests passed.
- 2026-11-04: A new UI regression caught initial Shortcut navigation staying on Home. Replaced request polling with handlers for restoration completion, foreground entry and request changes. Both focused UI tests now pass: pending text copy/history preservation without a model, and pending-first Shortcut navigation. Independent re-review found no remaining confirmed Critical/Important issue. The complete simulator scheme and unsigned device Release checks are in progress.
- The recovery UI test uses an isolated real filesystem store under an explicit Debug test launch flag; it does not establish signed App Group entitlement or physical keyboard IPC behavior. Public keyboard receipt retry/recreation still needs physical-device acceptance.
- 2026-11-04: Complete iPhone 17 / iOS 27 regression passed: 159 unit tests (one optional fixture skipped), 17 UI tests, zero failures. A focused iPhone 16e / iOS 26.2 run also passed all 41 core tests and both new recovery/navigation UI tests. The unsigned generic iPhone Release build passed. Swift formatting, generated-localization drift, both generator tests, 25-locale key consistency, changed Markdown/JSON Prettier checks and `git diff --check` passed. Independent re-review accepted the event-driven routing repair with no remaining confirmed Critical/Important findings. Logs and the verification receipt are retained in this thread's storage under `ios-flow-continuity/`.

### Hardware and subsequent experiments

1. Obtain the target iPhone/iOS and signed App Group installation; run the physical-device acceptance checklist above on this first batch. The coordinator requested device details from the user; no answer is recorded yet.
2. Measure local-model quality/latency and background completion on that device before changing the recording cap or selecting a production model.
3. Spike iOS 18+ background recording intents plus Live Activities, including cold start, locking, denied permission/activity and interruption paths. Keep the foreground Shortcut fallback.
4. Refine repeated dictation and first-use practice from the observed device results. Recheck the competitor's current behavior before implementing platform-dependent paths. Do not mark this plan complete from simulator tests alone.

## Decisions and remaining questions

- Follow the user's request for Flow-like delivery: safe automatic insertion with a manual fallback, not unconditional insertion into whichever field happens to be focused.
- Preserve local-first processing and explicit Send. Do not copy competitor pricing, accounts, cloud processing or unsupported desktop-only functions.
- The final keyboard-to-app start mechanism depends on verified public API support. Unsupported routes stay explicit in this plan rather than being represented as implemented.
- Apple restricts keyboard microphone access and app launching: [keyboard capabilities](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard), [App Review extensions](https://developer.apple.com/app-store/review/guidelines/#extensions). The implemented alternative is a [foreground App Intent](https://developer.apple.com/documentation/appintents/appintent/supportedmodes), manually selected in Shortcuts and optionally assigned to a supported [Action Button](https://support.apple.com/guide/shortcuts/run-shortcuts-with-the-action-button-apdfea15680b/ios).
- Future background start requires a separate spike with [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent) (iOS 18+) and a live activity for the recording lifetime. The installed SDK/docs establish API availability, not reliable cold-start/locked-device behavior.
- An unsaved result, retained audio, or an unhandled keyboard result blocks a new start. The continuity continuation adds a UUID-only handling-attempt receipt and explicit keep-in-history/clear recovery. Reusable background sessions remain outside the verified implementation.

# Native iOS app

The app is a native SwiftUI target, separate from the Tauri desktop application. `project.yml` is its XcodeGen specification; `Yanyu.xcodeproj` is checked in so Xcode can open the project directly. The target's build phase builds the Rust core for iPhone and Apple Silicon simulator and generates its UniFFI Swift binding. The first build needs Rust with the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets, CMake, Xcode, and network access for Cargo dependencies.

Generate the project after changing target sources or settings:

```bash
cd ..
node scripts/generate-ios-localizations.mjs
cd ios
xcodegen generate --spec project.yml
```

Build and run the unit tests from this directory:

```bash
xcodebuild build -project Yanyu.xcodeproj -scheme Yanyu -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Yanyu.xcodeproj -scheme Yanyu -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
xcrun swift-format lint --strict Yanyu/*.swift YanyuTests/*.swift YanyuUITests/*.swift
```

Check that the native string catalog and `InfoPlist.strings` still match the i18next sources with `node scripts/generate-ios-localizations.mjs --check` from the repository root.

The deployment target is currently set to iOS 17 as a development default. Phase 0 must confirm the minimum supported iOS version and device range before release planning.

`scripts/build-ios-core.sh` can be run from the repository root to build the portable Rust core for both iOS architectures. Xcode also runs it as a build phase. Before compiling, it checks the full optional-feature and target dependency graph and fails if any Tauri crate enters the portable core. Its CMake arguments include a workaround for a `transcribe-cpp-sys` C/C++ flag issue observed with the current Xcode toolchain.

## Keyboard extension and voice input

The `YanyuKeyboard` extension provides basic Latin typing, numbers, punctuation,
backspace, newline, a keyboard switcher, and insertion of a local voice transcript.
The extension has no microphone, speech model, network client, history access, or
clipboard access. Chinese and English speech use the model loaded in the main app;
this is not a Chinese phonetic typing keyboard.

To install on a device, sign **both** `Yanyu` and `YanyuKeyboard` with the same
Apple developer team. Register and enable the App Group
`group.com.siyuqian.yanyu` for both bundle identifiers. The entitlements and
background-audio mode are checked in; XcodeGen regenerates both Info.plists.
A provisioning profile must authorize that group before device installation.

1. In iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard,
   select Yanyu. Allow Full Access if you want to stop recording from the keyboard.
   Basic typing remains available without Full Access. No network requests are
   made by the keyboard, including with Full Access enabled.
2. Use **Prepare speech model** in Yanyu to download, verify and load the pinned
   Qwen Q4 candidate, with visible size, progress, cancellation and retry. This
   preparation is available in Release; arbitrary imports and evaluation tools
   remain Debug-only. Model quality/performance on a physical iPhone is still an
   open gate. Open the keyboard button in the toolbar and tap **Start keyboard
   dictation**. Each session starts explicitly in the app. The ordinary recording
   button is a separate foreground-only path and stops when the app backgrounds.
3. Switch to your destination app, focus an editable field, and select Yanyu
   with the globe key. Recording continues in the background, for up to 60 seconds.
4. Tap **Stop** in the keyboard (or in Yanyu). The containing app transcribes
   locally within the execution time iOS grants after recording stops.
5. When stopped through the keyboard, a completed result inserts automatically
   only if the same keyboard instance, session, field and cursor context remain
   unchanged. Changing fields, editing, moving the cursor or hiding the keyboard
   falls back to a preview with **Insert text**. Manual insertion can replace a
   selection; automatic insertion never replaces selected text. Results insert
   once. The keyboard never taps Send.
6. **Undo insertion** is available only while the host exposes the full inserted
   text and both insertion boundaries are intact. It is unavailable for truncated
   context or grapheme merges, and is invalidated by typing, selection changes or
   hiding the keyboard. It removes only that insertion and cannot be repeated.
   Start the next recording by returning to Yanyu or invoking its foreground
   Shortcut again.
7. A ready result that the keyboard has not handled blocks the next keyboard
   recording. Yanyu shows that result even when no speech model is loaded: copy
   it, return to the keyboard to insert it, or explicitly choose **Keep in history
   and clear keyboard result**. Clearing removes only this shared handoff, not
   the saved transcript. A stale action cannot clear a newer result or an active
   recording. A Shortcut request opens this recovery page and is consumed; clearing
   does not start recording automatically.

### Foreground Shortcut

In Shortcuts, add Yanyu's **Start Keyboard Dictation** action. On supported
iPhones, assign that shortcut under Settings → Action Button → Shortcut. This
uses a public foreground App Intent on iOS 17 and later, opens Yanyu, restores its
existing state, and starts the same keyboard session if setup/model/recovery state
permits. Return to your destination app manually and select the Yanyu keyboard.
This does not register automatic Siri phrases or background/Live Activity capture.

A request expires after 30 seconds and is consumed on setup, model or busy errors;
finish the indicated step and invoke it again. Pending audio, an unsaved result,
or an unhandled keyboard result blocks a new recording. A new session replaces
the keyboard snapshot only after handling or an explicit clear; the saved
transcript remains in the app's history. Shortcut
metadata/build verification does not establish physical Action Button behavior.
See the [experience plan](../docs/exec-plans/ios-flow-experience.md).

The shared App Group contains one session snapshot, a session-specific stop
request, and a UUID-only handling receipt. The receipt records a keyboard insertion
attempt; it does not prove the destination accepted the text. The keyboard retries
the receipt after a write failure without repeating insertion. Missing local keyboard
preferences do not override an existing receipt. Only explicit keyboard sessions publish text, after a successful
history save. Ordinary dictation/history stay in the app sandbox. Live snapshots
expire after five seconds without a heartbeat; completed results cannot be read
or inserted after five minutes. Shared files are protected while the phone is
locked and excluded from backups. Expired files are purged when the app next runs
or starts another session; iOS suspension can delay physical removal. The keyboard
stores only the last inserted session ID in its own preferences to prevent repeats.
Raw audio follows the existing local recovery/deletion policy.

Device verification is still required for microphone continuity across app switches,
App Group provisioning, Full Access and receipt synchronization, background inference deadlines, locking,
calls and audio route changes. If iOS expires processing time, return to Yanyu to
retry or delete the retained capture. Some apps and secure fields disallow custom
keyboards. The keyboard cannot start its own microphone session; see Apple's
[custom keyboard access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
and [background recording](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)
documentation.

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
2. Load a validated model in Yanyu, open the keyboard button in its toolbar,
   and tap **Start keyboard dictation**. Each session starts explicitly in the app.
3. Switch to your destination app, focus an editable field, and select Yanyu
   with the globe key. Recording continues in the background, for up to 60 seconds.
4. Tap **Stop** in the keyboard (or in Yanyu). The containing app transcribes
   locally within the execution time iOS grants after recording stops.
5. Scroll through the transcript preview and tap **Insert text**. The keyboard
   inserts once at the current cursor; it never taps Send. Start the next recording
   by returning to Yanyu.

The shared App Group contains only one session snapshot and a session-specific
stop request. Only explicit keyboard sessions publish text, after a successful
history save. Ordinary dictation/history stay in the app sandbox. Live snapshots
expire after five seconds without a heartbeat; completed results cannot be read
or inserted after five minutes. Shared files are protected while the phone is
locked and excluded from backups. Expired files are purged when the app next runs
or starts another session; iOS suspension can delay physical removal. The keyboard
stores only the last inserted session ID in its own preferences to prevent repeats.
Raw audio follows the existing local recovery/deletion policy.

Device verification is still required for microphone continuity across app switches,
App Group provisioning and Full Access, background inference deadlines, locking,
calls and audio route changes. If iOS expires processing time, return to Yanyu to
retry or delete the retained capture. Some apps and secure fields disallow custom
keyboards. The keyboard cannot start its own microphone session; see Apple's
[custom keyboard access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
and [background recording](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)
documentation.

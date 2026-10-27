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

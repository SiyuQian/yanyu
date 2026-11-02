# Build Instructions

This guide covers how to set up the development environment and build Yanyu from source across different platforms.

## Prerequisites

### All Platforms

- [Rust](https://rustup.rs/) (latest stable)
- [Bun](https://bun.sh/) package manager
- [Tauri Prerequisites](https://tauri.app/start/prerequisites/)

### Platform-Specific Requirements

#### macOS

- Xcode Command Line Tools
- Install with: `xcode-select --install`

##### Intel Mac (x86_64)

Prebuilt ONNX Runtime binaries are not available for Intel Macs. Install ONNX Runtime via Homebrew and link dynamically:

```bash
brew install onnxruntime
ORT_LIB_LOCATION=$(brew --prefix onnxruntime)/lib ORT_PREFER_DYNAMIC_LINK=1 bun run tauri dev
```

The same environment variables apply for production builds:

```bash
ORT_LIB_LOCATION=$(brew --prefix onnxruntime)/lib ORT_PREFER_DYNAMIC_LINK=1 bun run tauri build
```

#### Windows

- Microsoft C++ Build Tools: Visual Studio 2019/2022 with C++ development
  tools, or Visual Studio Build Tools 2019/2022
- [CMake](https://cmake.org/download/) (must be on `PATH`):

  ```powershell
  winget install Kitware.CMake
  ```

- [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) from LunarG — required to
  build the Vulkan GPU backend (`vulkan-shaders-gen` needs the SDK's headers
  and `glslc`):

  ```powershell
  winget install KhronosGroup.VulkanSDK
  ```

  Open a new terminal afterward so `VULKAN_SDK` is set.

> [!NOTE]
> Windows' 260-character path limit used to break the native Vulkan build in
> most checkouts. Since `transcribe-cpp` 0.1.3 the build works around it
> automatically (it compiles through a short NTFS junction — no admin rights
> or setup needed), so a normal checkout just builds. If you still hit
> path-limit errors, see
> [Windows build fails with path-limit errors](#windows-build-fails-with-path-limit-errors-msb3491--ftk1011--msb6003)
> in Troubleshooting.

#### Linux

- Build essentials
- ALSA development libraries
- Install with:

  ```bash
  # Ubuntu/Debian
  sudo apt update
  sudo apt install build-essential clang libclang-dev libevdev-dev libasound2-dev pkg-config libssl-dev libvulkan-dev vulkan-tools glslc spirv-headers glslang-tools libgtk-3-dev libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libgtk-layer-shell0 libgtk-layer-shell-dev patchelf cmake

  # Fedora/RHEL
  sudo dnf groupinstall "Development Tools"
  sudo dnf install alsa-lib-devel pkgconf openssl-devel vulkan-devel glslc \
    clang clang-devel libevdev-devel \
    spirv-headers-devel spirv-tools-devel glslang \
    gtk3-devel webkit2gtk4.1-devel libappindicator-gtk3-devel librsvg2-devel \
    gtk-layer-shell gtk-layer-shell-devel \
    cmake

  # Arch Linux
  sudo pacman -S base-devel clang libevdev shaderc spirv-headers glslang alsa-lib pkgconf openssl vulkan-devel \
    gtk3 webkit2gtk-4.1 libappindicator-gtk3 librsvg gtk-layer-shell \
    cmake
  ```

## Setup Instructions

### 1. Clone the Repository

```bash
git clone git@github.com:SiyuQian/yanyu.git
cd yanyu
```

### 2. Install Dependencies

```bash
bun install
```

### 3. Start Dev Server

```bash
bun tauri dev
```

### 4. Build for Production

```bash
bun run tauri build
```

This compiles a release binary and generates platform-specific bundles (deb, rpm, AppImage on Linux; dmg on macOS; msi on Windows).

### Faster Local Builds

Use the development server for UI changes. Rust development builds keep limited
debug information to reduce compiler output and linker work.

For an optimized build to install and try locally:

```bash
bun run build:fast
```

This command disables LTO, enables incremental compilation, and uses 16 codegen
units. It keeps the normal release optimization level for inference code.
Artifacts use a separate cache at `src-tauri/target/fast`. The first build fills
that cache. Later builds reuse it.

On macOS, the command creates only
`src-tauri/target/fast/release/bundle/macos/Yanyu.app`. Other platforms use their
normal bundle formats. Tauri arguments pass through to the build command:

```bash
bun run build:fast --no-bundle
bun run build:fast --bundles app,dmg
```

Use `bun run tauri build` for distribution. Its full LTO and single codegen unit
remain enabled. Compare transcription and polishing performance with that build
before distributing a change. Fast builds do not change application settings.

If a global `CFLAGS=-std=c++17` is set, unset `CFLAGS` before either build command.
C++ compiler options belong in `CXXFLAGS`.

### CI Build Stages

Linux CI compiles once with `tauri build --no-bundle`. It then locates and exposes
the native speech libraries before `tauri bundle` creates the installers.
The `tauri-action` adapter only bundles the existing binary, so release asset
discovery and uploads continue through the action.

Linux x64 CI caches Vulkan SDK packages from the existing LunarG apt repository.
ARM64 CI caches the SDK installation through its installation action. System
packages and Vulkan runtime libraries still install through apt. Release builds
retain the existing policy of skipping the Rust artifact cache.

## macOS Local Install (after each rebuild or release)

Run these steps each time you build a new version and want it in `/Applications`.

1. Update to the commit you want: `git checkout main && git pull`.
2. Build only the app bundle. Unset `CFLAGS` first: a global `CFLAGS=-std=c++17`
   breaks the C build of `ring` (`invalid argument '-std=c++17' not allowed with 'C'`).
   ```bash
   unset CFLAGS
   bun run tauri build --bundles app
   ```
   Output: `src-tauri/target/release/bundle/macos/Yanyu.app` (about 5 minutes on a cold build).
3. Quit Yanyu, then replace the installed app:
   ```bash
   osascript -e 'tell application id "com.siyuqian.yanyu" to quit' || true
   pkill -f /Applications/Yanyu.app || true
   rm -rf /Applications/Yanyu.app
   cp -R src-tauri/target/release/bundle/macos/Yanyu.app /Applications/Yanyu.app
   codesign --verify --deep --strict /Applications/Yanyu.app && echo sig-ok
   ```
4. Clear the stale Accessibility grant (the ad-hoc `cdhash` changes on every build, see
   [Troubleshooting](#macos-accessibility-remains-enabled-after-a-local-rebuild)), then open the app:
   ```bash
   tccutil reset Accessibility com.siyuqian.yanyu
   open /Applications/Yanyu.app
   ```
5. Grant permissions when prompted: **Accessibility** (System Settings > Privacy & Security >
   Accessibility, switch Yanyu on) and **Microphone**. If Yanyu stays on `Waiting...`,
   quit and reopen it after enabling Accessibility.

## Linux Install (from source)

The raw binary (`src-tauri/target/release/yanyu`) cannot run standalone — it needs Tauri resource files (tray icons, sounds, VAD model) to be co-located at the expected path.

**Install from the deb bundle** (works on any Linux distro):

```bash
cd /tmp
ar x /path/to/yanyu/src-tauri/target/release/bundle/deb/Yanyu_*_amd64.deb data.tar.gz
tar xzf data.tar.gz
sudo cp usr/bin/yanyu /usr/bin/
sudo cp -a usr/lib/. /usr/lib/
sudo cp -r usr/share/icons/hicolor/* /usr/share/icons/hicolor/
sudo cp usr/share/applications/Yanyu.desktop /usr/share/applications/
```

The runtime libraries live in the app-private `/usr/lib/Yanyu/` (on the binary's rpath), so no `ldconfig` step is needed.

After subsequent rebuilds, copy the binary and any refreshed runtime libraries:

```bash
sudo cp src-tauri/target/release/yanyu /usr/bin/
sudo mkdir -p /usr/lib/Yanyu
sudo cp -a src-tauri/transcribe-libs/. /usr/lib/Yanyu/
```

Resources only need re-copying if they change upstream (new icons, sounds, models, etc.).

## Troubleshooting

### macOS Accessibility remains enabled after a local rebuild

Local builds use the ad-hoc `signingIdentity: "-"`. A rebuild can have a new macOS code
identity while the old **System Settings > Privacy & Security > Accessibility** entry
remains visibly enabled, leaving Yanyu on `Waiting...`.

After installing the final bundle at `/Applications/Yanyu.app`, quit Yanyu, clear only its
stale Accessibility record, then reopen it:

```bash
osascript -e 'tell application id "com.siyuqian.yanyu" to quit' || true
tccutil reset Accessibility com.siyuqian.yanyu
open /Applications/Yanyu.app
```

Grant Accessibility again when prompted. This does not reset Microphone or other TCC
services, and official releases normally do not need it.

For optional diagnosis, compare the designated requirements of the previous and rebuilt
bundles:

```bash
codesign -dr - /path/to/previous/Yanyu.app 2>&1
codesign -dr - /Applications/Yanyu.app 2>&1
```

An ad-hoc requirement contains a `cdhash`; a changed requirement confirms the rebuild is
not covered by the old grant. The reset procedure does not require this check.

See [issue #1618](https://github.com/cjpais/Handy/issues/1618) for the related onboarding
and stale-permission report.

### AppImage build fails on Arch / rolling-release distros

`linuxdeploy` bundles its own `strip` binary which is too old to process system libraries built with newer toolchains on rolling-release distros (Arch, CachyOS, Manjaro, EndeavourOS).

The error from Tauri:

```
Bundling Yanyu_*_amd64.AppImage
failed to bundle project `failed to run linuxdeploy`
```

Tauri swallows the real linuxdeploy error. To see it, run linuxdeploy manually:

```bash
cd src-tauri/target/release/bundle/appimage
~/.cache/tauri/linuxdeploy-x86_64.AppImage --appimage-extract-and-run \
  --appdir Yanyu.AppDir --plugin gtk --output appimage
```

**Workaround:** The binary, deb, and rpm bundles all build fine — only the AppImage step fails. To skip it:

```bash
bun run tauri build -- --bundles deb
```

Then install using the deb extraction method above.

### Windows build fails with path-limit errors (`MSB3491` / `FTK1011` / `MSB6003`)

On Windows the native build can fail partway through `transcribe-cpp-sys` with
any of these (all the same root cause):

```
error MSB3491: Could not write lines to file "...VCTargetsPath.tlog\VCTargetsPath.lastbuildstate".
Path: ... exceeds the OS max path limit. The fully qualified file name must be less than 260 characters.
```

```
FileTracker : error FTK1011: could not create the new file tracking log file:
...\vulkan-shaders-gen-build\...\cmTC_xxxxx.tlog\link.write.1.tlog.
The system cannot find the path specified.
```

```
error MSB6003: The specified task executable "CL.exe" could not be run.
System.IO.DirectoryNotFoundException: Could not find a part of the path ...
```

This is **not** a code or toolchain problem — it's Windows' legacy 260-character
path limit (`MAX_PATH`), overflowed by the Vulkan shader generator's nested
CMake build tree on top of Cargo's already-deep
`target\release\build\<crate>-<hash>\out\build\...` directory.

Since `transcribe-cpp` 0.1.3 this is mitigated automatically: the native build
compiles through a short NTFS junction under `%LOCALAPPDATA%\tcs` (created
without admin rights), so a normal checkout builds with no setup. Enabling
Windows long paths does **not** reliably help here — MSBuild's native
`FileTracker` (`tracker.exe`) ignores the long-paths flag — which is why the
junction, not the registry flag, is the fix.

If you still see the errors above, junction creation was likely blocked
(filesystem or corporate policy) — the failing build's log then contains a
`transcribe-cpp-sys: could not create short build junction ...` warning — or
your checkout is deep enough to overflow even the shortened layout. Work
around either case with a short Cargo target directory:

```powershell
# Per-shell:
$env:CARGO_TARGET_DIR = "C:\h"

# Or persist it for all future terminals (note: redirects ALL your
# Rust projects' build output, not just Yanyu):
[Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR', 'C:\h', 'User')
```

Artifacts then land in `C:\h\release\...` instead of the repo's
`src-tauri\target\`. Open a **new terminal** if you persisted the variable —
it is only picked up by freshly started processes. Then `bun run tauri dev`
and `bun run tauri build` work normally.

### Windows `tauri build` fails at bundling with `program not found`

If the build compiles all the way to `Built application at: ...\yanyu.exe` and
then fails with:

```
Signing C:\...\yanyu.exe with a custom signing command
failed to bundle project `program not found`
```

that's the code-signing step: `tauri.conf.json` configures a custom
`signCommand` (`trusted-signing-cli`, Azure Trusted Signing) that only exists
in the release CI environment. Local development doesn't need it:

```powershell
# Development (no bundling/signing at all):
bun run tauri dev

# Or compile a release binary without the installer/signing step:
bun run tauri build --no-bundle
```

## Publishing GitHub Releases

The `Release` workflow reuses the cross-platform build workflow and uploads installers
as assets on a GitHub Release. It builds macOS (Apple Silicon and Intel), Windows
(x64 and ARM64), and Linux (x64 and ARM64).

### Set the desktop version

Choose a version explicitly and run from the repository root:

```bash
bun run version:set 0.1.0
bun run check:version
bun run test:release
```

`version:set` synchronizes `package.json`, `src-tauri/tauri.conf.json`,
`src-tauri/Cargo.toml`, and the app entry in `src-tauri/Cargo.lock`. Tauri uses this
version for the app and installers; Rust also uses it in the tray and settings.
Dependency versions, the portable core crate, and native iOS versions are independent.
The command changes files only: it does not commit, tag, or push.

Use `major.minor.patch` or a numeric prerelease such as `0.2.0-1`, without a `v`
prefix, build metadata, or leading zeros. Every release includes Windows MSI,
so major/minor are limited to 255, patch and the optional prerelease number to 65535. Named prereleases such as `rc.1` are unsupported by the bundled Tauri MSI
version converter. Invalid versions fail before files are written. CI checks that all
four desktop version sources agree. `bun run check:version v0.1.0` additionally
checks that a release tag matches the application version.

Prefer stable versions for distribution. Debian interprets the numeric suffix as
a package revision, so `0.2.0-1` sorts above `0.2.0`. After distributing that
prerelease, use a higher stable version such as `0.2.1` to preserve package upgrade
ordering.

Add any in-app release notes under `src/content/release-notes/{version}.md` before
tagging; see [the release notes guide](src/content/release-notes/README.md).
The GitHub Release description is generated from repository changes separately.

### Push a version tag

1. Commit the version files and release notes using a conventional commit such as
   `chore(release): prepare 0.1.0` so the app and installers share one version.
2. Merge the changes into `main`, including the release workflow, and update your
   local checkout to the merged commit. Run the usual lint and formatting checks.
3. Tag that exact commit and push the tag:

   ```bash
   git tag -a v0.1.0 -m "Release v0.1.0"
   git push origin v0.1.0
   ```

4. Follow **Actions → Release**. The tag push starts the workflow automatically.
   It validates the tag and all version files, creates or reuses a draft, then
   builds the exact tagged commit across all seven build jobs without Rust caches.
5. Once every build and package audit succeeds, the workflow publishes the draft
   with its installers. Download them from the Release's **Assets** section or
   the link in the workflow summary.

Tags must use the exact `v{version}` format. A prerelease version such as
`v0.2.0-1` produces a GitHub prerelease and does not become the latest stable
release. Stable releases use GitHub's date and semantic-version selection for
Latest, so retrying an older version does not explicitly promote it over a newer
version. Moving a tag during a run prevents publication. Create a new version to
change an already published release; its installers are never replaced by this workflow.

Push tags with your own Git credentials. Tags pushed by a workflow's built-in
`GITHUB_TOKEN` do not trigger another push workflow; that automation must explicitly
dispatch `Release` instead.

### Retry a failed release

A failed platform build leaves the release as a draft. Rerun the failed jobs in
Actions, or use **Actions → Release → Run workflow** from `main` and supply the
existing tag (for example `v0.1.0`). Manual dispatch builds that tag's commit,
regardless of the branch selected in the Actions form. The draft is reused,
including edited release notes, and publication still waits for all builds and
audits. Keep the tag fixed while retrying. Published releases are rejected before
builds start. Publishing a draft manually does not trigger another build.

### Signing and download access

Release builds currently use `sign-binaries: false`. macOS uses an ad-hoc signature
without Apple notarization. Windows installers do not use a publisher certificate.
Users may encounter operating-system security warnings. Trusted distribution requires
Apple Developer signing/notarization and Windows code-signing credentials, configured
as repository secrets before enabling `sign-binaries` in the release workflow.

The workflow uses GitHub's built-in `GITHUB_TOKEN` with `contents: write` to upload
assets. No personal access token is required. The repository must be public for people
without repository access to download its releases. These installers do not enable
in-app automatic updates (`createUpdaterArtifacts` is currently disabled).

Yanyu uses its own application version, starting at `0.0.1`, independently of
upstream Handy. Existing tags still refer to their original commits. Merge this
workflow before creating a new version tag: rerunning an old Release job does not
include version or workflow fixes merged afterward.

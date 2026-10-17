# Yanyu · 言语

**English** | [简体中文](README.zh-CN.md)

Yanyu is a personal speech input project based on [Handy](https://github.com/cjpais/Handy). We plan to improve the UI/UX and later add tools to organize, manually correct, and export personal speech samples for model training.

The application already uses Yanyu branding and an independent identifier. The interface redesign, training-data export, and model-training workflow are not yet implemented.

Optional local polishing uses Qwen3-0.6B on Apple Silicon Macs with fixed conservative cleanup and terminology correction rules. Enable it in General settings. Your existing custom words supply a bounded terminology list, independently of the profile. Clear recognition errors may be replaced by whole listed terms when the transcript or enabled domain supports the correction; uncertain names and literal quotations stay unchanged. An enabled personalization profile supplies domain context only. Disabled or deleted profiles do not influence local polishing. The Prompt editor is removed, but saved legacy prompts remain on disk. Local previews use the same processing as daily dictation and never fall back to an external service. Inputs over 200 characters skip local polishing. Unavailable models, invalid output and the 500 ms deadline preserve the original transcript.

With local polishing off, enabled personalization automatically processes each dictation through the configured service. It sends the transcript, bounded custom terminology and enabled profile context, not the recording. The optional recording preview uses the same cleanup and requires no separate activation. Service failure, invalid output or a 10-second deadline preserves the original transcript. Both routes share validation: at most two short terminology substitutions and conservative cleanup elsewhere. Substitutions cannot replace identifiers, numbers, quotations or common negation/condition markers, and an output containing one must keep them all; cleanup without a substitution uses only the existing cleanup checks. English substitutions require a single whole word; Chinese source spans are limited to four characters. Unlisted substitutions are rejected. Without usable custom terms, processing remains cleanup-only. Structural checks cannot distinguish every genuine name from a recognition error or guarantee semantic fidelity, and the small local model may not finish a correction within 500 ms.

## Project origin

- Upstream project: [cjpais/Handy](https://github.com/cjpais/Handy)
- Initial import commit: `f6b3f82`
- Original project documentation: [README.upstream.md](README.upstream.md)
- Upstream Git history is preserved to track provenance and synchronize updates.

Yanyu is an independent derivative project with no official affiliation with or endorsement from Handy. The application name, icons, tray, and installers use Yanyu branding. Its application identifier is `com.siyuqian.yanyu`.

Yanyu uses separate data directories and system permissions from Handy, so both applications can be installed together. Existing Handy settings, models, and history do not migrate automatically. Automatic updates are disabled until Yanyu has its own release channel and signing keys. Windows installers currently have no configured publisher signature.

## Technology and development

- Interface: React, TypeScript, Tailwind CSS
- Desktop application: Tauri 2, Rust
- Speech recognition: local model inference

Development requires Bun, Rust, and the Tauri build dependencies for your platform. See [BUILD.md](BUILD.md) for the full setup.

```bash
bun install
bun run tauri dev
```

See [AGENTS.md](AGENTS.md) for the project map, [ARCHITECTURE.md](ARCHITECTURE.md) for the architecture, and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the development reference. Before your first development run, prepare the Silero VAD model as described in the development reference. Keep personal recordings and training data local; do not commit them to this public repository.

## License and attribution

This project uses the [MIT License](LICENSE). It retains upstream author CJ Pais's copyright notice and the complete license text. Preserve these notices when distributing the code or substantial portions of it.

The MIT code license does not grant rights to Handy's name, logos, or brand assets. See the [upstream README](https://github.com/cjpais/Handy#license) for branding information.

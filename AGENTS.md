# Agent map

言语 · Yanyu is a personal desktop speech input project derived from Handy.
Read [README](README.md) for implemented scope and future product intentions.

## Process

For direct feature/bug requests in an Orca lead session (`ORCA_TERMINAL_HANDLE` is set), read `~/.agents/skills/orca-dev-workflow/routing.md` before source edits. Invoke the installed workflow only when that router selects it. Follow live worker/provider assignments instead. Explicit user process choices take precedence. Check: review.

## Repository map

- `src/`: React UI, settings/model stores, translations, generated Tauri bindings.
- `src-tauri/src/`: Rust runtime, commands, managers, audio toolkit and platform integrations.
- `src-tauri/resources/`: bundled resources, including the required VAD model.
- `tests/`: Playwright UI tests. `scripts/`: development and consistency checks.
- `.github/`: contributor templates and CI definitions.
- `docs/`: project knowledge and plans.

## Commands

Run from the repository root unless specified otherwise. Setup details and platform exceptions: [Development](docs/DEVELOPMENT.md), [Build](BUILD.md).

```bash
bun install
bun run dev
bun run tauri dev
bun run build
bun run tauri build
bun run lint
bun run lint:fix
bun run format:check
bun run format
bun run format:frontend
bun run format:backend
bun run test:keyboard
bun run test:playwright
bun run check:translations
bun run check:model-languages
cargo test --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --lib --tests
```

Prepare `src-tauri/resources/models/silero_vad_v4.onnx` before desktop development; see [Development](docs/DEVELOPMENT.md#development-commands).

## Rules

- All user-facing UI text must use i18next; add English source keys first. Check: `bun run lint` checks JSX literals, `bun run check:translations` checks locale consistency.
- Follow [translation contribution guidelines](CONTRIBUTING_TRANSLATIONS.md). Check: review and translation checks.
- Use strict TypeScript, avoid `any`, functional React hooks, Tailwind, and the `@/` alias. Check: `bun run build` for types; other conventions require review.
- Handle Rust errors explicitly, avoid production `unwrap`, use descriptive names and document public APIs. Check: review; clippy provides partial coverage.
- Run lint and formatting before commits; Rust changes also require cargo fmt and clippy. Check: commands above.
- CLI flags are runtime overrides and must not modify persisted settings. Check: review; see [architecture](ARCHITECTURE.md).
- Keep personal recordings and training data local; never commit them to this public repository. Check: review, [security](docs/SECURITY.md).
- Preserve the MIT copyright and license notices when distributing code or substantial portions. Check: review, [license](LICENSE).
- `README.md` is the English source; keep `README.zh-CN.md` synchronized with it and retain language-switch links at the top of both files. Check: review and documentation link checks.
- All PR titles, descriptions, and comments must be entirely in English, regardless of the conversation language. Check: review before publishing.
- Before opening any PR, issue or discussion, read and strictly follow the relevant repository template, including every mandatory section. Check: review.
- For PRs, read [the PR template](.github/PULL_REQUEST_TEMPLATE.md). If a human-written section is required, leave a clear TODO and ask the human to fill it; never invent their voice. Check: review.
- Blank issues are disabled. Use [issue templates](.github/ISSUE_TEMPLATE/); feature requests go to Handy Discussions, not issues, under the inherited contributor process. Check: [config](.github/ISSUE_TEMPLATE/config.yml), review.
- Preserve the inherited Handy feature-freeze constraint: new features need community support in Discussions before an upstream PR. Yanyu-specific applicability needs clarification before proposing features. Check: review, [contributing](CONTRIBUTING.md).
- Use conventional commit prefixes and explain why. Check: review.

## Knowledge base

- [Architecture](ARCHITECTURE.md): domains, dependencies, invariants and extension points.
- [Development reference](docs/DEVELOPMENT.md): full command recipes, CLI and platform notes, inherited contributor workflow.
- [Design decisions](docs/design-docs/index.md) and [core beliefs](docs/design-docs/core-beliefs.md).
- [Plans](docs/PLANS.md) and [technical debt](docs/exec-plans/tech-debt-tracker.md).
- [Quality evidence](docs/QUALITY_SCORE.md) and [security](docs/SECURITY.md).
- [Frontend](docs/FRONTEND.md), [visual design](docs/DESIGN.md), [reliability](docs/RELIABILITY.md).
- [Product scope](docs/PRODUCT_SENSE.md) and [product specifications](docs/product-specs/index.md).

Not applicable: `docs/generated/` (the existing generator writes TypeScript bindings, not documentation); `docs/references/` (no vendor reference material needs copying).

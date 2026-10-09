# Core beliefs

## Existing principles

1. Keep personal speech data local and outside the public repository. Source: [README](../../README.md). Check: review.
2. Preserve the fork's independent identity and upstream provenance. Source: [README](../../README.md), [Tauri configuration](../../src-tauri/tauri.conf.json). Check: review.
3. Translate UI text through the English source locale. Source: [contribution guide](../../CONTRIBUTING_TRANSLATIONS.md). Check: lint and translation consistency commands.
4. Keep runtime CLI overrides separate from saved preferences. Source: [development reference](../DEVELOPMENT.md). Check: review.
5. Follow repository templates and retain human authorship where required. Source: [agent rules](../../AGENTS.md). Check: review.

## Proposed documentation maintenance

Use the repository as the source of recorded decisions. When code changes, review the linked architecture, quality evidence and debt entries.

A recurring gardening pass could check links, command drift and the principles above, then propose small corrections. No schedule or CI job is created by this documentation change. This is a recommendation, not an established team process.

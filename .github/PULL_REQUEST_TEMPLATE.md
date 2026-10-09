## Description

<!-- Describe what changed and why, based on the actual diff. -->

## Review Guide

**Start here:** <!-- Name the most important file or component. -->

<!-- Suggest a review order and explain any tricky logic or decisions. -->

## Visual Changes

<!-- For visible UI changes, add before/after screenshots or describe the change. Remove this section otherwise. -->

Before:

After:

## Verification

<!-- Replace these items with relevant commands and flows. Check only items actually verified. Remove irrelevant items. -->

- [ ] `bun run lint` passes
- [ ] `bun run build` passes
- [ ] `cargo test --manifest-path src-tauri/Cargo.toml --lib` passes
- [ ] `cargo clippy --manifest-path src-tauri/Cargo.toml --lib --tests` passes
- [ ] Relevant browser tests pass
- [ ] Interactive changes checked with keyboard navigation and a screen reader

## Additional Notes

<!-- Describe feature flags, dependencies, limitations, migrations or follow-up work. Remove this section if unnecessary. -->

## For Reviewers (human)

- [ ] Self-review of the code
- [ ] Design matches the intended behavior
- [ ] Checked for security implications

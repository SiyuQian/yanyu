# Visual design

## Existing conventions

[Theme CSS](../src/styles/theme.css) defines the theme tokens. [App CSS](../src/App.css) defines application layout, and [overlay CSS](../src/overlay/RecordingOverlay.css) handles the recording surface. Use these tokens and existing Tailwind conventions before adding new styling systems.

[Shared UI components](../src/components/ui/) provide buttons, dialogs, toggles, inputs and settings containers. Keep behavior consistent by reusing them. Check: review; no mechanical component-reuse check exists.

[App](../src/App.tsx) initializes RTL direction and adjusts onboarding scrollbar gutters. Test layout changes against [settings layout tests](../tests/settings-layout.spec.ts). The [PR template](../.github/PULL_REQUEST_TEMPLATE.md) requests keyboard/screen-reader verification for relevant interactive changes. Browser automation alone cannot establish screen-reader behavior.

## Product direction

The [README](../README.md) plans UI/UX improvements but states the interface redesign is not implemented. This inventory records current conventions and does not establish a future design system.

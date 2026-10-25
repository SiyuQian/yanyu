# Visual design

## Existing conventions

[Theme CSS](../src/styles/theme.css) defines the theme tokens. [App CSS](../src/App.css) defines application layout, and [overlay CSS](../src/overlay/RecordingOverlay.css) handles the recording surface. Use these tokens and existing Tailwind conventions before adding new styling systems.

[Shared UI components](../src/components/ui/) provide buttons, dialogs, toggles, inputs and settings containers. Keep behavior consistent by reusing them. Check: review; no mechanical component-reuse check exists.

[App](../src/App.tsx) initializes RTL direction and adjusts onboarding scrollbar gutters. Test layout changes against [settings layout tests](../tests/settings-layout.spec.ts). The [PR template](../.github/PULL_REQUEST_TEMPLATE.md) requests keyboard/screen-reader verification for relevant interactive changes. Browser automation alone cannot establish screen-reader behavior.

## Product direction

The desktop workspace uses soft neutral surfaces, teal accents, and rounded cards. Light and dark themes share the workspace tokens in `theme.css`. The recording overlay keeps its separate palette.

The main window opens centered at 1120 × 780 and can shrink to 680 × 570. Grouped navigation separates daily work from application settings. Each page has a persistent heading above its scrollable content. At narrow widths, navigation and spacing become compact and setting rows wrap.

New workspace copy has English, Simplified Chinese, and Traditional Chinese versions. Other locales use English copy until translated.

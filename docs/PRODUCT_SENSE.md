# Product scope

[README](../README.md) is the product source: Yanyu is a personal speech-input fork of Handy, with independent branding and application identity.

## Implemented scope

The repository implements desktop recording, local speech recognition, history, settings, shortcuts and text output. It also contains optional local, remote and Apple post-processing paths. See [architecture](../ARCHITECTURE.md) for code evidence.

Independent branding is implemented. Handy settings, models and history do not migrate automatically. Automatic updates remain disabled pending a Yanyu release channel and signing setup.

## Intentions

The desktop interface uses a spacious workspace with grouped navigation, persistent page headings, and light and dark themes. The README proposes personal speech-sample organization, manual correction and export for future training. Training-data export and model-training workflows are not implemented. These intentions have no recorded execution plan or acceptance specification.

## Contributor bar

Keep speech samples local and preserve upstream license attribution. Inherited Handy contributor rules include feature-freeze/discussion routing. The local PR template differs from that inherited description; resolve the policy for Yanyu before feature submission (debt D7).

See [product specification index](product-specs/index.md). Do not present future intentions as shipped capabilities.

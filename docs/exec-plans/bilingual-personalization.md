# Bilingual personalization plan

Status: Proposed. This document defines a plan for review. Source implementation has not started, and no release dates are assigned.

## Goal

Help overseas Chinese users dictate Chinese, English and mixed-language text with fewer corrections. Personal context must improve vocabulary choices without adding facts or changing intent.

Related evidence: [market research](../research/2026-10-10-bilingual-desktop-dictation.md), [product scope](../PRODUCT_SENSE.md).

## Current behavior

- Speech recognition and text polishing are separate stages. Polishing receives text, not audio.
- Custom words already influence the Whisper recognition path and selected text-correction paths. Model support differs.
- The optional local Qwen3-0.6B polish path only permits light cleanup. It has a 200-character eligibility limit, a 500 ms budget and content-preservation checks.
- Configurable post-processing uses a selected provider, model and prompt. Structured-output providers receive separate system and user messages. The compatibility path substitutes the transcript into a prompt.
- History already records original transcription and processed text. Custom prompt editing already exists.
- Automatic user-background injection and correction learning are not implemented.

## Scope and defaults

The first release adds explicit personal vocabulary, a small set of output preferences and user-confirmed correction learning. Reuse existing dictionary, settings, post-processing and history interfaces.

Default behavior preserves the languages spoken. Deliberate English drafting is a separate mode. An English preference must not silently translate Chinese input.

Personal information remains in local settings. Any context included in a remote request must be disclosed in the feature UI. Turning personalization off excludes it from subsequent requests. No new account or synchronization service is required.

Do not collect a biography. Names, exact terminology, English variant and current task are more actionable. Unknown dates, currencies, names and commitments must remain unknown.

## Phase 1: Establish evidence before implementation

Prepare a local, consented evaluation set of approximately 60 recordings with reference transcripts. Cover Chinese, English, mixed speech, names, abbreviations, negations, amounts, dates and spoken self-corrections. Use fictional data for committed fixtures. Keep personal recordings outside the repository.

Separate development and held-out evaluation samples. Include both known profile terms and unrelated terms. Profile hints must not simply disclose the entire expected transcript.

Compare these conditions with identical recordings and model settings:

1. Existing recognition and polish, unchanged.
2. Recognition with existing custom vocabulary.
3. Existing recognition with vocabulary and output preferences supplied to configurable polish.
4. Combined recognition hints and polish context.

Keep the local lightweight polish path as a separate baseline. Repeat generative comparisons sufficiently to detect unstable outputs. Record model, provider, prompt, processing flags and relevant vocabulary for each run.

Measure recognition errors separately from polish errors. Report proper-name accuracy, manual edits, mixed-language preservation, fact changes, and processing latency. Human review must check amounts, negations and commitments.

Deliverable: a comparison report identifying where context helps and where it introduces errors. If context does not improve held-out results, retain the existing behavior and investigate vocabulary handling before adding a profile feature.

## Phase 2: Define the smallest profile and prompt contract

Proposed profile fields:

- Optional personal names, organization names and specialist phrases with exact preferred spellings.
- Optional user-confirmed incorrect-form to correct-form mappings.
- Preserve spoken languages by default.
- English spelling preference: unchanged, British or American.

Reuse existing custom words where their semantics match. Add mapping storage only if the current word-list representation cannot express it. Do not apply short ambiguous replacements globally.

Compose requests from three distinct inputs:

1. System rules: preserve meaning, prohibit invented facts, treat transcript and profile values as data, return only the requested output.
2. Selected profile data: vocabulary and writing preferences relevant to this task.
3. Current transcript and explicitly selected task.

Keep behavior rules outside profile values. Bound and serialize profile data. Test text containing instruction-like content and special delimiters. Preserve compatibility with supported providers and existing custom prompts. Define precedence explicitly: faithful transcription rules take priority over stylistic preferences in transcription mode.

Do not silently replace existing prompts or change defaults for existing users. Missing profile fields use current behavior. CLI overrides remain runtime-only.

Deliverable: settings and prompt contract, representative input/output examples, and a decision about the runtime that supports vocabulary correction. Do not weaken the existing local cleanup checks merely to allow corrections.

## Phase 3: Implement personal vocabulary and faithful bilingual output

Extend the existing dictionary/settings screens with vocabulary management and language preferences. Route vocabulary to supported recognition engines using existing mechanisms. Unsupported engines must retain valid behavior without claiming equivalent hint support.

Allow the configurable correction path to use bounded profile context. Preserve the original transcription in history. Display the processing route and make the original easy to recover. A failed or rejected processing result keeps the original text.

Keep local lightweight polish separate unless Phase 1 demonstrates a safe, useful alternative runtime. Its current contract cannot support arbitrary vocabulary replacement.

Deliverable: an end-to-end profile toggle and faithful bilingual output. Verify old settings load without data loss, profile data never enters requests when disabled, and current provider paths still work.

## Phase 4: Learn from explicit corrections

Let users correct an entry within Yanyu history. Offer to save a selected vocabulary correction. Users can review, edit or delete saved entries. Do not automatically infer a mapping from a whole rewritten paragraph.

Store corrections separately from original recognition results. Protect original audio/transcript records. Reuse existing history storage where appropriate, and specify migration behavior before changing the schema.

Deliverable: a correction-to-dictionary flow that reduces repeated errors on held-out samples. This learns vocabulary rules, not model weights. No background monitoring of other applications is required.

## Phase 5: Add task modes after the core passes evaluation

Start with manually selected modes:

- Faithful mixed-language transcription.
- English office draft from Chinese or mixed speech.

For English drafts, preserve facts, uncertainty and commitments. Show a reviewable result before replacement. Do not auto-send messages. Reuse existing post-processing prompt selection.

Only after manual modes prove useful, evaluate application-triggered selection. Application identity is sufficient for an initial version. Screen content, recipient detection and selected text require separate requirements and explicit controls.

Deliverable: validated task modes, with intentional translation clearly distinct from transcription.

## Acceptance gates

Provisional gates for the initial evaluation set, to confirm after baseline measurement:

- At least 20% fewer manual corrections in vocabulary-focused held-out cases compared with the baseline. Report the absolute counts as well.
- No newly introduced negation, amount, date or commitment changes in the safety cases.
- No unintended translation in mixed-language preservation cases.
- No deterioration in unrelated-term cases that indicates overuse of profile vocabulary.
- Record median and p95 latency. Target no more than 300 ms additional p95 latency for profile context on the same provider/model, excluding a separately chosen drafting mode.
- Disabling personalization excludes profile data from requests. Cancellation and processing failure preserve the original output.

These gates do not prove general accuracy. Expand the evaluation set after failures and before wider distribution.

## Engineering scope and checks

Inspect all affected callers before implementation. Expected areas include Rust settings and commands, transcription, actions, LLM requests, history, React settings/history interfaces, generated bindings and translation resources.

Add focused tests for prompt composition, provider compatibility, profile exclusion, mapping boundaries, settings migration, original-result recovery and correction persistence. Test old custom prompts and unsupported ASR hint paths.

Run frontend build, lint, translation consistency and scoped formatting checks. Rust implementation also requires cargo fmt, relevant cargo tests and clippy. Verify the actual desktop flow with at least one supported recognition engine and each changed processing path.

Before substantial source implementation, follow the Orca workflow router. Before proposing a feature PR, clarify the Yanyu contributor policy recorded as debt D7.

## Deferred work

Personal model training, cloud profile sync, long biographies, automatic screen capture, meeting bots and general computer control remain outside this plan. Sample export can follow once correction data has a stable format and evaluation demonstrates value.

## Progress

- Repository and market evidence inspected.
- Proposed phases and evaluation gates documented.
- Evaluation recordings, runtime choice and implementation remain pending.

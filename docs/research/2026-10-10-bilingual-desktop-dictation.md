---
topic: "Yanyu: bilingual desktop dictation for overseas Chinese users"
target_users: "Overseas Chinese users doing English and Chinese office work and everyday writing"
date: 2026-10-10
---

# Research scope

Three parallel research roles examined competitors, public user complaints, and product trends. This is desk research, not a representative survey or a measured comparison. Vendor descriptions establish advertised features, not their quality. No rejected-idea records or same-day cache existed.

Yanyu already provides local recognition, history, custom words, configurable post-processing, optional local/remote/Apple processing, Chinese script selection, and streaming-preview infrastructure. Tray code also supports copying the last transcript. These are existing capabilities, not recommendations for new features.

## Competitor analysis

| Product      | Relevant advertised capabilities                                                                 | Source                                                                                                                                                                                                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wispr Flow   | Context-aware formatting, learned vocabulary, spoken snippets, selection editing                 | [Context](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness), [snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets), [dictionary](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary) |
| Superwhisper | Local/cloud models, custom modes, application-triggered modes                                    | [Official site](https://superwhisper.com/), [changelog](https://superwhisper.com/changelog)                                                                                                                                                                                  |
| VoiceInk     | Local transcription, optional text enhancement, precise phrase replacement, modes                | [Official site](https://tryvoiceink.com/), [modes](https://tryvoiceink.com/docs/modes)                                                                                                                                                                                       |
| Typeless     | Mixed-language dictation, app-dependent style, self-correction, selected-text editing            | [Official site](https://www.typeless.com/), [selected-text operations](https://www.typeless.com/ask-anything)                                                                                                                                                                |
| Aqua Voice   | Developer terminology, contextual output, replacements, selected-text editing; cloud recognition | [Guide](https://aquavoice.com/guide), [FAQ](https://aquavoice.com/info/faq), [cloud clarification](https://aquavoice.com/windows)                                                                                                                                            |
| Handy        | Free, open-source, offline desktop dictation; Yanyu upstream baseline                            | [Official repository](https://github.com/cjpais/Handy)                                                                                                                                                                                                                       |

Feature convergence suggests a shift from transcription toward completing writing tasks. It does not establish market size or Chinese-language superiority. Local processing also has direct competitors.

## User pain points

- Vocabulary management: users request batch imports and multiword entries in [Handy #1321](https://github.com/cjpais/Handy/issues/1321) and [#1385](https://github.com/cjpais/Handy/issues/1385). A local-processing user maintains hundreds of correction mappings in [discussion #1440](https://github.com/cjpais/Handy/discussions/1440).
- Input recovery: multiple users describe clipboard insertion problems in [#502](https://github.com/cjpais/Handy/issues/502). Focus changes and recovery requests appear in [discussion #211](https://github.com/cjpais/Handy/discussions/211). These reports do not demonstrate the same defects in Yanyu.
- Bilingual control: [discussion #923](https://github.com/cjpais/Handy/discussions/923) asks for a restricted language pair. This supports multilingual-control demand, but is not direct evidence of overseas Chinese demand.
- Overprocessing: users describe unwanted rewriting in [this Superwhisper discussion](https://www.reddit.com/r/superwhisper/comments/1w12rlw/how_to_avoid_ai_rewriting_in_its_style_how_to_get/). Original-text recovery is a useful interview hypothesis.

Public issues favor technical users experiencing problems. These samples cannot estimate prevalence or willingness to pay.

## Market trends

- Application-dependent output is established functionality: [Flow context awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness), [VoiceInk modes](https://tryvoiceink.com/docs/modes).
- Personalization can use correction dictionaries without training model weights: [Flow dictionary](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary).
- Selected-text voice editing is an adjacent writing workflow: [Typeless](https://www.typeless.com/ask-anything), [Aqua API](https://aquavoice.com/api).
- Local processing and cloud zero-retention policies are different properties. Aqua explicitly requires cloud recognition; Yanyu already offers local processing.
- Personal fine-tuning needs evidence before a product promise. [Hugging Face's Whisper tutorial](https://huggingface.co/blog/fine-tune-whisper) demonstrates dataset-based training, not improvement from a few personal recordings. Yanyu's planned correction/export workflow should precede training experiments.

## Prioritized opportunities

Scores are editorial judgments, not measured demand. Each dimension ranges from 0 to 3. Higher feasibility means easier delivery. Demand scores reflect usefulness hypotheses supported by the sources above.

| Opportunity                                                                      | Demand | Competitive gap | Trend alignment | Feasibility | Total |
| -------------------------------------------------------------------------------- | -----: | --------------: | --------------: | ----------: | ----: |
| Correction-to-dictionary workflow; names and bilingual phrases; batch management |      3 |               1 |               3 |           3 |    10 |
| Preserve Chinese/English code-switching, proper names and meaningful symbols     |      3 |               2 |               3 |           2 |    10 |
| Automatically select an existing output profile by application                   |      3 |               1 |               3 |           3 |    10 |
| Chinese speech to faithful English office writing with a reviewable draft        |      3 |               1 |               3 |           2 |     9 |
| Compare original and polished text; restore original; quicker input recovery     |      3 |               1 |               2 |           3 |     9 |
| Spoken triggers for exact reusable text: signatures, addresses, replies          |      2 |               0 |               3 |           3 |     8 |
| Select text and speak a revision or translation instruction                      |      2 |               0 |               3 |           2 |     7 |
| Correct, organize and export local speech samples for later evaluation           |      2 |               2 |               1 |           2 |     7 |

For bilingual output, distinguish preserving mixed speech from intentionally translating Chinese speech into English. Locale preferences should cover English variant, unambiguous dates, currency, and proper names without guessing omitted facts.

Recommended sequence: establish a Chinese/English evaluation set, improve correction and recovery, then add application profiles and bilingual office drafts. Defer meeting bots, general computer control, team administration and one-click personal model training until demand is demonstrated.

## Validation before a roadmap

Recruit roughly 10–15 overseas Chinese users as a proposed discovery sample, not an existing study. Include email, chat, forms, mixed-language speech and local-only use. Compare the same recordings and target apps across Yanyu and a small competitor set. Measure usable-output rate, manual edits, time from recording completion to insertion, and meaning changes in English drafts. Set acceptance thresholds after collecting a baseline.

No source implementation, real-device benchmarks, representative market survey, or personal-model training experiment was performed.

use yanyu_core::{
    apply_custom_words, normalize_transcription_output, remove_filler_words, OutputLanguageEvidence,
};

#[test]
fn custom_word_correction_preserves_case_and_punctuation() {
    let result = apply_custom_words("I use chat g p, daily.", &["ChatGPT".into()], 0.5);

    assert_eq!(result, "I use ChatGPT, daily.");
}

#[test]
fn language_evidence_gates_ambiguous_fillers() {
    let text = "um I think this works; uh, yes";

    let unknown = remove_filler_words(text, &OutputLanguageEvidence::Unknown, &None, true);
    let english = remove_filler_words(
        text,
        &OutputLanguageEvidence::ModelDetected("en".into()),
        &None,
        true,
    );

    assert_eq!(
        normalize_transcription_output(unknown),
        "um I think this works; yes"
    );
    assert_eq!(
        normalize_transcription_output(english),
        "I think this works; yes"
    );
}

#[test]
fn custom_filler_list_replaces_defaults_and_master_switch_disables_it() {
    let text = "um customword I think";
    let custom = Some(vec!["customword".into()]);

    let custom_result = remove_filler_words(
        text,
        &OutputLanguageEvidence::UserSelected("en".into()),
        &custom,
        true,
    );
    let disabled = remove_filler_words(
        text,
        &OutputLanguageEvidence::UserSelected("en".into()),
        &custom,
        false,
    );

    assert_eq!(normalize_transcription_output(custom_result), "um I think");
    assert_eq!(disabled, text);
}

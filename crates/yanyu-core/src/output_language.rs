use crate::canonical_language_code;

/// Evidence for the language of a transcription result.
///
/// This describes recognized output, not the app's interface language. An
/// unknown result should fail closed when applying language-specific cleanup.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OutputLanguageEvidence {
    UserSelected(String),
    ModelConstrained(String),
    /// The transcription model identified the spoken language.
    ModelDetected(String),
    /// Detected from recognized text, constrained by the model's languages.
    TextDetected(String),
    TranslatedToEnglish,
    Unknown,
}

impl OutputLanguageEvidence {
    /// Returns the known output language, if any.
    pub fn language(&self) -> Option<&str> {
        match self {
            Self::UserSelected(language)
            | Self::ModelConstrained(language)
            | Self::ModelDetected(language)
            | Self::TextDetected(language) => Some(language),
            Self::TranslatedToEnglish => Some("en"),
            Self::Unknown => None,
        }
    }
}

/// Resolves the best evidence for a transcription's output language.
///
/// A persisted user preference counts only when the engine actually applied
/// that language hint. A single-language model supplies a fallback when no
/// hint is applied. Translation output is always English.
pub fn resolve_output_language_evidence(
    selected_language: &str,
    applied_language_hint: Option<&str>,
    supported_languages: &[String],
    translated_to_english: bool,
) -> OutputLanguageEvidence {
    if translated_to_english {
        return OutputLanguageEvidence::TranslatedToEnglish;
    }

    if let Some(language) = applied_language_hint.filter(|lang| !lang.is_empty() && *lang != "auto")
    {
        if selected_language != "auto"
            && canonical_language_code(selected_language) == canonical_language_code(language)
        {
            return OutputLanguageEvidence::UserSelected(language.to_string());
        }

        return OutputLanguageEvidence::ModelConstrained(language.to_string());
    }

    if let [language] = supported_languages {
        return OutputLanguageEvidence::ModelConstrained(language.clone());
    }

    OutputLanguageEvidence::Unknown
}

/// Uses language detection from the audio only when stronger evidence is
/// unavailable.
pub fn with_model_detected_language(
    evidence: OutputLanguageEvidence,
    detected: Option<String>,
) -> OutputLanguageEvidence {
    match (evidence, detected) {
        (OutputLanguageEvidence::Unknown, Some(language))
            if !language.is_empty() && language != "auto" =>
        {
            OutputLanguageEvidence::ModelDetected(language)
        }
        (evidence, _) => evidence,
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        resolve_output_language_evidence, with_model_detected_language, OutputLanguageEvidence,
    };

    #[test]
    fn applied_selected_language_is_user_evidence_with_aliases() {
        assert_eq!(
            resolve_output_language_evidence("no", Some("nb"), &["nb".to_string()], false),
            OutputLanguageEvidence::UserSelected("nb".to_string())
        );
    }

    #[test]
    fn unapplied_or_mismatched_language_hint_is_model_constrained() {
        assert_eq!(
            resolve_output_language_evidence("pt", Some("en"), &["en".to_string()], false),
            OutputLanguageEvidence::ModelConstrained("en".to_string())
        );
        assert_eq!(
            resolve_output_language_evidence("en", None, &["en".to_string()], false),
            OutputLanguageEvidence::ModelConstrained("en".to_string())
        );
    }

    #[test]
    fn ignored_hint_on_multilingual_model_leaves_language_unknown() {
        assert_eq!(
            resolve_output_language_evidence(
                "en",
                None,
                &["en".to_string(), "pt".to_string()],
                false,
            ),
            OutputLanguageEvidence::Unknown
        );
    }

    #[test]
    fn translation_to_english_takes_precedence_over_source_hint() {
        assert_eq!(
            resolve_output_language_evidence(
                "pt",
                Some("pt"),
                &["en".to_string(), "pt".to_string()],
                true
            ),
            OutputLanguageEvidence::TranslatedToEnglish
        );
    }

    #[test]
    fn model_detection_only_fills_unknown_evidence() {
        assert_eq!(
            with_model_detected_language(OutputLanguageEvidence::Unknown, Some("en".to_string())),
            OutputLanguageEvidence::ModelDetected("en".to_string())
        );
        assert_eq!(
            with_model_detected_language(OutputLanguageEvidence::Unknown, Some("auto".to_string())),
            OutputLanguageEvidence::Unknown
        );
        assert_eq!(
            with_model_detected_language(
                OutputLanguageEvidence::UserSelected("pt".to_string()),
                Some("en".to_string()),
            ),
            OutputLanguageEvidence::UserSelected("pt".to_string())
        );
    }
}

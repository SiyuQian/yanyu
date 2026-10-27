/// The operation selected for a transcribe-cpp model run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptionTask {
    Transcribe,
    Translate,
}

/// Language and task options accepted by a single transcribe-cpp run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscribeCppRunPlan {
    pub task: TranscriptionTask,
    pub language: Option<String>,
    pub target_language: Option<String>,
}

/// Choose language and translation options supported by the loaded model.
///
/// Unsupported language hints fall back to model detection. Translation is
/// selected only when requested and supported; English input is never
/// translated to English. When translation is selected, the target is `en`.
pub fn build_transcribe_cpp_run_plan(
    translate_to_english: bool,
    effective_language: &str,
    model_languages: &[String],
    model_supports_translate: bool,
) -> TranscribeCppRunPlan {
    let requested_language = match effective_language {
        "auto" => None,
        other => Some(other.to_owned()),
    };
    let language = requested_language.filter(|language| model_languages.contains(language));
    let translate_to_english =
        translate_to_english && model_supports_translate && language.as_deref() != Some("en");

    let (task, target_language) = if translate_to_english {
        (TranscriptionTask::Translate, Some("en".to_owned()))
    } else {
        (TranscriptionTask::Transcribe, None)
    };

    TranscribeCppRunPlan {
        task,
        language,
        target_language,
    }
}

#[cfg(test)]
mod tests {
    use super::{build_transcribe_cpp_run_plan, TranscriptionTask};

    #[test]
    fn translates_supported_non_english_to_english_only_when_enabled() {
        let plan =
            build_transcribe_cpp_run_plan(true, "es", &["en".to_owned(), "es".to_owned()], true);

        assert_eq!(plan.task, TranscriptionTask::Translate);
        assert_eq!(plan.language.as_deref(), Some("es"));
        assert_eq!(plan.target_language.as_deref(), Some("en"));
    }

    #[test]
    fn does_not_translate_english_to_english() {
        let plan =
            build_transcribe_cpp_run_plan(true, "en", &["en".to_owned(), "es".to_owned()], true);

        assert_eq!(plan.task, TranscriptionTask::Transcribe);
        assert_eq!(plan.language.as_deref(), Some("en"));
        assert_eq!(plan.target_language, None);
    }

    #[test]
    fn unsupported_language_falls_back_to_auto_detection() {
        let plan =
            build_transcribe_cpp_run_plan(true, "fr", &["en".to_owned(), "es".to_owned()], true);

        assert_eq!(plan.task, TranscriptionTask::Translate);
        assert_eq!(plan.language, None);
        assert_eq!(plan.target_language.as_deref(), Some("en"));
    }

    #[test]
    fn model_without_translation_support_transcribes_in_supported_language() {
        let plan =
            build_transcribe_cpp_run_plan(true, "es", &["en".to_owned(), "es".to_owned()], false);

        assert_eq!(plan.task, TranscriptionTask::Transcribe);
        assert_eq!(plan.language.as_deref(), Some("es"));
        assert_eq!(plan.target_language, None);
    }
}

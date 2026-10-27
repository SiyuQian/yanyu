use std::collections::HashSet;

/// Converts the script aliases accepted in model metadata to the recognition
/// code expected by Yanyu's language picker.
fn recognition_language(language: &str) -> &str {
    match language {
        "zh-Hans" | "zh-Hant" => "zh",
        other => other,
    }
}

/// Returns a language's primary BCP-47 subtag (`en-US` → `en`).
fn base_language(language: &str) -> &str {
    language.split(&['-', '_'][..]).next().unwrap_or(language)
}

/// Stable comparison code for model language aliases.
///
/// Norwegian Bokmål (`nb`) maps to Norwegian (`no`), while Nynorsk (`nn`)
/// remains distinct. Filipino (`fil`) maps to Tagalog (`tl`). Callers still
/// return the original code advertised by the model.
pub fn canonical_language_code(language: &str) -> &str {
    match base_language(language) {
        "nb" => "no",
        "fil" => "tl",
        base => base,
    }
}

/// Normalizes script aliases and removes duplicate language codes in order.
#[uniffi::export]
pub fn canonicalize_supported_languages(languages: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut canonical = Vec::with_capacity(languages.len());

    for language in languages {
        let language = recognition_language(&language).to_string();
        if seen.insert(language.clone()) {
            canonical.push(language);
        }
    }

    canonical
}

/// Resolves persisted user language intent for a particular model.
///
/// This value is computed per run and must not overwrite the user's saved
/// preference. Matching returns the exact locale the model advertises.
pub fn effective_language(
    intent: &str,
    supported_languages: &[String],
    supports_language_detection: bool,
) -> String {
    if supported_languages.is_empty() {
        return intent.to_string();
    }

    if intent != "auto" {
        let exact_base_match = supported_languages
            .iter()
            .find(|language| base_language(language) == base_language(intent));
        let equivalent_match = || {
            supported_languages.iter().find(|language| {
                canonical_language_code(language) == canonical_language_code(intent)
            })
        };

        if let Some(code) = exact_base_match.or_else(equivalent_match) {
            return code.clone();
        }
    }

    if supports_language_detection {
        return "auto".to_string();
    }

    supported_languages
        .iter()
        .find(|language| base_language(language) == "en")
        .cloned()
        .unwrap_or_else(|| recognition_language(&supported_languages[0]).to_string())
}

/// UniFFI-owned-argument wrapper for [`effective_language`].
#[uniffi::export]
pub fn resolve_effective_language(
    intent: String,
    supported_languages: Vec<String>,
    supports_language_detection: bool,
) -> String {
    effective_language(&intent, &supported_languages, supports_language_detection)
}

#[cfg(test)]
mod tests {
    use crate::{canonical_language_code, canonicalize_supported_languages, effective_language};

    #[test]
    fn canonicalizes_chinese_script_tags_and_deduplicates() {
        assert_eq!(
            canonicalize_supported_languages(vec![
                "en".to_string(),
                "zh".to_string(),
                "zh-Hans".to_string(),
                "zh-Hant".to_string(),
                "yue".to_string(),
            ]),
            vec!["en", "zh", "yue"]
        );
    }

    #[test]
    fn resolves_language_intent_to_the_model_locale() {
        let languages = vec!["en-US".to_string(), "zh-CN".to_string()];
        assert_eq!(effective_language("en", &languages, true), "en-US");
        assert_eq!(effective_language("zh-Hans", &languages, true), "zh-CN");
    }

    #[test]
    fn preserves_language_aliases_and_prefers_exact_supported_code() {
        assert_eq!(canonical_language_code("nb-NO"), "no");
        assert_eq!(canonical_language_code("fil-PH"), "tl");
        assert_eq!(effective_language("nb", &["no".to_string()], true), "no");
        assert_eq!(
            effective_language("nb", &["no".to_string(), "nb".to_string()], true),
            "nb"
        );
    }

    #[test]
    fn unsupported_intent_uses_detection_or_a_concrete_fallback() {
        let languages = vec!["zh-Hant".to_string(), "en-US".to_string()];
        assert_eq!(effective_language("fr", &languages, true), "auto");
        assert_eq!(effective_language("auto", &languages, false), "en-US");
        assert_eq!(effective_language("auto", &[], false), "auto");
    }
}

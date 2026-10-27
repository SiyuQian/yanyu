//! Confidence-gated text-based language identification.
//!
//! Last-resort evidence for language-specific transcript cleanup when neither
//! the user's selection nor the transcription model identifies the output
//! language. Detection is constrained to languages the active model can
//! produce and fails closed when evidence is ambiguous.

use whatlang::{Detector, Lang};

/// Minimum whatlang confidence (0.0–1.0), in addition to its reliability
/// heuristic. A false positive could delete real words, so the gate is strict.
const MIN_CONFIDENCE: f64 = 0.9;

/// Converts model metadata to whatlang's ISO 639-3 language enum.
fn whatlang_lang_for_model_code(code: &str) -> Option<Lang> {
    let primary = code
        .trim()
        .split(&['-', '_'][..])
        .next()?
        .to_ascii_lowercase();

    if primary == "zh" {
        return Some(Lang::Cmn);
    }

    let language = match primary.len() {
        2 => isolang::Language::from_639_1(&primary)?,
        3 => isolang::Language::from_639_3(&primary)?,
        _ => return None,
    };

    Lang::from_code(language.to_639_3())
}

fn iso639_1_for_whatlang(language: Lang) -> Option<&'static str> {
    match language {
        Lang::Cmn => Some("zh"),
        other => isolang::Language::from_639_3(other.code())?.to_639_1(),
    }
}

/// Detects recognized-text language, constrained by the model's output list.
/// Returns an ISO 639-1 code only when detection is reliable and high-confidence.
pub fn detect_output_language(text: &str, supported_languages: &[String]) -> Option<String> {
    // Some model codes are outside whatlang's repertoire (such as Maltese or
    // Cantonese). Drop those entries without disabling representable ones.
    let allowlist: Vec<Lang> = supported_languages
        .iter()
        .filter_map(|code| whatlang_lang_for_model_code(code))
        .collect();

    let detector = if supported_languages.is_empty() {
        // Missing metadata is unconstrained, not an empty allowlist.
        Detector::new()
    } else if allowlist.is_empty() {
        // Metadata exists but cannot be represented, so fail closed.
        return None;
    } else {
        Detector::with_allowlist(allowlist)
    };

    let info = detector.detect(text)?;
    if !info.is_reliable() || info.confidence() < MIN_CONFIDENCE {
        return None;
    }

    iso639_1_for_whatlang(info.lang()).map(str::to_string)
}

/// UniFFI-owned-argument entry point for confidence-gated text detection.
#[uniffi::export]
pub fn detect_output_language_for_text(
    text: String,
    supported_languages: Vec<String>,
) -> Option<String> {
    detect_output_language(&text, &supported_languages)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn langs(codes: &[&str]) -> Vec<String> {
        codes.iter().map(|code| (*code).to_string()).collect()
    }

    #[test]
    fn detects_portuguese_without_mistaking_um_for_english_filler() {
        let detected = detect_output_language(
            "eu vi um carro na rua ontem de manhã quando fui ao mercado",
            &langs(&["en", "pt", "es"]),
        );

        assert_eq!(detected.as_deref(), Some("pt"));
    }

    #[test]
    fn short_ambiguous_text_returns_no_language() {
        assert_eq!(detect_output_language("um ok", &langs(&["en", "pt"])), None);
    }

    #[test]
    fn converts_model_language_codes_to_whatlang_codes() {
        assert_eq!(whatlang_lang_for_model_code("pt-BR"), Some(Lang::Por));
        assert_eq!(whatlang_lang_for_model_code("PT_br"), Some(Lang::Por));
        assert_eq!(whatlang_lang_for_model_code("eng"), Some(Lang::Eng));
        assert_eq!(whatlang_lang_for_model_code("zh-Hant"), Some(Lang::Cmn));
        assert_eq!(iso639_1_for_whatlang(Lang::Cmn), Some("zh"));
    }

    #[test]
    fn regional_model_allowlist_preserves_detection() {
        let detected = detect_output_language(
            "eu vi um carro na rua ontem de manhã quando fui ao mercado",
            &langs(&["en", "pt-BR"]),
        );

        assert_eq!(detected.as_deref(), Some("pt"));
    }

    #[test]
    fn drops_unmappable_languages_without_disabling_detection() {
        let detected = detect_output_language(
            "um so the weather forecast said it would probably rain throughout the whole weekend",
            &langs(&["zh", "yue", "en", "ja", "ko"]),
        );

        assert_eq!(detected.as_deref(), Some("en"));
    }

    #[test]
    fn detects_with_parakeet_v3_language_metadata() {
        let parakeet_v3 = langs(&[
            "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv",
            "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
        ]);
        let detected = detect_output_language(
            "eu vi um carro na rua ontem de manhã quando fui ao mercado",
            &parakeet_v3,
        );

        assert_eq!(detected.as_deref(), Some("pt"));
    }

    #[test]
    fn fully_unmappable_metadata_fails_closed() {
        let text = "eu vi um carro na rua ontem de manhã quando fui ao mercado";

        assert_eq!(detect_output_language(text, &langs(&["yue"])), None);
    }

    #[test]
    fn absent_model_metadata_allows_unconstrained_detection() {
        let detected = detect_output_language(
            "eu vi um carro na rua ontem de manhã quando fui ao mercado",
            &[],
        );

        assert_eq!(detected.as_deref(), Some("pt"));
    }
}

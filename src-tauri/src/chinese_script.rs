//! Simplified / Traditional script handling for Chinese transcription output.
//!
//! Recognition language (Mandarin vs Cantonese) and output script are separate
//! choices: the language picks what the model listens for, and the
//! [`ChineseScript`] setting picks how the resulting text is written.
//!
//! Whether to convert is decided from the text itself, not the run's detected
//! language: models tag a whole run with one language, and mixed
//! Mandarin/English speech is often tagged English. OpenCC only rewrites Han
//! characters, so English in the same text is left alone. Japanese and Korean
//! text is never converted: it's recognised by its kana or its language.

use crate::audio_toolkit::OutputLanguageEvidence;
use crate::settings::ChineseScript;
use ferrous_opencc::{config::BuiltinConfig, OpenCC};
use log::error;
use std::sync::OnceLock;

/// The Chinese language a transcription was produced in. Picks the regional
/// conversion tables: Taiwan for Mandarin, Hong Kong for Cantonese.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChineseVariety {
    Mandarin,
    Cantonese,
}

impl ChineseVariety {
    /// Maps an output language code (`zh`, `zh-CN`, `yue`, …) to a Chinese
    /// variety. Any other language returns `None` and is never converted.
    pub fn from_language(language: &str) -> Option<Self> {
        let base = language.split(&['-', '_'][..]).next()?.to_ascii_lowercase();
        match base.as_str() {
            "zh" => Some(Self::Mandarin),
            "yue" => Some(Self::Cantonese),
            _ => None,
        }
    }
}

/// CJK ideographs (Han characters), the only characters OpenCC rewrites.
fn is_han(c: char) -> bool {
    matches!(c,
        '\u{3400}'..='\u{4DBF}'
        | '\u{4E00}'..='\u{9FFF}'
        | '\u{F900}'..='\u{FAFF}'
        | '\u{20000}'..='\u{3134F}')
}

/// Hiragana and katakana, which Chinese never uses. Excludes the katakana
/// middle dot (・), which can turn up as punctuation in Chinese text.
fn is_kana(c: char) -> bool {
    matches!(c,
        '\u{3040}'..='\u{309F}'
        | '\u{30A0}'..='\u{30FA}'
        | '\u{30FC}'..='\u{30FF}'
        | '\u{31F0}'..='\u{31FF}'
        | '\u{FF66}'..='\u{FF9F}')
}

/// Languages other than Chinese that write Han characters natively.
fn writes_han_natively(language: &str) -> bool {
    let base = language.split(&['-', '_'][..]).next().unwrap_or("");
    base.eq_ignore_ascii_case("ja") || base.eq_ignore_ascii_case("ko")
}

/// The variety to convert `text` as, or `None` when it must be left alone.
///
/// Text with Han characters is treated as Chinese unless it contains kana or
/// the language is Japanese or Korean. Any other language is ignored: it
/// describes the whole run, and mixed Mandarin/English is often detected as
/// English. Cantonese tables are used when the language says `yue`, else
/// Mandarin's.
pub fn chinese_variety_for_text(
    text: &str,
    output_language: &OutputLanguageEvidence,
) -> Option<ChineseVariety> {
    let language = output_language.language();
    if language.is_some_and(writes_han_natively)
        || !text.chars().any(is_han)
        || text.chars().any(is_kana)
    {
        return None;
    }
    Some(
        language
            .and_then(ChineseVariety::from_language)
            .unwrap_or(ChineseVariety::Mandarin),
    )
}

/// The script a locale writes Chinese in, or `None` for non-Chinese locales.
///
/// `zh` defaults to Simplified unless tagged Hant or regioned to Taiwan, Hong
/// Kong or Macau; Cantonese (`yue`) defaults to Traditional unless tagged Hans.
pub fn chinese_script_for_locale(locale: &str) -> Option<ChineseScript> {
    let normalized = locale.to_lowercase().replace('_', "-");
    let subtags: Vec<_> = normalized.split('-').collect();
    let is_hant = subtags.contains(&"hant");
    let is_hans = subtags.contains(&"hans");
    let is_traditional_region = ["tw", "hk", "mo"]
        .iter()
        .any(|region| subtags.contains(region));

    let traditional = match subtags.first().copied() {
        Some("zh") => is_hant || (!is_hans && is_traditional_region),
        Some("yue") => !is_hans,
        _ => return None,
    };
    Some(if traditional {
        ChineseScript::Traditional
    } else {
        ChineseScript::Simplified
    })
}

/// The OpenCC converter for a variety/script pair, built on first use and
/// reused after. Building one parses its dictionaries, which is too slow to
/// repeat on every live-preview update. A failed build is cached as `None`.
fn converter(variety: ChineseVariety, script: ChineseScript) -> Option<&'static OpenCC> {
    static MANDARIN_SIMPLIFIED: OnceLock<Option<OpenCC>> = OnceLock::new();
    static MANDARIN_TRADITIONAL: OnceLock<Option<OpenCC>> = OnceLock::new();
    static CANTONESE_SIMPLIFIED: OnceLock<Option<OpenCC>> = OnceLock::new();
    static CANTONESE_TRADITIONAL: OnceLock<Option<OpenCC>> = OnceLock::new();

    let (cell, config) = match (variety, script) {
        (_, ChineseScript::AsTranscribed) => return None,
        (ChineseVariety::Mandarin, ChineseScript::Simplified) => {
            (&MANDARIN_SIMPLIFIED, BuiltinConfig::Tw2sp)
        }
        (ChineseVariety::Mandarin, ChineseScript::Traditional) => {
            (&MANDARIN_TRADITIONAL, BuiltinConfig::S2tw)
        }
        (ChineseVariety::Cantonese, ChineseScript::Simplified) => {
            (&CANTONESE_SIMPLIFIED, BuiltinConfig::Hk2s)
        }
        (ChineseVariety::Cantonese, ChineseScript::Traditional) => {
            (&CANTONESE_TRADITIONAL, BuiltinConfig::S2hk)
        }
    };

    cell.get_or_init(|| match OpenCC::from_config(config) {
        Ok(converter) => Some(converter),
        Err(e) => {
            error!(
                "Failed to initialize OpenCC converter: {}. Keeping the original script.",
                e
            );
            None
        }
    })
    .as_ref()
}

/// Rewrites `text` into `script`. Fails open: if OpenCC can't be initialized
/// the text is returned unchanged.
pub fn convert_chinese_script(
    text: &str,
    variety: ChineseVariety,
    script: ChineseScript,
) -> String {
    match converter(variety, script) {
        Some(converter) => converter.convert(text),
        None => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn variety_comes_from_the_text_not_the_detected_language() {
        let mixed = "欸我跟你说，结果一打开电脑就发现，Oh my god, I forgot to charge my laptop.";
        for evidence in [
            OutputLanguageEvidence::ModelDetected("en".to_string()),
            OutputLanguageEvidence::TextDetected("en".to_string()),
            OutputLanguageEvidence::UserSelected("en".to_string()),
            OutputLanguageEvidence::Unknown,
        ] {
            assert_eq!(
                chinese_variety_for_text(mixed, &evidence),
                Some(ChineseVariety::Mandarin),
                "{evidence:?}"
            );
        }
        assert_eq!(
            chinese_variety_for_text(
                "佢哋喺度",
                &OutputLanguageEvidence::ModelDetected("yue".to_string())
            ),
            Some(ChineseVariety::Cantonese)
        );
    }

    #[test]
    fn japanese_and_han_free_text_are_left_alone() {
        let unknown = OutputLanguageEvidence::Unknown;
        assert_eq!(chinese_variety_for_text("学校に行きます", &unknown), None);
        assert_eq!(chinese_variety_for_text("コーヒー", &unknown), None);
        assert_eq!(chinese_variety_for_text("Hello, world.", &unknown), None);
        assert_eq!(chinese_variety_for_text("", &unknown), None);
        // Kanji-only text, but the language is Japanese or Korean.
        for evidence in [
            OutputLanguageEvidence::UserSelected("ja".to_string()),
            OutputLanguageEvidence::ModelDetected("ja".to_string()),
            OutputLanguageEvidence::ModelDetected("ko".to_string()),
        ] {
            assert_eq!(chinese_variety_for_text("東京大学", &evidence), None);
        }
        // The katakana middle dot alone doesn't make text Japanese.
        assert!(chinese_variety_for_text("马克・吐温", &unknown).is_some());
    }

    #[test]
    fn cantonese_uses_hong_kong_tables() {
        // Hong Kong standard writes 裏 where Taiwan writes 裡.
        assert_eq!(
            convert_chinese_script(
                "里面",
                ChineseVariety::Cantonese,
                ChineseScript::Traditional
            ),
            "裏面"
        );
        assert_eq!(
            convert_chinese_script("裏面", ChineseVariety::Cantonese, ChineseScript::Simplified),
            "里面"
        );
    }
}

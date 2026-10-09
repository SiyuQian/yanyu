/// Build the exact expected field value using accessibility UTF-16 offsets.
#[cfg(any(target_os = "macos", test))]
pub fn inserted_value(value: &str, start: usize, length: usize, text: &str) -> Option<String> {
    let units: Vec<u16> = value.encode_utf16().collect();
    let end = start.checked_add(length)?;
    let prefix = String::from_utf16(units.get(..start)?).ok()?;
    let suffix = String::from_utf16(units.get(end..)?).ok()?;
    Some(format!("{prefix}{text}{suffix}"))
}

/// Validate an explicitly selected vocabulary term before persistence.
pub fn validate_word(word: &str, output: &str, existing: &[String]) -> Result<String, String> {
    if word.chars().any(char::is_control) {
        return Err("invalid_word".into());
    }
    let word = word.split_whitespace().collect::<Vec<_>>().join(" ");
    if word.is_empty()
        || word.encode_utf16().count() > 50
        || !output.contains(&word)
        || existing
            .iter()
            .any(|old| old.to_lowercase() == word.to_lowercase())
    {
        return Err("invalid_word".into());
    }
    Ok(word)
}

/// Permit mutation only for the exact verified target and unchanged contents.
#[cfg(any(target_os = "macos", test))]
pub fn can_replace(same_target: bool, expected: &str, actual: &str) -> bool {
    same_target && expected == actual
}

/// Preserve eligibility only while the correction editor itself has focus.
pub fn opening_eligible(editor_focused: bool, eligible: bool, same_target: bool) -> bool {
    if editor_focused {
        eligible
    } else {
        same_target
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn learned_terms_use_settings_length_and_whitespace_without_stripping_names() {
        assert_eq!(
            validate_word("  Ada   Lovelace  ", "Ada Lovelace", &[]),
            Ok("Ada Lovelace".into())
        );
        assert!(validate_word("Ada   Lovelace", "Ada   Lovelace", &[]).is_err());
        for word in ["O'Connor", "Smith, Jr.", "<name>", "quoted \"name\""] {
            assert_eq!(validate_word(word, word, &[]), Ok(word.into()));
        }
        assert!(validate_word(&"😀".repeat(26), &"😀".repeat(26), &[]).is_err());
        assert!(validate_word(&"a".repeat(51), &"a".repeat(51), &[]).is_err());
        assert!(validate_word("Ada   Lovelace", "Ada Lovelace", &["Ada Lovelace".into()]).is_err());
    }

    #[test]
    fn reopening_only_preserves_eligibility_when_the_editor_has_focus() {
        assert!(opening_eligible(true, true, false));
        assert!(!opening_eligible(true, false, true));
        assert!(!opening_eligible(false, true, false));
        assert!(opening_eligible(false, false, true));
    }

    #[test]
    fn insertion_uses_utf16_and_preserves_surrounding_text() {
        assert_eq!(
            inserted_value("😀 old!", 3, 3, "新词"),
            Some("😀 新词!".into())
        );
        assert_eq!(inserted_value("😀", 1, 0, "x"), None);
        assert_eq!(inserted_value("abc", 4, 0, "x"), None);
    }

    #[test]
    fn learning_requires_an_explicit_short_term_in_corrected_output() {
        assert_eq!(validate_word("新词", "使用新词", &[]), Ok("新词".into()));
        assert!(validate_word("", "hello", &[]).is_err());
        assert!(validate_word("other", "hello", &[]).is_err());
        assert!(validate_word("hello", "hello", &["Hello".into()]).is_err());
        assert!(validate_word("a\nb", "a\nb", &[]).is_err());
        assert!(validate_word(&"a".repeat(81), &"a".repeat(81), &[]).is_err());
    }

    #[test]
    fn changed_or_different_targets_are_rejected() {
        assert!(!can_replace(false, "expected", "expected"));
        assert!(!can_replace(true, "expected", "changed"));
        assert!(can_replace(true, "expected", "expected"));
    }
}

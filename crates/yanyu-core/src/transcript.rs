/// Selects the text a history consumer should reuse, preserving the source verbatim.
///
/// A user correction takes precedence over local post-processing, which takes precedence over the
/// original recognition result. Empty strings remain valid selected values; callers decide how to
/// handle blank text for their specific action.
pub fn select_transcript_text_ref<'a>(
    transcription_text: &'a str,
    post_processed_text: Option<&'a str>,
    user_corrected_text: Option<&'a str>,
) -> &'a str {
    user_corrected_text
        .or(post_processed_text)
        .unwrap_or(transcription_text)
}

/// Applies the platform-independent cleanup used for recognized transcript text.
///
/// Three or more consecutive copies of an alphabetic word are collapsed to one,
/// and all whitespace is normalized to single spaces. This deliberately leaves
/// language-specific filler removal and script conversion to each app shell.
#[uniffi::export]
pub fn normalize_transcription_output(text: String) -> String {
    let words: Vec<&str> = text.split_whitespace().collect();
    let mut normalized = Vec::with_capacity(words.len());
    let mut index = 0;

    while index < words.len() {
        let word = words[index];
        let lowercase = word.to_lowercase();

        if lowercase.chars().all(char::is_alphabetic) {
            let mut count = 1;
            while index + count < words.len() && words[index + count].to_lowercase() == lowercase {
                count += 1;
            }

            normalized.push(word);
            index += if count >= 3 { count } else { 1 };
        } else {
            normalized.push(word);
            index += 1;
        }
    }

    normalized.join(" ")
}

#[cfg(test)]
mod tests {
    use crate::{normalize_transcription_output, select_transcript_text_ref};

    #[test]
    fn normalization_collapses_long_stutters_but_preserves_short_repeats() {
        assert_eq!(
            normalize_transcription_output("  I I I I think this works  ".to_string()),
            "I think this works"
        );
        assert_eq!(
            normalize_transcription_output("no no, wait".to_string()),
            "no no, wait"
        );
    }

    #[test]
    fn normalization_collapses_whitespace_without_changing_han_text() {
        assert_eq!(
            normalize_transcription_output("你好，\n\t世界  世界".to_string()),
            "你好， 世界 世界"
        );
    }

    #[test]
    fn normalization_handles_empty_and_whitespace_only_text() {
        assert_eq!(normalize_transcription_output(String::new()), "");
        assert_eq!(normalize_transcription_output(" \n\t ".to_string()), "");
    }

    #[test]
    fn corrected_text_takes_precedence_without_trimming() {
        assert_eq!(
            select_transcript_text_ref("raw", Some("polished"), Some("  corrected\n ")),
            "  corrected\n "
        );
    }

    #[test]
    fn polished_text_is_selected_when_no_correction_exists() {
        assert_eq!(
            select_transcript_text_ref("raw", Some(" polished "), None),
            " polished "
        );
    }

    #[test]
    fn original_text_is_selected_when_no_derived_text_exists() {
        assert_eq!(select_transcript_text_ref(" raw ", None, None), " raw ");
    }

    #[test]
    fn empty_derived_text_is_still_selected() {
        assert_eq!(select_transcript_text_ref("raw", Some(""), None), "");
        assert_eq!(
            select_transcript_text_ref("raw", Some("polished"), Some("")),
            ""
        );
    }
}

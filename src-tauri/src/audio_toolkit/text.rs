pub use yanyu_core::{apply_custom_words, remove_filler_words, OutputLanguageEvidence};

pub fn normalize_transcription_output(text: &str) -> String {
    yanyu_core::normalize_transcription_output(text.to_owned())
}

use crate::transcript::select_transcript_text_ref;
use serde::{Deserialize, Serialize};

/// One transcript-history record shared across platform-specific storage layers.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[cfg_attr(feature = "desktop-specta", derive(specta::Type))]
pub struct HistoryEntry {
    /// Stable local database identifier.
    pub id: i64,
    /// Recording filename associated with the transcript, when the platform stores audio.
    pub file_name: String,
    /// Creation time as a Unix timestamp in seconds.
    pub timestamp: i64,
    /// Whether the user marked this entry as saved.
    pub saved: bool,
    /// Display title shown in history.
    pub title: String,
    /// Original recognized text.
    pub transcription_text: String,
    /// Optional result from local post-processing.
    pub post_processed_text: Option<String>,
    /// Prompt used for local post-processing, when present.
    pub post_process_prompt: Option<String>,
    /// Whether local post-processing was requested.
    pub post_process_requested: bool,
    /// Code explaining why local post-processing kept the original text.
    pub post_process_skip_reason: Option<String>,
    /// Exact user correction; recognition and post-processing remain unchanged.
    pub user_corrected_text: Option<String>,
}

/// One bounded slice of local transcript history.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[cfg_attr(feature = "desktop-specta", derive(specta::Type))]
pub struct HistoryPage {
    /// Entries to display in the requested order.
    pub entries: Vec<HistoryEntry>,
    /// Whether the storage layer found entries beyond this page.
    pub has_more: bool,
}

/// Trims a storage query's `limit + 1` result and reports whether another page exists.
///
/// Storage layers own filtering and ordering. They can fetch one extra entry and pass the result
/// here to keep pagination boundaries consistent across desktop and mobile.
#[uniffi::export]
pub fn paginate_history_entries(mut entries: Vec<HistoryEntry>, limit: Option<u64>) -> HistoryPage {
    let has_more =
        limit.is_some_and(|limit| usize::try_from(limit).is_ok_and(|limit| entries.len() > limit));
    if let Some(limit) = limit {
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        entries.truncate(limit);
    }

    HistoryPage { entries, has_more }
}

/// Selects the verbatim history text a user should reuse.
///
/// User corrections take precedence over local post-processing, which takes precedence over the
/// original recognition result. An empty derived string remains selected; callers handle blank
/// text according to the action they perform.
#[uniffi::export]
pub fn select_history_text(entry: HistoryEntry) -> String {
    select_transcript_text_ref(
        &entry.transcription_text,
        entry.post_processed_text.as_deref(),
        entry.user_corrected_text.as_deref(),
    )
    .to_owned()
}

#[cfg(test)]
mod tests {
    use super::{paginate_history_entries, select_history_text, HistoryEntry};

    fn entry() -> HistoryEntry {
        HistoryEntry {
            id: 17,
            file_name: "capture.wav".to_owned(),
            timestamp: 1_798_326_400,
            saved: false,
            title: "Recording".to_owned(),
            transcription_text: "raw transcript".to_owned(),
            post_processed_text: Some("polished transcript".to_owned()),
            post_process_prompt: None,
            post_process_requested: true,
            post_process_skip_reason: None,
            user_corrected_text: Some("  corrected\n ".to_owned()),
        }
    }

    #[test]
    fn history_text_prefers_the_verbatim_user_correction() {
        assert_eq!(select_history_text(entry()), "  corrected\n ");
    }

    #[test]
    fn history_text_falls_back_to_post_processed_then_original_text() {
        let mut record = entry();
        record.user_corrected_text = None;
        assert_eq!(select_history_text(record.clone()), "polished transcript");

        record.post_processed_text = None;
        assert_eq!(select_history_text(record), "raw transcript");
    }

    #[test]
    fn history_text_preserves_an_empty_correction_as_the_selected_value() {
        let mut record = entry();
        record.user_corrected_text = Some(String::new());

        assert_eq!(select_history_text(record), "");
    }

    #[test]
    fn history_pagination_truncates_to_the_limit_and_reports_more_entries() {
        let page = paginate_history_entries(vec![entry(), entry(), entry()], Some(2));

        assert_eq!(page.entries.len(), 2);
        assert!(page.has_more);
    }

    #[test]
    fn history_pagination_handles_zero_exact_and_unbounded_limits() {
        let entries = vec![entry(), entry()];

        let empty_page = paginate_history_entries(entries.clone(), Some(0));
        assert!(empty_page.entries.is_empty());
        assert!(empty_page.has_more);

        let exact_page = paginate_history_entries(entries.clone(), Some(2));
        assert_eq!(exact_page.entries.len(), 2);
        assert!(!exact_page.has_more);

        let unbounded_page = paginate_history_entries(entries, None);
        assert_eq!(unbounded_page.entries.len(), 2);
        assert!(!unbounded_page.has_more);
    }
}

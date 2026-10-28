//! Selected text is read exclusively through platform Accessibility APIs.
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
mod macos;

/// Explicit local operation requested by a selection shortcut.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, specta::Type)]
#[serde(rename_all = "snake_case")]
pub enum SelectionOperation {
    #[default]
    Translate,
    Polish,
}

/// Maximum number of Unicode scalar values accepted for selection processing.
pub const MAX_SELECTION_CHARACTERS: usize = 10_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectionError {
    PermissionDenied,
    Unsupported,
    NoSelection,
    TooLong,
}
impl SelectionError {
    /// Stable localization key; never contains selected text or platform diagnostics.
    pub fn code(self) -> &'static str {
        match self {
            Self::PermissionDenied => "permission_denied",
            Self::Unsupported => "unsupported_selection",
            Self::NoSelection => "no_selection",
            Self::TooLong => "too_long",
        }
    }
}
#[derive(Clone, Copy, Debug)]
pub struct SelectionBounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
pub struct Selection {
    pub text: String,
    pub bounds: Option<SelectionBounds>,
}
/// Captures the frontmost application's selection before any preview UI is shown.
pub fn capture() -> Result<Selection, SelectionError> {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    return macos::capture();
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    Err(SelectionError::Unsupported)
}
fn validate_text(text: String) -> Result<String, SelectionError> {
    if text.trim().is_empty() {
        Err(SelectionError::NoSelection)
    } else if text.chars().count() > MAX_SELECTION_CHARACTERS {
        Err(SelectionError::TooLong)
    } else {
        Ok(text)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_blank_and_oversized_selections_without_modifying_source_text() {
        assert_eq!(
            validate_text(" \n".into()),
            Err(SelectionError::NoSelection)
        );
        assert_eq!(
            validate_text("a".repeat(MAX_SELECTION_CHARACTERS + 1)),
            Err(SelectionError::TooLong)
        );
        assert_eq!(validate_text(" hello\n".into()), Ok(" hello\n".into()));
    }
}

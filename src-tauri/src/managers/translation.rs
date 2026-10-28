//! One local selection operation at a time; selected text is never persisted or logged.
use super::local_polishing::LocalPolishingManager;
use crate::selection::SelectionOperation;
use crate::{selection, translation_overlay};
use serde::Serialize;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tauri::{AppHandle, Emitter, Manager};

/// Transient snapshot sent to the translation webview and returned by its state command.
#[derive(Clone, Default, Serialize, specta::Type)]
pub struct TranslationState {
    pub operation: SelectionOperation,
    /// Empty before the first request. Then `loading` during capture/inference,
    /// `result` on success, `error` on failure, or `idle` after dismissal.
    pub phase: String,
    /// Completed selection result in `result` only. Null in all other phases.
    pub text: Option<String>,
    /// Stable localization key in `error` only. Serialized as null otherwise.
    pub error: Option<String>,
    /// Increments on start, accepted completion, and dismissal, wrapping at u32::MAX.
    /// Stale completions leave it unchanged. Copy requires the current result revision.
    pub revision: u32,
}
#[derive(Default)]
struct Inner {
    state: TranslationState,
    cancel: Option<Arc<AtomicBool>>,
}
impl Inner {
    fn begin(&mut self, operation: SelectionOperation) -> Option<Arc<AtomicBool>> {
        if self.cancel.is_some() {
            return None;
        }
        let cancel = Arc::new(AtomicBool::new(false));
        self.cancel = Some(cancel.clone());
        self.state.operation = operation;
        self.state.revision = self.state.revision.wrapping_add(1);
        self.state.phase = "loading".into();
        self.state.text = None;
        self.state.error = None;
        Some(cancel)
    }
    fn complete(&mut self, cancel: &Arc<AtomicBool>, result: Result<String, String>) -> bool {
        // A dismissed request must never overwrite the next selection's state.
        if !self.cancel.as_ref().is_some_and(|c| Arc::ptr_eq(c, cancel)) {
            return false;
        }
        self.cancel = None;
        self.state.revision = self.state.revision.wrapping_add(1);
        match result {
            Ok(text) => {
                self.state.phase = "result".into();
                self.state.text = Some(text);
            }
            Err(error) => {
                self.state.phase = "error".into();
                self.state.error = Some(error);
            }
        }
        true
    }
    fn dismiss(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            cancel.store(true, Ordering::Release);
        }
        self.state.revision = self.state.revision.wrapping_add(1);
        self.state.phase = "idle".into();
        self.state.text = None;
        self.state.error = None;
    }
}
#[derive(Default)]
pub struct TranslationManager(Mutex<Inner>);
impl TranslationManager {
    /// Snapshot recovers any events emitted before the webview's listener was installed.
    pub fn state(&self) -> TranslationState {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .state
            .clone()
    }
    fn emit(&self, app: &AppHandle) {
        if let Err(error) = app.emit_to("translation_overlay", "translation-state", self.state()) {
            log::warn!("Could not deliver translation state: {error}");
        }
    }
    /// Capture synchronously before creating or activating any window.
    pub fn start(app: &AppHandle, operation: SelectionOperation) {
        if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            return;
        }
        let manager = app.state::<Self>();
        let cancel = {
            let mut inner = manager.0.lock().unwrap_or_else(|e| e.into_inner());
            let Some(cancel) = inner.begin(operation) else {
                return;
            };
            cancel
        };
        let selection = selection::capture();
        let bounds = selection.as_ref().ok().and_then(|s| s.bounds);
        // Source text and geometry are captured even on the first invocation, before window creation.
        if let Err(error) = translation_overlay::show(app, bounds) {
            log::warn!("Could not schedule translation window: {error}");
            manager.dismiss(app);
            return;
        }
        manager.emit(app);
        let handle = app.clone();
        tauri::async_runtime::spawn(async move {
            let result = match selection {
                Ok(selection) => {
                    let model = handle.state::<Arc<LocalPolishingManager>>().inner().clone();
                    model
                        .process_selection(&selection.text, operation, cancel.clone())
                        .await
                }
                Err(error) => Err(error.code().into()),
            };
            let manager = handle.state::<Self>();
            let mut inner = manager.0.lock().unwrap_or_else(|e| e.into_inner());
            if !inner.complete(&cancel, result) {
                return;
            }
            drop(inner);
            manager.emit(&handle);
        });
    }
    /// Cancel work, discard transient selection/result state, and hide the popover.
    pub fn dismiss(&self, app: &AppHandle) {
        let mut inner = self.0.lock().unwrap_or_else(|e| e.into_inner());
        inner.dismiss();
        drop(inner);
        self.emit(app);
        if let Some(window) = app.get_webview_window("translation_overlay") {
            if let Err(error) = window.hide() {
                log::warn!("Could not hide translation window: {error}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeout_publishes_error_and_allows_a_subsequent_request() {
        let mut inner = Inner::default();
        let timed_out = inner.begin(SelectionOperation::Translate).unwrap();
        assert!(inner.begin(SelectionOperation::Polish).is_none());
        assert_eq!(inner.state.operation, SelectionOperation::Translate);
        // The inference deadline cancels background work before returning the error.
        timed_out.store(true, Ordering::Release);
        assert!(inner.complete(&timed_out, Err("timeout".into())));
        assert!(inner.cancel.is_none());
        assert_eq!(inner.state.phase, "error");
        assert_eq!(inner.state.error.as_deref(), Some("timeout"));
        assert!(inner.state.text.is_none());
        assert_eq!(inner.state.revision, 2);

        let next = inner
            .begin(SelectionOperation::Translate)
            .expect("timeout must release the active request");
        assert_eq!(inner.state.phase, "loading");
        assert!(inner.state.error.is_none());
        assert!(inner.complete(&next, Ok("你好".into())));
        assert_eq!(inner.state.phase, "result");
        assert_eq!(inner.state.text.as_deref(), Some("你好"));
        assert!(inner.state.error.is_none());
        assert_eq!(inner.state.revision, 4);
    }

    #[test]
    fn dismissed_and_stale_requests_cannot_publish_or_release_a_new_request() {
        let mut inner = Inner::default();
        let dismissed = inner.begin(SelectionOperation::Translate).unwrap();
        inner.dismiss();
        assert!(dismissed.load(Ordering::Acquire));
        assert!(!inner.complete(&dismissed, Ok("late".into())));
        assert_eq!(inner.state.phase, "idle");
        assert_eq!(inner.state.revision, 2);
        let current = inner.begin(SelectionOperation::Polish).unwrap();
        assert!(!inner.complete(&dismissed, Err("timeout".into())));
        assert!(Arc::ptr_eq(inner.cancel.as_ref().unwrap(), &current));
        assert_eq!(inner.state.phase, "loading");
        assert_eq!(inner.state.operation, SelectionOperation::Polish);
        assert_eq!(inner.state.revision, 3);
        assert!(inner.complete(&current, Ok("新的".into())));
        assert!(!inner.complete(&current, Err("late duplicate".into())));
        assert_eq!(inner.state.text.as_deref(), Some("新的"));
        assert_eq!(inner.state.operation, SelectionOperation::Polish);
        assert_eq!(inner.state.revision, 4);
    }
}

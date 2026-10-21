//! One local selection translation at a time; selected text is never persisted or logged.
use super::local_polishing::LocalPolishingManager;
use crate::{selection, translation_overlay};
use serde::Serialize;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Default, Serialize, specta::Type)]
pub struct TranslationState {
    pub phase: String,
    pub text: Option<String>,
    pub error: Option<String>,
    pub revision: u32,
}
#[derive(Default)]
struct Inner {
    state: TranslationState,
    cancel: Option<Arc<AtomicBool>>,
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
    pub fn start(app: &AppHandle) {
        if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            return;
        }
        let manager = app.state::<Self>();
        let cancel = {
            let mut inner = manager.0.lock().unwrap_or_else(|e| e.into_inner());
            if inner.cancel.is_some() {
                return;
            }
            let cancel = Arc::new(AtomicBool::new(false));
            inner.cancel = Some(cancel.clone());
            inner.state.revision = inner.state.revision.wrapping_add(1);
            inner.state.phase = "loading".into();
            inner.state.text = None;
            inner.state.error = None;
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
                    model.translate(&selection.text, cancel.clone()).await
                }
                Err(error) => Err(error.code().into()),
            };
            let manager = handle.state::<Self>();
            let mut inner = manager.0.lock().unwrap_or_else(|e| e.into_inner());
            // A dismissed request must never overwrite the next selection's state.
            if cancel.load(Ordering::Acquire)
                || !inner
                    .cancel
                    .as_ref()
                    .is_some_and(|c| Arc::ptr_eq(c, &cancel))
            {
                return;
            }
            inner.cancel = None;
            inner.state.revision = inner.state.revision.wrapping_add(1);
            match result {
                Ok(text) => {
                    inner.state.phase = "result".into();
                    inner.state.text = Some(text);
                }
                Err(error) => {
                    inner.state.phase = "error".into();
                    inner.state.error = Some(error);
                }
            }
            drop(inner);
            manager.emit(&handle);
        });
    }
    /// Cancel work, discard transient selection/result state, and hide the popover.
    pub fn dismiss(&self, app: &AppHandle) {
        let mut inner = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(cancel) = inner.cancel.take() {
            cancel.store(true, Ordering::Release);
        }
        inner.state.revision = inner.state.revision.wrapping_add(1);
        inner.state.phase = "idle".into();
        inner.state.text = None;
        inner.state.error = None;
        drop(inner);
        self.emit(app);
        if let Some(window) = app.get_webview_window("translation_overlay") {
            if let Err(error) = window.hide() {
                log::warn!("Could not hide translation window: {error}");
            }
        }
    }
}

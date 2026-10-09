//! On-demand correction. Transcript and target snapshots remain in memory only.
mod guards;
#[cfg(target_os = "macos")]
mod macos;
use crate::settings::{get_settings, write_settings, ClipboardHandling, PasteMethod};
use once_cell::sync::Lazy;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_store::StoreExt;

#[cfg(target_os = "macos")]
type Target = macos::Target;
#[cfg(not(target_os = "macos"))]
pub struct Target;
#[cfg(not(target_os = "macos"))]
impl Target {
    fn capture(_: &str) -> Option<Self> {
        None
    }
    fn confirm(&self) -> bool {
        false
    }
    fn matches_focus(&self) -> bool {
        false
    }
    fn replace(&self, _: &str) -> Option<bool> {
        None
    }
}

#[derive(Clone, serde::Serialize, specta::Type)]
pub struct CorrectionSession {
    pub generation: u32,
    pub draft: String,
    pub word: Option<String>,
}
#[derive(Default)]
struct State {
    generation: u32,
    session: Option<CorrectionSession>,
    target: Option<Target>,
    eligible: bool,
    trailing_space: bool,
}
impl State {
    fn record(
        &mut self,
        text: String,
        target: Option<Target>,
        success: bool,
        trailing_space: bool,
    ) {
        self.target = None;
        self.eligible = false;
        if !success {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        self.session = Some(CorrectionSession {
            generation: self.generation,
            draft: text,
            word: None,
        });
        self.trailing_space = trailing_space;
        self.target = target.filter(Target::confirm);
    }
    fn save(&mut self, generation: u32, draft: String, word: Option<String>) -> Result<(), String> {
        let session = self
            .session
            .as_mut()
            .filter(|s| s.generation == generation)
            .ok_or("stale_session")?;
        if draft.encode_utf16().count() > 32768 {
            return Err("too_long".into());
        }
        session.draft = draft;
        session.word = word;
        Ok(())
    }
}
static STATE: Lazy<Mutex<State>> = Lazy::new(|| Mutex::new(State::default()));

/// Capture the target immediately before the existing delivery operation.
pub fn capture(app: &AppHandle, text: &str) -> Option<Target> {
    let settings = get_settings(app);
    if crate::secure_input::is_enabled_now()
        || settings.auto_submit
        || matches!(
            settings.paste_method,
            PasteMethod::None | PasteMethod::ExternalScript
        )
    {
        return None;
    }
    let delivered = if settings.append_trailing_space {
        format!("{text} ")
    } else {
        text.to_string()
    };
    Target::capture(&delivered)
}

/// Retain only successfully delivered final output, independent of history/WAV.
pub fn delivered(app: &AppHandle, text: String, target: Option<Target>, success: bool) {
    let Ok(mut state) = STATE.lock() else {
        return;
    };
    let settings = get_settings(app);
    let has_output = settings.paste_method != PasteMethod::None
        || settings.clipboard_handling == ClipboardHandling::CopyToClipboard;
    state.record(
        text,
        target,
        success && has_output,
        settings.append_trailing_space,
    );
}

/// Open the hidden-until-invoked editor after checking the original focus.
pub fn open(app: &AppHandle) -> Result<(), String> {
    let app = app.clone();
    let dispatcher = app.clone();
    dispatcher
        .run_on_main_thread(move || {
            let result = (|| -> Result<(), String> {
                let mut state = STATE.lock().map_err(|_| "state_failed")?;
                // A repeated shortcut while editing must preserve the original eligibility.
                let window = app.get_webview_window("correction");
                let editor_focused = window
                    .as_ref()
                    .is_some_and(|w| w.is_focused().unwrap_or(false));
                state.eligible = guards::opening_eligible(
                    editor_focused,
                    state.eligible,
                    state.target.as_ref().is_some_and(Target::matches_focus),
                );
                drop(state);
                let window = match window {
                    Some(window) => window,
                    None => {
                        let window = WebviewWindowBuilder::new(
                            &app,
                            "correction",
                            WebviewUrl::App("src/correction/index.html".into()),
                        )
                        .title("言语 · Yanyu")
                        .inner_size(560.0, 400.0)
                        .min_inner_size(440.0, 320.0)
                        .visible(false)
                        .build()
                        .map_err(|_| "window_failed")?;
                        // Hide instead of destroying so cancellation and reopening preserve drafts.
                        let close_window = window.clone();
                        window.on_window_event(move |event| {
                            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                                api.prevent_close();
                                let _ = close_window.hide();
                            }
                        });
                        window
                    }
                };
                window.show().map_err(|_| "window_failed")?;
                window.set_focus().map_err(|_| "window_failed")?;
                let _ = window.emit("correction-open", ());
                Ok(())
            })();
            if let Err(error) = result {
                log::warn!("Correction panel: {error}");
            }
        })
        .map_err(|_| "window_failed".into())
}

/// Read the current correction draft. A lazy window can fetch this after mount.
#[tauri::command]
#[specta::specta]
pub fn get_correction_session() -> Result<Option<CorrectionSession>, String> {
    Ok(STATE.lock().map_err(|_| "state_failed")?.session.clone())
}

/// Preserve edits and an explicitly selected term without persisting app text.
#[tauri::command]
#[specta::specta]
pub fn save_correction_draft(
    generation: u32,
    draft: String,
    word: Option<String>,
) -> Result<(), String> {
    STATE
        .lock()
        .map_err(|_| "state_failed")?
        .save(generation, draft, word)
}

/// Hide the editor without discarding the draft.
#[tauri::command]
#[specta::specta]
pub async fn close_correction(app: AppHandle) -> Result<(), String> {
    on_main(&app, |app| {
        app.get_webview_window("correction")
            .ok_or("window_failed")?
            .hide()
            .map_err(|_| "window_failed".into())
    })
    .await
}

async fn on_main<T: Send + 'static>(
    app: &AppHandle,
    action: impl FnOnce(AppHandle) -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let handle = app.clone();
    app.run_on_main_thread(move || {
        let _ = sender.send(action(handle));
    })
    .map_err(|_| "window_failed")?;
    receiver.await.map_err(|_| "window_failed")?
}

/// Apply only to a verified saved range, otherwise copy with an explicit outcome.
#[tauri::command]
#[specta::specta]
pub async fn apply_correction(
    app: AppHandle,
    generation: u32,
    draft: String,
    word: Option<String>,
) -> Result<String, String> {
    save_correction_draft(generation, draft.clone(), word.clone())?;
    on_main(&app, move |app| {
        let mut state = STATE.lock().map_err(|_| "state_failed")?;
        if state.generation != generation {
            return Err("stale_session".into());
        }
        if draft.trim().is_empty() {
            return Err("empty_text".into());
        }
        let mut settings = get_settings(&app);
        let learned = word
            .as_deref()
            .map(|word| guards::validate_word(word, &draft, &settings.custom_words))
            .transpose()?;
        let text = if state.trailing_space {
            format!("{draft} ")
        } else {
            draft.clone()
        };
        let result = if state.eligible {
            state
                .target
                .as_ref()
                .and_then(|target| target.replace(&text))
        } else {
            None
        };
        // A range is consumed even after uncertain mutation. Never retry destructive output.
        state.eligible = false;
        state.target = None;
        let outcome = match result {
            Some(true) => "replaced",
            other => {
                app.clipboard()
                    .write_text(&draft)
                    .map_err(|_| "copy_failed")?;
                if other == Some(false) {
                    "uncertain_copied"
                } else {
                    "copied"
                }
            }
        };
        if let Some(word) = learned {
            settings.custom_words.push(word);
            write_settings(&app, settings);
            app.store(crate::portable::store_path(
                crate::settings::SETTINGS_STORE_PATH,
            ))
            .map_err(|_| "learning_failed")?
            .save()
            .map_err(|_| "learning_failed")?;
            if let Some(session) = &mut state.session {
                session.word = None;
            }
        }
        Ok(outcome.into())
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn final_delivered_text_survives_output_failure_without_replacement_eligibility() {
        let mut state = State::default();
        state.record("polished final text".into(), None, true, true);
        assert_eq!(state.session.as_ref().unwrap().draft, "polished final text");
        let generation = state.generation;
        state.eligible = true;
        state.record("failed output".into(), None, false, false);
        assert_eq!(state.session.as_ref().unwrap().draft, "polished final text");
        assert_eq!(state.generation, generation);
        assert!(!state.eligible);
        state.record("new delivery".into(), None, true, false);
        assert_ne!(state.generation, generation);
        assert_eq!(state.session.as_ref().unwrap().draft, "new delivery");
    }

    #[test]
    fn draft_is_preserved_and_stale_updates_cannot_overwrite_it() {
        let mut state = State {
            generation: 2,
            session: Some(CorrectionSession {
                generation: 2,
                draft: "polished output".into(),
                word: None,
            }),
            ..State::default()
        };
        state
            .save(2, "corrected word".into(), Some("word".into()))
            .unwrap();
        assert_eq!(state.session.as_ref().unwrap().draft, "corrected word");
        assert!(state.save(1, "stale".into(), None).is_err());
        assert_eq!(state.session.as_ref().unwrap().draft, "corrected word");
        assert_eq!(
            state.session.as_ref().unwrap().word.as_deref(),
            Some("word")
        );
    }

    #[test]
    fn oversized_draft_is_rejected_without_discarding_edits() {
        let mut state = State {
            session: Some(CorrectionSession {
                generation: 0,
                draft: "keep".into(),
                word: None,
            }),
            ..State::default()
        };
        assert!(state.save(0, "😀".repeat(16385), None).is_err());
        assert_eq!(state.session.as_ref().unwrap().draft, "keep");
    }
}

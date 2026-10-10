//! On-demand correction. Transcript and target snapshots remain in memory only.
mod guards;
#[cfg(target_os = "macos")]
mod macos;
use crate::settings::{get_settings, ClipboardHandling, PasteMethod};
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
    /// The draft last delivered for this generation and its outcome.
    delivered: Option<(String, &'static str)>,
    /// A native write may have changed the target, so later copies must not ask for a blind paste.
    uncertain: bool,
}
impl State {
    fn record(
        &mut self,
        text: String,
        target: Option<Target>,
        success: bool,
        trailing_space: bool,
        editor_focused: bool,
    ) {
        if editor_focused {
            return;
        }
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
        self.delivered = None;
        self.uncertain = false;
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
impl State {
    /// Deliver a draft, then attempt optional learning. A replaced draft is never delivered again.
    fn apply(
        &mut self,
        draft: &str,
        word: Option<&str>,
        existing: &[String],
        replace: impl FnOnce(&str) -> Option<bool>,
        copy: impl FnOnce(&str) -> bool,
        learn: impl FnOnce(String) -> bool,
    ) -> Result<String, String> {
        let outcome = match &self.delivered {
            // A replacement is final. Copies are repeated so the clipboard holds the draft again.
            Some((delivered, "replaced")) if delivered == draft => "replaced",
            _ => {
                let text = if self.trailing_space {
                    format!("{draft} ")
                } else {
                    draft.to_string()
                };
                // A range is consumed even after uncertain mutation. Never retry destructive output.
                let result = if std::mem::take(&mut self.eligible) {
                    replace(&text)
                } else {
                    None
                };
                self.target = None;
                self.uncertain |= result == Some(false);
                let outcome = match (result, self.uncertain) {
                    (Some(true), _) => "replaced",
                    (_, uncertain) if !copy(draft) => {
                        return Err(if uncertain {
                            "uncertain_copy_failed"
                        } else {
                            "copy_failed"
                        }
                        .into());
                    }
                    (_, true) => "uncertain_copied",
                    _ => "copied",
                };
                self.delivered = Some((draft.to_string(), outcome));
                outcome
            }
        };
        let learning = match word.map(|word| guards::validate_word(word, draft, existing)) {
            None | Some(Ok(None)) => None,
            Some(Ok(Some(word))) => (!learn(word)).then_some("learning_failed"),
            Some(Err(_)) => Some("invalid_word"),
        };
        if let Some(error) = learning {
            return Ok(format!("{outcome}_{error}"));
        }
        if let Some(session) = &mut self.session {
            session.word = None;
        }
        Ok(outcome.into())
    }
}
fn learn_word(
    settings: &mut crate::settings::AppSettings,
    word: String,
    save: impl FnOnce(&crate::settings::AppSettings) -> Result<(), String>,
    notify: impl FnOnce(),
) -> bool {
    settings.custom_words.push(word);
    if save(settings).is_err() {
        settings.custom_words.pop();
        return false;
    }
    notify();
    true
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
        app.get_webview_window("correction")
            .is_some_and(|window| window.is_focused().unwrap_or(false)),
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
        let existing = settings.custom_words.clone();
        let target = state.target.take();
        let clipboard = app.clipboard();
        state.apply(
            &draft,
            word.as_deref(),
            &existing,
            |text| target.as_ref().and_then(|target| target.replace(text)),
            |text| clipboard.write_text(text).is_ok(),
            |word| {
                learn_word(
                    &mut settings,
                    word,
                    |settings| {
                        let store = app
                            .store(crate::portable::store_path(
                                crate::settings::SETTINGS_STORE_PATH,
                            ))
                            .map_err(|_| "learning_failed")?;
                        let previous = store.get("settings");
                        store.set(
                            "settings",
                            serde_json::to_value(settings).map_err(|_| "learning_failed")?,
                        );
                        let saved = store.save().map_err(|_| "learning_failed".into());
                        if saved.is_err() {
                            // Roll back the cached store as well, so the selected word remains retryable.
                            if let Some(previous) = previous {
                                store.set("settings", previous);
                            }
                        }
                        saved
                    },
                    || {
                        if let Err(error) = app.emit(
                            "settings-changed",
                            serde_json::json!({ "setting": "custom_words" }),
                        ) {
                            log::warn!("Could not notify settings windows after learning: {error}");
                        }
                    },
                )
            },
        )
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dictation_into_editor_preserves_the_original_session_and_draft() {
        let mut state = State::default();
        state.record("original".into(), None, true, false, false);
        let generation = state.generation;
        state
            .save(generation, "my draft".into(), Some("draft".into()))
            .unwrap();
        state.eligible = true;
        state.record("spoken correction".into(), None, true, false, true);
        assert_eq!(state.generation, generation);
        assert_eq!(state.session.as_ref().unwrap().draft, "my draft");
        assert_eq!(
            state.session.as_ref().unwrap().word.as_deref(),
            Some("draft")
        );
        assert!(state.eligible);
    }

    #[test]
    fn learning_notifies_other_windows_only_after_persistence() {
        let mut settings = crate::settings::get_default_settings();
        settings.custom_words = vec!["existing".into()];
        let saved = std::cell::Cell::new(false);
        let notified = std::cell::Cell::new(false);
        assert!(learn_word(
            &mut settings,
            "learned".into(),
            |settings| {
                assert_eq!(settings.custom_words, ["existing", "learned"]);
                saved.set(true);
                Ok(())
            },
            || {
                assert!(saved.get());
                notified.set(true);
            }
        ));
        assert!(notified.get());
        assert_eq!(settings.custom_words, ["existing", "learned"]);
    }

    #[test]
    fn failed_learning_rolls_back_and_can_be_retried() {
        let mut settings = crate::settings::get_default_settings();
        settings.custom_words = vec!["existing".into()];
        let attempted = std::cell::Cell::new(false);
        assert!(!learn_word(
            &mut settings,
            "learned".into(),
            |_| {
                attempted.set(true);
                Err("disk full".into())
            },
            || panic!("failed persistence must not notify")
        ));
        assert!(attempted.get());
        assert_eq!(settings.custom_words, ["existing"]);
        assert_eq!(
            guards::validate_word("learned", "learned", &settings.custom_words),
            Ok(Some("learned".into()))
        );
        assert!(learn_word(
            &mut settings,
            "learned".into(),
            |_| Ok(()),
            || {}
        ));
        assert_eq!(settings.custom_words, ["existing", "learned"]);
    }

    #[test]
    fn final_delivered_text_survives_output_failure_without_replacement_eligibility() {
        let mut state = State::default();
        state.record("polished final text".into(), None, true, true, false);
        assert_eq!(state.session.as_ref().unwrap().draft, "polished final text");
        let generation = state.generation;
        state.eligible = true;
        state.record("failed output".into(), None, false, false, false);
        assert_eq!(state.session.as_ref().unwrap().draft, "polished final text");
        assert_eq!(state.generation, generation);
        assert!(!state.eligible);
        state.record("new delivery".into(), None, true, false, false);
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

    /// Counts native replacement attempts and clipboard writes across retries.
    #[derive(Default)]
    struct Calls {
        replace: std::cell::Cell<u32>,
        copy: std::cell::Cell<u32>,
    }
    impl Calls {
        fn apply(
            &self,
            state: &mut State,
            draft: &str,
            word: Option<&str>,
            replaced: Option<bool>,
            copied: bool,
            learned: bool,
        ) -> Result<String, String> {
            state.apply(
                draft,
                word,
                &["Known".into()],
                |_| {
                    self.replace.set(self.replace.get() + 1);
                    replaced
                },
                |_| {
                    self.copy.set(self.copy.get() + 1);
                    copied
                },
                |_| learned,
            )
        }
        fn counts(&self) -> (u32, u32) {
            (self.replace.get(), self.copy.get())
        }
    }

    fn delivered_state() -> State {
        let mut state = State::default();
        state.record("Hello old".into(), None, true, false, false);
        state.eligible = true;
        state
    }

    #[test]
    fn learning_retry_keeps_the_original_outcome_without_replacing_again() {
        // Only a replacement is final. Copied outcomes write the clipboard again on every Apply.
        for (replaced, outcome, copies) in [
            (Some(true), "replaced", 0),
            (None, "copied", 3),
            (Some(false), "uncertain_copied", 3),
        ] {
            let calls = Calls::default();
            let mut state = delivered_state();
            let first = calls.apply(
                &mut state,
                "Hello Yanyu",
                Some("Yanyu"),
                replaced,
                true,
                false,
            );
            assert_eq!(first, Ok(format!("{outcome}_learning_failed")));
            for learned in [false, true] {
                let retry = calls.apply(
                    &mut state,
                    "Hello Yanyu",
                    Some("Yanyu"),
                    Some(true),
                    true,
                    learned,
                );
                let expected = if learned {
                    outcome.to_string()
                } else {
                    format!("{outcome}_learning_failed")
                };
                assert_eq!(retry, Ok(expected));
            }
            assert_eq!(calls.counts(), (1, copies), "{outcome}");
        }
    }

    #[test]
    fn changed_draft_copies_conservatively_and_new_dictation_resets_delivery() {
        let calls = Calls::default();
        let mut state = delivered_state();
        assert_eq!(
            calls.apply(&mut state, "Hello Yanyu", None, Some(true), true, true),
            Ok("replaced".into())
        );
        assert_eq!(
            calls.apply(&mut state, "Hello again", None, Some(true), true, true),
            Ok("copied".into())
        );
        assert_eq!(calls.counts(), (1, 1));
        state.record("Hello Yanyu".into(), None, true, false, true);
        assert_eq!(
            calls.apply(&mut state, "Hello again", None, Some(true), true, true),
            Ok("copied".into()),
            "dictation into the editor is not a new external delivery"
        );
        assert_eq!(
            calls.counts(),
            (1, 2),
            "the copy repeats, the replacement does not"
        );
        state.record("Hello Yanyu".into(), None, true, false, false);
        state.eligible = true;
        assert_eq!(
            calls.apply(&mut state, "Hello Yanyu", None, Some(true), true, true),
            Ok("replaced".into())
        );
        assert_eq!(calls.counts(), (2, 2));
    }

    #[test]
    fn optional_learning_problems_do_not_block_delivery() {
        let calls = Calls::default();
        let mut state = delivered_state();
        state
            .save(state.generation, "Hello known".into(), Some("known".into()))
            .unwrap();
        assert_eq!(
            calls.apply(
                &mut state,
                "Hello known",
                Some("known"),
                Some(true),
                true,
                false
            ),
            Ok("replaced".into()),
            "an already remembered term is a no-op"
        );
        assert_eq!(state.session.as_ref().unwrap().word, None);

        let calls = Calls::default();
        let mut state = delivered_state();
        assert_eq!(
            calls.apply(
                &mut state,
                "Hello Yanyu",
                Some("absent"),
                Some(true),
                true,
                true
            ),
            Ok("replaced_invalid_word".into())
        );
        assert_eq!(
            calls.apply(&mut state, "Hello Yanyu", None, Some(true), true, true),
            Ok("replaced".into()),
            "clearing the invalid word applies without a second delivery"
        );
        assert_eq!(calls.counts(), (1, 0));
    }

    #[test]
    fn uncertain_write_with_clipboard_failure_stays_explicit_on_retry() {
        let calls = Calls::default();
        let mut state = delivered_state();
        assert_eq!(
            calls.apply(&mut state, "Hello Yanyu", None, Some(false), false, true),
            Err("uncertain_copy_failed".into())
        );
        assert_eq!(
            calls.apply(&mut state, "Hello Yanyu", None, Some(true), false, true),
            Err("uncertain_copy_failed".into())
        );
        assert_eq!(
            calls.apply(&mut state, "Hello Yanyu", None, Some(true), true, true),
            Ok("uncertain_copied".into())
        );
        assert_eq!(
            calls.apply(&mut state, "Changed", None, Some(true), true, true),
            Ok("uncertain_copied".into())
        );
        assert_eq!(calls.counts(), (1, 4));
        assert_eq!(
            calls.apply(&mut state, "Changed", None, Some(true), false, true),
            Err("uncertain_copy_failed".into()),
            "a repeated copy failure is reported, not hidden by the earlier success"
        );
        assert_eq!(
            calls.apply(&mut state, "Changed", None, Some(true), true, true),
            Ok("uncertain_copied".into())
        );
        assert_eq!(calls.counts(), (1, 6));

        let calls = Calls::default();
        let mut state = delivered_state();
        assert_eq!(
            calls.apply(&mut state, "Hello Yanyu", None, None, false, true),
            Err("copy_failed".into())
        );
    }

    #[test]
    fn repeated_apply_recopies_a_copied_draft_but_never_rewrites_a_replacement() {
        let clipboard = std::cell::RefCell::new(String::new());
        let replaces = std::cell::Cell::new(0);
        let apply = |state: &mut State, replaced: Option<bool>, copied: bool| {
            state.apply(
                "Hello Yanyu",
                None,
                &[],
                |_| {
                    replaces.set(replaces.get() + 1);
                    replaced
                },
                |text| {
                    if copied {
                        *clipboard.borrow_mut() = text.to_string();
                    }
                    copied
                },
                |_| true,
            )
        };

        let mut state = delivered_state();
        assert_eq!(apply(&mut state, None, true), Ok("copied".into()));
        *clipboard.borrow_mut() = "something else".into();
        assert_eq!(apply(&mut state, Some(true), true), Ok("copied".into()));
        assert_eq!(
            *clipboard.borrow(),
            "Hello Yanyu",
            "the clipboard holds the draft again"
        );
        assert_eq!(
            apply(&mut state, Some(true), false),
            Err("copy_failed".into())
        );
        assert_eq!(apply(&mut state, Some(true), true), Ok("copied".into()));
        assert_eq!(
            replaces.get(),
            1,
            "a consumed target is never replaced again"
        );

        let mut state = delivered_state();
        assert_eq!(apply(&mut state, Some(true), true), Ok("replaced".into()));
        *clipboard.borrow_mut() = "something else".into();
        assert_eq!(apply(&mut state, Some(true), true), Ok("replaced".into()));
        assert_eq!(apply(&mut state, Some(true), false), Ok("replaced".into()));
        assert_eq!(replaces.get(), 2);
        assert_eq!(
            *clipboard.borrow(),
            "something else",
            "no clipboard write after a replacement"
        );
    }
}

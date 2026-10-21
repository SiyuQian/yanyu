use crate::managers::translation::{TranslationManager, TranslationState};
use tauri::{AppHandle, Emitter, Manager, State, WebviewWindow};
use tauri_plugin_clipboard_manager::ClipboardExt;

/// Return transient translation state; nothing is stored on disk.
#[tauri::command]
#[specta::specta]
pub fn get_translation_state(manager: State<'_, TranslationManager>) -> TranslationState {
    manager.state()
}

/// Copy only the current completed translation, after the popover's explicit Copy action.
#[tauri::command]
#[specta::specta]
pub fn copy_translation(
    app: AppHandle,
    window: WebviewWindow,
    manager: State<'_, TranslationManager>,
    revision: u32,
) -> Result<(), String> {
    if window.label() != "translation_overlay" {
        return Err("unavailable".into());
    }
    let state = manager.state();
    if state.phase != "result" || state.revision != revision {
        return Err("unavailable".into());
    }
    app.clipboard()
        .write_text(state.text.ok_or("unavailable")?)
        .map_err(|_| "copy_failed".into())
}
/// Dismiss the popover and cancel work without clipboard access.
#[tauri::command]
#[specta::specta]
pub fn dismiss_translation(app: AppHandle, manager: State<'_, TranslationManager>) {
    manager.dismiss(&app);
}

/// Open shared model resources in General settings; never start a download.
#[tauri::command]
#[specta::specta]
pub fn open_translation_model_settings(
    app: AppHandle,
    manager: State<'_, TranslationManager>,
) -> Result<(), String> {
    manager.dismiss(&app);
    crate::show_main_window(&app);
    if let Some(window) = app.get_webview_window("main") {
        window
            .emit("translation-model-settings", ())
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

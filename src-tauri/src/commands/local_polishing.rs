use crate::{
    managers::local_polishing::{LocalPolishingManager, LocalPolishingStatus},
    settings::{get_settings, write_settings},
};
use std::sync::Arc;
use tauri::{AppHandle, State};

/// Returns the current local-polishing download and model status.
#[tauri::command]
#[specta::specta]
pub fn get_local_polishing_status(
    manager: State<'_, Arc<LocalPolishingManager>>,
) -> LocalPolishingStatus {
    manager.status()
}
/// Persists the local-polishing setting and schedules model loading or resource release.
#[tauri::command]
#[specta::specta]
pub fn set_local_polishing_enabled(
    app: AppHandle,
    manager: State<'_, Arc<LocalPolishingManager>>,
    enabled: bool,
) -> Result<(), String> {
    if enabled && !manager.status().supported {
        return Err("Local polishing requires an Apple Silicon Mac".into());
    }
    let mut settings = get_settings(&app);
    settings.local_polishing_enabled = enabled;
    write_settings(&app, settings);
    manager.set_enabled(enabled);
    Ok(())
}
/// Starts an explicit asynchronous download of the pinned polishing model and tokenizer.
#[tauri::command]
#[specta::specta]
pub fn download_local_polishing_model(
    manager: State<'_, Arc<LocalPolishingManager>>,
) -> Result<(), String> {
    manager.download()
}
/// Signals cancellation of the current local-polishing download.
#[tauri::command]
#[specta::specta]
pub fn cancel_local_polishing_download(manager: State<'_, Arc<LocalPolishingManager>>) {
    manager.cancel_download();
}
/// Persists disabled local polishing and deletes its installed model artifacts.
#[tauri::command]
#[specta::specta]
pub fn delete_local_polishing_model(
    app: AppHandle,
    manager: State<'_, Arc<LocalPolishingManager>>,
) -> Result<(), String> {
    let mut settings = get_settings(&app);
    settings.local_polishing_enabled = false;
    write_settings(&app, settings);
    manager.delete()
}

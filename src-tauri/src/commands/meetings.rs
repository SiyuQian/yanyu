//! Typed local-only meeting commands. Expensive operations run on blocking workers.
use crate::{
    managers::model::ModelManager,
    meetings::{Meeting, MeetingManager, MeetingMode},
};
use std::{path::PathBuf, sync::Arc};
use tauri::{Manager, State};
use tauri_plugin_dialog::DialogExt;
#[derive(serde::Serialize, specta::Type)]
pub struct MeetingSetup {
    pub available: bool,
    pub moss_installed: bool,
    pub qwen_installed: bool,
}
#[derive(serde::Deserialize, specta::Type)]
#[serde(rename_all = "snake_case")]
pub enum MeetingControl {
    Pause,
    Resume,
    Stop,
    Cancel,
}
async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> anyhow::Result<T> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())
}
fn moss(models: &ModelManager) -> Option<PathBuf> {
    models
        .get_available_models()
        .into_iter()
        .find(|m| m.is_downloaded && m.filename.starts_with("MOSS-Transcribe-Diarize-"))
        .and_then(|m| models.get_model_path(&m.id).ok())
}
#[tauri::command]
#[specta::specta]
pub fn meeting_setup(
    manager: State<'_, Arc<MeetingManager>>,
    models: State<'_, Arc<ModelManager>>,
) -> MeetingSetup {
    MeetingSetup {
        available: crate::meetings::available(),
        moss_installed: moss(&models).is_some_and(|p| p.is_file()),
        qwen_installed: manager.summary_directory.join("model.gguf").is_file()
            && manager.summary_directory.join("tokenizer.json").is_file(),
    }
}
#[tauri::command]
#[specta::specta]
pub async fn meeting_list(manager: State<'_, Arc<MeetingManager>>) -> Result<Vec<Meeting>, String> {
    let manager = manager.inner().clone();
    blocking(move || manager.list()).await
}
#[tauri::command]
#[specta::specta]
pub async fn meeting_start(
    manager: State<'_, Arc<MeetingManager>>,
    mode: MeetingMode,
) -> Result<Meeting, String> {
    let manager = manager.inner().clone();
    blocking(move || manager.start(mode)).await
}
#[tauri::command]
#[specta::specta]
pub async fn meeting_control(
    manager: State<'_, Arc<MeetingManager>>,
    id: String,
    action: MeetingControl,
) -> Result<(), String> {
    let manager = manager.inner().clone();
    blocking(move || match action {
        MeetingControl::Pause => manager.pause(&id, true),
        MeetingControl::Resume => manager.pause(&id, false),
        MeetingControl::Stop => manager.stop(&id).map(|_| ()),
        MeetingControl::Cancel => manager.cancel(&id),
    })
    .await
}
#[tauri::command]
#[specta::specta]
pub async fn meeting_process(
    manager: State<'_, Arc<MeetingManager>>,
    models: State<'_, Arc<ModelManager>>,
    id: String,
    summary_only: bool,
    labels: [String; 3],
) -> Result<(), String> {
    let model = moss(&models);
    let manager = manager.inner().clone();
    blocking(move || manager.process(id, model, summary_only, labels)).await
}
#[tauri::command]
#[specta::specta]
pub async fn meeting_edit(
    manager: State<'_, Arc<MeetingManager>>,
    meeting: Meeting,
) -> Result<Meeting, String> {
    let manager = manager.inner().clone();
    blocking(move || {
        manager
            .store
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .edit(meeting)
    })
    .await
}
#[tauri::command]
#[specta::specta]
pub async fn meeting_delete(
    manager: State<'_, Arc<MeetingManager>>,
    id: String,
) -> Result<(), String> {
    let manager = manager.inner().clone();
    blocking(move || {
        manager
            .store
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .delete(&id)
    })
    .await
}
#[tauri::command]
#[specta::specta]
pub async fn meeting_audio(
    manager: State<'_, Arc<MeetingManager>>,
    id: String,
) -> Result<String, String> {
    let manager = manager.inner().clone();
    blocking(move || {
        let store = manager.store.lock().unwrap_or_else(|e| e.into_inner());
        let _ = store.get(&id)?;
        let path = store.directory(&id)?.join("playback.wav");
        anyhow::ensure!(
            path.is_file() && !path.is_symlink(),
            "recording_unavailable"
        );
        Ok(path.to_string_lossy().into_owned())
    })
    .await
}
#[tauri::command]
#[specta::specta]
pub async fn meeting_export(app: tauri::AppHandle, id: String) -> Result<bool, String> {
    blocking(move || {
        let manager = app.state::<Arc<MeetingManager>>();
        let text = manager
            .store
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .markdown(&id)?;
        let Some(destination) = app
            .dialog()
            .file()
            .add_filter("Markdown", &["md"])
            .set_file_name("meeting.md")
            .blocking_save_file()
        else {
            return Ok(false);
        };
        let path = destination
            .into_path()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        std::fs::write(path, text)?;
        Ok(true)
    })
    .await
}

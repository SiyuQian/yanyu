//! Typed local-only meeting commands. Expensive operations run on blocking workers.
use crate::{
    managers::model::ModelManager,
    meetings::{Meeting, MeetingManager, MeetingMode, MeetingPage},
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
/// Report platform availability and explicitly installed prerequisites without downloading models.
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
/// Return up to 50 lightweight history rows at `offset`, newest first, plus active records.
/// Full transcripts and notes are available through `meeting_get`; failures preserve local files.
#[tauri::command]
#[specta::specta]
pub async fn meeting_list(
    manager: State<'_, Arc<MeetingManager>>,
    offset: u32,
) -> Result<MeetingPage, String> {
    let manager = manager.inner().clone();
    blocking(move || manager.list(offset)).await
}
/// Read one complete local record by its validated opaque ID. Missing or invalid IDs return an error.
#[tauri::command]
#[specta::specta]
pub async fn meeting_get(
    manager: State<'_, Arc<MeetingManager>>,
    id: String,
) -> Result<Meeting, String> {
    let manager = manager.inner().clone();
    blocking(move || manager.get(&id)).await
}
/// Start microphone capture, plus computer audio in online mode.
/// Requires Apple Silicon macOS 13+, permissions, and no active recording.
/// Success returns the persisted recording; startup failures retain a failed local record.
#[tauri::command]
#[specta::specta]
pub async fn meeting_start(
    manager: State<'_, Arc<MeetingManager>>,
    mode: MeetingMode,
) -> Result<Meeting, String> {
    let manager = manager.inner().clone();
    blocking(move || manager.start(mode)).await
}
/// Pause, resume, or stop the matching active recording, or cancel its processing job.
/// Stop waits for native finalization; capture failures retain recoverable audio and return an error.
/// Cancellation requests interruption and retains completed checkpoints; it does not await the job.
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
/// Start a local background processing job for an idle record; success means queued, not completed.
/// `summary_only` requires a completed transcript and only Qwen; otherwise installed MOSS is also required.
/// `labels` are the discussion, decisions, and action-item headings in that order.
/// Poll the record for progress or failure; recordings and completed transcript checkpoints are retained.
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
/// Save editable title, transcript text, speaker display names, and notes for an idle record.
/// Validates IDs and size limits, preserves capture data, and marks notes stale after transcript changes.
/// Returns the committed record; `durability_warning` reports a post-commit directory-sync failure separately.
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
/// Permanently remove an idle local record and its owned audio files. Busy or invalid records are rejected.
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
/// Return the owned playback WAV path for a valid record. Missing or symlinked audio returns an error.
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
/// Ask for a Markdown destination and export the retained notes, transcript, citations, and quality warnings.
/// Returns false when the save dialog is cancelled; file or record failures return an error.
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

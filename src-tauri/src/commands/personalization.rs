//! Acknowledged local profile operations and an isolated, ephemeral recording trial.
use crate::audio_toolkit::VadPolicy;
use crate::managers::{
    audio::AudioRecordingManager, model::ModelManager, transcription::TranscriptionManager,
};
use crate::personalization::{
    generated_enabled, service_ready, PersonalizationProfile, ProcessingMode,
};
use crate::settings::{get_settings, SETTINGS_STORE_PATH};
use crate::TranscriptionCoordinator;
use serde::Serialize;
use specta::Type;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::time::Duration;
use tauri::{AppHandle, Manager};
use tauri_plugin_store::StoreExt;

const TRIAL_BINDING: &str = "personalization_preview";
const MAX_SECONDS: u64 = 60;

#[derive(Serialize, Type)]
/// Configured prerequisites, without claiming a successful live service test.
pub struct PersonalizationStatus {
    pub service_ready: bool,
    pub asr_ready: bool,
    pub active: bool,
}

#[derive(Serialize, Type)]
/// Ephemeral recognition and processing results for a preview comparison.
pub struct TrialResult {
    pub original: String,
    pub processed: String,
    pub processing_succeeded: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Starting,
    Arming,
    Capturing,
    Processing,
}
struct TrialSession {
    id: String,
    cancelled: Arc<AtomicBool>,
    phase: Phase,
}
impl TrialSession {
    fn cancel(&self, capture_only: bool) -> bool {
        if capture_only && self.phase == Phase::Processing {
            return false;
        }
        self.cancelled.store(true, Ordering::Release);
        true
    }
}

/// Owns the trial from preparation until capture and processing finish.
#[derive(Default)]
pub struct TrialState(Mutex<Option<TrialSession>>);

fn persist(
    app: &AppHandle,
    change: impl FnOnce(&mut crate::settings::AppSettings),
) -> Result<(), String> {
    let store = app
        .store(crate::portable::store_path(SETTINGS_STORE_PATH))
        .map_err(|e| e.to_string())?;
    let mut settings = get_settings(app);
    change(&mut settings);
    let value = serde_json::to_value(&settings).map_err(|e| e.to_string())?;
    let previous = store.get("settings");
    store.set("settings", value);
    if let Err(error) = store.save() {
        if let Some(previous) = previous {
            store.set("settings", previous);
        }
        return Err(error.to_string());
    }
    Ok(())
}

#[tauri::command]
#[specta::specta]
/// Persist the whole validated profile and explicitly select generated mode when enabled.
pub fn save_personalization(
    app: AppHandle,
    mut profile: PersonalizationProfile,
) -> Result<(), String> {
    profile.validate()?;
    profile.invitation_dismissed = true;
    persist(&app, |s| {
        if profile.enabled {
            s.processing_mode = ProcessingMode::Generated;
        }
        s.personalization = profile;
    })
}

#[tauri::command]
#[specta::specta]
/// Persist dismissal so the optional invitation does not repeat.
pub fn dismiss_personalization_invitation(app: AppHandle) -> Result<(), String> {
    persist(&app, |s| s.personalization.invitation_dismissed = true)
}

#[tauri::command]
#[specta::specta]
/// Remove local profile context without restoring arbitrary custom instructions.
pub fn delete_personalization(app: AppHandle) -> Result<(), String> {
    persist(&app, |s| {
        s.personalization = PersonalizationProfile {
            invitation_dismissed: true,
            ..Default::default()
        }
    })
}

#[tauri::command]
#[specta::specta]
/// Explicitly select generated or legacy processing while retaining saved prompts.
pub fn set_processing_mode(app: AppHandle, mode: ProcessingMode) -> Result<(), String> {
    persist(&app, |s| s.processing_mode = mode)
}

#[tauri::command]
#[specta::specta]
/// Report selected service configuration and installed ASR prerequisites.
pub fn get_personalization_status(app: AppHandle) -> PersonalizationStatus {
    let settings = get_settings(&app);
    let ready = service_ready(&settings, super::check_apple_intelligence_available());
    PersonalizationStatus {
        service_ready: ready,
        asr_ready: app
            .state::<Arc<ModelManager>>()
            .get_model_path(&settings.selected_model)
            .is_ok(),
        active: generated_enabled(&settings) && ready,
    }
}

fn finish(app: &AppHandle, id: &str) {
    if let Ok(mut session) = app.state::<TrialState>().0.lock() {
        if session.as_ref().is_some_and(|s| s.id == id) {
            app.state::<Arc<AudioRecordingManager>>().cancel_recording();
            *session = None;
            app.state::<TranscriptionCoordinator>().release_preview();
        }
    }
}
struct TrialGuard(AppHandle, String, bool);
impl Drop for TrialGuard {
    fn drop(&mut self) {
        if !self.2 {
            return;
        }
        self.0
            .state::<Arc<TranscriptionManager>>()
            .maybe_unload_immediately("personalization preview");
        finish(&self.0, &self.1);
    }
}

#[tauri::command]
#[specta::specta]
/// Reserve the idle dictation pipeline and start a bounded preview recording.
pub async fn start_personalization_trial(app: AppHandle, id: String) -> Result<(), String> {
    if id.is_empty() || id.len() > 80 {
        return Err("Invalid trial identifier".into());
    }
    let status = get_personalization_status(app.clone());
    if !status.active || !status.asr_ready {
        return Err("Finish model and service setup before the trial".into());
    }
    let cancelled = Arc::new(AtomicBool::new(false));
    {
        let state = app.state::<TrialState>();
        let mut session = state.0.lock().map_err(|e| e.to_string())?;
        if session.is_some() {
            return Err("A recording trial is already running".into());
        }
        *session = Some(TrialSession {
            id: id.clone(),
            cancelled: cancelled.clone(),
            phase: Phase::Starting,
        });
    }
    let worker_app = app.clone();
    let worker_id = id.clone();
    let worker = tauri::async_runtime::spawn_blocking(move || {
        let coordinator = worker_app.state::<TranscriptionCoordinator>();
        if let Err(error) = coordinator.reserve_preview() {
            // This session did not own the coordinator reservation.
            if let Ok(mut session) = worker_app.state::<TrialState>().0.lock() {
                *session = None;
            }
            return Err(error);
        }
        let mut guard = TrialGuard(worker_app.clone(), worker_id.clone(), true);
        let tm = worker_app.state::<Arc<TranscriptionManager>>();
        let rm = worker_app.state::<Arc<AudioRecordingManager>>();
        if cancelled.load(Ordering::Acquire) {
            return Err("Trial cancelled".into());
        }
        tm.load_model(&get_settings(&worker_app).selected_model)
            .map_err(|e| e.to_string())?;
        if cancelled.load(Ordering::Acquire) {
            return Err("Trial cancelled".into());
        }
        let readiness = rm.try_start_recording(TRIAL_BINDING, VadPolicy::Disabled)?;
        {
            let state = worker_app.state::<TrialState>();
            let mut session = state.0.lock().map_err(|e| e.to_string())?;
            let current = session.as_mut().ok_or("Trial cancelled")?;
            current.phase = Phase::Arming;
            if current.cancelled.load(Ordering::Acquire) {
                rm.cancel_recording();
                return Err("Trial cancelled".into());
            }
        }
        let generation = readiness.generation();
        if !readiness.wait()
            || cancelled.load(Ordering::Acquire)
            || !rm.is_recording_readiness_current(generation)
        {
            rm.cancel_recording();
            return Err("Microphone did not become ready or trial was cancelled".into());
        }
        {
            let state = worker_app.state::<TrialState>();
            let mut session = state.0.lock().map_err(|e| e.to_string())?;
            let current = session.as_mut().ok_or("Trial cancelled")?;
            if current.cancelled.load(Ordering::Acquire) {
                rm.cancel_recording();
                return Err("Trial cancelled".into());
            }
            current.phase = Phase::Capturing;
        }
        guard.2 = false;
        Ok(())
    });
    // A backend deadline bounds capture even if the frontend disappears or a start is still waiting.
    let timeout_app = app.clone();
    let timeout_id = id.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(MAX_SECONDS)).await;
        let _ = cancel_trial(&timeout_app, &timeout_id, true);
    });
    worker.await.map_err(|e| e.to_string())?
}

#[tauri::command]
#[specta::specta]
/// Recognize and process captured samples without paste, history or audio persistence.
pub async fn stop_personalization_trial(app: AppHandle, id: String) -> Result<TrialResult, String> {
    let cancelled = {
        let state = app.state::<TrialState>();
        let mut session = state.0.lock().map_err(|e| e.to_string())?;
        let current = session
            .as_mut()
            .filter(|s| s.id == id && s.phase == Phase::Capturing)
            .ok_or("No ready trial recording")?;
        current.phase = Phase::Processing;
        current.cancelled.clone()
    };
    let _guard = TrialGuard(app.clone(), id, true);
    let worker_app = app.clone();
    let worker_cancelled = cancelled.clone();
    let original = tauri::async_runtime::spawn_blocking(move || {
        let rm = worker_app.state::<Arc<AudioRecordingManager>>();
        let generation = rm.cancel_generation();
        let samples = rm
            .stop_recording(TRIAL_BINDING, generation)
            .ok_or("Trial capture was cancelled")?;
        if samples.len() > MAX_SECONDS as usize * 16_000 + 16_000
            || worker_cancelled.load(Ordering::Acquire)
        {
            return Err("Trial cancelled or exceeded one minute".to_string());
        }
        worker_app
            .state::<Arc<TranscriptionManager>>()
            .transcribe(samples)
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())??;
    if cancelled.load(Ordering::Acquire) {
        return Err("Trial cancelled".into());
    }
    let processed = {
        let settings = get_settings(&app);
        let operation = async {
            if generated_enabled(&settings) {
                crate::actions::post_process_transcription(&settings, &original).await
            } else {
                None
            }
        };
        tokio::pin!(operation);
        loop {
            if cancelled.load(Ordering::Acquire) {
                return Err("Trial cancelled".into());
            }
            if let Ok(result) =
                tokio::time::timeout(Duration::from_millis(25), operation.as_mut()).await
            {
                break result;
            }
        }
    };
    if cancelled.load(Ordering::Acquire) {
        return Err("Trial cancelled".into());
    }
    Ok(TrialResult {
        processing_succeeded: processed.is_some(),
        processed: processed.unwrap_or_else(|| original.clone()),
        original,
    })
}

#[tauri::command]
#[specta::specta]
/// Cancel only the identified trial and retain ownership until active processing drains.
pub fn cancel_personalization_trial(app: AppHandle, id: String) -> Result<(), String> {
    cancel_trial(&app, &id, false)
}

fn cancel_trial(app: &AppHandle, id: &str, capture_only: bool) -> Result<(), String> {
    let capturing = {
        let state = app.state::<TrialState>();
        let session = state.0.lock().map_err(|e| e.to_string())?;
        let Some(current) = session.as_ref().filter(|s| s.id == id) else {
            return Ok(());
        };
        if !current.cancel(capture_only) {
            return Ok(());
        }
        if current.phase != Phase::Starting {
            app.state::<Arc<AudioRecordingManager>>().cancel_recording();
        }
        current.phase == Phase::Capturing
    };
    if capturing {
        finish(app, id);
    }
    Ok(())
}

/// Window-close cleanup also cancels a start whose command response has not reached the UI.
pub fn cancel_active_trial(app: &AppHandle) {
    let id = app.try_state::<TrialState>().and_then(|state| {
        state
            .0
            .lock()
            .ok()
            .and_then(|s| s.as_ref().map(|s| s.id.clone()))
    });
    if let Some(id) = id {
        let _ = cancel_personalization_trial(app.clone(), id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_deadline_does_not_cancel_processing_but_explicit_cancel_does() {
        let session = TrialSession {
            id: "sample".into(),
            cancelled: Arc::new(AtomicBool::new(false)),
            phase: Phase::Processing,
        };
        assert!(!session.cancel(true));
        assert!(!session.cancelled.load(Ordering::Acquire));
        assert!(session.cancel(false));
        assert!(session.cancelled.load(Ordering::Acquire));
    }

    #[test]
    fn cancellation_marks_starting_and_capturing_sessions() {
        for phase in [Phase::Starting, Phase::Arming, Phase::Capturing] {
            let session = TrialSession {
                id: "sample".into(),
                cancelled: Arc::new(AtomicBool::new(false)),
                phase,
            };
            assert!(session.cancel(true));
            assert!(session.cancelled.load(Ordering::Acquire));
        }
    }
}

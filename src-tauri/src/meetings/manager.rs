use super::{
    capture,
    diarization::{self, BankResult},
    notes, Meeting, MeetingMode, MeetingStatus, Store,
};
use crate::engine_supervisor::{
    DeviceSelector, EngineError, EngineSupervisor, LoadSpec, RunFailureKind,
};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, MutexGuard,
    },
};
use transcribe_cpp::{Backend, Diarize, RunOptions, TimestampKind};
fn lock<T>(value: &Mutex<T>) -> MutexGuard<'_, T> {
    value.lock().unwrap_or_else(|e| e.into_inner())
}
struct Active {
    id: String,
    capture: capture::Capture,
}
struct Processing {
    id: String,
    cancel: Arc<AtomicBool>,
    engine: EngineSupervisor,
}
/// Owns meeting files and native resources without touching dictation managers or settings.
pub struct MeetingManager {
    pub store: Mutex<Store>,
    active: Mutex<Option<Active>>,
    processing: Mutex<Option<Processing>>,
    pub summary_directory: PathBuf,
}
impl MeetingManager {
    pub fn new(root: PathBuf, summary_directory: PathBuf) -> anyhow::Result<Arc<Self>> {
        let store = Store::new(root)?;
        let existing_records = store.list()?;

        let manager = Arc::new(Self {
            store: Mutex::new(store),
            active: Mutex::new(None),
            processing: Mutex::new(None),
            summary_directory,
        });
        let weak = Arc::downgrade(&manager);
        std::thread::Builder::new()
            .name("meeting-capture-state".into())
            .spawn(move || {
                if let Some(manager) = weak.upgrade() {
                    if let Err(error) = lock(&manager.store).recover_records(existing_records) {
                        log::error!("Meeting startup recovery: {error}");
                    }
                }
                loop {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    let Some(manager) = weak.upgrade() else { break };
                    if let Err(error) = manager.refresh_capture() {
                        log::error!("Meeting capture checkpoint failed: {error}");
                    }
                }
            })?;
        Ok(manager)
    }
    pub fn list(&self) -> anyhow::Result<Vec<Meeting>> {
        lock(&self.store).list()
    }
    pub fn start(&self, mode: MeetingMode) -> anyhow::Result<Meeting> {
        anyhow::ensure!(capture::available(), "unsupported");
        let mut active = lock(&self.active);
        anyhow::ensure!(active.is_none(), "meeting_recording_busy");
        let mut meeting = lock(&self.store).create(mode)?;
        let path = lock(&self.store).directory(&meeting.id)?;
        match capture::Capture::start(&path, mode == MeetingMode::Online) {
            Ok(capture) => {
                *active = Some(Active {
                    id: meeting.id.clone(),
                    capture,
                });
                Ok(meeting)
            }
            Err(error) => {
                meeting.status = MeetingStatus::Failed;
                meeting.error = Some(error.to_string());
                lock(&self.store).save(&meeting)?;
                Err(error)
            }
        }
    }
    pub fn pause(&self, id: &str, paused: bool) -> anyhow::Result<()> {
        let active = lock(&self.active);
        let capture = active
            .as_ref()
            .filter(|a| a.id == id)
            .ok_or_else(|| anyhow::anyhow!("capture_not_active"))?;
        capture.capture.pause(paused)?;
        let store = lock(&self.store);
        let mut meeting = store.get(id)?;
        meeting.status = if paused {
            MeetingStatus::Paused
        } else {
            MeetingStatus::Recording
        };
        store.save(&meeting)
    }
    fn refresh_capture(&self) -> anyhow::Result<()> {
        let mut active = lock(&self.active);
        let Some(current) = active.as_ref() else {
            return Ok(());
        };
        let store = lock(&self.store);
        let mut meeting = store.get(&current.id)?;
        let path = store.directory(&current.id)?;
        let mut error = current.capture.error();
        if let Ok(snapshot) = capture::snapshot(&path) {
            meeting.status = if snapshot.paused {
                MeetingStatus::Paused
            } else {
                MeetingStatus::Recording
            };
            meeting.mic_frames = snapshot.mic_frames;
            meeting.system_frames = snapshot.system_frames;
            meeting.duration_ms = meeting.mic_frames.max(meeting.system_frames) / 16;
            error = error.or(snapshot.error);
        }
        if let Some(error) = error {
            meeting.capture_error = Some(error.clone());
            meeting.error = Some(error);
            drop(active.take());
            meeting.status = MeetingStatus::Recoverable;
            if let Err(error) = store.finalize_audio(&mut meeting) {
                meeting.error = Some(error.to_string());
            }
        }
        store.save(&meeting)
    }
    pub fn stop(&self, id: &str) -> anyhow::Result<Meeting> {
        let mut active = lock(&self.active);
        anyhow::ensure!(
            active.as_ref().is_some_and(|a| a.id == id),
            "capture_not_active"
        );
        drop(active.take());
        let store = lock(&self.store);
        let mut meeting = store.get(id)?;
        if let Err(error) = store.finalize_audio(&mut meeting) {
            meeting.status = MeetingStatus::Recoverable;
            meeting.capture_error = Some(error.to_string());
            meeting.error = Some(error.to_string());
            store.save(&meeting)?;
            return Err(error);
        }
        meeting.status = if meeting.error.is_some() {
            MeetingStatus::Recoverable
        } else {
            MeetingStatus::Recorded
        };
        store.save(&meeting)?;
        Ok(meeting)
    }
    pub fn cancel(&self, id: &str) -> anyhow::Result<()> {
        let processing = lock(&self.processing);
        let current = processing
            .as_ref()
            .filter(|p| p.id == id)
            .ok_or_else(|| anyhow::anyhow!("processing_not_active"))?;
        current.cancel.store(true, Ordering::Release);
        current.engine.cancel();
        Ok(())
    }
    pub fn shutdown(&self) {
        let current = { lock(&self.active).as_ref().map(|a| a.id.clone()) };
        if let Some(current) = current {
            if let Err(error) = self.stop(&current) {
                log::error!("Meeting shutdown: {error}");
            }
        }
        if let Some(job) = lock(&self.processing).as_ref() {
            job.cancel.store(true, Ordering::Release);
            job.engine.cancel();
        }
    }
    pub fn process(
        self: &Arc<Self>,
        id: String,
        model: Option<PathBuf>,
        summary_only: bool,
        labels: [String; 3],
    ) -> anyhow::Result<()> {
        anyhow::ensure!(capture::available(), "unsupported");
        anyhow::ensure!(
            labels.iter().all(|s| !s.is_empty() && s.len() < 200),
            "invalid_note_labels"
        );
        let mut processing = lock(&self.processing);
        anyhow::ensure!(processing.is_none(), "meeting_processing_busy");
        let mut meeting = lock(&self.store).get(&id)?;
        anyhow::ensure!(!meeting.status.busy(), "meeting_busy");
        if summary_only {
            anyhow::ensure!(meeting.transcript_complete, "no_transcript");
        } else {
            anyhow::ensure!(!meeting.transcript_complete, "transcript_already_complete");
            anyhow::ensure!(
                model.as_ref().is_some_and(|p| p.is_file()),
                "missing_moss_model"
            );
        }
        anyhow::ensure!(
            self.summary_directory.join("model.gguf").is_file()
                && self.summary_directory.join("tokenizer.json").is_file(),
            "missing_qwen_model"
        );
        let cancel = Arc::new(AtomicBool::new(false));
        let engine = EngineSupervisor::new(true);
        meeting.status = if summary_only {
            MeetingStatus::Summarizing
        } else {
            MeetingStatus::Transcribing
        };
        meeting.error = None;
        lock(&self.store).save(&meeting)?;
        *processing = Some(Processing {
            id: id.clone(),
            cancel: cancel.clone(),
            engine: engine.clone(),
        });
        drop(processing);
        let manager = self.clone();
        let spawned = std::thread::Builder::new()
            .name("meeting-inference".into())
            .spawn(move || {
                let result = manager.run(
                    &id,
                    model.as_deref(),
                    summary_only,
                    &labels,
                    &engine,
                    &cancel,
                );
                engine.unload().wait();
                let store = lock(&manager.store);
                if let Ok(mut meeting) = store.get(&id) {
                    if let Err(error) = result {
                        meeting.status = MeetingStatus::Failed;
                        meeting.error = Some(error.to_string());
                        if let Err(error) = store.save(&meeting) {
                            log::error!("Meeting failure checkpoint: {error}");
                        }
                    }
                }
                drop(store);
                *lock(&manager.processing) = None;
            });
        if let Err(error) = spawned {
            *lock(&self.processing) = None;
            meeting.status = MeetingStatus::Failed;
            meeting.error = Some(error.to_string());
            lock(&self.store).save(&meeting)?;
            return Err(error.into());
        }
        Ok(())
    }
    fn run(
        &self,
        id: &str,
        model: Option<&Path>,
        summary_only: bool,
        labels: &[String; 3],
        engine: &EngineSupervisor,
        cancel: &AtomicBool,
    ) -> anyhow::Result<()> {
        let mut meeting = lock(&self.store).get(id)?;
        if !summary_only {
            if meeting.status == MeetingStatus::Recoverable
                || !lock(&self.store)
                    .directory(id)?
                    .join("playback.wav")
                    .exists()
            {
                let store = lock(&self.store);
                store.finalize_audio(&mut meeting)?;
                store.save(&meeting)?;
            }
            let path = model.ok_or_else(|| anyhow::anyhow!("missing_moss_model"))?;
            let path = path.canonicalize()?;
            let info = engine.load(LoadSpec {
                path,
                backend: Backend::Auto,
                device: DeviceSelector::Auto,
            })?;
            anyhow::ensure!(info.supports_diarization, "model_lacks_diarization");
            let mut pending = std::collections::VecDeque::new();
            let mut start = meeting.completed_ms;
            while start < meeting.duration_ms {
                let maximum = (start + 45000).min(meeting.duration_ms);
                let tail =
                    lock(&self.store).read_audio(id, maximum.saturating_sub(1000), maximum)?;
                let end = super::window_end(start, meeting.duration_ms, &tail);
                pending.push_back((start, end));
                start = end;
            }
            while let Some((start, end)) = pending.pop_front() {
                check_cancel(cancel)?;
                match self.transcribe_body(
                    &mut meeting,
                    start,
                    end,
                    info.effective_max_audio_ms,
                    engine,
                    cancel,
                ) {
                    Ok(rows) => {
                        check_cancel(cancel)?;
                        meeting.segments.extend(rows);
                        meeting.completed_ms = end;
                        lock(&self.store).save(&meeting)?;
                    }
                    Err(error) => {
                        let split=error.downcast_ref::<EngineError>().is_some_and(|e|matches!(e,EngineError::Meeting(f) if matches!(f.kind,RunFailureKind::TooLong|RunFailureKind::Truncated|RunFailureKind::Repetition)));
                        if split && end - start >= 10000 {
                            let middle = start + (end - start) / 2;
                            pending.push_front((middle, end));
                            pending.push_front((start, middle));
                        } else {
                            return Err(error);
                        }
                    }
                }
            }
            engine.unload().wait();
            check_cancel(cancel)?;
            meeting.transcript_complete = true;
            meeting.status = MeetingStatus::Summarizing;
            lock(&self.store).save(&meeting)?;
        }
        let generated =
            notes::generate(&self.summary_directory, &meeting.segments, labels, cancel)?;
        check_cancel(cancel)?;
        meeting.notes = generated;
        meeting.notes_stale = false;
        meeting.status = MeetingStatus::Complete;
        meeting.error = None;
        lock(&self.store).save(&meeting)?;
        Ok(())
    }
    pub(super) fn transcribe_body(
        &self,
        meeting: &mut Meeting,
        start: u32,
        end: u32,
        limit: i64,
        engine: &EngineSupervisor,
        cancel: &AtomicBool,
    ) -> anyhow::Result<Vec<super::MeetingSegment>> {
        let body = lock(&self.store).read_audio(&meeting.id, start, end)?;
        let mut references = meeting.references.clone();
        references.sort_by(|a, b| a.speaker.cmp(&b.speaker));
        let banks: Vec<_> = if references.is_empty() {
            vec![vec![]]
        } else {
            references.chunks(8).map(|c| c.to_vec()).collect()
        };
        let mut predictions = vec![];
        for anchors in banks {
            check_cancel(cancel)?;
            let mut pcm = vec![];
            for anchor in &anchors {
                pcm.extend(lock(&self.store).read_audio(
                    &meeting.id,
                    anchor.start_ms,
                    anchor.end_ms,
                )?);
                pcm.resize(pcm.len() + 4000, 0.);
            }
            let prefix_ms = (pcm.len() / 16) as u32;
            pcm.extend_from_slice(&body);
            if limit > 0 && (pcm.len() / 16) as i64 > limit {
                return Err(
                    EngineError::Meeting(Box::new(crate::engine_supervisor::RunFailure {
                        kind: RunFailureKind::TooLong,
                        message: "input_too_long".into(),
                        partial: None,
                    }))
                    .into(),
                );
            }
            anyhow::ensure!(pcm.len() * 4 < 8_000_000, "audio_window_too_long");
            let result = engine.transcribe_meeting(
                pcm,
                RunOptions {
                    diarize: Diarize::On,
                    timestamps: TimestampKind::Segment,
                    ..Default::default()
                },
            );
            if let Err(EngineError::Meeting(failure)) = &result {
                save_failure_diagnostic(&lock(&self.store).directory(&meeting.id)?, failure)?;
            }
            let result = result?;
            anyhow::ensure!(
                result.text.trim().is_empty() || !result.segments.is_empty(),
                "missing_segment_timestamps"
            );
            predictions.push(BankResult {
                anchors,
                prefix_ms,
                segments: result.segments,
            });
        }
        let result = diarization::reconcile(meeting, &predictions, start, end);
        if result.is_err() {
            let path = lock(&self.store)
                .directory(&meeting.id)?
                .join("transcription-diagnostic.json");
            serde_json::to_writer(std::fs::File::create(path)?, &predictions)?;
        }
        result
    }
}
fn save_failure_diagnostic(
    directory: &Path,
    failure: &crate::engine_supervisor::RunFailure,
) -> anyhow::Result<()> {
    serde_json::to_writer(
        std::fs::File::create(directory.join("transcription-failure.json"))?,
        failure,
    )?;
    Ok(())
}
fn check_cancel(cancel: &AtomicBool) -> anyhow::Result<()> {
    anyhow::ensure!(!cancel.load(Ordering::Acquire), "processing_cancelled");
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn incomplete_native_output_is_diagnostic_only_and_retains_partial_text() {
        let dir = tempfile::tempdir().unwrap();
        let failure = crate::engine_supervisor::RunFailure {
            kind: crate::engine_supervisor::RunFailureKind::Truncated,
            message: "budget".into(),
            partial: Some(transcribe_cpp::Transcript {
                text: "incomplete speech".into(),
                ..Default::default()
            }),
        };
        super::save_failure_diagnostic(dir.path(), &failure).unwrap();
        let value: serde_json::Value = serde_json::from_slice(
            &std::fs::read(dir.path().join("transcription-failure.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(value["partial"]["text"], "incomplete speech");
        assert_eq!(value["kind"], "Truncated");
        assert!(!dir.path().join("meeting.json").exists());
    }
}

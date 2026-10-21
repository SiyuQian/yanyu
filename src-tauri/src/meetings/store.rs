use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "snake_case")]
pub enum MeetingMode {
    InPerson,
    Online,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "snake_case")]
pub enum MeetingStatus {
    Recording,
    Paused,
    Recoverable,
    Recorded,
    Transcribing,
    Summarizing,
    Complete,
    Failed,
}
impl MeetingStatus {
    pub fn busy(self) -> bool {
        matches!(
            self,
            Self::Recording | Self::Paused | Self::Transcribing | Self::Summarizing
        )
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, specta::Type)]
pub struct MeetingSegment {
    pub id: String,
    pub start_ms: u32,
    pub end_ms: u32,
    pub text: String,
    pub speaker: Option<String>,
    pub uncertain: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize, specta::Type)]
pub struct SpeakerReference {
    pub speaker: String,
    pub start_ms: u32,
    pub end_ms: u32,
}
#[derive(Debug, Clone, Serialize, Deserialize, specta::Type)]
pub struct Meeting {
    pub version: u32,
    pub id: String,
    pub title: String,
    pub mode: MeetingMode,
    pub created_at: String,
    pub status: MeetingStatus,
    pub mic_frames: u32,
    pub system_frames: u32,
    pub duration_ms: u32,
    pub completed_ms: u32,
    pub transcript_complete: bool,
    pub segments: Vec<MeetingSegment>,
    pub speakers: BTreeMap<String, String>,
    pub references: Vec<SpeakerReference>,
    pub notes: String,
    pub notes_stale: bool,
    pub error: Option<String>,
    #[serde(default)]
    pub capture_error: Option<String>,
    #[serde(default)]
    pub durability_warning: Option<String>,
}
/// Lightweight history row; full transcript and notes are fetched separately.
#[derive(Debug, Clone, Serialize, Deserialize, specta::Type)]
pub struct MeetingSummary {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub status: MeetingStatus,
    pub duration_ms: u32,
    pub completed_ms: u32,
}
impl From<&Meeting> for MeetingSummary {
    fn from(meeting: &Meeting) -> Self {
        Self {
            id: meeting.id.clone(),
            title: meeting.title.clone(),
            created_at: meeting.created_at.clone(),
            status: meeting.status,
            duration_ms: meeting.duration_ms,
            completed_ms: meeting.completed_ms,
        }
    }
}
/// A bounded history page plus active records, which remain visible on every page.
#[derive(Serialize, specta::Type)]
pub struct MeetingPage {
    pub items: Vec<MeetingSummary>,
    pub active: Vec<MeetingSummary>,
    pub has_more: bool,
}
/// A successful replacement is committed even if its directory sync fails.
pub struct SaveOutcome {
    pub durability_warning: Option<String>,
}
pub struct Store {
    root: PathBuf,
    summaries: std::cell::RefCell<Option<Vec<MeetingSummary>>>,
}
impl Store {
    pub fn new(root: PathBuf) -> anyhow::Result<Self> {
        fs::create_dir_all(&root)?;
        Ok(Self {
            root,
            summaries: std::cell::RefCell::new(None),
        })
    }
    pub fn directory(&self, id: &str) -> anyhow::Result<PathBuf> {
        anyhow::ensure!(
            id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()),
            "invalid_meeting_id"
        );
        let path = self.root.join(id);
        anyhow::ensure!(!path.is_symlink(), "invalid_meeting_path");
        Ok(path)
    }
    pub fn create(&self, mode: MeetingMode) -> anyhow::Result<Meeting> {
        let mut random = [0u8; 16];
        File::open("/dev/urandom")?.read_exact(&mut random)?;
        let id: String = random.iter().map(|b| format!("{b:02x}")).collect();
        fs::create_dir(self.directory(&id)?)?;
        let meeting = Meeting {
            version: 1,
            id,
            title: String::new(),
            mode,
            created_at: chrono::Utc::now().to_rfc3339(),
            status: MeetingStatus::Recording,
            mic_frames: 0,
            system_frames: 0,
            duration_ms: 0,
            completed_ms: 0,
            transcript_complete: false,
            segments: vec![],
            speakers: BTreeMap::new(),
            references: vec![],
            notes: String::new(),
            notes_stale: false,
            error: None,
            capture_error: None,
            durability_warning: None,
        };
        self.save(&meeting)?;
        Ok(meeting)
    }
    pub fn get(&self, id: &str) -> anyhow::Result<Meeting> {
        let path = self.directory(id)?.join("meeting.json");
        anyhow::ensure!(!path.is_symlink(), "invalid_meeting_path");
        let meeting: Meeting = serde_json::from_reader(File::open(path)?)?;
        anyhow::ensure!(
            meeting.id == id && meeting.version == 1,
            "invalid_meeting_metadata"
        );
        Ok(meeting)
    }
    /// Atomically replace metadata. Errors before rename are uncommitted; sync warnings after rename are committed.
    pub fn save(&self, meeting: &Meeting) -> anyhow::Result<SaveOutcome> {
        self.save_with_sync(meeting, |directory| File::open(directory)?.sync_all())
    }
    fn save_with_sync(
        &self,
        meeting: &Meeting,
        sync: impl FnOnce(&Path) -> std::io::Result<()>,
    ) -> anyhow::Result<SaveOutcome> {
        let directory = self.directory(&meeting.id)?;
        let mut file = File::create(directory.join("meeting.json.tmp"))?;
        serde_json::to_writer(&mut file, meeting)?;
        file.sync_all()?;
        // Invalidate the derived index before the commit point so a crash cannot leave stale history.
        match fs::remove_file(directory.join("summary.json")) {
            Ok(()) => (),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.into()),
        }
        fs::rename(
            directory.join("meeting.json.tmp"),
            directory.join("meeting.json"),
        )?;
        let durability_warning = sync(&directory).err().map(|error| error.to_string());
        if let Some(error) = &durability_warning {
            log::warn!("Meeting metadata committed; directory durability uncertain: {error}");
        }
        let summary = MeetingSummary::from(meeting);
        self.write_summary(&summary);
        if let Some(rows) = self.summaries.borrow_mut().as_mut() {
            if let Some(existing) = rows.iter_mut().find(|row| row.id == meeting.id) {
                *existing = summary;
            } else {
                rows.push(summary);
                sort_summaries(rows);
            }
        }
        Ok(SaveOutcome { durability_warning })
    }
    fn write_summary(&self, summary: &MeetingSummary) {
        let result = (|| -> anyhow::Result<()> {
            let directory = self.directory(&summary.id)?;
            let temporary = directory.join("summary.json.tmp");
            match fs::remove_file(&temporary) {
                Ok(()) => (),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                Err(error) => return Err(error.into()),
            }
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)?;
            file.write_all(&serde_json::to_vec(summary)?)?;
            fs::rename(
                directory.join("summary.json.tmp"),
                directory.join("summary.json"),
            )?;
            Ok(())
        })();
        if let Err(error) = result {
            log::warn!("Meeting summary cache write: {error}");
        }
    }
    fn load_summaries(&self) -> anyhow::Result<()> {
        if self.summaries.borrow().is_none() {
            let mut rows = BTreeMap::new();
            for entry in fs::read_dir(&self.root)? {
                let entry = entry?;
                let Some(id) = entry.file_name().to_str().map(str::to_owned) else {
                    continue;
                };
                let Ok(directory) = self.directory(&id) else {
                    continue;
                };
                let cache_path = directory.join("summary.json");
                let cached = (!cache_path.is_symlink())
                    .then(|| fs::read(cache_path).ok())
                    .flatten()
                    .and_then(|bytes| serde_json::from_slice::<MeetingSummary>(&bytes).ok())
                    .filter(|summary| summary.id == id);
                let summary = cached.or_else(|| {
                    self.get(&id).ok().map(|meeting| {
                        let summary = MeetingSummary::from(&meeting);
                        self.write_summary(&summary);
                        summary
                    })
                });
                if let Some(summary) = summary {
                    rows.insert(id, summary);
                }
            }
            let mut rows: Vec<_> = rows.into_values().collect();
            sort_summaries(&mut rows);
            *self.summaries.borrow_mut() = Some(rows);
        }
        Ok(())
    }
    /// Read cached lightweight rows, migrating older metadata only once per process.
    pub fn list(&self) -> anyhow::Result<Vec<MeetingSummary>> {
        self.load_summaries()?;
        Ok(self
            .summaries
            .borrow()
            .as_ref()
            .cloned()
            .unwrap_or_default())
    }
    /// Return a 50-row history page and active progress without loading transcript details.
    pub fn page(&self, offset: u32) -> anyhow::Result<MeetingPage> {
        self.load_summaries()?;
        let cache = self.summaries.borrow();
        let rows = cache.as_deref().unwrap_or_default();
        let active = rows
            .iter()
            .filter(|row| row.status.busy())
            .cloned()
            .collect();
        let offset = offset as usize;
        let has_more = rows.len().saturating_sub(offset) > 50;
        Ok(MeetingPage {
            items: rows.iter().skip(offset).take(50).cloned().collect(),
            active,
            has_more,
        })
    }
    /// Recover only records left busy by a prior process; call before allowing new recording.
    pub fn recover_interrupted(&self) -> anyhow::Result<()> {
        for row in self.list()?.into_iter().filter(|row| row.status.busy()) {
            self.recover_records(vec![self.get(&row.id)?])?;
        }
        Ok(())
    }
    pub fn edit(&self, edit: Meeting) -> anyhow::Result<Meeting> {
        let mut current = self.get(&edit.id)?;
        anyhow::ensure!(!current.status.busy(), "meeting_busy");
        anyhow::ensure!(
            edit.title.chars().count() <= 200
                && edit.notes.len() <= 2_000_000
                && edit.segments.len() == current.segments.len(),
            "invalid_meeting_edit"
        );
        let changed = edit
            .segments
            .iter()
            .zip(&current.segments)
            .any(|(a, b)| a.text != b.text);
        for (input, original) in edit.segments.iter().zip(&mut current.segments) {
            anyhow::ensure!(
                input.id == original.id && input.text.len() <= 100_000,
                "invalid_meeting_edit"
            );
            original.text.clone_from(&input.text);
        }
        anyhow::ensure!(
            edit.speakers.keys().eq(current.speakers.keys())
                && edit
                    .speakers
                    .values()
                    .all(|n| !n.trim().is_empty() && n.chars().count() <= 100),
            "invalid_speaker_names"
        );
        current.title = edit.title;
        current.notes = edit.notes;
        current.speakers = edit.speakers;
        current.notes_stale |= changed;
        current.durability_warning = None;
        let outcome = self.save(&current)?;
        current.durability_warning = outcome.durability_warning;
        Ok(current)
    }
    pub fn delete(&self, id: &str) -> anyhow::Result<()> {
        anyhow::ensure!(!self.get(id)?.status.busy(), "meeting_busy");
        fs::remove_dir_all(self.directory(id)?)?;
        if let Some(rows) = self.summaries.borrow_mut().as_mut() {
            rows.retain(|row| row.id != id);
        }
        Ok(())
    }
    pub fn recover_records(&self, records: Vec<Meeting>) -> anyhow::Result<()> {
        for mut meeting in records {
            if meeting.status.busy() {
                if matches!(
                    meeting.status,
                    MeetingStatus::Recording | MeetingStatus::Paused
                ) {
                    meeting.status = MeetingStatus::Recoverable;
                    meeting.error = Some("capture_interrupted".into());
                    meeting.capture_error = Some("capture_interrupted".into());
                    if let Err(error) = self.finalize_audio(&mut meeting) {
                        meeting.error = Some(error.to_string());
                    }
                } else {
                    meeting.status = MeetingStatus::Failed;
                    meeting.error = Some("processing_interrupted".into());
                }
                self.save(&meeting)?;
            }
        }
        Ok(())
    }
    pub fn finalize_audio(&self, meeting: &mut Meeting) -> anyhow::Result<()> {
        let directory = self.directory(&meeting.id)?;
        // Native side publishes durable counts only after both files have synced.
        if let Ok(bytes) = fs::read(directory.join("capture.json")) {
            let capture: super::capture::CaptureSnapshot = serde_json::from_slice(&bytes)?;
            meeting.mic_frames = capture.mic_frames;
            meeting.system_frames = capture.system_frames;
            if let Some(error) = capture.error {
                meeting.capture_error = Some(error.clone());
                meeting.error = Some(error);
            }
        }
        for (name, count) in [
            ("mic.pcm", &mut meeting.mic_frames),
            ("system.pcm", &mut meeting.system_frames),
        ] {
            let path = directory.join(name);
            anyhow::ensure!(!path.is_symlink(), "invalid_meeting_path");
            let available = match fs::metadata(path) {
                Ok(metadata) => metadata.len() / 4,
                Err(error)
                    if name == "system.pcm"
                        && meeting.mode == MeetingMode::InPerson
                        && error.kind() == std::io::ErrorKind::NotFound =>
                {
                    0
                }
                Err(error) => return Err(error.into()),
            };
            *count = (*count as u64).min(available).min(u32::MAX as u64) as u32;
        }
        let count = meeting.mic_frames.max(meeting.system_frames);
        meeting.duration_ms = count / 16;
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let output = directory.join("playback.wav.tmp");
        let mut writer = hound::WavWriter::create(&output, spec)?;
        let mut mic = PcmReader::new(&directory.join("mic.pcm"), meeting.mic_frames)?;
        let mut system = PcmReader::new(&directory.join("system.pcm"), meeting.system_frames)?;
        let gain = if meeting.mode == MeetingMode::Online {
            0.5
        } else {
            1.0
        };
        for _ in 0..count {
            let sample = ((mic.next()? + system.next()?) * gain).clamp(-1.0, 1.0);
            writer.write_sample((sample * i16::MAX as f32) as i16)?;
        }
        writer.finalize()?;
        File::open(&output)?.sync_all()?;
        fs::rename(output, directory.join("playback.wav"))?;
        Ok(())
    }
    pub fn markdown(&self, id: &str) -> anyhow::Result<String> {
        let m = self.get(id)?;
        let mut text = format!("# {}\n\n{}\n\n{}\n\n", m.title, m.created_at, m.notes);
        if !m.notes.is_empty() {
            text.push_str("> Generated meeting notes are a draft. Verify source citations; tasks can be missed and proposals misclassified.\n\n");
        }
        if m.notes_stale {
            text.push_str("> Notes may be out of date because the transcript changed. Regenerate notes before relying on them.\n\n");
        }
        if let Some(error) = m.capture_error {
            text.push_str(&format!("> capture_error: {error}\n\n"));
        }
        for segment in m.segments {
            let mut speaker = segment
                .speaker
                .as_ref()
                .and_then(|s| m.speakers.get(s))
                .cloned()
                .unwrap_or_else(|| "?".into());
            if segment.uncertain {
                speaker.push_str(" (speaker attribution uncertain)");
            }
            text.push_str(&format!(
                "<a id=\"{}\"></a>\n[{:02}:{:02}] **{}**: {}\n\n",
                segment.id,
                segment.start_ms / 60000,
                segment.start_ms / 1000 % 60,
                speaker,
                segment.text
            ));
        }
        Ok(text)
    }
    pub fn read_audio(&self, id: &str, start_ms: u32, end_ms: u32) -> anyhow::Result<Vec<f32>> {
        anyhow::ensure!(
            end_ms >= start_ms && end_ms - start_ms <= 75_000,
            "audio_window_too_long"
        );
        let path = self.directory(id)?.join("playback.wav");
        anyhow::ensure!(!path.is_symlink(), "invalid_meeting_path");
        let mut reader = hound::WavReader::open(path)?;
        reader.seek(start_ms * 16)?;
        Ok(reader
            .samples::<i16>()
            .take(((end_ms - start_ms) * 16) as usize)
            .map(|s| s.map(|n| n as f32 / 32768.))
            .collect::<Result<_, _>>()?)
    }
}
fn sort_summaries(rows: &mut [MeetingSummary]) {
    rows.sort_by(|a, b| {
        b.created_at
            .cmp(&a.created_at)
            .then_with(|| a.id.cmp(&b.id))
    });
}
struct PcmReader {
    reader: Option<std::io::BufReader<File>>,
    remaining: u32,
}
impl PcmReader {
    fn new(path: &Path, frames: u32) -> anyhow::Result<Self> {
        Ok(Self {
            reader: if frames > 0 {
                Some(std::io::BufReader::new(File::open(path)?))
            } else {
                None
            },
            remaining: frames,
        })
    }
    fn next(&mut self) -> anyhow::Result<f32> {
        if self.remaining == 0 {
            return Ok(0.);
        }
        let mut bytes = [0; 4];
        if let Some(reader) = &mut self.reader {
            reader.read_exact(&mut bytes)?;
        }
        self.remaining -= 1;
        let value = f32::from_le_bytes(bytes);
        anyhow::ensure!(value.is_finite(), "invalid_audio_sample");
        Ok(value)
    }
}

#[cfg(test)]
mod durability_tests {
    use super::*;
    #[test]
    fn post_rename_sync_failure_returns_committed_outcome() {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::new(directory.path().into()).unwrap();
        let mut meeting = store.create(MeetingMode::InPerson).unwrap();
        meeting.title = "Committed edit".into();
        let outcome = store
            .save_with_sync(&meeting, |_| {
                Err(std::io::Error::other("injected directory sync failure"))
            })
            .unwrap();
        assert!(outcome
            .durability_warning
            .unwrap()
            .contains("injected directory sync failure"));
        assert_eq!(store.get(&meeting.id).unwrap().title, "Committed edit");
    }
}

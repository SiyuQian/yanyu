use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::Read,
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
}
pub struct Store {
    root: PathBuf,
}
impl Store {
    pub fn new(root: PathBuf) -> anyhow::Result<Self> {
        fs::create_dir_all(&root)?;
        Ok(Self { root })
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
    pub fn save(&self, meeting: &Meeting) -> anyhow::Result<()> {
        let directory = self.directory(&meeting.id)?;
        let mut file = File::create(directory.join("meeting.json.tmp"))?;
        serde_json::to_writer(&mut file, meeting)?;
        file.sync_all()?;
        fs::rename(
            directory.join("meeting.json.tmp"),
            directory.join("meeting.json"),
        )?;
        File::open(directory)?.sync_all()?;
        Ok(())
    }
    pub fn list(&self) -> anyhow::Result<Vec<Meeting>> {
        let mut rows = vec![];
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if let Some(id) = entry.file_name().to_str() {
                if let Ok(meeting) = self.get(id) {
                    rows.push(meeting);
                }
            }
        }
        rows.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(rows)
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
        self.save(&current)?;
        Ok(current)
    }
    pub fn delete(&self, id: &str) -> anyhow::Result<()> {
        anyhow::ensure!(!self.get(id)?.status.busy(), "meeting_busy");
        fs::remove_dir_all(self.directory(id)?)?;
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
            let available = fs::metadata(path).map(|m| m.len() / 4).unwrap_or(0);
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
        if let Some(error) = m.capture_error {
            text.push_str(&format!("> capture_error: {error}\n\n"));
        }
        for segment in m.segments {
            let speaker = segment
                .speaker
                .as_ref()
                .and_then(|s| m.speakers.get(s))
                .cloned()
                .unwrap_or_else(|| "?".into());
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

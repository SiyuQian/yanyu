use super::*;
use std::io::Write;

#[test]
fn recovery_uses_committed_frames_and_discards_partial_tail() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into()).unwrap();
    let mut meeting = store.create(MeetingMode::Online).unwrap();
    let path = store.directory(&meeting.id).unwrap();
    std::fs::write(path.join("mic.pcm"), [0u8; 83]).unwrap();
    std::fs::write(path.join("system.pcm"), [0u8; 40]).unwrap();
    meeting.mic_frames = 16;
    meeting.system_frames = 8;
    store.save(&meeting).unwrap();
    store.recover_records(store.list().unwrap()).unwrap();
    let recovered = store.get(&meeting.id).unwrap();
    assert_eq!(recovered.status, MeetingStatus::Recoverable);
    assert_eq!((recovered.mic_frames, recovered.system_frames), (16, 8));
    assert_eq!(
        std::fs::metadata(path.join("playback.wav")).unwrap().len(),
        76
    );
    assert!(recovered.error.is_some());
    assert!(recovered.capture_error.is_some());
}

#[test]
fn owned_paths_and_busy_records_cannot_be_deleted_or_edited() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into()).unwrap();
    assert!(store.get("../outside").is_err());
    let mut meeting = store.create(MeetingMode::InPerson).unwrap();
    assert!(store.delete(&meeting.id).is_err());
    meeting.status = MeetingStatus::Recorded;
    store.save(&meeting).unwrap();
    let mut edit = meeting.clone();
    edit.title = "Edited".into();
    edit.notes = "Current notes".into();
    store.edit(edit).unwrap();
    assert!(store
        .markdown(&meeting.id)
        .unwrap()
        .contains("Current notes"));
    store.delete(&meeting.id).unwrap();
    assert!(!store.directory(&meeting.id).unwrap().exists());
}

#[test]
fn wav_mix_is_bounded_aligned_and_keeps_both_sources() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into()).unwrap();
    let mut meeting = store.create(MeetingMode::Online).unwrap();
    let path = store.directory(&meeting.id).unwrap();
    for (name, values) in [
        ("mic.pcm", vec![1f32, 0., -1.]),
        ("system.pcm", vec![0f32, 1.]),
    ] {
        let mut file = std::fs::File::create(path.join(name)).unwrap();
        for sample in values {
            file.write_all(&sample.to_le_bytes()).unwrap();
        }
    }
    meeting.mic_frames = 3;
    meeting.system_frames = 2;
    store.finalize_audio(&mut meeting).unwrap();
    let samples: Vec<i16> = hound::WavReader::open(path.join("playback.wav"))
        .unwrap()
        .samples()
        .map(Result::unwrap)
        .collect();
    assert_eq!(samples, [16383, 16383, -16383]);
}

#[test]
fn quiet_boundaries_cover_two_hours_without_overlaps_or_gaps() {
    let tail = vec![0f32; 16000];
    let mut cursor = 0;
    let mut windows = 0;
    while cursor < 7_200_000 {
        let end = window_end(cursor, 7_200_000, &tail);
        assert!(end > cursor && end - cursor <= 45000);
        cursor = end;
        windows += 1;
    }
    assert_eq!(cursor, 7_200_000);
    assert_eq!(windows, 160);
    let mut tail = vec![1f32; 16000];
    tail[8000..8800].fill(0.);
    assert_eq!(window_end(0, 90000, &tail), 44550);
}

#[test]
fn atomic_failure_keeps_previous_metadata_and_processing_blocks_mutation() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into()).unwrap();
    let mut meeting = store.create(MeetingMode::InPerson).unwrap();
    meeting.status = MeetingStatus::Transcribing;
    store.save(&meeting).unwrap();
    assert!(store.delete(&meeting.id).is_err());
    assert!(store.edit(meeting.clone()).is_err());
    let path = store.directory(&meeting.id).unwrap();
    std::fs::create_dir(path.join("meeting.json.tmp")).unwrap();
    meeting.title = "Uncommitted".into();
    assert!(store.save(&meeting).is_err());
    assert_eq!(store.get(&meeting.id).unwrap().title, "");
}
#[test]
fn transcript_edits_invalidate_notes_without_changing_audio_references() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().into()).unwrap();
    let mut meeting = store.create(MeetingMode::InPerson).unwrap();
    meeting.status = MeetingStatus::Complete;
    meeting.segments.push(MeetingSegment {
        id: "s0".into(),
        start_ms: 0,
        end_ms: 2000,
        text: "Original".into(),
        speaker: Some("speaker_1".into()),
        uncertain: false,
    });
    meeting.speakers.insert("speaker_1".into(), "A".into());
    meeting.references.push(SpeakerReference {
        speaker: "speaker_1".into(),
        start_ms: 0,
        end_ms: 2000,
    });
    meeting.notes = "Previous notes".into();
    store.save(&meeting).unwrap();
    meeting.segments[0].text = "Corrected".into();
    meeting.speakers.insert("speaker_1".into(), "Alice".into());
    let saved = store.edit(meeting).unwrap();
    assert!(saved.notes_stale);
    assert_eq!(saved.references[0].end_ms, 2000);
    assert_eq!(saved.notes, "Previous notes");
    let markdown = store.markdown(&saved.id).unwrap();
    assert!(markdown.contains("**Alice**: Corrected"));
    assert!(markdown.contains("id=\"s0\""));
}

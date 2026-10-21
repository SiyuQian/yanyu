//! Opt-in experiments use only authored fixtures and explicitly installed artifacts.
use super::*;
use std::{
    fs,
    io::{Seek, SeekFrom, Write},
    path::PathBuf,
    sync::atomic::AtomicBool,
};
#[test]
#[ignore = "Requires explicitly installed pinned Qwen artifacts; writes authored evidence only"]
fn real_qwen_notes_fixture() {
    let directory = PathBuf::from(
        std::env::var_os("MEETING_QWEN_DIRECTORY").expect("set MEETING_QWEN_DIRECTORY"),
    );
    let output = PathBuf::from(
        std::env::var_os("MEETING_EVIDENCE_DIRECTORY").expect("set MEETING_EVIDENCE_DIRECTORY"),
    );
    fs::create_dir_all(&output).unwrap();
    let variants = [
        (
            "en",
            vec![
                "We discussed Friday release, but rejected Friday.",
                "We decided to release on Monday.",
                "Alice will prepare the checklist by Thursday.",
                "We agreed to check the backup process. No owner or deadline was assigned.",
                "A dashboard was proposed. No decision was made and it is not an approved action.",
            ],
        ),
        (
            "zh",
            vec![
                "我们讨论了周五发布，但否决了周五。",
                "我们决定周一发布。",
                "Alice 周四前准备检查清单。",
                "我们同意检查备份流程，未指定负责人和截止日期。",
                "有人提出增加仪表板，但没有作出决定，也没有批准此待办。",
            ],
        ),
    ];
    let mut failures = vec![];
    for (language, texts) in variants {
        let segments: Vec<_> = texts
            .iter()
            .enumerate()
            .map(|(i, text)| MeetingSegment {
                id: format!("s{i}"),
                start_ms: i as u32 * 3000,
                end_ms: i as u32 * 3000 + 2500,
                text: (*text).into(),
                speaker: Some("speaker_1".into()),
                uncertain: false,
            })
            .collect();
        fs::write(
            output.join(format!("qwen-{language}-input.json")),
            serde_json::to_vec_pretty(&segments).unwrap(),
        )
        .unwrap();
        let started = std::time::Instant::now();
        let cancel = AtomicBool::new(false);
        let mut model =
            crate::managers::local_polishing::NativeModel::load(&directory, &cancel).unwrap();
        let raw = model
            .generate_prompt(
                &notes::prompt(&segments, false).unwrap(),
                2048,
                512,
                std::time::Instant::now() + std::time::Duration::from_secs(120),
                &cancel,
            )
            .unwrap();
        fs::write(
            output.join(format!("qwen-{language}-raw.txt")),
            raw.as_deref().unwrap_or("<incomplete>"),
        )
        .unwrap();
        drop(model);
        let result = notes::generate(
            &directory,
            &segments,
            &["Discussion".into(), "Decisions".into(), "Actions".into()],
            &cancel,
        );
        match result {
            Ok(markdown) => {
                fs::write(output.join(format!("qwen-{language}-output.md")), &markdown).unwrap();
                let decisions = markdown
                    .split("## Decisions")
                    .nth(1)
                    .unwrap_or("")
                    .split("## Actions")
                    .next()
                    .unwrap_or("");
                let actions = markdown.split("## Actions").nth(1).unwrap_or("");
                if !decisions.contains("#s1")
                    || decisions.contains("#s0")
                    || decisions.contains("#s4")
                    || !actions.contains("#s2")
                    || !actions.contains("#s3")
                    || actions.contains("#s4")
                {
                    failures.push(format!("{language}: semantic fixture failed"));
                }
            }
            Err(error) => {
                fs::write(
                    output.join(format!("qwen-{language}-error.txt")),
                    error.to_string(),
                )
                .unwrap();
                failures.push(format!("{language}: {error}"));
            }
        }
        eprintln!("Qwen {language} elapsed: {:?}", started.elapsed());
    }
    assert!(failures.is_empty(), "{}", failures.join("; "));
}
#[test]
#[ignore = "Requires explicit MOSS path, built worker, and authored fixture WAV/manifest"]
fn real_moss_reference_reels() {
    let path =
        PathBuf::from(std::env::var_os("MEETING_MOSS_MODEL").expect("set MEETING_MOSS_MODEL"));
    let fixture = PathBuf::from(
        std::env::var_os("MEETING_FIXTURE_DIRECTORY").expect("set MEETING_FIXTURE_DIRECTORY"),
    );
    let evidence = PathBuf::from(
        std::env::var_os("MEETING_EVIDENCE_DIRECTORY").expect("set MEETING_EVIDENCE_DIRECTORY"),
    );
    let temp = tempfile::tempdir().unwrap();
    let manager = MeetingManager::new(temp.path().join("meetings"), PathBuf::new()).unwrap();
    let mut meeting = manager
        .store
        .lock()
        .unwrap()
        .create(MeetingMode::InPerson)
        .unwrap();
    let owned = manager
        .store
        .lock()
        .unwrap()
        .directory(&meeting.id)
        .unwrap();
    fs::copy(fixture.join("dialogue.wav"), owned.join("playback.wav")).unwrap();
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(fixture.join("manifest.json")).unwrap()).unwrap();
    let engine = crate::engine_supervisor::EngineSupervisor::new(true);
    let info = engine
        .load(crate::engine_supervisor::LoadSpec {
            path,
            backend: transcribe_cpp::Backend::Auto,
            device: crate::engine_supervisor::DeviceSelector::Auto,
        })
        .unwrap();
    assert!(info.supports_diarization);
    let mut identity = std::collections::BTreeMap::new();
    let mut failures = vec![];
    for window in manifest["windows"].as_array().unwrap() {
        let start = window["start_ms"].as_u64().unwrap() as u32;
        let end = window["end_ms"].as_u64().unwrap() as u32;
        let rows = manager
            .transcribe_body(
                &mut meeting,
                start,
                end,
                info.effective_max_audio_ms,
                &engine,
                &AtomicBool::new(false),
            )
            .unwrap();
        for turn in window["turns"].as_array().unwrap() {
            let expected = turn["speaker"].as_str().unwrap();
            let at = turn["start_ms"].as_u64().unwrap() as u32;
            let until = turn["end_ms"].as_u64().unwrap() as u32;
            let matched = rows
                .iter()
                .find(|row| row.start_ms.abs_diff(at) <= 500 && row.end_ms.abs_diff(until) <= 500);
            if let Some(row) = matched {
                if row.uncertain || row.speaker.is_none() {
                    failures.push(format!("uncertain {expected} at {at}"));
                    continue;
                }
                let actual = row.speaker.clone().unwrap();
                if let Some(previous) = identity.insert(expected.to_string(), actual.clone()) {
                    if previous != actual {
                        failures.push(format!("identity changed: {expected}"));
                    }
                }
            } else {
                failures.push(format!("missing/timing mismatch {expected} at {at}"));
            }
        }
        meeting.segments.extend(rows);
    }
    engine.unload().wait();
    fs::create_dir_all(&evidence).unwrap();
    fs::write(
        evidence.join("moss-transcript.json"),
        serde_json::to_vec_pretty(&meeting.segments).unwrap(),
    )
    .unwrap();
    assert!(failures.is_empty(), "{}", failures.join("; "));
}
#[test]
#[ignore = "Two-hour sparse synthetic storage test, not voiced or native capture quality"]
fn two_hour_storage_recovery() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("meetings")).unwrap();
    let mut meeting = store.create(MeetingMode::Online).unwrap();
    let directory = store.directory(&meeting.id).unwrap();
    let count = 7200 * 16000;
    for name in ["mic.pcm", "system.pcm"] {
        let mut file = fs::File::create(directory.join(name)).unwrap();
        file.set_len(count as u64 * 4).unwrap();
        for second in [0u64, 3600, 7199] {
            file.seek(SeekFrom::Start(second * 16000 * 4)).unwrap();
            file.write_all(&1f32.to_le_bytes()).unwrap();
        }
        file.sync_all().unwrap();
    }
    meeting.mic_frames = count;
    meeting.system_frames = count;
    store.save(&meeting).unwrap();
    store.recover_records(store.list().unwrap()).unwrap();
    let recovered = store.get(&meeting.id).unwrap();
    assert_eq!(recovered.duration_ms, 7_200_000);
    let mut reader = hound::WavReader::open(directory.join("playback.wav")).unwrap();
    assert_eq!(reader.duration(), 115_200_000);
    for sample in [0, 57_600_000, 115_184_000] {
        reader.seek(sample).unwrap();
        assert_eq!(reader.samples::<i16>().next().unwrap().unwrap(), 32767);
    }
    eprintln!(
        "raw logical bytes: {}; playback bytes: {}",
        count as u64 * 8,
        fs::metadata(directory.join("playback.wav")).unwrap().len()
    );
}

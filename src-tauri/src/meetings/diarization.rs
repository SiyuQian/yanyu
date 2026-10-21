use super::{Meeting, MeetingSegment, SpeakerReference};
use transcribe_cpp::Segment;
#[derive(serde::Serialize)]
pub struct BankResult {
    pub anchors: Vec<SpeakerReference>,
    pub prefix_ms: u32,
    pub segments: Vec<Segment>,
}
pub fn reconcile(
    meeting: &mut Meeting,
    banks: &[BankResult],
    start: u32,
    end: u32,
) -> anyhow::Result<Vec<MeetingSegment>> {
    use std::collections::{BTreeMap, BTreeSet};
    anyhow::ensure!(!banks.is_empty(), "missing_diarization_output");
    let mut bodies = vec![];
    let mut mappings = vec![];
    let mut coverage = BTreeSet::new();
    let mut all_valid = true;
    for bank in banks {
        let prefix = i64::from(bank.prefix_ms);
        anyhow::ensure!(
            bank.segments.iter().all(|row| row.t0_ms >= 0
                && row.t1_ms > row.t0_ms
                && row.t1_ms <= prefix + i64::from(end - start)),
            "invalid_segment_timestamps"
        );
        anyhow::ensure!(
            !bank
                .segments
                .iter()
                .any(|row| row.t0_ms < prefix && row.t1_ms > prefix),
            "reference_boundary_overlap"
        );
        let mut mapping = BTreeMap::new();
        let mut cursor = 0i64;
        let mut valid = true;
        for anchor in &bank.anchors {
            let duration = i64::from(anchor.end_ms - anchor.start_ms);
            let mut overlaps: BTreeMap<i32, i64> = BTreeMap::new();
            let mut boundaries: BTreeMap<i32, (i64, i64)> = BTreeMap::new();
            for row in &bank.segments {
                let overlap = row.t1_ms.min(cursor + duration) - row.t0_ms.max(cursor);
                if overlap > 0 && row.speaker_id > 0 {
                    *overlaps.entry(row.speaker_id).or_default() += overlap;
                    let boundary = boundaries
                        .entry(row.speaker_id)
                        .or_insert((row.t0_ms, row.t1_ms));
                    boundary.0 = boundary.0.min(row.t0_ms);
                    boundary.1 = boundary.1.max(row.t1_ms);
                }
            }
            let candidates: Vec<_> = overlaps
                .iter()
                .filter(|(_, n)| **n * 100 >= duration * 80)
                .collect();
            if candidates.len() == 1 {
                let id = *candidates[0].0;
                let (left, right) = boundaries[&id];
                if (left - cursor).abs() <= 200
                    && (right - cursor - duration).abs() <= 200
                    && !mapping.contains_key(&id)
                {
                    mapping.insert(id, anchor.speaker.clone());
                    coverage.insert(anchor.speaker.clone());
                } else {
                    valid = false;
                }
            } else {
                valid = false;
            }
            cursor += duration + 250;
        }
        let body: Vec<_> = bank
            .segments
            .iter()
            .filter(|r| r.t1_ms > i64::from(bank.prefix_ms))
            .cloned()
            .map(|mut row| {
                row.t0_ms -= i64::from(bank.prefix_ms);
                row.t1_ms -= i64::from(bank.prefix_ms);
                row
            })
            .collect();
        if body
            .iter()
            .any(|r| r.t0_ms < 0 || r.t1_ms <= r.t0_ms || r.t1_ms > i64::from(end - start) + 200)
        {
            valid = false;
        }
        all_valid &= valid;
        mappings.push((mapping, valid));
        bodies.push(body);
    }
    let aligned = bodies.iter().all(|body| {
        body.len() == bodies[0].len()
            && body.iter().zip(&bodies[0]).all(|(a, b)| {
                a.text.trim() == b.text.trim()
                    && (a.t0_ms - b.t0_ms).abs() <= 200
                    && (a.t1_ms - b.t1_ms).abs() <= 200
            })
    });
    let complete = all_valid && aligned && meeting.speakers.keys().all(|id| coverage.contains(id));
    let first_window = meeting.speakers.is_empty();
    let mut new_ids = BTreeMap::new();
    let mut output = vec![];
    for (index, row) in bodies[0].iter().enumerate() {
        let mut candidates = BTreeSet::new();
        let mut contradiction = false;
        for (body, (mapping, valid)) in bodies.iter().zip(&mappings) {
            if aligned && *valid {
                if let Some(id) = mapping.get(&body[index].speaker_id) {
                    candidates.insert(id.clone());
                }
            }
        }
        if candidates.len() > 1 {
            contradiction = true;
        }
        let mut speaker = if aligned && !contradiction && candidates.len() == 1 {
            candidates.into_iter().next()
        } else {
            None
        };
        let timing_valid =
            row.t0_ms >= 0 && row.t1_ms > row.t0_ms && row.t1_ms <= i64::from(end - start) + 200;
        let overlapping = bodies[0].iter().enumerate().any(|(other, r)| {
            other != index
                && r.speaker_id != row.speaker_id
                && r.t0_ms < row.t1_ms
                && row.t0_ms < r.t1_ms
        });
        if speaker.is_none()
            && !contradiction
            && !overlapping
            && timing_valid
            && row.speaker_id > 0
            && (complete || first_window)
        {
            speaker = Some(
                new_ids
                    .entry(row.speaker_id)
                    .or_insert_with(|| {
                        let id = format!("speaker_{}", meeting.speakers.len() + 1);
                        meeting.speakers.insert(id.clone(), id.clone());
                        id
                    })
                    .clone(),
            );
        }
        let uncertain = speaker.is_none() || !timing_valid || overlapping || !aligned || !all_valid;
        if overlapping || !timing_valid {
            speaker = None;
        }
        output.push(MeetingSegment {
            id: format!("s{}_{}", start, index),
            start_ms: start + row.t0_ms as u32,
            end_ms: start + row.t1_ms as u32,
            text: row.text.clone(),
            speaker,
            uncertain,
        });
    }
    // Keep one longest clean turn per canonical voice; never replace with ambiguous overlap.
    for row in &output {
        if row.uncertain || row.end_ms - row.start_ms < 1000 {
            continue;
        }
        if let Some(id) = &row.speaker {
            let reference = SpeakerReference {
                speaker: id.clone(),
                start_ms: row.start_ms,
                end_ms: row.end_ms.min(row.start_ms + 3000),
            };
            if let Some(old) = meeting.references.iter_mut().find(|r| r.speaker == *id) {
                if reference.end_ms - reference.start_ms > old.end_ms - old.start_ms {
                    *old = reference;
                }
            } else {
                meeting.references.push(reference);
            }
        }
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meetings::{MeetingMode, Store};
    fn row(start: i64, end: i64, id: i32, text: &str) -> Segment {
        Segment {
            t0_ms: start,
            t1_ms: end,
            speaker_id: id,
            text: text.into(),
            ..Default::default()
        }
    }
    #[test]
    fn a_segment_crossing_the_reference_boundary_is_never_saved_as_body_text() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().into()).unwrap();
        let mut meeting = store.create(MeetingMode::InPerson).unwrap();
        meeting.speakers.insert("speaker_1".into(), "A".into());
        let bank = BankResult {
            anchors: vec![SpeakerReference {
                speaker: "speaker_1".into(),
                start_ms: 0,
                end_ms: 2000,
            }],
            prefix_ms: 2250,
            segments: vec![
                row(0, 2000, 1, "reference"),
                row(2000, 3000, 1, "reference text and body"),
            ],
        };
        assert!(reconcile(&mut meeting, &[bank], 45000, 46000).is_err());
    }
    #[test]
    fn overlapping_first_window_voices_never_become_canonical() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().into()).unwrap();
        let mut meeting = store.create(MeetingMode::InPerson).unwrap();
        let output = reconcile(
            &mut meeting,
            &[BankResult {
                anchors: vec![],
                prefix_ms: 0,
                segments: vec![
                    row(0, 2000, 1, "overlap A"),
                    row(1000, 3000, 2, "overlap B"),
                ],
            }],
            0,
            3000,
        )
        .unwrap();
        assert!(output
            .iter()
            .all(|row| row.uncertain && row.speaker.is_none()));
        assert!(meeting.speakers.is_empty());
        assert!(meeting.references.is_empty());
    }
    #[test]
    fn missing_known_reference_never_creates_a_new_identity() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().into()).unwrap();
        let mut meeting = store.create(MeetingMode::InPerson).unwrap();
        meeting.speakers.insert("speaker_1".into(), "A".into());
        meeting.speakers.insert("speaker_2".into(), "B".into());
        let output = reconcile(
            &mut meeting,
            &[BankResult {
                anchors: vec![],
                prefix_ms: 0,
                segments: vec![row(0, 2000, 1, "unknown voice")],
            }],
            45000,
            47000,
        )
        .unwrap();
        assert!(output[0].uncertain);
        assert!(output[0].speaker.is_none());
        assert_eq!(meeting.speakers.len(), 2);
    }
    #[test]
    fn returning_voice_is_matched_by_anchor_instead_of_local_order() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().into()).unwrap();
        let mut meeting = store.create(MeetingMode::InPerson).unwrap();
        for name in ["speaker_1", "speaker_2"] {
            meeting.speakers.insert(name.into(), name.into());
        }
        let refs = vec![
            SpeakerReference {
                speaker: "speaker_1".into(),
                start_ms: 0,
                end_ms: 2000,
            },
            SpeakerReference {
                speaker: "speaker_2".into(),
                start_ms: 2500,
                end_ms: 4500,
            },
        ];
        let bank = BankResult {
            anchors: refs,
            prefix_ms: 4500,
            segments: vec![
                row(0, 2000, 7, "reference A"),
                row(2250, 4250, 3, "reference B"),
                row(4500, 6500, 3, "B returns"),
                row(6500, 8500, 7, "A returns"),
            ],
        };
        let output = reconcile(&mut meeting, &[bank], 45000, 49000).unwrap();
        assert_eq!(output.len(), 2);
        assert_eq!(output[0].speaker.as_deref(), Some("speaker_2"));
        assert_eq!(output[1].speaker.as_deref(), Some("speaker_1"));
        assert_eq!(output[0].start_ms, 45000);
        assert!(output.iter().all(|s| !s.text.contains("reference")));
    }
}

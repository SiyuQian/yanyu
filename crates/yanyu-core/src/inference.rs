use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use transcribe_cpp::{CancelToken, Error as TranscribeError, Model, RunOptions, Session};

use crate::{decode_wav_to_16khz_mono, CoreError, IncompleteOutputKind};

const IDLE_STAGE: u8 = 0;
const PREPARING_AUDIO_STAGE: u8 = 1;
const RECOGNIZING_STAGE: u8 = 2;

/// Current phase of a file transcription operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TranscriptionStage {
    /// No transcription is active.
    Idle,
    /// Reading and normalizing the audio file before inference.
    PreparingAudio,
    /// The native speech model is recognizing the prepared audio.
    Recognizing,
}

fn transcription_stage_from_code(stage: u8) -> TranscriptionStage {
    match stage {
        PREPARING_AUDIO_STAGE => TranscriptionStage::PreparingAudio,
        RECOGNIZING_STAGE => TranscriptionStage::Recognizing,
        _ => TranscriptionStage::Idle,
    }
}

/// Shared kind for native transcription failures consumed by app shells.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum TranscriptionFailureKind {
    /// The audio exceeds the model's supported duration.
    TooLong,
    /// The operation was cancelled after zero or more complete chunks.
    Aborted,
    /// The decoder reached its generation budget before end-of-stream.
    Truncated,
    /// The decoder stopped after detecting repeated output.
    Repetition,
    /// Any native failure without a dedicated recovery category.
    Other,
}

/// Native failure details shared between iOS and desktop adapters.
#[derive(Debug, Clone)]
pub struct TranscriptionFailure {
    /// Stable recovery category for app-specific behavior.
    pub kind: TranscriptionFailureKind,
    /// Human-readable native failure detail for logs and diagnostics.
    pub message: String,
    /// Full partial result when the native engine retained one.
    pub partial: Option<transcribe_cpp::Transcript>,
}

/// Classify a native failure while preserving its diagnostics and partial result.
pub fn classify_transcription_error(error: &TranscribeError) -> TranscriptionFailure {
    let kind = match error {
        TranscribeError::InputTooLong(_) => TranscriptionFailureKind::TooLong,
        TranscribeError::Aborted { .. } => TranscriptionFailureKind::Aborted,
        TranscribeError::OutputTruncated { .. } => TranscriptionFailureKind::Truncated,
        TranscribeError::OutputRepetition { .. } => TranscriptionFailureKind::Repetition,
        _ => TranscriptionFailureKind::Other,
    };

    TranscriptionFailure {
        kind,
        message: error.to_string(),
        partial: error.partial().cloned(),
    }
}

#[derive(Debug, uniffi::Record)]
pub struct TranscriptResult {
    pub text: String,
    pub detected_language: Option<String>,
    pub audio_duration_ms: u64,
    pub processing_duration_ms: u64,
}

#[derive(uniffi::Object)]
pub struct Transcriber {
    session: Mutex<Session>,
    cancel_token: CancelToken,
    run_active: Mutex<bool>,
    stage: AtomicU8,
}

#[uniffi::export]
impl Transcriber {
    #[uniffi::constructor]
    pub fn load_model(model_path: String) -> Result<Arc<Self>, CoreError> {
        let model = Model::load(&model_path).map_err(|error| CoreError::ModelLoad {
            message: error.to_string(),
        })?;
        let mut session = model.session().map_err(|error| CoreError::ModelLoad {
            message: error.to_string(),
        })?;
        let cancel_token = CancelToken::new();
        session.set_cancel_token(&cancel_token);

        Ok(Arc::new(Self {
            session: Mutex::new(session),
            cancel_token,
            run_active: Mutex::new(false),
            stage: AtomicU8::new(IDLE_STAGE),
        }))
    }

    /// Reports the current transcription phase without estimating completion.
    pub fn current_stage(&self) -> TranscriptionStage {
        transcription_stage_from_code(self.stage.load(Ordering::Acquire))
    }

    pub fn transcribe_file(
        &self,
        audio_path: String,
        language: Option<String>,
    ) -> Result<TranscriptResult, CoreError> {
        let _run_guard = self.begin_run()?;
        let start = Instant::now();
        let audio = decode_wav_to_16khz_mono(audio_path).map_err(|error| match error {
            CoreError::AudioRead { message } => CoreError::AudioRead { message },
            CoreError::UnsupportedAudio { message } => CoreError::UnsupportedAudio { message },
            CoreError::Resample { message } => CoreError::Resample { message },
            _ => CoreError::Inference {
                message: error.to_string(),
            },
        })?;
        self.stage.store(RECOGNIZING_STAGE, Ordering::Release);
        let audio_duration_ms = (audio.len() as u64).saturating_mul(1_000) / 16_000;
        let options = RunOptions {
            language,
            ..RunOptions::default()
        };
        let transcript = self
            .session
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .run(&audio, &options)
            .map_err(map_transcription_error)?;

        Ok(TranscriptResult {
            text: crate::normalize_transcription_output(transcript.text),
            detected_language: transcript.language,
            audio_duration_ms,
            processing_duration_ms: start.elapsed().as_millis().min(u128::from(u64::MAX)) as u64,
        })
    }

    pub fn cancel(&self) {
        let active = self
            .run_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if *active {
            self.cancel_token.cancel();
        }
    }
}

impl Transcriber {
    fn begin_run(&self) -> Result<ActiveRunGuard<'_>, CoreError> {
        let mut active = self
            .run_active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if *active {
            return Err(CoreError::Busy);
        }
        self.cancel_token.reset();
        *active = true;
        self.stage.store(PREPARING_AUDIO_STAGE, Ordering::Release);
        Ok(ActiveRunGuard {
            active: &self.run_active,
            stage: &self.stage,
        })
    }
}

struct ActiveRunGuard<'a> {
    active: &'a Mutex<bool>,
    stage: &'a AtomicU8,
}

impl Drop for ActiveRunGuard<'_> {
    fn drop(&mut self) {
        self.stage.store(IDLE_STAGE, Ordering::Release);
        *self
            .active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = false;
    }
}

fn map_transcription_error(error: TranscribeError) -> CoreError {
    let failure = classify_transcription_error(&error);
    match failure.kind {
        TranscriptionFailureKind::Aborted => CoreError::Cancelled {
            partial_text: failure
                .partial
                .map(|transcript| crate::normalize_transcription_output(transcript.text)),
        },
        TranscriptionFailureKind::Truncated => CoreError::IncompleteOutput {
            kind: IncompleteOutputKind::Truncated,
            partial_text: failure
                .partial
                .map(|transcript| crate::normalize_transcription_output(transcript.text)),
        },
        TranscriptionFailureKind::Repetition => CoreError::IncompleteOutput {
            kind: IncompleteOutputKind::Repetition,
            partial_text: failure
                .partial
                .map(|transcript| crate::normalize_transcription_output(transcript.text)),
        },
        TranscriptionFailureKind::TooLong => CoreError::InputTooLong {
            message: failure.message,
        },
        TranscriptionFailureKind::Other => CoreError::Inference {
            message: failure.message,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;
    use transcribe_cpp::Transcript;

    #[test]
    fn active_run_stage_transitions_and_resets_when_guard_drops() {
        let active = Mutex::new(true);
        let stage = AtomicU8::new(PREPARING_AUDIO_STAGE);
        {
            let _guard = ActiveRunGuard {
                active: &active,
                stage: &stage,
            };
            assert_eq!(
                transcription_stage_from_code(stage.load(Ordering::Acquire)),
                TranscriptionStage::PreparingAudio
            );
            stage.store(RECOGNIZING_STAGE, Ordering::Release);
            assert_eq!(
                transcription_stage_from_code(stage.load(Ordering::Acquire)),
                TranscriptionStage::Recognizing
            );
        }

        assert_eq!(
            transcription_stage_from_code(stage.load(Ordering::Acquire)),
            TranscriptionStage::Idle
        );
        assert!(!*active.lock().unwrap());
    }

    #[test]
    fn shared_failure_classifier_keeps_kind_message_and_partial_transcript() {
        let error = TranscribeError::OutputTruncated {
            message: "generation budget reached".into(),
            partial: Some(Box::new(Transcript {
                text: "partial result".into(),
                ..Default::default()
            })),
        };

        let failure = classify_transcription_error(&error);

        assert_eq!(failure.kind, TranscriptionFailureKind::Truncated);
        assert_eq!(
            failure.message,
            "output truncated before end-of-stream: generation budget reached"
        );
        assert_eq!(
            failure.partial.as_ref().map(|part| part.text.as_str()),
            Some("partial result")
        );
    }

    #[test]
    fn shared_failure_classifier_keeps_cancellation_and_input_limit_distinct() {
        let aborted = TranscribeError::Aborted {
            message: "cancelled".into(),
            partial: Some(Box::new(Transcript {
                text: "completed chunk".into(),
                ..Default::default()
            })),
        };
        let too_long = TranscribeError::InputTooLong("duration limit".into());

        let aborted_failure = classify_transcription_error(&aborted);
        let too_long_failure = classify_transcription_error(&too_long);

        assert_eq!(aborted_failure.kind, TranscriptionFailureKind::Aborted);
        assert_eq!(
            aborted_failure
                .partial
                .as_ref()
                .map(|part| part.text.as_str()),
            Some("completed chunk")
        );
        assert_eq!(too_long_failure.kind, TranscriptionFailureKind::TooLong);
        assert!(too_long_failure.partial.is_none());
    }

    #[test]
    fn truncated_output_keeps_its_partial_transcript() {
        let error = TranscribeError::OutputTruncated {
            message: "generation budget reached".into(),
            partial: Some(Box::new(Transcript {
                text: "partial result".into(),
                ..Default::default()
            })),
        };

        assert!(matches!(
            map_transcription_error(error),
            CoreError::IncompleteOutput {
                kind: IncompleteOutputKind::Truncated,
                partial_text: Some(text),
            } if text == "partial result"
        ));
    }

    #[test]
    fn repeated_output_keeps_its_partial_transcript() {
        let error = TranscribeError::OutputRepetition {
            message: "repeated output detected".into(),
            partial: Some(Box::new(Transcript {
                text: "once, without the repeated tail".into(),
                ..Default::default()
            })),
        };

        assert!(matches!(
            map_transcription_error(error),
            CoreError::IncompleteOutput {
                kind: IncompleteOutputKind::Repetition,
                partial_text: Some(text),
            } if text == "once, without the repeated tail"
        ));
    }

    #[test]
    fn cancelled_partial_transcript_is_normalized_before_exposing_to_ui() {
        let error = TranscribeError::Aborted {
            message: "cancelled by user".into(),
            partial: Some(Box::new(Transcript {
                text: "  I I I I would   like to stop  ".into(),
                ..Default::default()
            })),
        };

        assert!(matches!(
            map_transcription_error(error),
            CoreError::Cancelled {
                partial_text: Some(text),
            } if text == "I would like to stop"
        ));
    }

    #[test]
    fn overlong_audio_maps_to_a_typed_recovery_error() {
        let error = TranscribeError::InputTooLong("audio exceeds model duration".into());

        assert!(matches!(
            map_transcription_error(error),
            CoreError::InputTooLong { .. }
        ));
    }
}

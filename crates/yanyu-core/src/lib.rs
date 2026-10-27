mod audio;
mod content_range;
pub mod gguf_meta;
mod hash;
mod history;
#[cfg(feature = "inference")]
mod inference;
mod integrity;
mod language_detection;
mod languages;
pub mod model_capabilities;
pub mod model_catalog;
mod model_discovery;
mod model_lifecycle;
mod model_order;
mod model_package;
mod output_language;
mod text;
mod transcript;
mod transcription_plan;

pub use audio::decode_wav_to_16khz_mono;
pub use content_range::{parse_content_range, validate_partial_content_range, ContentRange};
pub use hash::{compute_file_sha256, sha256_file, Sha256Accumulator, Sha256Digest};
pub use history::{paginate_history_entries, select_history_text, HistoryEntry, HistoryPage};
#[cfg(feature = "inference")]
pub use inference::{
    classify_transcription_error, Transcriber, TranscriptResult, TranscriptionFailure,
    TranscriptionFailureKind, TranscriptionStage,
};
pub use integrity::{verify_file_integrity, verify_file_integrity_at, FileIntegrity};
pub use language_detection::{detect_output_language, detect_output_language_for_text};
pub use languages::{
    canonical_language_code, canonicalize_supported_languages, effective_language,
    resolve_effective_language,
};
pub use model_capabilities::{
    derive_local_model_capabilities, probe_model_file, CapabilityProbe, Compatibility,
    LocalModelCapabilities,
};
pub use model_catalog::{
    bundled_model_catalog, catalog_mirror_fallbacks, default_quant_file, find_catalog_file,
    CatalogMirrorFile, DiskStatus, EngineType, ModelDescriptor, ModelInfo, ModelSource, QuantFile,
};
pub use model_discovery::discover_local_transcribe_models;
pub use model_lifecycle::{
    is_catalog_alternate_quant, model_should_disappear_when_missing, resolve_selected_model,
};
pub use model_order::{sort_models_by_catalog_rank, sort_models_by_catalog_rank_in_place};
pub use model_package::{
    validate_model_package_descriptor, validate_model_package_identity, ModelPackageArtifact,
    ModelPackageDescriptor,
};
pub use output_language::{
    resolve_output_language_evidence, with_model_detected_language, OutputLanguageEvidence,
};
pub use text::{
    apply_custom_words, clean_transcription_fillers, correct_transcription_custom_words,
    post_process_transcription, remove_filler_words, TranscriptPostProcessingOptions,
};
pub use transcript::{normalize_transcription_output, select_transcript_text_ref};
pub use transcription_plan::{
    build_transcribe_cpp_run_plan, TranscribeCppRunPlan, TranscriptionTask,
};

/// Describes why the native transcription engine returned incomplete output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum IncompleteOutputKind {
    /// The decoder reached its output budget before finishing.
    Truncated,
    /// The decoder stopped after detecting repeated output.
    Repetition,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("Audio file could not be read: {message}")]
    AudioRead { message: String },
    #[error("Audio format is not supported: {message}")]
    UnsupportedAudio { message: String },
    #[error("Audio could not be resampled: {message}")]
    Resample { message: String },
    #[error("The transcription model could not be loaded: {message}")]
    ModelLoad { message: String },
    #[error("Transcription failed: {message}")]
    Inference { message: String },
    #[error("Audio exceeds the model's supported duration: {message}")]
    InputTooLong { message: String },
    #[error("Transcription stopped early ({kind:?})")]
    IncompleteOutput {
        kind: IncompleteOutputKind,
        partial_text: Option<String>,
    },
    #[error("Transcription was cancelled")]
    Cancelled { partial_text: Option<String> },
    #[error("File hashing failed: {message}")]
    FileHash { message: String },
    #[error("File size mismatch: expected {expected} bytes, got {actual} bytes")]
    FileSizeMismatch { expected: u64, actual: u64 },
    #[error("SHA-256 mismatch: expected {expected}, got {actual}")]
    FileHashMismatch { expected: String, actual: String },
    #[error("Invalid expected SHA-256 digest: {message}")]
    InvalidExpectedSha256 { message: String },
    #[error("Model package manifest is invalid")]
    InvalidModelPackageManifest,
    #[error("A transcription is already running")]
    Busy,
}

uniffi::setup_scaffolding!();

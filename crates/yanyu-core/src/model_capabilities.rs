//! Model capability probing — the seam between Handy's model UI and "what can
//! this GGUF actually do".
//!
//! Capabilities are canonical *in the GGUF itself*: transcribe-cpp reads them
//! from the model's metadata at load time, and the runtime reconciles the
//! desktop registry against that ground truth once a model is loaded —
//! streaming, translation, language detection, and the supported-language set.
//! This module covers the other half — reading the same values from the GGUF header
//! *before* download, so search/listing can show them honestly ahead of a load.
//!
//! Everything goes through the [`CapabilityProber`] trait. Today the only
//! implementation, [`GgufHeaderProber`], parses a local GGUF's header directly
//! via [`crate::gguf_meta`]. If transcribe-cpp later exposes a
//! metadata-only probe (covering parakeet-style *inferred* streaming and legacy
//! `.bin`), a `TranscribeCppProber` can be dropped in behind this same trait
//! without touching any caller.

use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::gguf_meta::{self, GgufError, GgufMetadata};

/// Architecture strings transcribe-cpp can load — the `.name` of each arch under
/// its `src/arch/`, which is exactly the value stored in `general.architecture`.
/// Keep this in sync with transcribe-cpp; an arch absent here still parses, it's
/// just surfaced as [`Compatibility::MaybeIncompatible`] rather than promised.
pub const KNOWN_ARCHES: &[&str] = &[
    "whisper",
    "parakeet",
    "qwen3_asr",
    "voxtral",
    "voxtral_realtime",
    "cohere",
    "cohere_asr",
    "canary",
    "canary_qwen",
    "moonshine",
    "moonshine_streaming",
    "sensevoice",
    "gigaam",
    "granite",
    "granite_speech",
    "granite_nar",
    "granite_speech_nar",
    "funasr_nano",
    "medasr",
    "moss",
    "sortformer",
];

// GGUF metadata keys transcribe-cpp writes for ASR models.
const KEY_ARCH: &str = "general.architecture";
const KEY_NAME: &str = "general.name";
const KEY_VARIANT: &str = "stt.variant";
const KEY_LANGUAGES: &str = "general.languages";
const KEY_CAP_STREAMING: &str = "stt.capability.streaming";
const KEY_CAP_TRANSLATE: &str = "stt.capability.translate";
const KEY_CAP_LANG_DETECT: &str = "stt.capability.lang_detect";
const PROBE_KEYS: &[&str] = &[
    KEY_ARCH,
    KEY_NAME,
    KEY_VARIANT,
    KEY_LANGUAGES,
    KEY_CAP_STREAMING,
    KEY_CAP_TRANSLATE,
    KEY_CAP_LANG_DETECT,
];

/// How confident we are that Handy can run a given model, judged from its GGUF
/// header alone (pre-download).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
#[cfg_attr(feature = "desktop-specta", derive(specta::Type))]
#[serde(rename_all = "snake_case")]
pub enum Compatibility {
    /// Parsed as GGUF and the architecture is one transcribe-cpp ships.
    Compatible,
    /// Parsed as GGUF, but the architecture is unknown to us — might work.
    MaybeIncompatible,
    /// Not a GGUF we can use (bad magic, unsupported version, malformed).
    Unsupported,
    /// We haven't looked yet.
    #[default]
    Unknown,
}

/// Capabilities surfaced in the model UI. Every field is optional on purpose:
/// `None` means "not known yet" — a community model whose header omits the key,
/// or a field (parakeet streaming) the header parse can't determine. The UI
/// renders that honestly as unknown, and the runtime fills it in for real once
/// the model is loaded.
#[derive(Debug, Clone, Default, Serialize, Deserialize, uniffi::Record)]
#[cfg_attr(feature = "desktop-specta", derive(specta::Type))]
pub struct CapabilityProbe {
    pub verdict: Compatibility,
    /// `general.name`, when present.
    pub display_name: Option<String>,
    /// `general.architecture`, when present.
    pub architecture: Option<String>,
    /// `stt.variant`, when present.
    pub variant: Option<String>,
    /// `general.languages` — transcribable language codes.
    pub languages: Option<Vec<String>>,
    /// `stt.capability.streaming` — native live-streaming support.
    pub supports_streaming: Option<bool>,
    /// `stt.capability.translate` — translation to English.
    pub supports_translation: Option<bool>,
    /// `stt.capability.lang_detect` — automatic language detection.
    pub supports_language_detect: Option<bool>,
}

impl CapabilityProbe {
    /// A probe for something we definitively could not read as a usable GGUF.
    pub fn unsupported() -> Self {
        CapabilityProbe {
            verdict: Compatibility::Unsupported,
            ..Default::default()
        }
    }

    /// Build a probe from parsed GGUF metadata.
    ///
    /// Streaming for the parakeet family is *inferred* by transcribe-cpp's
    /// native loader from encoder hparams rather than a flat bool, so when the
    /// explicit `stt.capability.streaming` key is absent we leave it `None`
    /// (unknown) and let post-load reconciliation settle it — we never guess.
    pub fn from_metadata(meta: &GgufMetadata) -> Self {
        let architecture = meta.get_str(KEY_ARCH).map(str::to_string);
        let verdict = match architecture.as_deref() {
            Some(arch) if KNOWN_ARCHES.contains(&arch) => Compatibility::Compatible,
            _ => Compatibility::MaybeIncompatible,
        };
        CapabilityProbe {
            verdict,
            display_name: meta.get_str(KEY_NAME).map(str::to_string),
            architecture,
            variant: meta.get_str(KEY_VARIANT).map(str::to_string),
            languages: meta.get_string_array(KEY_LANGUAGES),
            supports_streaming: meta.get_bool(KEY_CAP_STREAMING),
            supports_translation: meta.get_bool(KEY_CAP_TRANSLATE),
            supports_language_detect: meta.get_bool(KEY_CAP_LANG_DETECT),
        }
    }
}

/// Resolved runtime capabilities for a model discovered on disk.
///
/// Missing metadata stays conservative: the runtime does not advertise a
/// capability unless the model header explicitly provides it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LocalModelCapabilities {
    pub supports_streaming: bool,
    pub supports_translation: bool,
    pub supports_language_selection: bool,
    pub supports_language_detection: bool,
    pub supported_languages: Vec<String>,
}

/// Derives the local-model capability fields shared by desktop and iOS callers.
#[uniffi::export]
pub fn derive_local_model_capabilities(probe: CapabilityProbe) -> LocalModelCapabilities {
    let supported_languages =
        crate::canonicalize_supported_languages(probe.languages.unwrap_or_default());
    LocalModelCapabilities {
        supports_streaming: probe.supports_streaming.unwrap_or(false),
        supports_translation: probe.supports_translation.unwrap_or(false),
        supports_language_selection: supported_languages.len() > 1,
        supports_language_detection: probe.supports_language_detect.unwrap_or(false),
        supported_languages,
    }
}

/// Reads model capabilities from a local GGUF's header. See the module docs for
/// the substitution story (`GgufHeaderProber` now, a transcribe-cpp-backed
/// prober later).
pub trait CapabilityProber: Send + Sync {
    /// Probe a GGUF already on disk (custom-dir + HF-cache scans, post-download).
    fn probe_file(&self, path: &Path) -> CapabilityProbe;
}

/// Pure-Rust prober backed by [`crate::gguf_meta`]. The default and,
/// for the foreseeable future, only implementation.
pub struct GgufHeaderProber;

impl CapabilityProber for GgufHeaderProber {
    fn probe_file(&self, path: &Path) -> CapabilityProbe {
        match read_header_metadata(path) {
            Ok(meta) => CapabilityProbe::from_metadata(&meta),
            Err(_) => CapabilityProbe::unsupported(),
        }
    }
}

/// Probe a local model file for GGUF architecture and transcription capabilities.
///
/// This is a metadata-only check. It does not load model tensors or determine
/// whether the model fits the current device's memory or performance limits.
#[uniffi::export]
pub fn probe_model_file(path: String) -> CapabilityProbe {
    GgufHeaderProber.probe_file(Path::new(&path))
}

/// Read just enough of `path` to parse its GGUF metadata header, without ever
/// loading the (potentially multi-GB) tensor data. Grows the prefix
/// geometrically if a header is unusually large.
fn read_header_metadata(path: &Path) -> Result<GgufMetadata, GgufError> {
    // The KV metadata block precedes the tensor-info table. Shipping ASR models
    // place all of it well within the first 64 KiB, so that's the common-case
    // read. Older / community GGUFs may carry it deeper, so the loop grows the
    // prefix geometrically (jumping straight to the size the parser reports it
    // needs) up to a hard cap.
    const INITIAL_PREFIX: usize = 64 << 10; // 64 KiB
    const MAX_PREFIX: usize = 16 << 20; // 16 MiB

    /// Read up to `size` bytes from the start of `path`, tolerating short reads.
    fn read_prefix(path: &Path, size: usize) -> std::io::Result<Vec<u8>> {
        use std::io::Read;
        let mut file = std::fs::File::open(path)?;
        let mut buf = vec![0u8; size];
        let mut filled = 0;
        while filled < buf.len() {
            match file.read(&mut buf[filled..]) {
                Ok(0) => break,
                Ok(n) => filled += n,
                Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        buf.truncate(filled);
        Ok(buf)
    }

    let mut size = INITIAL_PREFIX;
    loop {
        let buf = read_prefix(path, size).map_err(|_| GgufError::Malformed("cannot read file"))?;
        let read_len = buf.len();
        match gguf_meta::parse_header(&buf, PROBE_KEYS) {
            Ok(meta) => return Ok(meta),
            Err(GgufError::Truncated { needed }) => {
                if read_len < size {
                    // Hit EOF and still truncated → file shorter than its header.
                    return Err(GgufError::Malformed("file shorter than its header"));
                }
                let next = needed.max(size.saturating_mul(2)).min(MAX_PREFIX);
                if next <= size {
                    return Err(GgufError::Truncated { needed });
                }
                size = next;
            }
            Err(e) => return Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gguf_meta::{GgufMetadata, GgufValue};
    use std::collections::HashMap;
    use tempfile::tempdir;

    fn meta_with(kvs: Vec<(&str, GgufValue)>) -> GgufMetadata {
        let mut kv = HashMap::new();
        for (k, v) in kvs {
            kv.insert(k.to_string(), v);
        }
        GgufMetadata { kv }
    }

    fn push_gguf_string(bytes: &mut Vec<u8>, value: &str) {
        bytes.extend_from_slice(&(value.len() as u64).to_le_bytes());
        bytes.extend_from_slice(value.as_bytes());
    }

    fn minimal_gguf_with_architecture(architecture: &str) -> Vec<u8> {
        let mut bytes = b"GGUF".to_vec();
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&0u64.to_le_bytes());
        bytes.extend_from_slice(&1u64.to_le_bytes());
        push_gguf_string(&mut bytes, "general.architecture");
        bytes.extend_from_slice(&8u32.to_le_bytes()); // GGUF string value type
        push_gguf_string(&mut bytes, architecture);
        bytes
    }

    #[test]
    fn known_arch_is_compatible_and_reads_caps() {
        let meta = meta_with(vec![
            ("general.architecture", GgufValue::String("parakeet".into())),
            (
                "general.name",
                GgufValue::String("Parakeet Unified EN 0.6B".into()),
            ),
            ("stt.capability.streaming", GgufValue::Bool(true)),
            (
                "general.languages",
                GgufValue::Array(vec![GgufValue::String("en".into())]),
            ),
        ]);
        let probe = CapabilityProbe::from_metadata(&meta);
        assert_eq!(probe.verdict, Compatibility::Compatible);
        assert_eq!(
            probe.display_name.as_deref(),
            Some("Parakeet Unified EN 0.6B")
        );
        assert_eq!(probe.architecture.as_deref(), Some("parakeet"));
        assert_eq!(probe.supports_streaming, Some(true));
        assert_eq!(probe.languages, Some(vec!["en".to_string()]));
        // Absent key stays unknown rather than defaulting to false.
        assert_eq!(probe.supports_translation, None);
    }

    #[test]
    fn derives_local_model_capabilities_from_optional_probe_fields() {
        let derived = derive_local_model_capabilities(CapabilityProbe {
            languages: Some(vec![
                "en".to_string(),
                "zh-Hans".to_string(),
                "zh-Hant".to_string(),
            ]),
            supports_streaming: Some(true),
            supports_translation: None,
            supports_language_detect: Some(true),
            ..Default::default()
        });

        assert!(derived.supports_streaming);
        assert!(!derived.supports_translation);
        assert!(derived.supports_language_selection);
        assert!(derived.supports_language_detection);
        assert_eq!(derived.supported_languages, vec!["en", "zh"]);
    }

    #[test]
    fn does_not_offer_language_selection_for_one_language() {
        let derived = derive_local_model_capabilities(CapabilityProbe {
            languages: Some(vec!["en".to_string()]),
            ..Default::default()
        });

        assert!(!derived.supports_language_selection);
        assert_eq!(derived.supported_languages, vec!["en"]);
    }

    #[test]
    fn unknown_arch_is_maybe_incompatible() {
        let meta = meta_with(vec![(
            "general.architecture",
            GgufValue::String("llama".into()),
        )]);
        assert_eq!(
            CapabilityProbe::from_metadata(&meta).verdict,
            Compatibility::MaybeIncompatible
        );
    }

    #[test]
    fn probes_a_local_gguf_header_without_loading_tensor_data() {
        let directory = tempdir().expect("create temporary model directory");
        let model_path = directory.path().join("whisper.gguf");
        std::fs::write(&model_path, minimal_gguf_with_architecture("whisper"))
            .expect("write minimal GGUF model header");

        let probe = GgufHeaderProber.probe_file(&model_path);

        assert_eq!(probe.verdict, Compatibility::Compatible);
        assert_eq!(probe.architecture.as_deref(), Some("whisper"));
    }
}

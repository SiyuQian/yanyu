use crate::model_capabilities::{CapabilityProbe, CapabilityProber, GgufHeaderProber};
use crate::{DiskStatus, EngineType, ModelDescriptor, ModelInfo, ModelSource};
use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::Path;

/// Discovers local transcribe-cpp `.bin` and `.gguf` model files.
///
/// Existing transcribe-cpp models are used to skip predefined filenames and
/// IDs already represented by the caller. Catalog descriptors preserve their
/// catalog metadata when an alternate quant is found on disk. Directory
/// ownership, catalog loading, and logging remain the responsibility of the
/// calling application.
pub fn discover_local_transcribe_models(
    models_dir: &Path,
    existing_models: &[ModelInfo],
    catalog: &[ModelDescriptor],
) -> io::Result<Vec<ModelInfo>> {
    if !models_dir.exists() {
        return Ok(Vec::new());
    }

    let predefined_filenames = existing_models
        .iter()
        .filter(|model| {
            matches!(model.engine_type, EngineType::TranscribeCpp) && !model.is_directory
        })
        .map(|model| model.filename.clone())
        .collect::<HashSet<_>>();
    let mut known_ids = existing_models
        .iter()
        .map(|model| model.id.clone())
        .collect::<HashSet<_>>();
    let mut discovered = Vec::new();

    for entry in fs::read_dir(models_dir)? {
        let Ok(entry) = entry else {
            // A concurrently removed or unreadable entry should not prevent the
            // rest of the user's models from being discovered.
            continue;
        };
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let Some(filename) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if filename.starts_with('.') {
            continue;
        }

        let (model_id, is_gguf) = if let Some(stem) = filename.strip_suffix(".bin") {
            (stem.to_string(), false)
        } else if let Some(stem) = filename.strip_suffix(".gguf") {
            (stem.to_string(), true)
        } else {
            continue;
        };

        if predefined_filenames.contains(filename) {
            continue;
        }

        if let Some((descriptor, file)) = crate::find_catalog_file(filename, None, catalog) {
            let model = descriptor.to_model_info_for_file(
                file,
                &DiskStatus {
                    is_downloaded: true,
                    ..Default::default()
                },
            );
            if known_ids.insert(model.id.clone()) {
                discovered.push(model);
            }
            continue;
        }

        if !known_ids.insert(model_id.clone()) {
            continue;
        }

        let fallback_name = model_id
            .replace(['-', '_'], " ")
            .split_whitespace()
            .map(|word| {
                let mut chars = word.chars();
                match chars.next() {
                    None => String::new(),
                    Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
        let size_mb = path
            .metadata()
            .map(|metadata| metadata.len() / (1024 * 1024))
            .unwrap_or_default();
        let probe = if is_gguf {
            GgufHeaderProber.probe_file(&path)
        } else {
            CapabilityProbe::default()
        };
        let capabilities = crate::derive_local_model_capabilities(probe.clone());
        let display_name = probe
            .display_name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or(&fallback_name)
            .to_string();

        discovered.push(ModelInfo {
            id: model_id,
            name: display_name,
            description: "Not officially supported".to_string(),
            filename: filename.to_string(),
            source: ModelSource::Local,
            size_mb,
            is_downloaded: true,
            is_downloading: false,
            partial_size: 0,
            is_directory: false,
            engine_type: EngineType::TranscribeCpp,
            accuracy_score: 0.0,
            speed_score: 0.0,
            supports_translation: capabilities.supports_translation,
            is_recommended: false,
            supported_languages: capabilities.supported_languages,
            supports_language_selection: capabilities.supports_language_selection,
            is_custom: true,
            supports_streaming: capabilities.supports_streaming,
            supports_language_detection: capabilities.supports_language_detection,
        });
    }

    Ok(discovered)
}

#[cfg(test)]
mod tests {
    use super::discover_local_transcribe_models;
    use crate::{
        CapabilityProbe, DiskStatus, EngineType, ModelDescriptor, ModelInfo, ModelSource, QuantFile,
    };
    use std::fs;
    use tempfile::TempDir;

    fn existing_model(id: &str, filename: &str) -> ModelInfo {
        ModelInfo {
            id: id.to_string(),
            name: id.to_string(),
            description: String::new(),
            filename: filename.to_string(),
            source: ModelSource::Local,
            size_mb: 0,
            is_downloaded: false,
            is_downloading: false,
            partial_size: 0,
            is_directory: false,
            engine_type: EngineType::TranscribeCpp,
            accuracy_score: 0.0,
            speed_score: 0.0,
            supports_translation: false,
            is_recommended: false,
            supported_languages: Vec::new(),
            supports_language_selection: false,
            is_custom: false,
            supports_streaming: false,
            supports_language_detection: false,
        }
    }

    fn descriptor() -> ModelDescriptor {
        ModelDescriptor {
            id: "org/repo/model-Q8_0.gguf".to_string(),
            source: ModelSource::HuggingFace {
                repo_id: "org/repo".to_string(),
                revision: "main".to_string(),
            },
            name: "Catalog model".to_string(),
            description: "Catalog description".to_string(),
            engine_type: EngineType::TranscribeCpp,
            caps: CapabilityProbe::default(),
            files: vec![
                QuantFile {
                    filename: "model-Q4_K_M.gguf".to_string(),
                    quant: "Q4_K_M".to_string(),
                    size_bytes: 10,
                    sha256: None,
                },
                QuantFile {
                    filename: "model-Q8_0.gguf".to_string(),
                    quant: "Q8_0".to_string(),
                    size_bytes: 20,
                    sha256: None,
                },
            ],
            default_quant: Some("Q8_0".to_string()),
            speed_score: 0.5,
            accuracy_score: 0.5,
            recommended_rank: Some(1),
            recommended: true,
        }
    }

    fn gguf_with_name(name: &str) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"GGUF");
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&0u64.to_le_bytes());
        bytes.extend_from_slice(&1u64.to_le_bytes());
        for value in ["general.name", name] {
            bytes.extend_from_slice(&(value.len() as u64).to_le_bytes());
            bytes.extend_from_slice(value.as_bytes());
            if value == "general.name" {
                bytes.extend_from_slice(&8u32.to_le_bytes());
            }
        }
        bytes
    }

    #[test]
    fn discovers_custom_bin_and_gguf_files_and_skips_unrelated_entries() {
        let directory = TempDir::new().unwrap();
        fs::write(directory.path().join("my-custom-model.bin"), b"model").unwrap();
        fs::write(
            directory.path().join("friendly_model.gguf"),
            gguf_with_name("Friendly model"),
        )
        .unwrap();
        fs::write(directory.path().join(".hidden.bin"), b"hidden").unwrap();
        fs::write(directory.path().join("download.bin.partial"), b"partial").unwrap();
        fs::write(directory.path().join("notes.txt"), b"text").unwrap();
        fs::create_dir(directory.path().join("folder.bin")).unwrap();
        fs::write(directory.path().join("ggml-small.bin"), b"predefined").unwrap();
        fs::write(directory.path().join("existing-id.bin"), b"duplicate").unwrap();

        let existing = [
            existing_model("small", "ggml-small.bin"),
            existing_model("existing-id", "old-name.bin"),
        ];
        let discovered =
            discover_local_transcribe_models(directory.path(), &existing, &[]).unwrap();
        let by_id = discovered
            .iter()
            .map(|model| (model.id.as_str(), model))
            .collect::<std::collections::HashMap<_, _>>();

        assert_eq!(by_id.len(), 2);
        let custom = by_id.get("my-custom-model").unwrap();
        assert_eq!(custom.name, "My Custom Model");
        assert_eq!(custom.filename, "my-custom-model.bin");
        assert!(custom.is_custom);
        assert!(custom.is_downloaded);
        assert!(matches!(custom.source, ModelSource::Local));

        let gguf = by_id.get("friendly_model").unwrap();
        assert_eq!(gguf.name, "Friendly model");
        assert_eq!(gguf.filename, "friendly_model.gguf");
        assert!(gguf.is_custom);
    }

    #[test]
    fn discovers_catalog_alternate_quant_but_deduplicates_default_quant() {
        let directory = TempDir::new().unwrap();
        fs::write(directory.path().join("model-Q4_K_M.gguf"), b"").unwrap();
        fs::write(directory.path().join("model-Q8_0.gguf"), b"").unwrap();
        let catalog = [descriptor()];
        let default_info = catalog[0].to_model_info(&DiskStatus::default());

        let discovered = discover_local_transcribe_models(
            directory.path(),
            std::slice::from_ref(&default_info),
            &catalog,
        )
        .unwrap();

        assert_eq!(discovered.len(), 1);
        assert_eq!(discovered[0].id, "org/repo/model-Q4_K_M.gguf");
        assert_eq!(discovered[0].name, "Catalog model (Q4_K_M)");
        assert_eq!(discovered[0].description, "Catalog description");
        assert!(discovered[0].is_downloaded);
        assert!(!discovered[0].is_custom);
    }

    #[test]
    fn missing_models_directory_returns_no_discoveries() {
        let directory = TempDir::new().unwrap();
        let missing = directory.path().join("missing");

        assert!(discover_local_transcribe_models(&missing, &[], &[])
            .unwrap()
            .is_empty());
    }
}

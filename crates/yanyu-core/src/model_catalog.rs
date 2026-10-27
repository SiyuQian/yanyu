use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};

use crate::{derive_local_model_capabilities, CapabilityProbe};

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Enum)]
#[cfg_attr(feature = "desktop-specta", derive(specta::Type))]
pub enum EngineType {
    /// Any GGML/GGUF model loaded through transcribe-cpp. The architecture is
    /// auto-detected from the model file.
    TranscribeCpp,
    Parakeet,
    Moonshine,
    MoonshineStreaming,
    SenseVoice,
    GigaAM,
    Canary,
    Cohere,
}

/// Where a model comes from and how an app obtains it.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Enum)]
#[cfg_attr(feature = "desktop-specta", derive(specta::Type))]
pub enum ModelSource {
    /// Direct HTTP download from a model host.
    Url {
        url: String,
        /// Expected SHA-256 for integrity verification; `None` skips it.
        sha256: Option<String>,
    },
    /// A file inside a Hugging Face Hub repo.
    HuggingFace { repo_id: String, revision: String },
    /// Already present on disk, such as a user-provided custom model.
    Local,
}

/// Runtime model data presented to a Yanyu application.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
#[cfg_attr(feature = "desktop-specta", derive(specta::Type))]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub description: String,
    pub filename: String,
    pub source: ModelSource,
    pub size_mb: u64,
    pub is_downloaded: bool,
    pub is_downloading: bool,
    pub partial_size: u64,
    pub is_directory: bool,
    pub engine_type: EngineType,
    pub accuracy_score: f32,
    pub speed_score: f32,
    pub supports_translation: bool,
    pub is_recommended: bool,
    pub supported_languages: Vec<String>,
    pub supports_language_selection: bool,
    pub is_custom: bool,
    pub supports_streaming: bool,
    pub supports_language_detection: bool,
}

/// One downloadable quantization of a model, matching a `files[]` catalog item.
#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct QuantFile {
    pub filename: String,
    pub quant: String,
    pub size_bytes: u64,
    /// Content SHA-256; `None` only for catalogs predating the field.
    #[serde(default)]
    pub sha256: Option<String>,
}

/// Selects the declared default quantization, or the first available file.
pub fn default_quant_file<'a>(
    files: &'a [QuantFile],
    default_quant: Option<&str>,
) -> Option<&'a QuantFile> {
    files
        .iter()
        .find(|file| Some(file.quant.as_str()) == default_quant)
        .or_else(|| files.first())
}

/// Live disk/download status kept separate from static model specifications.
#[derive(Debug, Clone, Default)]
pub struct DiskStatus {
    pub is_downloaded: bool,
    pub is_downloading: bool,
    pub partial_size: u64,
}

/// A source-independent model specification rendered with live disk status.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ModelDescriptor {
    pub id: String,
    pub source: ModelSource,
    pub name: String,
    pub description: String,
    pub engine_type: EngineType,
    pub caps: CapabilityProbe,
    pub files: Vec<QuantFile>,
    pub default_quant: Option<String>,
    pub speed_score: f32,
    pub accuracy_score: f32,
    /// Editorial sort priority across the whole catalog (lower is higher).
    pub recommended_rank: Option<u32>,
    /// Whether new users see this model in the curated recommendation set.
    pub recommended: bool,
}

#[derive(Debug, Deserialize)]
struct CatalogRoot {
    #[serde(default)]
    mirrors: Vec<String>,
    models: Vec<CatalogModel>,
}

#[derive(Debug, Deserialize)]
struct CatalogModel {
    id: String,
    revision: Option<String>,
    name: String,
    description: String,
    architecture: Option<String>,
    languages: Vec<String>,
    capabilities: CatalogCapabilities,
    speed_score: Option<f32>,
    accuracy_score: Option<f32>,
    files: Vec<QuantFile>,
    default_quant: Option<String>,
    recommended_rank: Option<u32>,
    #[serde(default)]
    recommended: bool,
}

#[derive(Debug, Deserialize)]
struct CatalogCapabilities {
    streaming: bool,
    translate: bool,
    lang_detect: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CatalogMirrorFile {
    pub url: String,
    pub sha256: String,
    pub size_bytes: u64,
}

static CATALOG_ROOT: Lazy<CatalogRoot> = Lazy::new(|| {
    serde_json::from_str(include_str!("../resources/catalog.json"))
        .expect("bundled catalog.json is valid JSON matching the catalog schema")
});

/// The canonical, version-pinned model catalog shared by desktop and iOS.
pub static CATALOG: Lazy<Vec<ModelDescriptor>> = Lazy::new(|| {
    CATALOG_ROOT
        .models
        .iter()
        .map(|model| {
            let default_filename = default_quant_file(&model.files, model.default_quant.as_deref())
                .map(|file| file.filename.clone())
                .unwrap_or_default();
            ModelDescriptor {
                id: format!("{}/{}", model.id, default_filename),
                source: ModelSource::HuggingFace {
                    repo_id: model.id.clone(),
                    revision: model.revision.clone().unwrap_or_else(|| "main".to_owned()),
                },
                name: model.name.clone(),
                description: model.description.clone(),
                engine_type: EngineType::TranscribeCpp,
                caps: CapabilityProbe {
                    verdict: crate::Compatibility::Compatible,
                    display_name: None,
                    architecture: model.architecture.clone(),
                    variant: None,
                    languages: Some(model.languages.clone()),
                    supports_streaming: Some(model.capabilities.streaming),
                    supports_translation: Some(model.capabilities.translate),
                    supports_language_detect: Some(model.capabilities.lang_detect),
                },
                files: model.files.clone(),
                default_quant: model.default_quant.clone(),
                speed_score: model.speed_score.unwrap_or_default() / 100.0,
                accuracy_score: model.accuracy_score.unwrap_or_default() / 100.0,
                recommended_rank: model.recommended_rank,
                recommended: model.recommended,
            }
        })
        .collect()
});

/// Returns an owned snapshot for generated Swift bindings.
#[uniffi::export]
pub fn bundled_model_catalog() -> Vec<ModelDescriptor> {
    CATALOG.clone()
}

/// Returns immutable mirror fallbacks, each pinned to the bundled artifact hash.
pub fn catalog_mirror_fallbacks(model_id: &str) -> Vec<CatalogMirrorFile> {
    let Some((model, file)) = CATALOG_ROOT.models.iter().find_map(|model| {
        model
            .files
            .iter()
            .find(|file| format!("{}/{}", model.id, file.filename) == model_id)
            .map(|file| (model, file))
    }) else {
        return Vec::new();
    };
    let Some(revision) = model.revision.as_deref() else {
        return Vec::new();
    };
    let Some(sha256) = file.sha256.as_deref() else {
        return Vec::new();
    };

    CATALOG_ROOT
        .mirrors
        .iter()
        .map(|base| CatalogMirrorFile {
            url: format!(
                "{}/{}/{}/{}",
                base.trim_end_matches('/'),
                model.id,
                revision,
                file.filename
            ),
            sha256: sha256.to_owned(),
            size_bytes: file.size_bytes,
        })
        .collect()
}

impl ModelDescriptor {
    pub fn default_file(&self) -> Option<&QuantFile> {
        default_quant_file(&self.files, self.default_quant.as_deref())
    }

    /// Renders the default quantization with the supplied current disk status.
    pub fn to_model_info(&self, status: &DiskStatus) -> ModelInfo {
        self.render_model_info(self.default_file(), status)
    }

    /// Renders one specific quantization, preserving catalog metadata.
    pub fn to_model_info_for_file(&self, file: &QuantFile, status: &DiskStatus) -> ModelInfo {
        self.render_model_info(Some(file), status)
    }

    fn render_model_info(&self, file: Option<&QuantFile>, status: &DiskStatus) -> ModelInfo {
        let is_default = match (file, self.default_file()) {
            (Some(file), Some(default_file)) => file.filename == default_file.filename,
            _ => true,
        };
        let id = match (&self.source, file) {
            (ModelSource::HuggingFace { repo_id, .. }, Some(file)) => {
                format!("{repo_id}/{}", file.filename)
            }
            _ => self.id.clone(),
        };
        let name = if is_default {
            self.name.clone()
        } else {
            format!(
                "{} ({})",
                self.name,
                file.map(|file| file.quant.as_str()).unwrap_or("")
            )
        };
        let capabilities = derive_local_model_capabilities(self.caps.clone());

        ModelInfo {
            id,
            name,
            description: self.description.clone(),
            filename: file.map(|file| file.filename.clone()).unwrap_or_default(),
            source: self.source.clone(),
            size_mb: file
                .map(|file| file.size_bytes / (1024 * 1024))
                .unwrap_or(0),
            is_downloaded: status.is_downloaded,
            is_downloading: status.is_downloading,
            partial_size: status.partial_size,
            is_directory: false,
            engine_type: self.engine_type.clone(),
            accuracy_score: self.accuracy_score,
            speed_score: self.speed_score,
            supports_translation: capabilities.supports_translation,
            is_recommended: self.recommended && is_default,
            supported_languages: capabilities.supported_languages,
            supports_language_selection: capabilities.supports_language_selection,
            is_custom: false,
            supports_streaming: capabilities.supports_streaming,
            supports_language_detection: capabilities.supports_language_detection,
        }
    }
}

/// Finds a catalog entry for any listed quantization by filename.
///
/// When `repo_id` is provided, a matching filename from any other source or
/// repository is rejected. Passing `None` searches all descriptors, matching
/// local models discovered outside a specific repository context.
pub fn find_catalog_file<'a>(
    filename: &str,
    repo_id: Option<&str>,
    catalog: &'a [ModelDescriptor],
) -> Option<(&'a ModelDescriptor, &'a QuantFile)> {
    catalog.iter().find_map(|descriptor| {
        if let Some(repo_id) = repo_id {
            match &descriptor.source {
                ModelSource::HuggingFace {
                    repo_id: descriptor_repo,
                    ..
                } if descriptor_repo == repo_id => {}
                _ => return None,
            }
        }
        descriptor
            .files
            .iter()
            .find(|file| file.filename == filename)
            .map(|file| (descriptor, file))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn descriptor() -> ModelDescriptor {
        ModelDescriptor {
            id: "org/repo/model-Q8_0.gguf".to_string(),
            source: ModelSource::HuggingFace {
                repo_id: "org/repo".to_string(),
                revision: "main".to_string(),
            },
            name: "Model".to_string(),
            description: "desc".to_string(),
            engine_type: EngineType::TranscribeCpp,
            caps: CapabilityProbe {
                languages: Some(vec!["en".to_string(), "zh-Hans".to_string()]),
                supports_streaming: Some(true),
                supports_translation: Some(false),
                supports_language_detect: Some(true),
                ..Default::default()
            },
            files: vec![
                QuantFile {
                    filename: "model-Q4_K_M.gguf".to_string(),
                    quant: "Q4_K_M".to_string(),
                    size_bytes: 1,
                    sha256: None,
                },
                QuantFile {
                    filename: "model-Q8_0.gguf".to_string(),
                    quant: "Q8_0".to_string(),
                    size_bytes: 2 * 1024 * 1024,
                    sha256: Some("digest".to_string()),
                },
            ],
            default_quant: Some("Q8_0".to_string()),
            speed_score: 0.5,
            accuracy_score: 0.75,
            recommended_rank: Some(1),
            recommended: true,
        }
    }

    #[test]
    fn renders_default_model_info_with_live_status_and_capabilities() {
        let descriptor = descriptor();
        let status = DiskStatus {
            is_downloaded: true,
            is_downloading: false,
            partial_size: 0,
        };

        let info = descriptor.to_model_info(&status);

        assert_eq!(info.id, "org/repo/model-Q8_0.gguf");
        assert_eq!(info.name, "Model");
        assert_eq!(info.filename, "model-Q8_0.gguf");
        assert_eq!(info.size_mb, 2);
        assert!(info.is_downloaded);
        assert!(info.is_recommended);
        assert_eq!(info.supported_languages, vec!["en", "zh"]);
        assert!(info.supports_language_selection);
        assert!(info.supports_streaming);
        assert!(info.supports_language_detection);
    }

    #[test]
    fn renders_alternate_quant_without_default_recommendation() {
        let descriptor = descriptor();
        let info = descriptor.to_model_info_for_file(&descriptor.files[0], &DiskStatus::default());

        assert_eq!(info.id, "org/repo/model-Q4_K_M.gguf");
        assert_eq!(info.name, "Model (Q4_K_M)");
        assert_eq!(info.filename, "model-Q4_K_M.gguf");
        assert_eq!(info.size_mb, 0);
        assert!(!info.is_recommended);
        assert!(!info.is_custom);
    }

    #[test]
    fn quant_selection_uses_declared_default_then_first_file() {
        let descriptor = descriptor();
        assert_eq!(
            default_quant_file(&descriptor.files, Some("Q8_0")).map(|file| file.filename.as_str()),
            Some("model-Q8_0.gguf")
        );
        assert_eq!(
            default_quant_file(&descriptor.files, Some("missing"))
                .map(|file| file.filename.as_str()),
            Some("model-Q4_K_M.gguf")
        );
        assert!(default_quant_file(&[], None).is_none());
    }

    #[test]
    fn catalog_file_lookup_matches_any_quant_and_can_require_a_repository() {
        let catalog = [descriptor()];

        let (matched_descriptor, matched_file) =
            find_catalog_file("model-Q4_K_M.gguf", Some("org/repo"), &catalog).unwrap();
        assert_eq!(matched_descriptor.name, "Model");
        assert_eq!(matched_file.quant, "Q4_K_M");
        assert!(find_catalog_file("model-Q4_K_M.gguf", Some("org/other"), &catalog).is_none());
        assert!(find_catalog_file("unlisted.gguf", None, &catalog).is_none());
    }

    #[test]
    fn bundled_catalog_exposes_pinned_download_metadata_to_all_app_shells() {
        let catalog = super::bundled_model_catalog();
        assert!(!catalog.is_empty());

        let mut ids = catalog
            .iter()
            .map(|model| model.id.as_str())
            .collect::<Vec<_>>();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), catalog.len());

        let qwen = catalog
            .iter()
            .find(|model| model.name == "Qwen3-ASR 0.6B")
            .expect("the current evaluation model remains in the shared catalog");
        assert_eq!(qwen.recommended_rank, Some(9));
        assert_eq!(qwen.default_quant.as_deref(), Some("Q8_0"));
        assert!(qwen.files.iter().all(|file| file.sha256.is_some()));
    }
}

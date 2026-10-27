use crate::{ModelDescriptor, ModelInfo, ModelSource};

/// Reports whether a catalog file is an alternate quant rather than its
/// descriptor's default file.
pub fn is_catalog_alternate_quant(
    repo_id: &str,
    filename: &str,
    catalog: &[ModelDescriptor],
) -> bool {
    crate::find_catalog_file(filename, Some(repo_id), catalog).is_some_and(|(descriptor, file)| {
        descriptor
            .default_file()
            .is_some_and(|default_file| default_file.filename != file.filename)
    })
}

/// Whether a model registry entry should be removed after its local file is
/// gone. Custom files and non-default catalog quants exist only while present
/// on disk; downloadable defaults and legacy/unknown remote models stay listed.
pub fn model_should_disappear_when_missing(model: &ModelInfo, catalog: &[ModelDescriptor]) -> bool {
    model.is_custom
        || match &model.source {
            ModelSource::HuggingFace { repo_id, .. } => {
                is_catalog_alternate_quant(repo_id, &model.filename, catalog)
            }
            _ => false,
        }
}

/// Resolves the selected model from the current ranked model list.
///
/// An installed current selection is retained. Missing selections are cleared;
/// a replacement is chosen only after onboarding, using the order supplied by
/// the caller (which should match the order shown in its model picker).
pub fn resolve_selected_model(
    selected_model_id: &str,
    onboarding_completed: bool,
    available_models: &[ModelInfo],
) -> Option<String> {
    if !selected_model_id.is_empty()
        && available_models
            .iter()
            .any(|model| model.id == selected_model_id && model.is_downloaded)
    {
        return Some(selected_model_id.to_string());
    }

    if !onboarding_completed {
        return None;
    }

    available_models
        .iter()
        .find(|model| model.is_downloaded)
        .map(|model| model.id.clone())
}

#[cfg(test)]
mod tests {
    use super::{
        is_catalog_alternate_quant, model_should_disappear_when_missing, resolve_selected_model,
    };
    use crate::{CapabilityProbe, EngineType, ModelDescriptor, ModelInfo, ModelSource, QuantFile};

    fn model(id: &str, is_downloaded: bool) -> ModelInfo {
        ModelInfo {
            id: id.to_string(),
            name: id.to_string(),
            description: String::new(),
            filename: String::new(),
            source: ModelSource::Local,
            size_mb: 0,
            is_downloaded,
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
            is_custom: true,
            supports_streaming: false,
            supports_language_detection: false,
        }
    }

    fn catalog_model(repo_id: &str, filename: &str) -> ModelInfo {
        let mut model = model(&format!("{repo_id}/{filename}"), false);
        model.source = ModelSource::HuggingFace {
            repo_id: repo_id.to_string(),
            revision: "main".to_string(),
        };
        model.filename = filename.to_string();
        model.is_custom = false;
        model
    }

    fn catalog_descriptor() -> ModelDescriptor {
        ModelDescriptor {
            id: "org/repo/model-Q8_0.gguf".to_string(),
            source: ModelSource::HuggingFace {
                repo_id: "org/repo".to_string(),
                revision: "main".to_string(),
            },
            name: "Model".to_string(),
            description: "Test model".to_string(),
            engine_type: EngineType::TranscribeCpp,
            caps: CapabilityProbe::default(),
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
                    size_bytes: 2,
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

    #[test]
    fn keeps_the_selected_model_when_its_files_are_available() {
        let models = [model("first", true), model("selected", true)];

        assert_eq!(
            resolve_selected_model("selected", true, &models),
            Some("selected".to_string())
        );
    }

    #[test]
    fn does_not_auto_select_while_onboarding_is_pending() {
        let models = [model("downloaded", true)];

        assert_eq!(resolve_selected_model("", false, &models), None);
    }

    #[test]
    fn clears_a_missing_selection_without_replacing_it_during_onboarding() {
        let models = [model("downloaded", true)];

        assert_eq!(
            resolve_selected_model("removed-model", false, &models),
            None
        );
    }

    #[test]
    fn selects_the_first_downloaded_model_after_onboarding() {
        let models = [
            model("not-downloaded", false),
            model("first-downloaded", true),
            model("second-downloaded", true),
        ];

        assert_eq!(
            resolve_selected_model("removed-model", true, &models),
            Some("first-downloaded".to_string())
        );
    }

    #[test]
    fn clears_a_missing_selection_when_no_model_is_downloaded() {
        let models = [model("not-downloaded", false)];

        assert_eq!(resolve_selected_model("removed-model", true, &models), None);
    }

    #[test]
    fn removes_custom_models_when_their_files_are_missing() {
        let custom_model = model("custom", false);

        assert!(model_should_disappear_when_missing(&custom_model, &[]));
    }

    #[test]
    fn keeps_downloadable_catalog_defaults_when_their_files_are_missing() {
        let catalog = [catalog_descriptor()];
        let default_model = catalog_model("org/repo", "model-Q8_0.gguf");

        assert!(!model_should_disappear_when_missing(
            &default_model,
            &catalog
        ));
    }

    #[test]
    fn identifies_non_default_catalog_quants_as_disk_only_entries() {
        let catalog = [catalog_descriptor()];
        let alternate_model = catalog_model("org/repo", "model-Q4_K_M.gguf");

        assert!(is_catalog_alternate_quant(
            "org/repo",
            "model-Q4_K_M.gguf",
            &catalog
        ));
        assert!(model_should_disappear_when_missing(
            &alternate_model,
            &catalog
        ));
    }

    #[test]
    fn keeps_unknown_or_foreign_hub_models_when_their_files_are_missing() {
        let catalog = [catalog_descriptor()];
        let unknown_model = catalog_model("org/other", "model-Q4_K_M.gguf");
        let unknown_filename = catalog_model("org/repo", "other.gguf");

        assert!(!model_should_disappear_when_missing(
            &unknown_model,
            &catalog
        ));
        assert!(!model_should_disappear_when_missing(
            &unknown_filename,
            &catalog
        ));
    }

    #[test]
    fn keeps_non_custom_url_models_when_their_files_are_missing() {
        let mut model = model("legacy", false);
        model.is_custom = false;
        model.source = ModelSource::Url {
            url: "https://example.com/model.bin".to_string(),
            sha256: None,
        };

        assert!(!model_should_disappear_when_missing(&model, &[]));
    }
}

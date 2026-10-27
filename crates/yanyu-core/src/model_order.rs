use std::collections::HashMap;

use crate::{ModelDescriptor, ModelInfo};

/// Sorts models using the same display order as the catalog-backed model picker:
/// editorial rank, recommended status, accuracy, speed, then name. Unknown and
/// unranked IDs sort after catalog-ranked models.
pub fn sort_models_by_catalog_rank_in_place(models: &mut [ModelInfo], catalog: &[ModelDescriptor]) {
    let rank_by_id = catalog
        .iter()
        .filter_map(|descriptor| {
            descriptor
                .recommended_rank
                .map(|rank| (descriptor.id.as_str(), rank))
        })
        .collect::<HashMap<_, _>>();

    models.sort_by(|left, right| {
        rank_by_id
            .get(left.id.as_str())
            .copied()
            .unwrap_or(u32::MAX)
            .cmp(
                &rank_by_id
                    .get(right.id.as_str())
                    .copied()
                    .unwrap_or(u32::MAX),
            )
            .then((!left.is_recommended).cmp(&(!right.is_recommended)))
            .then(right.accuracy_score.total_cmp(&left.accuracy_score))
            .then(right.speed_score.total_cmp(&left.speed_score))
            .then_with(|| left.name.cmp(&right.name))
    });
}

/// Sorts an owned model list through the Swift-facing API.
#[uniffi::export]
pub fn sort_models_by_catalog_rank(
    mut models: Vec<ModelInfo>,
    catalog: Vec<ModelDescriptor>,
) -> Vec<ModelInfo> {
    sort_models_by_catalog_rank_in_place(&mut models, &catalog);
    models
}

#[cfg(test)]
mod tests {
    use super::sort_models_by_catalog_rank;
    use crate::{CapabilityProbe, EngineType, ModelDescriptor, ModelInfo, ModelSource};

    fn model(id: &str, recommended: bool, accuracy: f32, speed: f32) -> ModelInfo {
        ModelInfo {
            id: id.to_string(),
            name: id.to_string(),
            description: String::new(),
            filename: String::new(),
            source: ModelSource::Local,
            size_mb: 0,
            is_downloaded: true,
            is_downloading: false,
            partial_size: 0,
            is_directory: false,
            engine_type: EngineType::TranscribeCpp,
            accuracy_score: accuracy,
            speed_score: speed,
            supports_translation: false,
            is_recommended: recommended,
            supported_languages: Vec::new(),
            supports_language_selection: false,
            is_custom: false,
            supports_streaming: false,
            supports_language_detection: false,
        }
    }

    fn descriptor(id: &str, recommended_rank: Option<u32>) -> ModelDescriptor {
        ModelDescriptor {
            id: id.to_string(),
            source: ModelSource::Local,
            name: id.to_string(),
            description: String::new(),
            engine_type: EngineType::TranscribeCpp,
            caps: CapabilityProbe::default(),
            files: Vec::new(),
            default_quant: None,
            speed_score: 0.0,
            accuracy_score: 0.0,
            recommended_rank,
            recommended: false,
        }
    }

    fn ids(models: Vec<ModelInfo>) -> Vec<String> {
        models.into_iter().map(|model| model.id).collect()
    }

    #[test]
    fn catalog_rank_precedes_recommended_status_and_scores() {
        let catalog = [
            descriptor("ranked-first", Some(1)),
            descriptor("ranked-later", Some(2)),
        ];
        let models = vec![
            model("unranked-recommended", true, 1.0, 1.0),
            model("ranked-later", false, 0.0, 0.0),
            model("ranked-first", false, 0.0, 0.0),
        ];

        let models = sort_models_by_catalog_rank(models, catalog.to_vec());

        assert_eq!(
            ids(models),
            ["ranked-first", "ranked-later", "unranked-recommended"]
        );
    }

    #[test]
    fn unranked_models_sort_by_recommendation_accuracy_speed_then_name() {
        let models = vec![
            model("accuracy-high", false, 0.9, 0.1),
            model("recommended-low", true, 0.1, 0.0),
            model("accuracy-tie-slow", false, 0.8, 0.2),
            model("name-z", false, 0.8, 0.8),
            model("name-a", false, 0.8, 0.8),
            model("accuracy-tie-fast", false, 0.8, 0.8),
        ];

        let models = sort_models_by_catalog_rank(models, Vec::new());

        assert_eq!(
            ids(models),
            [
                "recommended-low",
                "accuracy-high",
                "accuracy-tie-fast",
                "name-a",
                "name-z",
                "accuracy-tie-slow",
            ]
        );
    }
}

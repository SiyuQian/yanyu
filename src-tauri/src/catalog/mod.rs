//! Desktop access to the canonical model catalog bundled in `yanyu-core`.

use once_cell::sync::Lazy;

pub use yanyu_core::{CatalogMirrorFile as MirrorFile, ModelDescriptor, QuantFile};

/// The shared catalog, parsed once by the portable Rust core.
pub static CATALOG: Lazy<Vec<ModelDescriptor>> = Lazy::new(yanyu_core::bundled_model_catalog);

/// Ordered mirror URLs for a catalog model file, pinned to the catalog's hash.
pub fn mirror_fallbacks(model_id: &str) -> Vec<MirrorFile> {
    yanyu_core::catalog_mirror_fallbacks(model_id)
}

/// Finds any catalog quant by filename, optionally requiring an exact repository match.
pub fn file_in_catalog(
    filename: &str,
    repo_id: Option<&str>,
) -> Option<(&'static ModelDescriptor, &'static QuantFile)> {
    yanyu_core::find_catalog_file(filename, repo_id, CATALOG.as_slice())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managers::model_capabilities::KNOWN_ARCHES;
    use std::collections::BTreeSet;

    #[test]
    fn catalog_parses_and_is_nonempty() {
        assert!(!CATALOG.is_empty(), "bundled catalog should contain models");
    }

    #[test]
    fn ids_are_unique() {
        let mut ids: Vec<&str> = CATALOG
            .iter()
            .map(|descriptor| descriptor.id.as_str())
            .collect();
        ids.sort_unstable();
        let before = ids.len();
        ids.dedup();
        assert_eq!(before, ids.len(), "catalog descriptor ids must be unique");
    }

    #[test]
    fn pure_diarization_models_are_not_downloadable() {
        assert!(
            CATALOG
                .iter()
                .all(|model| model.caps.architecture.as_deref() != Some("sortformer")),
            "Sortformer produces speaker segments, not transcription text"
        );
    }

    #[test]
    fn scores_are_normalised_0_to_1() {
        for descriptor in CATALOG.iter() {
            assert!(
                (0.0..=1.0).contains(&descriptor.speed_score),
                "{} speed",
                descriptor.id
            );
            assert!(
                (0.0..=1.0).contains(&descriptor.accuracy_score),
                "{} accuracy",
                descriptor.id
            );
        }
    }

    #[test]
    fn every_catalog_model_has_mirror_fallbacks_with_hashes() {
        for descriptor in CATALOG.iter() {
            let mirrors = mirror_fallbacks(&descriptor.id);
            assert!(
                !mirrors.is_empty(),
                "{}: no mirror fallbacks",
                descriptor.id
            );
            for mirror in &mirrors {
                assert_eq!(mirror.sha256.len(), 64, "{}: invalid hash", descriptor.id);
                assert!(mirror.size_bytes > 0, "{}: missing size", descriptor.id);
                assert!(
                    mirror.url.starts_with("https://"),
                    "{}: bad url {}",
                    descriptor.id,
                    mirror.url
                );
            }
        }
    }

    #[test]
    fn catalog_architectures_are_known_to_capability_probe() {
        let missing: BTreeSet<&str> = CATALOG
            .iter()
            .filter_map(|descriptor| descriptor.caps.architecture.as_deref())
            .filter(|architecture| !KNOWN_ARCHES.contains(architecture))
            .collect();

        assert!(
            missing.is_empty(),
            "catalog architecture(s) missing from KNOWN_ARCHES: {:?}",
            missing
        );
    }
}

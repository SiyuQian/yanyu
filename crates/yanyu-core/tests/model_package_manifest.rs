use yanyu_core::{
    validate_model_package_descriptor, validate_model_package_identity, CoreError,
    ModelPackageArtifact, ModelPackageDescriptor,
};

const SHA256: &str = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

fn manifest(files: Vec<ModelPackageArtifact>) -> ModelPackageDescriptor {
    ModelPackageDescriptor {
        id: "org/repo/asr-model".to_string(),
        version: "1.0.0".to_string(),
        files,
    }
}

fn artifact(path: &str, sha256: &str) -> ModelPackageArtifact {
    ModelPackageArtifact {
        relative_path: path.to_string(),
        size_bytes: 5,
        sha256: sha256.to_string(),
    }
}

#[test]
fn accepts_safe_multi_file_package_paths() {
    let descriptor = manifest(vec![
        artifact("weights/encoder.bin", SHA256),
        artifact("tokenizer/vocab.json", SHA256),
    ]);

    assert!(validate_model_package_descriptor(descriptor).is_ok());
}

#[test]
fn rejects_unsafe_relative_paths() {
    for path in [
        "../model.bin",
        "/absolute/model.bin",
        "weights//model.bin",
        "weights/./model.bin",
        "weights/../model.bin",
        "weights\\model.bin",
        ".yanyu-package-manifest.json",
    ] {
        assert!(matches!(
            validate_model_package_descriptor(manifest(vec![artifact(path, SHA256)])),
            Err(CoreError::InvalidModelPackageManifest)
        ));
    }
}

#[test]
fn rejects_duplicate_and_file_directory_conflicts() {
    for files in [
        vec![
            artifact("weights/model.bin", SHA256),
            artifact("weights/model.bin", SHA256),
        ],
        vec![
            artifact("weights", SHA256),
            artifact("weights/model.bin", SHA256),
        ],
    ] {
        assert!(matches!(
            validate_model_package_descriptor(manifest(files)),
            Err(CoreError::InvalidModelPackageManifest)
        ));
    }
}

#[test]
fn rejects_malformed_sha256_and_empty_package() {
    assert!(matches!(
        validate_model_package_descriptor(manifest(vec![artifact("model.bin", "not-a-digest")])),
        Err(CoreError::InvalidModelPackageManifest)
    ));
    assert!(matches!(
        validate_model_package_descriptor(manifest(Vec::new())),
        Err(CoreError::InvalidModelPackageManifest)
    ));
}

#[test]
fn rejects_non_normalized_unicode_paths() {
    let decomposed_name = "cafe\u{301}.bin";
    assert!(matches!(
        validate_model_package_descriptor(manifest(vec![artifact(decomposed_name, SHA256)])),
        Err(CoreError::InvalidModelPackageManifest)
    ));
}

#[test]
fn rejects_invalid_identifiers_before_path_derivation() {
    assert!(
        validate_model_package_identity("org/repo/model".to_string(), "1.0".to_string()).is_ok()
    );
    for (id, version) in [
        (String::new(), "1.0".to_string()),
        ("model\nname".to_string(), "1.0".to_string()),
        ("model".to_string(), "".to_string()),
        ("model".to_string(), "v".repeat(181)),
    ] {
        assert!(matches!(
            validate_model_package_identity(id, version),
            Err(CoreError::InvalidModelPackageManifest)
        ));
    }
}

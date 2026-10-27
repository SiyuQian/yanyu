use std::collections::HashSet;

use unicode_normalization::UnicodeNormalization;

use crate::CoreError;

const INTERNAL_MANIFEST_PATH: &str = ".yanyu-package-manifest.json";

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ModelPackageArtifact {
    pub relative_path: String,
    pub size_bytes: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ModelPackageDescriptor {
    pub id: String,
    pub version: String,
    pub files: Vec<ModelPackageArtifact>,
}

/// Validates the platform-independent fields of a model package manifest.
#[uniffi::export]
pub fn validate_model_package_descriptor(
    descriptor: ModelPackageDescriptor,
) -> Result<(), CoreError> {
    validate_identity(&descriptor.id, &descriptor.version)?;
    if descriptor.files.is_empty() {
        return Err(CoreError::InvalidModelPackageManifest);
    }

    let mut paths = HashSet::with_capacity(descriptor.files.len());
    for file in &descriptor.files {
        if !is_valid_relative_path(&file.relative_path)
            || file.relative_path == INTERNAL_MANIFEST_PATH
            || !is_valid_sha256(&file.sha256)
            || !paths.insert(file.relative_path.as_str())
        {
            return Err(CoreError::InvalidModelPackageManifest);
        }
    }

    for path in &paths {
        let mut components = path.split('/').collect::<Vec<_>>();
        while components.len() > 1 {
            components.pop();
            if paths.contains(components.join("/").as_str()) {
                return Err(CoreError::InvalidModelPackageManifest);
            }
        }
    }

    Ok(())
}

/// Validates identifiers before a package path is derived from them.
#[uniffi::export]
pub fn validate_model_package_identity(id: String, version: String) -> Result<(), CoreError> {
    validate_identity(&id, &version)
}

fn validate_identity(id: &str, version: &str) -> Result<(), CoreError> {
    if is_valid_identifier(id) && is_valid_identifier(version) {
        Ok(())
    } else {
        Err(CoreError::InvalidModelPackageManifest)
    }
}

fn is_valid_identifier(identifier: &str) -> bool {
    !identifier.is_empty() && identifier.len() <= 180 && !identifier.chars().any(char::is_control)
}

fn is_valid_relative_path(path: &str) -> bool {
    if path.is_empty() || path.contains('\\') || path.contains('\0') || !path.nfc().eq(path.chars())
    {
        return false;
    }

    path.split('/').all(|component| {
        !component.is_empty() && component != "." && component != ".." && component.len() <= 255
    })
}

fn is_valid_sha256(digest: &str) -> bool {
    digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit())
}

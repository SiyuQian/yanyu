use crate::{hash::sha256_file_with_size, CoreError};
use std::path::Path;

/// The measured size and SHA-256 of an artifact that passed supplied checks.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileIntegrity {
    pub size_bytes: u64,
    pub sha256: String,
}

/// Reads a local artifact and verifies any expected size and SHA-256 digest.
///
/// This function reports integrity failures without deleting or modifying the
/// file; each caller owns its cleanup policy.
#[uniffi::export]
pub fn verify_file_integrity(
    path: String,
    expected_size_bytes: Option<u64>,
    expected_sha256: Option<String>,
) -> Result<FileIntegrity, CoreError> {
    verify_file_integrity_at(
        Path::new(&path),
        expected_size_bytes,
        expected_sha256.as_deref(),
    )
}

/// Path-preserving Rust API for callers that may receive non-UTF-8 paths.
pub fn verify_file_integrity_at(
    path: &Path,
    expected_size_bytes: Option<u64>,
    expected_sha256: Option<&str>,
) -> Result<FileIntegrity, CoreError> {
    let expected_sha256 = expected_sha256
        .map(|expected| {
            if expected.len() != 64 || !expected.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                return Err(CoreError::InvalidExpectedSha256 {
                    message: "expected a 64-character hexadecimal digest".to_string(),
                });
            }
            Ok(expected.to_ascii_lowercase())
        })
        .transpose()?;

    if let Some(expected) = expected_size_bytes {
        let metadata = std::fs::metadata(path).map_err(|error| CoreError::FileHash {
            message: error.to_string(),
        })?;
        let actual = metadata.len();
        if actual != expected {
            return Err(CoreError::FileSizeMismatch { expected, actual });
        }
    }

    let digest = sha256_file_with_size(path).map_err(|error| CoreError::FileHash {
        message: error.to_string(),
    })?;
    if let Some(expected) = expected_size_bytes {
        if digest.byte_count != expected {
            return Err(CoreError::FileSizeMismatch {
                expected,
                actual: digest.byte_count,
            });
        }
    }
    if let Some(expected) = expected_sha256 {
        if digest.sha256 != expected {
            return Err(CoreError::FileHashMismatch {
                expected,
                actual: digest.sha256,
            });
        }
    }

    Ok(FileIntegrity {
        size_bytes: digest.byte_count,
        sha256: digest.sha256,
    })
}

#[cfg(test)]
mod tests {
    use super::verify_file_integrity;
    use crate::CoreError;
    use tempfile::tempdir;

    fn fixture(contents: &[u8]) -> (tempfile::TempDir, std::path::PathBuf) {
        let directory = tempdir().expect("create temporary directory");
        let path = directory.path().join("model.gguf");
        std::fs::write(&path, contents).expect("write temporary model");
        (directory, path)
    }

    #[test]
    fn verifies_size_and_case_insensitive_sha256() {
        let (_directory, path) = fixture(b"hello");

        let integrity = verify_file_integrity(
            path.to_string_lossy().into_owned(),
            Some(5),
            Some("2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824".into()),
        )
        .expect("verify known file");

        assert_eq!(integrity.size_bytes, 5);
        assert_eq!(
            integrity.sha256,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn returns_typed_error_for_size_mismatch() {
        let (_directory, path) = fixture(b"hello");

        let result = verify_file_integrity(path.to_string_lossy().into_owned(), Some(6), None);

        assert!(matches!(
            result,
            Err(CoreError::FileSizeMismatch {
                expected: 6,
                actual: 5
            })
        ));
    }

    #[test]
    fn returns_typed_error_for_sha256_mismatch() {
        let (_directory, path) = fixture(b"hello");

        let result = verify_file_integrity(
            path.to_string_lossy().into_owned(),
            None,
            Some("0000000000000000000000000000000000000000000000000000000000000000".into()),
        );

        assert!(matches!(result, Err(CoreError::FileHashMismatch { .. })));
    }

    #[test]
    fn rejects_malformed_expected_sha256() {
        let (_directory, path) = fixture(b"hello");

        let result = verify_file_integrity(
            path.to_string_lossy().into_owned(),
            None,
            Some("not-a-sha256".into()),
        );

        assert!(matches!(
            result,
            Err(CoreError::InvalidExpectedSha256 { .. })
        ));
    }

    #[test]
    fn maps_file_open_errors_to_typed_core_error() {
        let result = verify_file_integrity("/tmp/yanyu-missing-model-artifact".into(), None, None);

        assert!(matches!(result, Err(CoreError::FileHash { .. })));
    }
}

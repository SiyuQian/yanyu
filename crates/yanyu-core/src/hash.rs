use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use sha2::{Digest, Sha256};

/// Incrementally computes a lowercase SHA-256 digest and the number of bytes hashed.
pub struct Sha256Accumulator {
    hasher: Sha256,
    byte_count: u64,
}

impl Default for Sha256Accumulator {
    fn default() -> Self {
        Self::new()
    }
}

impl Sha256Accumulator {
    /// Creates an empty SHA-256 accumulator.
    pub fn new() -> Self {
        Self {
            hasher: Sha256::new(),
            byte_count: 0,
        }
    }

    /// Adds one chunk of bytes to the running digest.
    pub fn update(&mut self, bytes: &[u8]) {
        self.hasher.update(bytes);
        self.byte_count = self.byte_count.saturating_add(bytes.len() as u64);
    }

    /// Returns the number of bytes already added.
    pub fn byte_count(&self) -> u64 {
        self.byte_count
    }

    /// Finalizes the digest and returns its byte count and lowercase hex value.
    pub fn finish(self) -> Sha256Digest {
        Sha256Digest {
            byte_count: self.byte_count,
            sha256: format!("{:x}", self.hasher.finalize()),
        }
    }
}

/// A finalized SHA-256 digest with the number of bytes included in the hash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sha256Digest {
    /// Total number of bytes added to the accumulator.
    pub byte_count: u64,
    /// Lowercase hexadecimal SHA-256 digest.
    pub sha256: String,
}

/// Computes a file's SHA-256 digest without loading the full file into memory.
pub fn sha256_file(path: impl AsRef<Path>) -> io::Result<String> {
    Ok(sha256_file_with_size(path)?.sha256)
}

/// Computes a file's SHA-256 digest and byte count in one streaming pass.
pub fn sha256_file_with_size(path: impl AsRef<Path>) -> io::Result<Sha256Digest> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256Accumulator::new();
    let mut buffer = [0u8; 64 * 1024];

    loop {
        let bytes_read = file.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    Ok(hasher.finish())
}

/// UniFFI entry point for hashing a local file from Swift.
#[uniffi::export]
pub fn compute_file_sha256(path: String) -> Result<String, crate::CoreError> {
    sha256_file(path).map_err(|error| crate::CoreError::FileHash {
        message: error.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::Sha256Accumulator;
    use std::io::Write;

    use tempfile::tempdir;

    use crate::{compute_file_sha256, CoreError};

    #[test]
    fn computes_a_known_sha256_through_the_ffi_function() -> Result<(), Box<dyn std::error::Error>>
    {
        let directory = tempdir()?;
        let path = directory.path().join("sample.bin");
        std::fs::write(&path, b"hello")?;

        assert_eq!(
            compute_file_sha256(path.to_string_lossy().into_owned())?,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
        Ok(())
    }

    #[test]
    fn incremental_hasher_tracks_bytes_across_chunks() {
        let mut hasher = Sha256Accumulator::new();
        hasher.update(b"he");
        hasher.update(b"llo");

        let digest = hasher.finish();
        assert_eq!(digest.byte_count, 5);
        assert_eq!(
            digest.sha256,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn default_hasher_starts_empty() {
        let digest = Sha256Accumulator::default().finish();

        assert_eq!(digest.byte_count, 0);
        assert_eq!(
            digest.sha256,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn hashes_large_files_incrementally() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempdir()?;
        let path = directory.path().join("large.bin");
        let mut file = std::fs::File::create(&path)?;
        let block = vec![b'a'; 1_000_000];
        file.write_all(&block)?;

        assert_eq!(
            super::super::sha256_file(&path)?,
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
        Ok(())
    }

    #[test]
    fn maps_file_read_errors_to_a_typed_ffi_error() {
        let result = compute_file_sha256("/tmp/yanyu-missing-hash-input".to_string());
        assert!(matches!(result, Err(CoreError::FileHash { .. })));
    }
}

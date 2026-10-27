//! Compatibility re-exports for portable model capability probing.
//!
//! Desktop callers retain their existing module path while the domain types,
//! GGUF probing, and shared tests live in `yanyu-core`.

pub use yanyu_core::model_capabilities::{
    CapabilityProbe, CapabilityProber, Compatibility, GgufHeaderProber,
};

#[cfg(test)]
pub use yanyu_core::model_capabilities::KNOWN_ARCHES;

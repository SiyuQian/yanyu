//! Serialized ownership of the native audio-only capture handle.
use serde::Deserialize;
#[derive(Deserialize)]
pub struct CaptureSnapshot {
    pub mic_frames: u32,
    pub system_frames: u32,
    pub paused: bool,
    pub error: Option<String>,
}
use std::path::Path;
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
mod native {
    use std::ffi::{c_char, c_void, CStr, CString};
    unsafe extern "C" {
        pub fn meeting_available() -> i32;
        fn meeting_start(path: *const c_char, online: i32, error: *mut *mut c_char) -> *mut c_void;
        fn meeting_pause(handle: *mut c_void, pause: i32) -> *mut c_char;
        fn meeting_stop(handle: *mut c_void) -> *mut c_char;
        fn meeting_error(handle: *mut c_void) -> *mut c_char;
        fn meeting_string_free(error: *mut c_char);
    }
    pub struct Capture(usize);
    fn error(pointer: *mut c_char) -> String {
        // SAFETY: bridge returns an allocated UTF-8 C string with its paired release.
        unsafe {
            let result = CStr::from_ptr(pointer).to_string_lossy().into_owned();
            meeting_string_free(pointer);
            result
        }
    }
    impl Capture {
        pub fn start(path: &std::path::Path, online: bool) -> anyhow::Result<Self> {
            let path = CString::new(
                path.to_str()
                    .ok_or_else(|| anyhow::anyhow!("invalid_meeting_path"))?,
            )?;
            let mut problem = std::ptr::null_mut();
            // SAFETY: stable C strings and output storage live until the synchronous call returns.
            let handle = unsafe { meeting_start(path.as_ptr(), i32::from(online), &mut problem) };
            if handle.is_null() {
                anyhow::bail!(
                    "{}",
                    if problem.is_null() {
                        "capture_start_failed".into()
                    } else {
                        error(problem)
                    }
                );
            }
            Ok(Self(handle as usize))
        }
        pub fn stop(&mut self) -> Option<String> {
            let handle = std::mem::replace(&mut self.0, 0);
            if handle == 0 {
                return None;
            }
            // SAFETY: consume the retained handle exactly once, after all callbacks finish.
            let result = unsafe { meeting_stop(handle as *mut c_void) };
            if result.is_null() {
                None
            } else {
                Some(error(result))
            }
        }
        pub fn error(&self) -> Option<String> {
            let pointer = unsafe { meeting_error(self.0 as *mut c_void) };
            if pointer.is_null() {
                None
            } else {
                Some(error(pointer))
            }
        }
        pub fn pause(&self, paused: bool) -> anyhow::Result<()> {
            // SAFETY: manager serializes calls and owns this retained native handle.
            let result = unsafe { meeting_pause(self.0 as *mut c_void, i32::from(paused)) };
            anyhow::ensure!(
                result.is_null(),
                "{}",
                if result.is_null() {
                    String::new()
                } else {
                    error(result)
                }
            );
            Ok(())
        }
    }
    impl Drop for Capture {
        fn drop(&mut self) {
            if let Some(error) = self.stop() {
                log::error!("Meeting capture dropped with failure: {error}");
            }
        }
    }
}
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
pub use native::Capture;
pub fn available() -> bool {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        unsafe { native::meeting_available() != 0 }
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        false
    }
}
#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
pub struct Capture;
#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
impl Capture {
    pub fn start(_: &Path, _: bool) -> anyhow::Result<Self> {
        anyhow::bail!("unsupported")
    }
    pub fn error(&self) -> Option<String> {
        None
    }
    pub fn stop(&mut self) -> Option<String> {
        None
    }
    pub fn pause(&self, _: bool) -> anyhow::Result<()> {
        anyhow::bail!("unsupported")
    }
}
pub fn snapshot(path: &Path) -> anyhow::Result<CaptureSnapshot> {
    Ok(serde_json::from_slice(&std::fs::read(
        path.join("capture.json"),
    )?)?)
}

//! Fixed, optional text model. It never participates in ASR model selection.
use futures_util::StreamExt;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

pub const OUTPUT_BUDGET: Duration = Duration::from_millis(500);
const SUPPORTED: bool = cfg!(all(target_os = "macos", target_arch = "aarch64"));
#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
const PROMPT: &str = "Lightly clean up the transcript. Preserve meaning, language and identifiers. Fix punctuation and capitalization only. Do not add, remove, translate or reorder words. Return only the cleaned text. /no_think";
struct Artifact {
    name: &'static str,
    url: &'static str,
    size: u64,
    sha256: &'static str,
}
const ARTIFACTS: [Artifact; 2] = [
    Artifact { name: "model.gguf", url: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/23749fefcc72300e3a2ad315e1317431b06b590a/Qwen3-0.6B-Q8_0.gguf", size: 639446688, sha256: "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031" },
    Artifact { name: "tokenizer.json", url: "https://huggingface.co/Qwen/Qwen3-0.6B/resolve/c1899de289a04d12100db370d81485cdf75e47ca/tokenizer.json", size: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4" },
];

#[derive(Clone, Serialize, specta::Type)]
pub struct LocalPolishingStatus {
    pub phase: String,
    pub progress: f64,
    pub error: Option<String>,
    pub downloaded: bool,
    pub supported: bool,
}
struct Inner {
    life: Lifecycle,
    model: Option<NativeModel>,
    busy: bool,
    work_cancel: Arc<AtomicBool>,
    download_cancel: Option<Arc<AtomicBool>>,
    status: LocalPolishingStatus,
}
pub struct LocalPolishingManager {
    directory: PathBuf,
    inner: Mutex<Inner>,
}

impl LocalPolishingManager {
    /// Creates a manager without loading weights or downloading artifacts.
    pub fn new(directory: PathBuf) -> Arc<Self> {
        let downloaded = ARTIFACTS
            .iter()
            .all(|a| fs::metadata(directory.join(a.name)).is_ok_and(|m| m.len() == a.size));
        Arc::new(Self {
            directory,
            inner: Mutex::new(Inner {
                life: Lifecycle::default(),
                model: None,
                busy: false,
                work_cancel: Arc::new(AtomicBool::new(false)),
                download_cancel: None,
                status: LocalPolishingStatus {
                    phase: if !SUPPORTED {
                        "unsupported"
                    } else if downloaded {
                        "downloaded"
                    } else {
                        "missing"
                    }
                    .into(),
                    progress: 0.,
                    error: None,
                    downloaded,
                    supported: SUPPORTED,
                },
            }),
        })
    }
    /// Returns the current download and model state.
    pub fn status(&self) -> LocalPolishingStatus {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .status
            .clone()
    }
    /// Invalidates current work and schedules a load or resource release.
    pub fn set_enabled(self: &Arc<Self>, enabled: bool) {
        let model = {
            let mut s = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            s.life.set_enabled(enabled);
            s.work_cancel.store(true, Ordering::Release);
            if !enabled && s.download_cancel.is_none() {
                s.status.phase = if !SUPPORTED {
                    "unsupported"
                } else if s.status.downloaded {
                    "downloaded"
                } else {
                    "missing"
                }
                .into();
            }
            s.model.take()
        };
        // GPU resource destruction stays off the command/UI thread.
        if let Some(model) = model {
            tauri::async_runtime::spawn_blocking(move || drop(model));
        }
        if enabled {
            self.preload();
        }
    }
    /// Loads and warms one model worker while enabled.
    pub fn preload(self: &Arc<Self>) {
        let (epoch, cancel) = {
            let mut s = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            if !SUPPORTED
                || !s.life.enabled
                || s.busy
                || s.model.is_some()
                || !s.status.downloaded
                || s.download_cancel.is_some()
            {
                return;
            }
            s.busy = true;
            s.status.phase = "loading".into();
            s.status.error = None;
            s.work_cancel = Arc::new(AtomicBool::new(false));
            (s.life.generation, s.work_cancel.clone())
        };
        let manager = self.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let loaded = NativeModel::load(&manager.directory, &cancel);
            let mut s = manager.inner.lock().unwrap_or_else(|e| e.into_inner());
            s.busy = false;
            if s.life.permits(epoch) {
                match loaded {
                    Ok(model) => {
                        s.model = Some(model);
                        s.status.phase = "ready".into();
                    }
                    Err(e) => {
                        s.status.phase = "error".into();
                        s.status.error = Some(e.to_string());
                    }
                }
            }
            let retry = s.life.enabled && s.life.generation != epoch;
            drop(s);
            if retry {
                manager.preload();
            }
        });
    }
    /// Returns only complete, validated cleanup within the output budget.
    pub async fn polish(self: &Arc<Self>, text: &str, prompt: &str) -> Option<String> {
        if !eligible(text, true) {
            return None;
        }
        let deadline = Instant::now() + OUTPUT_BUDGET;
        let (mut model, epoch, cancel) = {
            let mut s = self.inner.try_lock().ok()?;
            if !s.life.enabled || s.busy {
                return None;
            }
            let model = s.model.take()?;
            s.busy = true;
            s.work_cancel = Arc::new(AtomicBool::new(false));
            (model, s.life.generation, s.work_cancel.clone())
        };
        let stop = cancel.clone();
        let manager = self.clone();
        let original = text.to_string();
        let prompt = prompt.to_string();
        let task = tauri::async_runtime::spawn_blocking(move || {
            let result = model.generate(&original, &prompt, deadline, &cancel);
            model.clear();
            let mut s = manager.inner.lock().unwrap_or_else(|e| e.into_inner());
            s.busy = false;
            let valid = s.life.permits(epoch)
                && !cancel.load(Ordering::Acquire)
                && Instant::now() < deadline;
            if s.life.permits(epoch) {
                s.model = Some(model);
            }
            let retry = s.life.enabled && s.life.generation != epoch;
            drop(s);
            if retry {
                manager.preload();
            }
            if valid {
                result.ok().flatten()
            } else {
                None
            }
        });
        within_budget(async { task.await.ok().flatten() }, deadline, stop).await
    }
    /// Signals cancellation of the current explicit download.
    pub fn cancel_download(&self) {
        let s = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(cancel) = &s.download_cancel {
            cancel.store(true, Ordering::Release);
        }
    }
    /// Disables inference and deletes installed artifacts.
    pub fn delete(self: &Arc<Self>) -> Result<(), String> {
        let mut s = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        s.life.set_enabled(false);
        s.work_cancel.store(true, Ordering::Release);
        let model = s.model.take();
        if let Some(model) = model {
            tauri::async_runtime::spawn_blocking(move || drop(model));
        }
        if let Some(cancel) = &s.download_cancel {
            cancel.store(true, Ordering::Release);
        }
        if self.directory.exists() {
            fs::remove_dir_all(&self.directory).map_err(|e| e.to_string())?;
        }
        s.status.downloaded = false;
        s.status.progress = 0.;
        s.status.error = None;
        s.status.phase = if SUPPORTED { "missing" } else { "unsupported" }.into();
        Ok(())
    }
    /// Starts one explicit download of the pinned model and tokenizer.
    pub fn download(self: &Arc<Self>) -> Result<(), String> {
        let cancel = {
            let mut s = self.inner.lock().map_err(|e| e.to_string())?;
            if !SUPPORTED {
                return Err("Local polishing requires an Apple Silicon Mac".into());
            }
            if s.download_cancel.is_some() {
                return Err("A download is already running".into());
            }
            if s.status.downloaded {
                return Ok(());
            }
            let cancel = Arc::new(AtomicBool::new(false));
            s.download_cancel = Some(cancel.clone());
            s.status.phase = "downloading".into();
            s.status.error = None;
            s.status.progress = 0.;
            cancel
        };
        let manager = self.clone();
        tauri::async_runtime::spawn(async move {
            let staging = manager.directory.with_extension("partial");
            let result = manager.fetch(&staging, &cancel).await;
            let _ = fs::remove_dir_all(&staging);
            manager.finish_download(result, &cancel);
            manager.preload();
        });
        Ok(())
    }
    fn finish_download(&self, result: anyhow::Result<()>, cancel: &AtomicBool) {
        let mut s = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        s.download_cancel = None;
        match result {
            Ok(()) => {
                s.status.progress = if s.status.downloaded { 1. } else { 0. };
                s.status.phase = if s.status.downloaded {
                    "downloaded"
                } else {
                    "missing"
                }
                .into();
            }
            Err(e) => {
                s.status.phase = if cancel.load(Ordering::Acquire) {
                    "missing"
                } else {
                    "error"
                }
                .into();
                s.status.error = if cancel.load(Ordering::Acquire) {
                    None
                } else {
                    Some(e.to_string())
                };
            }
        }
    }
    fn install(&self, staging: &Path, cancel: &AtomicBool) -> anyhow::Result<()> {
        let mut s = self
            .inner
            .lock()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        check_stop(cancel, None)?;
        if self.directory.exists() {
            fs::remove_dir_all(&self.directory)?;
        }
        fs::rename(staging, &self.directory)?;
        s.status.downloaded = true;
        Ok(())
    }
    async fn fetch(&self, staging: &Path, cancel: &AtomicBool) -> anyhow::Result<()> {
        if staging.exists() {
            fs::remove_dir_all(staging)?;
        }
        fs::create_dir_all(staging)?;
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(600))
            .build()?;
        let total: u64 = ARTIFACTS.iter().map(|a| a.size).sum();
        let mut done = 0u64;
        let mut last_progress = Instant::now();
        for a in &ARTIFACTS {
            check_stop(cancel, None)?;
            let response = cancellable(client.get(a.url).send(), cancel)
                .await??
                .error_for_status()?;
            let mut stream = response.bytes_stream();
            let mut file = File::create(staging.join(a.name))?;
            let mut hash = Sha256::new();
            let mut size = 0;
            while let Some(chunk) = cancellable(stream.next(), cancel).await? {
                let chunk = chunk?;
                size += chunk.len() as u64;
                anyhow::ensure!(size <= a.size, "Downloaded artifact exceeds expected size");
                hash.update(&chunk);
                file.write_all(&chunk)?;
                done += chunk.len() as u64;
                if last_progress.elapsed() >= Duration::from_millis(100) {
                    self.inner
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .status
                        .progress = done as f64 / total as f64;
                    last_progress = Instant::now();
                }
            }
            validate_digest(a, size, &format!("{:x}", hash.finalize()))?;
            file.sync_all()?;
        }
        self.install(staging, cancel)
    }
}
async fn within_budget<F: std::future::Future<Output = Option<String>>>(
    future: F,
    deadline: Instant,
    cancel: Arc<AtomicBool>,
) -> Option<String> {
    let _stop_on_drop = CancelOnDrop(cancel);
    // Reserve 5 ms of the output budget for timer resolution and handoff.
    let deadline = deadline - Duration::from_millis(5);
    tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), future)
        .await
        .ok()
        .flatten()
}
struct CancelOnDrop(Arc<AtomicBool>);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
async fn cancellable<F: std::future::Future>(
    future: F,
    cancel: &AtomicBool,
) -> anyhow::Result<F::Output> {
    tokio::pin!(future);
    loop {
        check_stop(cancel, None)?;
        tokio::select! { result = &mut future => return Ok(result), _ = tokio::time::sleep(Duration::from_millis(50)) => {} }
    }
}
fn check_stop(cancel: &AtomicBool, deadline: Option<Instant>) -> anyhow::Result<()> {
    anyhow::ensure!(
        !cancel.load(Ordering::Acquire) && !deadline.is_some_and(|d| Instant::now() >= d),
        "Local polishing cancelled or timed out"
    );
    Ok(())
}
fn validate_digest(a: &Artifact, size: u64, digest: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        size == a.size && digest == a.sha256,
        "Invalid local polishing artifact: {}",
        a.name
    );
    Ok(())
}
fn validate_file(path: &Path, a: &Artifact, cancel: &AtomicBool) -> anyhow::Result<()> {
    let mut f = File::open(path)?;
    let mut hash = Sha256::new();
    let mut size = 0;
    let mut buffer = [0u8; 65536];
    loop {
        check_stop(cancel, None)?;
        let n = f.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        size += n as u64;
        hash.update(&buffer[..n]);
    }
    validate_digest(a, size, &format!("{:x}", hash.finalize()))
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
struct NativeModel {
    weights: candle_transformers::models::quantized_qwen3::ModelWeights,
    tokenizer: tokenizers::Tokenizer,
    device: candle_core::Device,
}
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
impl NativeModel {
    fn load(directory: &Path, cancel: &AtomicBool) -> anyhow::Result<Self> {
        for a in &ARTIFACTS {
            validate_file(&directory.join(a.name), a, cancel)?;
        }
        let device = candle_core::Device::new_metal(0)?;
        let mut reader = File::open(directory.join("model.gguf"))?;
        let content = candle_core::quantized::gguf_file::Content::read(&mut reader)?;
        let weights = candle_transformers::models::quantized_qwen3::ModelWeights::from_gguf(
            content,
            &mut reader,
            &device,
        )?;
        let tokenizer = tokenizers::Tokenizer::from_file(directory.join("tokenizer.json"))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let mut model = Self {
            weights,
            tokenizer,
            device,
        };
        // Compile lazy Metal kernels before announcing readiness. Cold work never blocks output.
        let _ = model.generate(
            "hello",
            PROMPT,
            Instant::now() + Duration::from_secs(30),
            cancel,
        )?;
        model.clear();
        check_stop(cancel, None)?;
        Ok(model)
    }
    fn clear(&mut self) {
        self.weights.clear_kv_cache();
    }
    fn generate(
        &mut self,
        text: &str,
        instructions: &str,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> anyhow::Result<Option<String>> {
        check_stop(cancel, Some(deadline))?;
        let prompt = inference_prompt(text, instructions);
        let mut input = self
            .tokenizer
            .encode(prompt, false)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .get_ids()
            .to_vec();
        anyhow::ensure!(
            input.len() <= 4096,
            "Prompt and transcript exceed local context budget"
        );
        self.clear();
        let mut offset = 0;
        let mut output = Vec::new();
        let mut sampler = candle_transformers::generation::LogitsProcessor::new(0, None, None);
        for _ in 0..128 {
            check_stop(cancel, Some(deadline))?;
            let tensor = candle_core::Tensor::new(input.as_slice(), &self.device)?.unsqueeze(0)?;
            let logits = self.weights.forward(&tensor, offset)?.squeeze(0)?;
            offset += input.len();
            let id = sampler.sample(&logits)?;
            check_stop(cancel, Some(deadline))?;
            if Some(id) == self.tokenizer.token_to_id("<|im_end|>")
                || Some(id) == self.tokenizer.token_to_id("<|endoftext|>")
            {
                let decoded = self
                    .tokenizer
                    .decode(&output, false)
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                return Ok(accepted_output(text, &decoded, true));
            }
            output.push(id);
            input = vec![id];
        }
        Ok(None)
    }
}
#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
struct NativeModel;
#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
impl NativeModel {
    fn load(_: &Path, _: &AtomicBool) -> anyhow::Result<Self> {
        anyhow::bail!("Local polishing requires an Apple Silicon Mac")
    }
    fn clear(&mut self) {}
    fn generate(
        &mut self,
        _: &str,
        _: &str,
        _: Instant,
        _: &AtomicBool,
    ) -> anyhow::Result<Option<String>> {
        Ok(None)
    }
}

fn accepted_output(original: &str, output: &str, complete: bool) -> Option<String> {
    let output = output.trim();
    if !complete
        || output.is_empty()
        || output.chars().any(|c| c.is_control() || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}'))
        || output.contains(['<', '>', '{', '}', '\n'])
        || output.chars().count() > original.chars().count() * 2 + 8
        || output.chars().count() * 2 < original.chars().count()
    {
        return None;
    }
    // Code-like tokens retain spelling and internal punctuation.
    for token in original.split_whitespace() {
        let token = token.trim_matches(|c: char| !c.is_alphanumeric() && !"_+#$".contains(c));
        if (token.contains(['_', '.', '/', '@', '-', ':', '+', '#', '$'])
            || token.chars().any(|c| c.is_ascii_digit())
            || token.chars().skip(1).any(|c| c.is_ascii_uppercase()))
            && !output.contains(token)
        {
            return None;
        }
    }
    Some(output.to_string())
}
fn inference_prompt(text: &str, instructions: &str) -> String {
    // Saved prompts use the same transcript placeholder as explicit provider trials.
    let instructions = instructions.replace("${output}", text);
    format!("<|im_start|>system\n{instructions}\nReturn only the processed transcript. /no_think<|im_end|>\n<|im_start|>user\n{text}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
}
pub(crate) fn eligible(text: &str, enabled: bool) -> bool {
    enabled && !text.trim().is_empty() && text.chars().count() <= 200
}
#[derive(Default)]
struct Lifecycle {
    enabled: bool,
    generation: u64,
}
impl Lifecycle {
    fn set_enabled(&mut self, enabled: bool) {
        self.generation = self.generation.wrapping_add(1);
        self.enabled = enabled;
    }
    fn permits(&self, generation: u64) -> bool {
        self.enabled && self.generation == generation
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn custom_prompt_can_rewrite_content_without_changing_identifiers() {
        assert_eq!(
            accepted_output("please send the file", "Kindly share the document.", true),
            Some("Kindly share the document.".into())
        );
        assert_eq!(accepted_output("send foo.bar", "Share foo bar", true), None);
    }

    #[tokio::test]
    async fn deadline_returns_fallback_and_signals_cooperative_stop() {
        let cancel = Arc::new(AtomicBool::new(false));
        let start = Instant::now();
        let result = within_budget(
            async {
                tokio::time::sleep(Duration::from_millis(150)).await;
                Some("late output".into())
            },
            start + Duration::from_millis(20),
            cancel.clone(),
        )
        .await;
        assert_eq!(result, None);
        assert!(cancel.load(Ordering::Acquire));
        assert!(start.elapsed() < Duration::from_millis(100));
    }
    #[tokio::test]
    #[ignore = "Downloads pinned artifacts into a temporary directory"]
    async fn managed_download_smoke() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("qwen3-0.6b");
        let manager = LocalPolishingManager::new(target.clone());
        manager.download().unwrap();
        assert!(
            manager.download().is_err(),
            "concurrent downloads must be rejected"
        );
        manager.cancel_download();
        let start = Instant::now();
        while manager.inner.lock().unwrap().download_cancel.is_some() {
            assert!(start.elapsed() < Duration::from_secs(10));
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(!target.exists());
        assert!(!target.with_extension("partial").exists());
        println!("Cancelled download cleaned up: {:?}", start.elapsed());
        let start = Instant::now();
        manager.download().unwrap();
        while manager.inner.lock().unwrap().download_cancel.is_some() {
            assert!(start.elapsed() < Duration::from_secs(600));
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let status = manager.status();
        println!(
            "Managed pinned download: {:?}, phase={}, error={:?}",
            start.elapsed(),
            status.phase,
            status.error
        );
        assert!(status.downloaded);
        assert_eq!(status.phase, "downloaded");
        let cancel = AtomicBool::new(false);
        for a in &ARTIFACTS {
            validate_file(&target.join(a.name), a, &cancel).unwrap();
        }
        assert!(
            manager.inner.lock().unwrap().model.is_none(),
            "download must not enable inference"
        );
        manager.delete().unwrap();
        assert!(!target.exists());
        assert!(!manager.status().downloaded);
        println!("Verified both pinned hashes, default-off download, cancellation, duplicate rejection and deletion");
    }
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    #[tokio::test]
    #[ignore = "Requires pinned real model in LOCAL_POLISHING_SMOKE_DIR"]
    async fn native_model_smoke() {
        let directory =
            PathBuf::from(std::env::var("LOCAL_POLISHING_SMOKE_DIR").expect("model directory"));
        let cancel = AtomicBool::new(false);
        let start = Instant::now();
        let model = NativeModel::load(&directory, &cancel).unwrap();
        println!("Validated load plus warmup: {:?}", start.elapsed());
        let manager = LocalPolishingManager::new(directory);
        {
            let mut s = manager.inner.lock().unwrap();
            s.life.set_enabled(true);
            s.model = Some(model);
            s.status.phase = "ready".into();
        }
        for text in [
            "hello world",
            "今天我们讨论一下这个项目",
            "请 review foo_bar42 and HTTPServer",
            "use foo_bar42 with HTTPServer",
        ] {
            let start = Instant::now();
            let result = manager.polish(text, PROMPT).await;
            println!(
                "Native manager {text:?}: {:?}, accepted={result:?}",
                start.elapsed()
            );
            assert!(start.elapsed() < Duration::from_millis(650));
            let drain_start = Instant::now();
            while manager.inner.lock().unwrap().busy {
                assert!(
                    drain_start.elapsed() < Duration::from_secs(10),
                    "generation failed to stop cooperatively"
                );
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            println!("Cooperative worker drain: {:?}", drain_start.elapsed());
            if let Some(output) = result {
                assert!(accepted_output(text, &output, true).is_some());
            }
        }
        let start = Instant::now();
        let cancel = Arc::new(AtomicBool::new(false));
        let result = within_budget(
            async {
                tokio::time::sleep(Duration::from_secs(1)).await;
                Some("late output".into())
            },
            start + OUTPUT_BUDGET,
            cancel.clone(),
        )
        .await;
        println!(
            "500 ms output boundary: {:?}, fallback={}",
            start.elapsed(),
            result.is_none()
        );
        assert!(result.is_none());
        assert!(cancel.load(Ordering::Acquire));
        let running_manager = manager.clone();
        let running =
            tokio::spawn(async move { running_manager.polish(&"hello ".repeat(30), PROMPT).await });
        tokio::time::sleep(Duration::from_millis(10)).await;
        let stop_start = Instant::now();
        manager.set_enabled(false);
        assert_eq!(running.await.unwrap(), None);
        while manager.inner.lock().unwrap().busy {
            assert!(stop_start.elapsed() < Duration::from_secs(10));
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        println!(
            "Disable during real inference, cooperative drain: {:?}",
            stop_start.elapsed()
        );
        assert!(manager.inner.lock().unwrap().model.is_none());
        assert_eq!(manager.polish("hello world", PROMPT).await, None);
        manager.set_enabled(true);
        manager.set_enabled(false);
        let stop_start = Instant::now();
        while manager.inner.lock().unwrap().busy {
            assert!(stop_start.elapsed() < Duration::from_secs(10));
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(manager.inner.lock().unwrap().model.is_none());
        println!(
            "Disabled: no retained model, no inference, cancelled reload drained in {:?}",
            stop_start.elapsed()
        );
    }
    #[test]
    fn prompt_request_contains_saved_instructions_and_transcript() {
        let request = inference_prompt("hello world", "Translate ${output} to French");
        assert!(request.contains("Translate hello world to French"));
        assert!(request.contains("<|im_start|>user\nhello world<|im_end|>"));
        assert!(request.contains("/no_think"));
    }
    #[test]
    fn prompt_output_rejects_malformed_truncated_and_changed_identifiers() {
        for output in [
            "",
            "<think>unfinished",
            "{broken}",
            "hello\nworld",
            "hello\u{200B}world",
        ] {
            assert_eq!(accepted_output("hello world", output, true), None);
        }
        assert_eq!(accepted_output("hello world", "Bonjour monde", false), None);
        assert_eq!(accepted_output("use foo.bar", "use foo bar", true), None);
        assert_eq!(accepted_output("use C++", "use C", true), None);
        assert_eq!(accepted_output("cost $5", "cost 5", true), None);
        assert_eq!(
            accepted_output("send 42 files", "Send 43 files.", true),
            None
        );
    }
    #[test]
    fn late_download_completion_cannot_resurrect_deleted_model() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("model");
        let manager = LocalPolishingManager::new(target.clone());
        let staging = target.with_extension("partial");
        fs::create_dir(&staging).unwrap();
        fs::write(staging.join("model.gguf"), b"completed fixture").unwrap();
        let cancel = AtomicBool::new(false);
        manager.install(&staging, &cancel).unwrap();
        manager.delete().unwrap();
        manager.finish_download(Ok(()), &cancel);
        assert!(!manager.status().downloaded);
        assert_eq!(manager.status().phase, "missing");
        assert!(!target.exists());
    }
    #[tokio::test]
    async fn caller_cancellation_stops_generation_even_before_deadline() {
        let cancel = Arc::new(AtomicBool::new(false));
        let c = cancel.clone();
        let task = tokio::spawn(within_budget(
            std::future::pending(),
            Instant::now() + OUTPUT_BUDGET,
            c,
        ));
        tokio::task::yield_now().await;
        task.abort();
        let _ = task.await;
        assert!(cancel.load(Ordering::Acquire));
    }
    #[test]
    fn cancelled_install_never_persists_artifacts() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("model");
        let manager = LocalPolishingManager::new(target.clone());
        let staging = target.with_extension("partial");
        fs::create_dir(&staging).unwrap();
        fs::write(staging.join("model.gguf"), b"partial").unwrap();
        let cancel = AtomicBool::new(true);
        assert!(manager.install(&staging, &cancel).is_err());
        assert!(!target.exists());
    }
    #[test]
    fn artifact_validation_rejects_wrong_hash_and_truncation() {
        let a = Artifact {
            name: "test",
            url: "",
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        };
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test");
        let cancel = AtomicBool::new(false);
        fs::write(&path, b"abc").unwrap();
        assert!(validate_file(&path, &a, &cancel).is_ok());
        fs::write(&path, b"abd").unwrap();
        assert!(validate_file(&path, &a, &cancel).is_err());
        fs::write(&path, b"ab").unwrap();
        assert!(validate_file(&path, &a, &cancel).is_err());
    }
    #[test]
    fn stale_load_cannot_reinstall_after_disable_and_reenable() {
        let mut state = Lifecycle::default();
        state.set_enabled(true);
        let old = state.generation;
        state.set_enabled(false);
        state.set_enabled(true);
        assert!(!state.permits(old));
        assert!(state.permits(state.generation));
    }
    #[test]
    fn custom_prompt_allows_translation_while_preserving_code_tokens() {
        assert_eq!(
            accepted_output("请 review foo_bar42", "Please review foo_bar42", true),
            Some("Please review foo_bar42".into())
        );
    }
    #[test]
    fn rejects_incomplete_and_model_scaffolding() {
        for (output, complete) in [
            ("clean", false),
            ("<think>reason</think>clean", true),
            ("{\"transcription\":\"clean\"}", true),
            ("", true),
            ("<|im_start|>assistant", true),
        ] {
            assert_eq!(accepted_output("original", output, complete), None);
        }
    }
    #[test]
    fn preserves_identifiers_and_rejects_large_rewrites() {
        assert_eq!(
            accepted_output("Use foo_bar42", "Use another_name", true),
            None
        );
        assert_eq!(
            accepted_output(
                "hello",
                "A very long explanation of the user's request",
                true
            ),
            None
        );
        assert_eq!(
            accepted_output("hello world", "Hello world.", true),
            Some("Hello world.".into())
        );
    }
    #[test]
    fn only_short_regular_voice_input_is_eligible() {
        assert!(!eligible("hello", false));
        assert!(!eligible(" \n", true));
        assert!(!eligible(&"x".repeat(201), true));
        assert!(eligible(&"你".repeat(200), true));
        assert!(!eligible(&"你".repeat(201), true));
        assert!(eligible("你好 hello", true));
    }
}

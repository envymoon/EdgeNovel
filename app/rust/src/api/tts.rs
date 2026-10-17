//! Local text-to-speech: Qwen3-TTS 0.6B (the CustomVoice checkpoint, with its
//! named speakers) run by qwentts.cpp's `tts-server`. Like llama-server in
//! [`crate::api::ai`], it is a separate download living in a data dir, spawned
//! beside the app and spoken to over loopback; nothing ever leaves the device.
//!
//! Why a server and not a process per sentence, the way the engine before it
//! ran: loading the model is the slow part, and a sentence takes a fraction of
//! a second once it is loaded. On a laptop RTX 4060 (Vulkan) it speaks a 12 s
//! sentence in 2.5 s; on CPU alone in about as long as it takes to say it.
//!
//! What it costs while loaded, and how that is kept down:
//! - the talker is Q8_0 and the codec Q8_0 (1.17 GB of files; the codec's own
//!   decoder paths stay F32 inside it), and the codec is its decoder alone —
//!   the encoder is only for cloning a voice;
//! - the talker's KV cache is sized for what one call says — a sentence — not
//!   the engine's 4096 positions, and held in F16: 112 MB instead of 896 (see
//!   `CONTEXT`);
//! - the text embedding, a third of the talker, is read from the file mapping
//!   rather than copied to the GPU: a sentence touches a few dozen of its rows;
//! - the codec decodes as the talker goes, a few frames at a time, instead of
//!   the whole sentence at the end: 1.3 GB at the peak instead of 3.5 (`speak`);
//! - nothing stays loaded for nobody: [`IDLE`] after the last sentence the
//!   engine is stopped, and the next one starts it again.
//!
//! Pace is not the engine's business — it has none — so the player stretches
//! playback instead, which also means a pace change needs nothing re-spoken.
//!
//! On iOS, where an app may start no process, the engine is compiled into the
//! app instead and spoken to directly ([`engine`]).

#[cfg(not(in_process_engine))]
use crate::api::ai::http;
#[cfg(not(in_process_engine))]
use serde_json::json;
use std::path::{Path, PathBuf};
#[cfg(not(in_process_engine))]
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

static TTS_DIR: OnceLock<PathBuf> = OnceLock::new();

#[cfg(windows)]
const ENGINE_EXE: &str = "tts-server.exe";
#[cfg(not(windows))]
const ENGINE_EXE: &str = "tts-server";

/// The voice model is two files that load together: the talker (the language
/// model, its code predictor and the speaker table) and the codec that turns
/// codes into sound. Found by these name prefixes.
const TALKER: &str = "qwen-talker-";
const CODEC: &str = "qwen-tokenizer-";

#[cfg_attr(in_process_engine, allow(dead_code))]
const PORT: u16 = 8739;

/// Talker positions to hold: prompt plus frames. A sentence of 150 characters
/// is about 120 prompt tokens and 500 frames; a call that runs past the end is
/// cut there, not failed (the engine is patched for that, see
/// experiments/qwen-tts).
const CONTEXT: &str = "1024";

/// How long the engine stays loaded after the last sentence. Long enough that a
/// pause to answer the door does not reload it, short enough that a book closed
/// for the night gives the memory back.
const IDLE: Duration = Duration::from_secs(180);

/// Sentences spoken ahead of time (提前合成) wait here as WAVs, one file per
/// talker, speaker and text, so listening to them later costs playback and
/// nothing else — the point on a phone that cannot speak as fast as it plays.
/// Only ever a cache: emptying it means speaking those sentences again.
const CACHE: &str = "cache";

/// What the cache may hold before the oldest clips go. A chapter is 30–40 MB of
/// 24 kHz speech, so this is some fifty chapters ahead.
const CACHE_CAP: u64 = 2 << 30;

/// Called once at startup with `<app-support>/tts`. The engine and the voice
/// model live here; the user can also drop files in by hand.
pub fn init_tts(dir: String) -> Result<(), String> {
    let p = PathBuf::from(dir);
    std::fs::create_dir_all(&p).map_err(|e| format!("建朗读目录失败: {e}"))?;
    #[cfg(in_process_engine)]
    engine::prepare(&p);
    let _ = TTS_DIR.set(p.clone());
    // A phone launched for the 听书 experiments runs them once, a little
    // after the app is up, into tts/experiment.
    #[cfg(in_process_engine)]
    if std::env::var_os("NOVEL_TTS_EXPERIMENT").is_some() {
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(15));
            let _ = experiment::run(&p.join("experiment"), 2);
        });
    }
    Ok(())
}

fn tts_dir() -> Result<&'static Path, String> {
    TTS_DIR
        .get()
        .map(|p| p.as_path())
        .ok_or_else(|| "朗读目录未初始化".into())
}

/// Whether there is an engine: compiled into the app on iOS, a download
/// everywhere else.
fn has_engine(dir: &Path) -> bool {
    cfg!(in_process_engine) || find_engine(dir).is_some()
}

/// The engine: `tts-server` at the top of the dir or one folder down (the
/// download unpacks into its own folder).
fn find_engine(dir: &Path) -> Option<PathBuf> {
    let top = dir.join(ENGINE_EXE);
    if top.is_file() {
        return Some(top);
    }
    let mut subdirs: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    subdirs.sort();
    subdirs
        .into_iter()
        .map(|d| d.join(ENGINE_EXE))
        .find(|p| p.is_file())
}

/// A model file by prefix, at the top of the dir. Of the talkers only a
/// CustomVoice one has named speakers, so it is the one taken.
fn find_model(dir: &Path, prefix: &str) -> Option<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.is_file()
                && p.extension().is_some_and(|x| x == "gguf")
                && p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with(prefix))
        })
        .collect();
    found.sort();
    if prefix == TALKER {
        found.retain(|p| p.to_string_lossy().contains("customvoice"));
    }
    found.into_iter().next()
}

fn file_bytes(p: &Path) -> i64 {
    std::fs::metadata(p).map(|m| m.len() as i64).unwrap_or(0)
}

#[derive(Debug, Clone)]
pub struct TtsStatus {
    pub dir: String,
    /// The engine binary is present.
    pub engine: bool,
    /// The installed talker's file name without `.gguf`, when the talker and
    /// the codec are both there.
    pub voice: Option<String>,
    pub engine_bytes: i64,
    pub voice_bytes: i64,
}

pub fn tts_status() -> Result<TtsStatus, String> {
    let dir = tts_dir()?;
    let talker = find_model(dir, TALKER);
    let codec = find_model(dir, CODEC);
    let voice = match (&talker, &codec) {
        (Some(t), Some(_)) => t.file_stem().map(|s| s.to_string_lossy().into_owned()),
        _ => None,
    };
    Ok(TtsStatus {
        dir: dir.display().to_string(),
        engine: has_engine(dir),
        voice,
        engine_bytes: find_engine(dir).as_deref().map(file_bytes).unwrap_or(0),
        voice_bytes: [talker, codec].iter().flatten().map(|p| file_bytes(p)).sum(),
    })
}

/// True when the engine and both model files are present — the only state in
/// which [`synth`] can succeed.
pub fn tts_ready() -> Result<bool, String> {
    let dir = tts_dir()?;
    Ok(has_engine(dir)
        && find_model(dir, TALKER).is_some()
        && find_model(dir, CODEC).is_some())
}

/// Delete the engine (its folder, if it came in one), but never the voice —
/// that is a separate download with a separate button.
pub fn delete_tts_engine() -> Result<(), String> {
    if cfg!(in_process_engine) {
        return Err("朗读引擎内置于应用".into());
    }
    let dir = tts_dir()?;
    let exe = find_engine(dir).ok_or("朗读引擎未安装")?;
    stop_tts();
    match exe.parent().filter(|p| *p != dir) {
        Some(folder) => std::fs::remove_dir_all(folder),
        None => std::fs::remove_file(&exe),
    }
    .map_err(|e| format!("删除失败: {e}"))
}

/// Delete the voice model: the talker and the codec together.
pub fn delete_tts_voice() -> Result<(), String> {
    let dir = tts_dir()?;
    let files: Vec<PathBuf> = [find_model(dir, TALKER), find_model(dir, CODEC)]
        .into_iter()
        .flatten()
        .collect();
    if files.is_empty() {
        return Err("语音未安装".into());
    }
    stop_tts();
    for f in files {
        std::fs::remove_file(&f).map_err(|e| format!("删除失败: {e}"))?;
    }
    Ok(())
}

#[cfg(not(in_process_engine))]
fn server() -> &'static Mutex<Option<Child>> {
    static S: OnceLock<Mutex<Option<Child>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

/// Held while the engine is being started or stopped, so a sentence that
/// arrives just as the idle timer fires waits and then starts it again,
/// instead of being sent to an engine on its way out.
static LIFECYCLE: Mutex<()> = Mutex::new(());
static BUSY: AtomicUsize = AtomicUsize::new(0);

fn last_used() -> &'static Mutex<Instant> {
    static L: OnceLock<Mutex<Instant>> = OnceLock::new();
    L.get_or_init(|| Mutex::new(Instant::now()))
}

#[cfg(not(in_process_engine))]
fn health() -> bool {
    matches!(http(PORT, "GET", "/health", None, 2), Ok((200, _)))
}

#[cfg(in_process_engine)]
fn health() -> bool {
    engine::loaded()
}

/// Stop the engine now. The next sentence starts it again.
pub fn stop_tts() {
    let _g = LIFECYCLE.lock().unwrap();
    kill();
}

#[cfg(not(in_process_engine))]
fn kill() {
    if let Some(mut child) = server().lock().unwrap().take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(in_process_engine)]
fn kill() {
    engine::unload();
}

/// The voice loaded where it can run now; the idle watcher starts with it.
#[cfg(in_process_engine)]
fn ensure() -> Result<(), String> {
    let _g = LIFECYCLE.lock().unwrap();
    let dir = tts_dir()?;
    let talker = find_model(dir, TALKER).ok_or("中文语音未安装")?;
    let codec = find_model(dir, CODEC).ok_or("中文语音未安装（缺编解码器）")?;
    let first = !engine::loaded();
    engine::ensure(&talker, &codec)?;
    if first {
        watch_idle();
    }
    Ok(())
}

/// Lets the voice go once nothing has been said for [`IDLE`], or for a few
/// seconds behind the screen, where iOS ends the apps that hold the most.
#[cfg(in_process_engine)]
fn watch_idle() {
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(5));
        let _g = LIFECYCLE.lock().unwrap();
        if !engine::loaded() {
            return;
        }
        let idle = if engine::background() { Duration::from_secs(15) } else { IDLE };
        if BUSY.load(Ordering::SeqCst) == 0 && last_used().lock().unwrap().elapsed() > idle {
            engine::unload();
            return;
        }
    });
}

#[cfg(not(in_process_engine))]
fn ensure() -> Result<(), String> {
    let _g = LIFECYCLE.lock().unwrap();
    if health() {
        return Ok(());
    }
    kill();
    let dir = tts_dir()?;
    let exe = find_engine(dir).ok_or("朗读引擎未安装")?;
    let talker = find_model(dir, TALKER).ok_or("中文语音未安装")?;
    let codec = find_model(dir, CODEC).ok_or("中文语音未安装（缺编解码器）")?;

    let mut cmd = Command::new(&exe);
    cmd.arg("--model")
        .arg(&talker)
        .arg("--codec")
        .arg(&codec)
        .args(["--host", "127.0.0.1", "--port", &PORT.to_string(), "--lang", "chinese"])
        .env("QWEN_TTS_CTX", CONTEXT)
        // The text embedding stays in the file mapping instead of the GPU, and
        // the KV cache is F16 (see experiments/qwen-tts).
        .env("QWEN_TTS_EMBD_MMAP", "1")
        .env("QWEN_TTS_KV", "f16")
        .current_dir(exe.parent().unwrap_or(dir))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Normal priority, unlike the summarizer: someone is listening.
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let child = cmd.spawn().map_err(|e| format!("启动朗读引擎失败: {e}"))?;
    crate::job::adopt(&child);
    *server().lock().unwrap() = Some(child);

    for _ in 0..240 {
        std::thread::sleep(Duration::from_millis(250));
        if health() {
            watch_idle();
            return Ok(());
        }
        let mut slot = server().lock().unwrap();
        if let Some(Ok(Some(status))) = slot.as_mut().map(|c| c.try_wait()) {
            *slot = None;
            return Err(format!("朗读引擎退出: {status}"));
        }
    }
    kill();
    Err("朗读引擎启动超时".into())
}

/// Stops the engine once nothing has been said for [`IDLE`]. One watcher per
/// start; it ends with the engine.
#[cfg(not(in_process_engine))]
fn watch_idle() {
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(5));
        let _g = LIFECYCLE.lock().unwrap();
        let mut slot = server().lock().unwrap();
        let Some(child) = slot.as_mut() else { return };
        if !matches!(child.try_wait(), Ok(None)) {
            *slot = None;
            return;
        }
        if BUSY.load(Ordering::SeqCst) == 0 && last_used().lock().unwrap().elapsed() > IDLE {
            drop(slot);
            kill();
            return;
        }
    });
}

/// Marks a sentence in flight from before the engine is checked until its
/// answer is in, so the idle timer never stops the engine under it.
struct InFlight;

impl InFlight {
    fn new() -> Self {
        BUSY.fetch_add(1, Ordering::SeqCst);
        InFlight
    }
}

impl Drop for InFlight {
    fn drop(&mut self) {
        *last_used().lock().unwrap() = Instant::now();
        BUSY.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Speak one sentence with the named speaker (e.g. `uncle_fu`) and return a
/// WAV. One sentence per call: the reader highlights sentence by sentence, and
/// a chapter can be resumed mid-way. A sentence spoken ahead of time comes
/// from the cache.
pub fn synth(text: String, voice: String) -> Result<Vec<u8>, String> {
    let line = one_line(&text)?;
    if let Ok(wav) = std::fs::read(cached(&line, &voice)?) {
        return Ok(wav);
    }
    speak(&line, &voice)
}

/// Speak one sentence into the cache for later. False when it was already there.
pub fn prepare(text: String, voice: String) -> Result<bool, String> {
    let line = one_line(&text)?;
    let path = cached(&line, &voice)?;
    if path.is_file() {
        return Ok(false);
    }
    let wav = speak(&line, &voice)?;
    let dir = path.parent().unwrap();
    std::fs::create_dir_all(dir).map_err(|e| format!("建缓存目录失败: {e}"))?;
    // Written aside and renamed, so a clip cut off by a crash is never played.
    let part = path.with_extension("part");
    std::fs::write(&part, &wav)
        .and_then(|_| std::fs::rename(&part, &path))
        .map_err(|e| format!("写缓存失败: {e}"))?;
    trim_cache(dir, CACHE_CAP);
    Ok(true)
}

pub fn tts_cache_bytes() -> Result<i64, String> {
    let dir = tts_dir()?.join(CACHE);
    Ok(cache_files(&dir).iter().map(|(_, len, _)| *len as i64).sum())
}

pub fn clear_tts_cache() -> Result<(), String> {
    let dir = tts_dir()?.join(CACHE);
    if dir.is_dir() {
        std::fs::remove_dir_all(&dir).map_err(|e| format!("清空失败: {e}"))?;
    }
    Ok(())
}

fn one_line(text: &str) -> Result<String, String> {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.is_empty() {
        return Err("空文本".into());
    }
    Ok(line)
}

/// Where a sentence's clip lives in the cache. The talker's file name is part
/// of the key, so a different model never answers with the old one's voice.
fn cached(line: &str, voice: &str) -> Result<PathBuf, String> {
    let dir = tts_dir()?;
    let talker = find_model(dir, TALKER).ok_or("中文语音未安装")?;
    let model = talker.file_name().unwrap_or_default().to_string_lossy();
    // Two FNV-1a passes with different seeds: 128 bits, so two sentences
    // never share a file however many are cached.
    let fnv = |seed: u64| {
        [model.as_bytes(), voice.as_bytes(), line.as_bytes()]
            .iter()
            .flat_map(|part| part.iter().chain(&[0u8]))
            .fold(seed, |h, b| (h ^ *b as u64).wrapping_mul(0x100_0000_01b3))
    };
    let key = format!("{:016x}{:016x}", fnv(0xcbf2_9ce4_8422_2325), fnv(0x84222325_cbf29ce4));
    Ok(dir.join(CACHE).join(format!("{key}.wav")))
}

fn cache_files(dir: &Path) -> Vec<(PathBuf, u64, std::time::SystemTime)> {
    let Ok(rd) = std::fs::read_dir(dir) else { return Vec::new() };
    rd.flatten()
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            m.is_file().then(|| (e.path(), m.len(), m.modified().unwrap_or(std::time::UNIX_EPOCH)))
        })
        .collect()
}

/// Over `cap`, the clips spoken longest ago go first, down to nine tenths of
/// it so this is not redone for every sentence that follows.
fn trim_cache(dir: &Path, cap: u64) {
    let mut files = cache_files(dir);
    let mut total: u64 = files.iter().map(|(_, len, _)| len).sum();
    if total <= cap {
        return;
    }
    files.sort_by_key(|(_, _, at)| *at);
    for (path, len, _) in files {
        if total <= cap / 10 * 9 {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total -= len;
        }
    }
}

/// A bound on frames (12.5 a second) at a slow reading pace, so a sentence the
/// model will not finish cannot run on into a minute of noise.
fn max_frames(line: &str) -> usize {
    (line.chars().count() * 6 + 40).min(900)
}

#[cfg(in_process_engine)]
fn speak(line: &str, voice: &str) -> Result<Vec<u8>, String> {
    let _busy = InFlight::new();
    let mut again = true;
    loop {
        ensure()?;
        match engine::speak(line, voice, max_frames(line)) {
            Ok(pcm) if pcm.is_empty() => return Err("语音合成为空".into()),
            Ok(pcm) => return Ok(wav(&pcm)),
            // Stopped on the GPU because the app went behind the screen:
            // spoken again, on the CPU.
            Err(_) if again && engine::misplaced() => again = false,
            Err(e) => return Err(e),
        }
    }
}

#[cfg(not(in_process_engine))]
fn speak(line: &str, voice: &str) -> Result<Vec<u8>, String> {
    let _busy = InFlight::new();
    ensure()?;
    let frames = max_frames(line);
    // Streamed: the codec decodes as the talker goes rather than the whole
    // sentence at the end, which is most of the memory a sentence costs.
    let body = json!({
        "input": line,
        "voice": voice,
        "language": "chinese",
        "response_format": "pcm",
        "max_new_tokens": frames,
    });
    let (status, pcm) = http(PORT, "POST", "/v1/audio/speech", Some(&body), 300)?;
    if status != 200 {
        let why: String = String::from_utf8_lossy(&pcm).chars().take(200).collect();
        return Err(format!("语音合成失败: {why}"));
    }
    if pcm.is_empty() {
        return Err("语音合成为空".into());
    }
    Ok(wav(&pcm))
}

/// The engine streams bare 16-bit 24 kHz mono; players and the cache want a file.
fn wav(pcm: &[u8]) -> Vec<u8> {
    const RATE: u32 = 24_000;
    let n = pcm.len() as u32;
    let mut w = Vec::with_capacity(44 + pcm.len());
    w.extend_from_slice(b"RIFF");
    w.extend_from_slice(&(36 + n).to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes()); // PCM
    w.extend_from_slice(&1u16.to_le_bytes()); // mono
    w.extend_from_slice(&RATE.to_le_bytes());
    w.extend_from_slice(&(RATE * 2).to_le_bytes());
    w.extend_from_slice(&2u16.to_le_bytes());
    w.extend_from_slice(&16u16.to_le_bytes());
    w.extend_from_slice(b"data");
    w.extend_from_slice(&n.to_le_bytes());
    w.extend_from_slice(pcm);
    w
}

/// The engine compiled into the app (ios_tts/, built by build.rs). One voice is
/// loaded at a time: on the GPU while the app is on screen, on the CPU behind
/// it, where iOS refuses GPU work and listening goes on with the screen locked.
#[cfg(in_process_engine)]
mod engine {
    use super::{CONTEXT, Path};
    use std::ffi::{c_char, c_int, c_void, CStr, CString};
    use std::sync::Mutex;

    extern "C" {
        fn edge_tts_load(talker: *const c_char, codec: *const c_char, gpu: c_int) -> c_int;
        fn edge_tts_unload();
        fn edge_tts_background() -> c_int;
        fn edge_tts_gpu() -> c_int;
        fn edge_tts_keep_awake(on: c_int);
        fn edge_tts_error() -> *const c_char;
        fn edge_tts_speak(
            text: *const c_char,
            speaker: *const c_char,
            max_frames: c_int,
            on_pcm: extern "C" fn(*const f32, c_int, *mut c_void),
            user: *mut c_void,
        ) -> c_int;
    }

    /// Where the voice is loaded: on the GPU (true) or the CPU (false).
    static LOADED: Mutex<Option<bool>> = Mutex::new(None);

    /// The engine's Metal kernels, compiled at build time rather than on the
    /// device. The engine loads them from a file.
    const METALLIB: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/tts.metallib"));

    /// Called once at startup, before anything runs: the engine reads its
    /// settings from the environment, as tts-server does from the one it is
    /// started with. Never fails the app's start: a library it could not
    /// write only costs the voice its GPU.
    pub fn prepare(dir: &Path) {
        std::env::set_var("QWEN_TTS_CTX", CONTEXT);
        std::env::set_var("QWEN_TTS_EMBD_MMAP", "1");
        std::env::set_var("QWEN_TTS_KV", "f16");
        // Compiled for iOS 16.4: no bfloat kernels, and none of the tensor
        // ones an A19 would otherwise ask for.
        std::env::set_var("GGML_METAL_BF16_DISABLE", "1");
        std::env::set_var("GGML_METAL_TENSOR_DISABLE", "1");
        let lib = dir.join(env!("EDGE_TTS_METALLIB"));
        if !lib.is_file() {
            // An earlier version's goes.
            for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with("tts-") && name.ends_with(".metallib") {
                    let _ = std::fs::remove_file(e.path());
                }
            }
            let part = lib.with_extension("part");
            let _ = std::fs::write(&part, METALLIB).and_then(|_| std::fs::rename(&part, &lib));
        }
        if lib.is_file() {
            std::env::set_var("GGML_METAL_LIBRARY", &lib);
        }
    }

    pub fn loaded() -> bool {
        LOADED.lock().unwrap().is_some()
    }

    pub fn background() -> bool {
        unsafe { edge_tts_background() != 0 }
    }

    /// Whether this GPU can run the voice (edge_tts.mm).
    pub fn gpu() -> bool {
        unsafe { edge_tts_gpu() != 0 }
    }

    /// The screen kept on, or let go (edge_tts.mm).
    pub fn keep_awake(on: bool) {
        unsafe { edge_tts_keep_awake(on as c_int) }
    }

    /// On the GPU with the app behind the screen: it has to move.
    pub fn misplaced() -> bool {
        *LOADED.lock().unwrap() == Some(true) && background()
    }

    fn error() -> String {
        unsafe { CStr::from_ptr(edge_tts_error()) }.to_string_lossy().into_owned()
    }

    pub fn unload() {
        if LOADED.lock().unwrap().take().is_some() {
            unsafe { edge_tts_unload() };
        }
    }

    /// Loaded on the GPU on screen, on the CPU behind it.
    pub fn ensure(talker: &Path, codec: &Path) -> Result<(), String> {
        let gpu = !background() && self::gpu();
        let mut loaded = LOADED.lock().unwrap();
        if *loaded == Some(gpu) {
            return Ok(());
        }
        let path = |p: &Path| CString::new(p.to_string_lossy().as_bytes()).map_err(|_| "路径无效".to_string());
        let (t, c) = (path(talker)?, path(codec)?);
        *loaded = None;
        if unsafe { edge_tts_load(t.as_ptr(), c.as_ptr(), gpu as c_int) } == 0 {
            return Err(format!("启动朗读引擎失败: {}", error()));
        }
        *loaded = Some(gpu);
        Ok(())
    }

    /// 16-bit little-endian, the way tts-server sends it: clamped, rounded
    /// to nearest.
    extern "C" fn take_pcm(samples: *const f32, n: c_int, user: *mut c_void) {
        let pcm = unsafe { &mut *(user as *mut Vec<u8>) };
        let samples = unsafe { std::slice::from_raw_parts(samples, n.max(0) as usize) };
        for &x in samples {
            let s = (x.clamp(-1.0, 1.0) * 32767.0).round_ties_even() as i16;
            pcm.extend_from_slice(&s.to_le_bytes());
        }
    }

    /// One sentence as bare 16-bit 24 kHz mono, decoded as the talker goes.
    pub fn speak(line: &str, voice: &str, frames: usize) -> Result<Vec<u8>, String> {
        let text = CString::new(line).map_err(|_| "文本无效".to_string())?;
        let speaker = CString::new(voice).map_err(|_| "音色无效".to_string())?;
        let mut pcm: Vec<u8> = Vec::new();
        let rc = unsafe {
            edge_tts_speak(
                text.as_ptr(),
                speaker.as_ptr(),
                frames as c_int,
                take_pcm,
                &mut pcm as *mut Vec<u8> as *mut c_void,
            )
        };
        if rc != 0 {
            return Err(format!("语音合成失败: {}", error()));
        }
        Ok(pcm)
    }
}

/// The 听书 speed experiments (ios_tts/qwentts-experiments.patch): the same
/// sentences with the same seed under each setting, timed and kept as WAVs, so
/// that a faster setting is checked against the plain one, by ear and by
/// experiments/qwen-tts/compare.py, before anything uses it. The settings run
/// there and back (ABBA), so a phone warming up costs every one alike. Run by
/// the tts_experiments test in CI, and on a phone launched with
/// NOVEL_TTS_EXPERIMENT set ([`init_tts`]).
#[cfg(in_process_engine)]
mod experiment {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicU64};
    use std::sync::Arc;

    const SEED: &str = "20261016";
    const VOICE: &str = "uncle_fu";

    /// The engine's environment at load for each; the plain one sets nothing.
    static SETTINGS: [(&str, &[(&str, &str)]); 5] = [
        ("base", &[]),
        ("chunk16", &[("QWEN_TTS_CODEC_MAX", "16")]),
        ("chunk32", &[("QWEN_TTS_CODEC_MAX", "32")]),
        ("thread", &[("QWEN_TTS_CODEC_THREAD", "1")]),
        ("batch2", &[("EDGE_TTS_BATCH", "2")]),
    ];

    /// Short to long, with characters that are read more than one way.
    static LINES: [&str; 8] = [
        "天快黑了，我们回家吧。",
        "长街尽头有一家老茶馆，掌柜的总爱给客人讲从前的故事。",
        "重新开始并不难，难的是承认自己曾经走错了路。",
        "她把信折好放进抽屉，又拿出来看了一遍，终于还是没有寄出去。",
        "这件事说起来复杂，其实道理很简单：谁也不愿意被别人当成傻子。",
        "山里的雨说来就来，行人纷纷躲到屋檐下，只有那个背着竹篓的少年还在慢慢地走。",
        "先生说，读书好比种树，头几年看不出什么，等到枝叶长成了，乘凉的人自然就来了。",
        "他一口气跑到河边，弯下腰大口喘气，抬头的时候，对岸的灯火已经一盏接一盏地亮了起来，像是有人在那边等他。",
    ];

    struct Clip {
        line: usize,
        took: f64,
        pcm: Vec<u8>,
    }

    fn note(out: &Path, log: &mut String, line: String) {
        println!("{line}");
        log.push_str(&line);
        log.push('\n');
        let _ = std::fs::write(out.join("results.txt"), &*log);
    }

    fn clear_vars() {
        for (var, _) in SETTINGS.iter().flat_map(|(_, vars)| vars.iter()) {
            std::env::remove_var(var);
        }
    }

    pub(super) fn run(out: &Path, rounds: usize) -> Result<(), String> {
        std::fs::create_dir_all(out).map_err(|e| format!("建实验目录失败: {e}"))?;
        let _ = std::fs::remove_file(out.join("done.txt"));
        std::fs::write(out.join("lines.txt"), LINES.join("\n") + "\n").map_err(|e| e.to_string())?;
        let mut log = String::new();
        note(out, &mut log, format!("[实验] GPU {} · 种子 {SEED} · 音色 {VOICE} · {rounds} 轮", engine::gpu()));
        std::env::set_var("EDGE_TTS_SEED", SEED);
        engine::keep_awake(true);
        let mut result = Ok(());
        'rounds: for round in 1..=rounds {
            let mut order: Vec<_> = SETTINGS.iter().collect();
            if round % 2 == 0 {
                order.reverse();
            }
            for (name, vars) in order {
                result = setting(out, &mut log, round, name, vars);
                if result.is_err() {
                    break 'rounds;
                }
            }
        }
        clear_vars();
        std::env::remove_var("EDGE_TTS_SEED");
        stop_tts();
        engine::keep_awake(false);
        let end = match &result {
            Ok(()) => "完成".to_string(),
            Err(e) => format!("中止：{e}"),
        };
        note(out, &mut log, format!("[实验] {end}"));
        let _ = std::fs::write(out.join("done.txt"), &end);
        result
    }

    /// One setting, one round: loaded afresh with its environment, then every
    /// sentence, one at a time or as many at once as it batches.
    fn setting(out: &Path, log: &mut String, round: usize, name: &str, vars: &[(&str, &str)]) -> Result<(), String> {
        stop_tts();
        clear_vars();
        for (var, value) in vars {
            std::env::set_var(var, value);
        }
        let lanes: usize =
            vars.iter().find(|(var, _)| *var == "EDGE_TTS_BATCH").and_then(|(_, v)| v.parse().ok()).unwrap_or(1);
        // The idle watcher leaves a voice in use alone.
        let _busy = InFlight::new();
        let peak = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let sampler = {
            let (peak, stop) = (peak.clone(), stop.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    peak.fetch_max(crate::engine_thread::footprint().0, Ordering::Relaxed);
                    std::thread::sleep(Duration::from_millis(100));
                }
            })
        };
        let t = Instant::now();
        let spoken = ensure().and_then(|_| {
            let load = t.elapsed().as_secs_f64();
            Ok((load, speak_all(lanes)?))
        });
        stop.store(true, Ordering::Relaxed);
        let _ = sampler.join();
        let (load, (wall, clips)) = spoken.map_err(|e| format!("{name} 第 {round} 轮：{e}"))?;
        let mut audio = 0.0;
        for c in &clips {
            let secs = c.pcm.len() as f64 / 48000.0;
            audio += secs;
            let file = out.join(format!("{name}-r{round}-{}.wav", c.line + 1));
            std::fs::write(&file, wav(&c.pcm)).map_err(|e| format!("写 WAV 失败: {e}"))?;
            let rtf = c.took / secs.max(0.01);
            note(out, log, format!("  {name} r{round} 第{}句 {secs:.2} 秒语音用 {:.2} 秒 · RTF {rtf:.2}", c.line + 1, c.took));
        }
        let rtf = wall / audio.max(0.01);
        let mb = peak.load(Ordering::Relaxed) >> 20;
        note(
            out,
            log,
            format!("[{name} r{round}] 载入 {load:.1} 秒 · {audio:.1} 秒语音共用 {wall:.1} 秒 · RTF {rtf:.2} · 内存最高 {mb} MB"),
        );
        Ok(())
    }

    /// Every sentence, `lanes` at a time: each worker takes the next one as
    /// it finishes the last, the way a reader's queue would hand them out.
    fn speak_all(lanes: usize) -> Result<(f64, Vec<Clip>), String> {
        let next = AtomicUsize::new(0);
        let clips = Mutex::new(Vec::new());
        let t = Instant::now();
        std::thread::scope(|s| {
            let workers: Vec<_> = (0..lanes)
                .map(|_| {
                    s.spawn(|| -> Result<(), String> {
                        loop {
                            let i = next.fetch_add(1, Ordering::SeqCst);
                            let Some(line) = LINES.get(i) else { return Ok(()) };
                            if engine::background() {
                                return Err("应用退到了后台".into());
                            }
                            let t = Instant::now();
                            let pcm = engine::speak(line, VOICE, max_frames(line))?;
                            if pcm.is_empty() {
                                return Err(format!("第{}句为空", i + 1));
                            }
                            clips.lock().unwrap().push(Clip { line: i, took: t.elapsed().as_secs_f64(), pcm });
                        }
                    })
                })
                .collect();
            workers.into_iter().try_for_each(|w| w.join().unwrap_or_else(|_| Err("线程崩溃".into())))
        })?;
        let mut clips = clips.into_inner().unwrap();
        clips.sort_by_key(|c| c.line);
        Ok((t.elapsed().as_secs_f64(), clips))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cache_lets_the_oldest_clips_go() {
        let dir = std::env::temp_dir().join(format!("novel-tts-cache-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let t0 = std::time::SystemTime::now() - Duration::from_secs(100);
        for i in 0..5u64 {
            let p = dir.join(format!("{i}.wav"));
            std::fs::write(&p, [0u8; 100]).unwrap();
            let f = std::fs::File::options().write(true).open(&p).unwrap();
            f.set_modified(t0 + Duration::from_secs(i)).unwrap();
        }
        trim_cache(&dir, 1000);
        assert_eq!(cache_files(&dir).len(), 5);
        trim_cache(&dir, 300);
        let mut left: Vec<String> =
            cache_files(&dir).iter().map(|(p, ..)| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
        left.sort();
        assert_eq!(left, ["3.wav", "4.wav"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The voice on Apple's GPU and CPU, the way iOS runs it (CI). NOVEL_TTS_DIR
    /// holds the talker and the codec.
    #[cfg(in_process_engine)]
    #[test]
    #[ignore]
    fn tts_bench() {
        extern "C" {
            fn edge_tts_set_background(on: std::ffi::c_int);
        }
        let memory = |phase: &str| {
            let (now, peak) = crate::engine_thread::footprint();
            println!("[内存] {phase}：当前 {} MB · 最高 {} MB", now >> 20, peak >> 20);
        };
        init_tts(std::env::var("NOVEL_TTS_DIR").expect("set NOVEL_TTS_DIR")).unwrap();
        assert!(tts_ready().unwrap());
        memory("开始");
        let lines = ["今天的风有点大，我们早点回家吧。", "他把书合上，望着窗外的雨，很久都没有说话，直到天色暗了下来。"];
        let gpu = engine::gpu();
        if !gpu {
            println!("[GPU] 这块 GPU 跑不了，只测处理器");
        }
        for (device, behind) in [("GPU", 0), ("CPU", 1)] {
            if behind == 0 && !gpu {
                continue;
            }
            unsafe { edge_tts_set_background(behind) };
            let t = Instant::now();
            ensure().unwrap();
            println!("[{device} 载入] {:.1} 秒", t.elapsed().as_secs_f64());
            memory(&format!("{device} 载入后"));
            for line in lines {
                let t = Instant::now();
                let wav = speak(line, "uncle_fu").unwrap();
                let secs = (wav.len() - 44) as f64 / 48000.0;
                let took = t.elapsed().as_secs_f64();
                println!("[{device}] {secs:.1} 秒语音用 {took:.1} 秒 · RTF {:.2}", took / secs);
                assert!(secs > 1.0);
            }
            memory(&format!("{device} 说完"));
        }

        // Behind the screen mid-sentence: said again on the CPU, not lost.
        if !gpu {
            stop_tts();
            return;
        }
        unsafe { edge_tts_set_background(0) };
        ensure().unwrap();
        let t = Instant::now();
        let line = std::thread::spawn(|| {
            speak("这一句说到一半，应用退到了后台，换到处理器上从头再说一遍。", "uncle_fu")
        });
        std::thread::sleep(Duration::from_millis(500));
        unsafe { edge_tts_set_background(1) };
        let wav = line.join().unwrap().unwrap();
        println!(
            "[切到后台] {:.1} 秒语音，共 {:.1} 秒",
            (wav.len() - 44) as f64 / 48000.0,
            t.elapsed().as_secs_f64()
        );
        assert!(!engine::misplaced());
        stop_tts();
        assert!(!health());
        memory("结束");
    }

    /// The 听书 experiments ([`experiment`]) where CI runs them: NOVEL_TTS_DIR
    /// holds the voice, the results and WAVs go to NOVEL_TTS_EXP_OUT.
    #[cfg(in_process_engine)]
    #[test]
    #[ignore]
    fn tts_experiments() {
        init_tts(std::env::var("NOVEL_TTS_DIR").expect("set NOVEL_TTS_DIR")).unwrap();
        assert!(tts_ready().unwrap());
        let out = std::env::var("NOVEL_TTS_EXP_OUT").expect("set NOVEL_TTS_EXP_OUT");
        experiment::run(Path::new(&out), 2).unwrap();
    }

    /// Needs the engine and the voice in %APPDATA%\com.novel\novel\tts.
    #[test]
    #[ignore]
    fn speaks_with_the_installed_voice() {
        let dir = std::env::var("APPDATA").unwrap() + r"\com.novel\novel\tts";
        init_tts(dir).unwrap();
        assert!(tts_ready().unwrap());
        for (i, line) in ["二月二，龙抬头。", "陈平安放下新折的那根桃枝，吹灭蜡烛，走出屋子后，坐在台阶上，仰头望去，星空璀璨。"]
            .iter()
            .enumerate()
        {
            let t = Instant::now();
            let wav = synth(line.to_string(), "uncle_fu".into()).unwrap();
            let secs = (wav.len() - 44) as f64 / 48000.0;
            println!("{i}: {secs:.1} s of speech in {:.1} s", t.elapsed().as_secs_f64());
            assert_eq!(&wav[..4], b"RIFF");
            assert!(secs > 1.0);
        }
        assert!(synth("你好。".into(), "nobody".into()).is_err());

        let line = "提前合成的句子从缓存里读。";
        let path = cached(line, "serena").unwrap();
        let _ = std::fs::remove_file(&path);
        assert!(prepare(line.into(), "serena".into()).unwrap());
        assert!(!prepare(line.into(), "serena".into()).unwrap());
        let t = Instant::now();
        assert_eq!(synth(line.into(), "serena".into()).unwrap(), std::fs::read(&path).unwrap());
        assert!(t.elapsed() < Duration::from_millis(200));
        std::fs::remove_file(&path).unwrap();
        stop_tts();
        assert!(!health());
    }
}

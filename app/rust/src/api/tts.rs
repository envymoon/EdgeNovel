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
//! app instead and spoken to directly ([`engine`]). On Android the server
//! ships in the APK (`libedge_tts_server.so`) and is started as here.

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
#[cfg_attr(target_os = "android", allow(dead_code))]
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

/// The light voice (iOS): Kokoro 1.1-zh, run by ios_tts/kokoro/ ([`light`]).
/// A download of its own, in its own folder: the model with its voices, and
/// the data its Chinese front end reads. Its speakers are named `k:<voice>`.
const LIGHT: &str = "kokoro";
const LIGHT_MODEL: &str = "kokoro-";
const LIGHT_TEXT: &str = "zh-frontend.bin";
const LIGHT_VOICE: &str = "k:";

/// The light voice's model and front-end data, when both are there.
fn light_files(dir: &Path) -> Option<(PathBuf, PathBuf)> {
    let d = dir.join(LIGHT);
    let text = d.join(LIGHT_TEXT);
    Some((find_model(&d, LIGHT_MODEL)?, text.is_file().then_some(text)?))
}

/// Called once at startup with `<app-support>/tts`. The engine and the voice
/// model live here; the user can also drop files in by hand.
pub fn init_tts(dir: String) -> Result<(), String> {
    let p = PathBuf::from(dir);
    std::fs::create_dir_all(&p).map_err(|e| format!("建朗读目录失败: {e}"))?;
    #[cfg(in_process_engine)]
    engine::prepare(&p);
    let _ = TTS_DIR.set(p);
    Ok(())
}

fn tts_dir() -> Result<&'static Path, String> {
    TTS_DIR
        .get()
        .map(|p| p.as_path())
        .ok_or_else(|| "朗读目录未初始化".into())
}

/// Whether there is an engine: compiled into the app on iOS, in the APK on
/// Android, a download everywhere else.
fn has_engine(dir: &Path) -> bool {
    cfg!(in_process_engine) || find_engine(dir).is_some()
}

/// The engine the APK installed beside the app's own code.
#[cfg(target_os = "android")]
fn find_engine(_: &Path) -> Option<PathBuf> {
    crate::android_engine::bundled("libedge_tts_server.so")
}

/// The engine: `tts-server` at the top of the dir or one folder down (the
/// download unpacks into its own folder).
#[cfg(not(target_os = "android"))]
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
    /// The light voice is there, model and front end both.
    pub light: bool,
    /// What the light voice's files take, whole or not.
    pub light_bytes: i64,
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
        light: light_files(dir).is_some(),
        light_bytes: light_bytes(dir),
    })
}

fn light_bytes(dir: &Path) -> i64 {
    std::fs::read_dir(dir.join(LIGHT))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .map(|p| file_bytes(&p))
        .sum()
}

/// Whether [`synth`] can speak with this voice: the light voice's speakers
/// need the light voice, the others the engine and the voice model.
pub fn tts_voice_ready(voice: String) -> Result<bool, String> {
    if voice.starts_with(LIGHT_VOICE) {
        return Ok(cfg!(in_process_engine) && light_files(tts_dir()?).is_some());
    }
    tts_ready()
}

/// Delete the light voice: its folder, with any download left in it.
pub fn delete_tts_light() -> Result<(), String> {
    let dir = tts_dir()?.join(LIGHT);
    if !dir.is_dir() {
        return Err("轻量语音未安装".into());
    }
    stop_tts();
    std::fs::remove_dir_all(&dir).map_err(|e| format!("删除失败: {e}"))
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
    if cfg!(any(in_process_engine, target_os = "android")) {
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
    light::unload();
}

/// The most sentences the GPU speaks at once (听书 同时合成).
#[cfg(in_process_engine)]
const MOST_LANES: usize = 4;

/// What the GPU runs under: the codec's fusions of its arithmetic left out
/// (with them, several sentences at once come out wrong) and its data moved
/// by the faster kernels (the same audio to the bit), both found on the
/// phone.
#[cfg(in_process_engine)]
const GPU_ENV: [(&str, &str); 2] = [("GGML_METAL_FUSION_DISABLE", "1"), ("GGML_METAL_FAST_MOVE", "2")];

/// How many sentences the GPU speaks at once, as the reader chose in the 听书
/// panel (`lanes` beside the voice, written by TtsPrepare), and the engine
/// settings that takes; `engine.json` there may set others in their place.
/// One at a time when nothing says.
#[cfg(in_process_engine)]
fn tuned(dir: &Path) -> (usize, Vec<(String, String)>) {
    let json = std::fs::read_to_string(dir.join("engine.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok());
    let lanes = std::fs::read_to_string(dir.join("lanes"))
        .ok()
        .and_then(|t| t.trim().parse::<usize>().ok())
        .or_else(|| json.as_ref()?["lanes"].as_u64().map(|n| n as usize))
        .unwrap_or(1)
        .clamp(1, MOST_LANES);
    let env = match json.as_ref().and_then(|v| v["env"].as_object()) {
        Some(o) => o.iter().filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string()))).collect(),
        None => GPU_ENV.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
    };
    (lanes, env)
}

/// The voice loaded where it can run now; the idle watcher starts with it.
#[cfg(in_process_engine)]
fn ensure() -> Result<(), String> {
    let _g = LIFECYCLE.lock().unwrap();
    let dir = tts_dir()?;
    let talker = find_model(dir, TALKER).ok_or("中文语音未安装")?;
    let codec = find_model(dir, CODEC).ok_or("中文语音未安装（缺编解码器）")?;
    // One voice in memory at a time.
    light::unload();
    let first = !engine::loaded();
    // Set for the load about to happen, not under a voice that is running.
    if engine::needs_load() {
        // The light voice's: this one runs as it always has.
        std::env::remove_var("GGML_METAL_OWN_QUEUE");
        if engine::background() || !engine::gpu() {
            std::env::remove_var("EDGE_TTS_BATCH");
        } else {
            let (lanes, env) = tuned(dir);
            for (k, v) in env {
                std::env::set_var(k, v);
            }
            std::env::set_var("EDGE_TTS_BATCH", lanes.to_string());
        }
    }
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
    #[cfg(target_os = "android")]
    let gpu = {
        note_crash();
        crate::android_engine::use_gpu()
    };
    #[cfg(not(target_os = "android"))]
    let gpu = true;
    let first = start(gpu);
    // A driver that cannot run it: the CPU, for this and every engine after it
    // this run.
    #[cfg(target_os = "android")]
    if first.is_err() && gpu {
        crate::android_engine::mark_gpu_failed();
        return start(false);
    }
    first
}

/// Android: a voice on the GPU that crashed under a sentence moves every
/// engine to the CPU, as the chat engine's does (ai.rs).
#[cfg(target_os = "android")]
fn note_crash() {
    use std::os::unix::process::ExitStatusExt;
    let mut slot = server().lock().unwrap();
    let Some(status) = slot.as_mut().and_then(|c| c.try_wait().ok().flatten()) else {
        return;
    };
    *slot = None;
    let crashed = matches!(
        status.signal(),
        Some(libc::SIGSEGV | libc::SIGBUS | libc::SIGILL | libc::SIGABRT | libc::SIGFPE)
    );
    if crashed && crate::android_engine::use_gpu() {
        crate::android_engine::mark_gpu_failed();
    }
}

/// Starts the engine and waits for it to answer. `gpu` is Android's choice;
/// elsewhere the engine takes the best device it finds.
#[cfg(not(in_process_engine))]
fn start(gpu: bool) -> Result<(), String> {
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
    #[cfg(target_os = "android")]
    {
        // It ends itself when the app is gone (parent_main.cpp).
        cmd.env("EDGE_PARENT_PID", std::process::id().to_string());
        if gpu {
            // Sentences spoken at once, as the reader chose in the 听书 panel
            // (`lanes`, written by TtsPrepare), as on iPhone.
            let lanes = std::fs::read_to_string(dir.join("lanes"))
                .ok()
                .and_then(|t| t.trim().parse::<usize>().ok())
                .unwrap_or(1)
                .clamp(1, 4);
            cmd.args(["--max-batch", &lanes.to_string()]);
        } else {
            cmd.args(["--device", "CPU"]).env("GGML_VK_VISIBLE_DEVICES", "");
        }
        // Startup diagnostics only, beside the chat engine's.
        if let Ok(log) = std::fs::File::create(dir.join(".novel-tts-engine.log")) {
            cmd.stderr(Stdio::from(log));
        }
    }
    #[cfg(not(target_os = "android"))]
    let _ = gpu;
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
    say(&line, &voice)
}

/// A sentence by whichever voice the speaker is of.
fn say(line: &str, voice: &str) -> Result<Vec<u8>, String> {
    match voice.strip_prefix(LIGHT_VOICE) {
        #[cfg(in_process_engine)]
        Some(name) => light::speak(line, name),
        #[cfg(not(in_process_engine))]
        Some(_) => Err("此设备没有轻量语音".into()),
        None => speak(line, voice),
    }
}

/// Speak one sentence into the cache for later. False when it was already there.
pub fn prepare(text: String, voice: String) -> Result<bool, String> {
    let line = one_line(&text)?;
    let path = cached(&line, &voice)?;
    if path.is_file() {
        return Ok(false);
    }
    let wav = say(&line, &voice)?;
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

/// Where a sentence's clip lives in the cache. The model's file name is part
/// of the key, so a different model never answers with the old one's voice.
fn cached(line: &str, voice: &str) -> Result<PathBuf, String> {
    let dir = tts_dir()?;
    let model = match voice.starts_with(LIGHT_VOICE) {
        true => light_files(dir).ok_or("轻量语音未安装")?.0,
        false => find_model(dir, TALKER).ok_or("中文语音未安装")?,
    };
    let model = model.file_name().unwrap_or_default().to_string_lossy();
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

/// How freely the talker draws each sound. The model's own defaults (0.9, 50,
/// a new seed every time) make each sentence a fresh guess at how it is said:
/// spoken alone, without the ones around it, the guesses swing from line to
/// line, and now and then wander into a dialect the voice never had. Lower and
/// narrower, the voice reads evenly; one seed, and a sentence said again comes
/// out the same. 0.3 rather than 0.6: the same narrating tone throughout, as
/// the reader asked for, with no sentence heard to stick or repeat.
#[derive(Clone, Copy)]
struct Sampling {
    temperature: f32,
    top_k: i32,
    seed: i64,
}

const STEADY: Sampling = Sampling { temperature: 0.3, top_k: 30, seed: 1 };

#[cfg(in_process_engine)]
fn speak(line: &str, voice: &str) -> Result<Vec<u8>, String> {
    speak_with(line, voice, STEADY)
}

#[cfg(in_process_engine)]
fn speak_with(line: &str, voice: &str, how: Sampling) -> Result<Vec<u8>, String> {
    let _busy = InFlight::new();
    // Stopped because the app went behind the screen or came back: spoken
    // again, on the CPU or the GPU, however often the screen goes off and on
    // meanwhile. Each lost sentence used to count against the job, and a few
    // glances at a locked phone ended it.
    let mut moves = 0;
    loop {
        let behind = engine::background();
        let said = ensure().and_then(|_| engine::speak(line, voice, max_frames(line), how));
        match said {
            Ok(pcm) if pcm.is_empty() => return Err("语音合成为空".into()),
            Ok(pcm) => return Ok(wav(&pcm)),
            Err(_) if moves < 20 && engine::moving(behind) => moves += 1,
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
        "temperature": STEADY.temperature,
        "top_k": STEADY.top_k,
        "seed": STEADY.seed,
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
        fn edge_tts_error() -> *const c_char;
        fn edge_tts_speak(
            text: *const c_char,
            speaker: *const c_char,
            max_frames: c_int,
            temperature: f32,
            top_k: c_int,
            seed: i64,
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

    /// Not loaded, or not where it can run now.
    pub fn needs_load() -> bool {
        *LOADED.lock().unwrap() != Some(!background() && gpu())
    }

    /// On the GPU with the app behind the screen, or on the CPU back on
    /// screen with a GPU that can run it: it has to move.
    pub fn misplaced() -> bool {
        match *LOADED.lock().unwrap() {
            Some(true) => background(),
            Some(false) => !background() && gpu(),
            None => false,
        }
    }

    /// Whether a sentence that failed was caught by the app going behind the
    /// screen or coming back (`behind`: where it was when the sentence
    /// started). iOS refuses the GPU a moment before the app hears it is
    /// behind the screen, so a GPU failure on screen waits a little for that.
    pub fn moving(behind: bool) -> bool {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            if misplaced() || background() != behind {
                return true;
            }
            if *LOADED.lock().unwrap() != Some(true) || std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
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
        crate::api::image::release();
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
    pub fn speak(line: &str, voice: &str, frames: usize, how: super::Sampling) -> Result<Vec<u8>, String> {
        let text = CString::new(line).map_err(|_| "文本无效".to_string())?;
        let speaker = CString::new(voice).map_err(|_| "音色无效".to_string())?;
        let mut pcm: Vec<u8> = Vec::new();
        let rc = unsafe {
            edge_tts_speak(
                text.as_ptr(),
                speaker.as_ptr(),
                frames as c_int,
                how.temperature,
                how.top_k as c_int,
                how.seed,
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

/// The most phonemes the model reads at once is 510; a longer sentence is
/// said in pieces.
#[cfg_attr(not(in_process_engine), allow(dead_code))]
const PIECE: usize = 500;

/// Phonemes in pieces the model can read, cut after a pause where there
/// is one, else between words, else anywhere.
#[cfg_attr(not(in_process_engine), allow(dead_code))]
fn pieces(ps: &str) -> Vec<String> {
    let chars: Vec<char> = ps.chars().collect();
    let mut out = Vec::new();
    let mut at = 0;
    while chars.len() - at > PIECE {
        let window = &chars[at..at + PIECE];
        let cut = window
            .iter()
            .rposition(|c| ",.!?;:".contains(*c))
            .or_else(|| window.iter().rposition(|c| *c == '/' || *c == ' '))
            .map_or(PIECE, |i| i + 1);
        out.push(window[..cut].iter().collect::<String>().trim().to_string());
        at += cut;
    }
    out.push(chars[at..].iter().collect::<String>().trim().to_string());
    out.retain(|p| !p.is_empty());
    out
}

/// The light voice (ios_tts/kokoro/), compiled into the app beside the
/// other. Text goes to phonemes here (`Zh`, core/src/zh_g2p.rs), phonemes to
/// sound there. Like the other voice: on the GPU on screen, on the CPU behind
/// it, let go when idle, and never in memory together with it.
#[cfg(in_process_engine)]
mod light {
    use super::{engine, last_used, light_files, pieces, tts_dir, tuned, wav, InFlight, BUSY, IDLE, LIFECYCLE};
    use novel_core::zh_g2p::Zh;
    use std::ffi::{c_char, c_int, c_void, CStr, CString};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    #[repr(C)]
    struct Kokoro {
        _private: [u8; 0],
    }

    extern "C" {
        fn edge_tts_watch();
        fn edge_tts_bg_epoch() -> i64;
        fn edge_tts_bg_sleep(epoch: i64, ns: i64);
        fn edge_tts_kokoro_load(path: *const c_char, gpu: c_int, threads: c_int) -> *mut Kokoro;
        fn edge_tts_kokoro_free(k: *mut Kokoro);
        fn edge_tts_kokoro_lanes(k: *mut Kokoro, n: c_int);
        fn edge_tts_kokoro_speak_checked(
            k: *mut Kokoro,
            phonemes: *const c_char,
            voice: *const c_char,
            speed: f32,
            seed: u32,
            n: *mut c_int,
            check: extern "C" fn(c_int, *mut c_void) -> c_int,
            user: *mut c_void,
        ) -> *mut f32;
        fn edge_tts_kokoro_free_audio(samples: *mut f32);
        fn edge_tts_kokoro_error(k: *const Kokoro) -> *const c_char;
    }

    /// The model and where it runs. Several sentences go through it at once
    /// (kokoro.cpp's lanes), each holding it, so nothing lets it go mid-way.
    struct Model {
        k: *mut Kokoro,
        gpu: bool,
    }

    unsafe impl Send for Model {}
    unsafe impl Sync for Model {}

    impl Drop for Model {
        fn drop(&mut self) {
            unsafe { edge_tts_kokoro_free(self.k) };
        }
    }

    /// The model and the front end.
    struct Loaded {
        model: Arc<Model>,
        zh: Arc<Zh>,
    }

    static LOADED: Mutex<Option<Loaded>> = Mutex::new(None);

    /// The GPU failed with the app on screen: this GPU cannot run it, so the
    /// CPU from then on.
    static NO_GPU: AtomicBool = AtomicBool::new(false);

    /// Lets it go once the sentences under way are done, so it is never in
    /// memory together with the other voice.
    pub fn unload() {
        let Some(l) = LOADED.lock().unwrap().take() else { return };
        let model = l.model;
        while Arc::strong_count(&model) > 1 {
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn loaded() -> bool {
        LOADED.lock().unwrap().is_some()
    }

    fn wanted_gpu() -> bool {
        !engine::background() && engine::gpu() && !NO_GPU.load(Ordering::SeqCst)
    }

    /// Loaded where it can run now; the front end stays across a move.
    fn ensure(slot: &mut Option<Loaded>, gpu: bool) -> Result<(), String> {
        if slot.as_ref().is_some_and(|l| l.model.gpu == gpu) {
            return Ok(());
        }
        let (model, text) = light_files(tts_dir()?).ok_or("轻量语音未安装")?;
        // Sentences still on the old one stop promptly on move; wait for them
        // so the old weights are freed before the new copy is allocated.
        let zh = match slot.take() {
            Some(l) => {
                let old = l.model;
                while Arc::strong_count(&old) > 1 {
                    std::thread::sleep(Duration::from_millis(20));
                }
                drop(old);
                l.zh
            }
            None => {
                let bytes = std::fs::read(&text).map_err(|e| format!("读取轻量语音失败: {e}"))?;
                Arc::new(Zh::load(&bytes)?)
            }
        };
        crate::api::image::release();
        // A line per sentence on how long each stage took (kokoro.cpp), kept
        // small; read over USB when the voice is slow.
        let log = tts_dir()?.join("light.log");
        if std::fs::metadata(&log).is_ok_and(|m| m.len() > 64 << 10) {
            let _ = std::fs::remove_file(&log);
        }
        std::env::set_var("EDGE_KOKORO_LOG", &log);
        // As many sentences at once as the reader chose for the other voice,
        // on the GPU, with its engine settings and a GPU queue for each, so
        // they run there side by side, not in turn; one at a time on the
        // CPU, where it works behind the screen and must stay light.
        let dir = tts_dir()?;
        let (mut lanes, env) = tuned(dir);
        if gpu {
            for (k, v) in env {
                std::env::set_var(k, v);
            }
            std::env::set_var("GGML_METAL_OWN_QUEUE", "1");
        } else {
            lanes = 1;
        }
        // `profile` beside it, put there over USB: the first sentences timed
        // op by op into the log, one at a time.
        if dir.join("profile").exists() {
            std::env::set_var("EDGE_KOKORO_PROFILE", "3");
            lanes = 1;
        } else {
            std::env::remove_var("EDGE_KOKORO_PROFILE");
        }
        let path = CString::new(model.to_string_lossy().as_bytes()).map_err(|_| "路径无效".to_string())?;
        let k = unsafe { edge_tts_kokoro_load(path.as_ptr(), gpu as c_int, 0) };
        if k.is_null() {
            return Err("启动轻量语音失败".into());
        }
        unsafe { edge_tts_kokoro_lanes(k, lanes as c_int) };
        *slot = Some(Loaded { model: Arc::new(Model { k, gpu }), zh });
        Ok(())
    }

    struct Pace {
        gpu: bool,
        epoch: i64,
        rest: bool,
        last: Instant,
    }

    extern "C" fn check_pace(mode: c_int, user: *mut c_void) -> c_int {
        let p = unsafe { &mut *(user as *mut Pace) };
        let (gpu, epoch, rest) = (p.gpu, p.epoch, p.rest);
        let misplaced = || {
            let behind = engine::background();
            let moved = unsafe { edge_tts_bg_epoch() != epoch };
            moved || if gpu { behind } else { !behind && engine::gpu() && !NO_GPU.load(Ordering::SeqCst) }
        };
        if misplaced() {
            return 1;
        }
        if mode < 0 {
            p.last = Instant::now();
            return 0;
        }
        if mode > 0 {
            if !gpu && rest && engine::background() {
                // Behind the screen, on the CPU, rest three times as long as
                // the chunk just computed, while holding the lane so another
                // sentence cannot keep the cores busy meanwhile; wakes at once
                // if the screen comes back on.
                let busy = p.last.elapsed().min(Duration::from_secs(5));
                if !busy.is_zero() {
                    unsafe { edge_tts_bg_sleep(epoch, (busy.as_nanos() as i64) * 3) };
                }
            }
            p.last = Instant::now();
            if misplaced() {
                return 1;
            }
        }
        0
    }

    /// One sentence, every piece of it, as 16-bit 24 kHz mono; on error, also
    /// whether this attempt ran on the GPU.
    fn say(line: &str, voice: &CStr) -> Result<Vec<u8>, (String, bool)> {
        let (model, zh, epoch) = {
            let _g = LIFECYCLE.lock().unwrap();
            // One voice in memory at a time.
            engine::unload();
            let mut slot = LOADED.lock().unwrap();
            let first = slot.is_none();
            let epoch = unsafe { edge_tts_bg_epoch() };
            let want = wanted_gpu();
            ensure(&mut slot, want).map_err(|e| (e, want))?;
            if first {
                watch_idle();
            }
            let l = slot.as_ref().unwrap();
            (l.model.clone(), l.zh.clone(), epoch)
        };
        let mut pace = Pace {
            gpu: model.gpu,
            epoch,
            rest: !cfg!(test),
            last: Instant::now(),
        };
        let mut pcm = Vec::new();
        for piece in pieces(&zh.phonemes(line)) {
            let ps = CString::new(piece).map_err(|_| ("文本无效".to_string(), model.gpu))?;
            let mut n: c_int = 0;
            let samples = unsafe {
                edge_tts_kokoro_speak_checked(
                    model.k,
                    ps.as_ptr(),
                    voice.as_ptr(),
                    1.0,
                    1,
                    &mut n,
                    check_pace,
                    &mut pace as *mut Pace as *mut c_void,
                )
            };
            if samples.is_null() {
                let why = unsafe { CStr::from_ptr(edge_tts_kokoro_error(model.k)) }.to_string_lossy().into_owned();
                return Err((format!("语音合成失败: {why}"), model.gpu));
            }
            for &x in unsafe { std::slice::from_raw_parts(samples, n.max(0) as usize) } {
                let s = (x.clamp(-1.0, 1.0) * 32767.0).round_ties_even() as i16;
                pcm.extend_from_slice(&s.to_le_bytes());
            }
            unsafe { edge_tts_kokoro_free_audio(samples) };
        }
        Ok(pcm)
    }

    /// Whether a failed attempt was caught by the app moving between screen
    /// and background (`behind`: where it was when the attempt started).
    fn moving(behind: bool, was_gpu: bool, err: &str) -> bool {
        if err.contains("cancelled") {
            return true;
        }
        let gpu_err = was_gpu && (err.contains("compute failed") || err.contains("启动轻量语音失败"));
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if engine::background() != behind || (was_gpu != wanted_gpu()) {
                return true;
            }
            if !gpu_err || Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    pub fn speak(line: &str, voice: &str) -> Result<Vec<u8>, String> {
        unsafe { edge_tts_watch() };
        let _busy = InFlight::new();
        let voice = CString::new(voice).map_err(|_| "音色无效".to_string())?;
        let mut moves = 0;
        let mut gpu_fails = 0;
        loop {
            let behind = engine::background();
            match say(line, &voice) {
                Ok(pcm) if pcm.is_empty() => return Err("语音合成为空".into()),
                Ok(pcm) => return Ok(wav(&pcm)),
                Err((e, was_gpu)) if moves < 20 && moving(behind, was_gpu, &e) => {
                    moves += 1;
                }
                Err((e, true))
                    if gpu_fails < 1
                        && !engine::background()
                        && (e.contains("compute failed") || e.contains("启动轻量语音失败")) =>
                {
                    gpu_fails += 1;
                    eprintln!("light voice: GPU failed on screen, CPU from now on: {e}");
                    NO_GPU.store(true, Ordering::SeqCst);
                }
                Err((e, _)) => return Err(e),
            }
        }
    }

    /// Lets the voice go once nothing has been said for [`IDLE`], or for a
    /// few seconds behind the screen.
    fn watch_idle() {
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_secs(5));
            if !loaded() {
                return;
            }
            let idle = if engine::background() { Duration::from_secs(15) } else { IDLE };
            if BUSY.load(Ordering::SeqCst) == 0 && last_used().lock().unwrap().elapsed() > idle {
                unload();
                return;
            }
        });
    }

    /// Where it is loaded: the GPU (true), the CPU (false), or not at all.
    #[cfg(test)]
    pub fn on_gpu() -> Option<bool> {
        LOADED.lock().unwrap().as_ref().map(|l| l.model.gpu)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_phonemes_are_cut_after_a_pause() {
        let long = "ㄋㄧ3/ㄏㄠ3, ".repeat(80);
        let ps = pieces(&long);
        assert!(ps.len() > 1);
        assert!(ps.iter().all(|p| p.chars().count() <= PIECE && p.ends_with(',')));
        assert_eq!(ps.concat().replace(' ', ""), long.replace(' ', ""));
        assert_eq!(pieces("ㄋㄧ3"), ["ㄋㄧ3"]);
    }

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

    /// The light voice the same way (CI): NOVEL_TTS_DIR/kokoro holds it.
    /// What it said goes to NOVEL_TTS_OUT, to be listened to.
    #[cfg(in_process_engine)]
    #[test]
    #[ignore]
    fn light_bench() {
        extern "C" {
            fn edge_tts_set_background(on: std::ffi::c_int);
        }
        let memory = |phase: &str| {
            let (now, peak) = crate::engine_thread::footprint();
            println!("[内存] {phase}：当前 {} MB · 最高 {} MB", now >> 20, peak >> 20);
        };
        init_tts(std::env::var("NOVEL_TTS_DIR").expect("set NOVEL_TTS_DIR")).unwrap();
        let out = std::env::var("NOVEL_TTS_OUT").map(PathBuf::from).ok();
        if let Some(o) = &out {
            std::fs::create_dir_all(o).unwrap();
        }
        assert!(tts_voice_ready("k:zf_001".into()).unwrap());
        assert!(tts_status().unwrap().light);
        memory("开始");
        let long = "他沿着河岸一直往前走，走过了石桥，走过了柳树，走过了村口那间早已没人住的老屋，".repeat(8) + "直到天黑。";
        let lines = [
            ("短句", "今天的风有点大，我们早点回家吧。".to_string()),
            ("长句", "他把书合上，望着窗外的雨，很久都没有说话，直到天色暗了下来，才慢慢站起身，去厨房烧了一壶水。".to_string()),
            ("数字", "第3章，2023年5月1日，他花了3.5元。".to_string()),
            ("超长", long),
        ];
        let gpu = engine::gpu();
        for (device, behind) in [("GPU", 0), ("CPU", 1)] {
            if behind == 0 && !gpu {
                println!("[GPU] 这块 GPU 跑不了，只测处理器");
                continue;
            }
            unsafe { edge_tts_set_background(behind) };
            let t = Instant::now();
            for (i, (name, line)) in lines.iter().enumerate() {
                let t1 = Instant::now();
                let wav = say(line, "k:zf_001").unwrap();
                let secs = (wav.len() - 44) as f64 / 48000.0;
                let took = t1.elapsed().as_secs_f64();
                if i == 0 {
                    println!("[{device} 首句含载入] {:.1} 秒", t.elapsed().as_secs_f64());
                    memory(&format!("{device} 载入后"));
                }
                println!("[{device} {name}] {secs:.1} 秒语音用 {took:.2} 秒 · RTF {:.2}", took / secs);
                assert!(secs > 1.0);
                if let Some(o) = &out {
                    std::fs::write(o.join(format!("{device}-{i}.wav")), &wav).unwrap();
                }
            }
            assert_eq!(light::on_gpu(), Some(behind == 0 && gpu));
            memory(&format!("{device} 说完"));
        }
        unsafe { edge_tts_set_background(0) };

        // Four at once, as the 听书 prepare sends them: each as when alone.
        let alone: Vec<Vec<u8>> = lines[..3].iter().map(|(_, l)| say(l, "k:zf_001").unwrap()).collect();
        let t = Instant::now();
        let together: Vec<Vec<u8>> = std::thread::scope(|s| {
            let hs: Vec<_> = lines[..3].iter().map(|(_, l)| s.spawn(move || say(l, "k:zf_001").unwrap())).collect();
            hs.into_iter().map(|h| h.join().unwrap()).collect()
        });
        let secs: f64 = together.iter().map(|w| (w.len() - 44) as f64 / 48000.0).sum();
        println!("[同时三句] {secs:.1} 秒语音用 {:.2} 秒 · RTF {:.2}", t.elapsed().as_secs_f64(), t.elapsed().as_secs_f64() / secs);
        assert!(alone == together);
        memory("同时三句后");

        // Every voice, and the cache.
        for v in ["zf_001", "zf_008", "zf_047", "zf_086", "zm_009", "zm_031", "zm_066"] {
            let wav = say("你好，很高兴认识你。", &format!("k:{v}")).unwrap();
            if let Some(o) = &out {
                std::fs::write(o.join(format!("voice-{v}.wav")), &wav).unwrap();
            }
        }
        assert!(say("你好。", "k:nobody").is_err());
        let line = "提前合成的句子从缓存里读。";
        let path = cached(line, "k:zm_009").unwrap();
        let _ = std::fs::remove_file(&path);
        assert!(prepare(line.into(), "k:zm_009".into()).unwrap());
        assert!(!prepare(line.into(), "k:zm_009".into()).unwrap());
        assert_ne!(path, cached(line, "k:zf_001").unwrap());

        // The other voice takes its place, and back.
        if tts_ready().unwrap() {
            ensure().unwrap();
            assert_eq!(light::on_gpu(), None);
            say("又换回来了。", "k:zf_001").unwrap();
            assert!(!engine::loaded());
        }
        stop_tts();
        assert_eq!(light::on_gpu(), None);
        memory("结束");
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

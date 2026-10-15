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

use crate::api::ai::http;
use serde_json::json;
use std::path::{Path, PathBuf};
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
    let _ = TTS_DIR.set(p);
    Ok(())
}

fn tts_dir() -> Result<&'static Path, String> {
    TTS_DIR
        .get()
        .map(|p| p.as_path())
        .ok_or_else(|| "朗读目录未初始化".into())
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
    let engine = find_engine(dir);
    let talker = find_model(dir, TALKER);
    let codec = find_model(dir, CODEC);
    let voice = match (&talker, &codec) {
        (Some(t), Some(_)) => t.file_stem().map(|s| s.to_string_lossy().into_owned()),
        _ => None,
    };
    Ok(TtsStatus {
        dir: dir.display().to_string(),
        engine: engine.is_some(),
        voice,
        engine_bytes: engine.as_deref().map(file_bytes).unwrap_or(0),
        voice_bytes: [talker, codec].iter().flatten().map(|p| file_bytes(p)).sum(),
    })
}

/// True when the engine and both model files are present — the only state in
/// which [`synth`] can succeed.
pub fn tts_ready() -> Result<bool, String> {
    let dir = tts_dir()?;
    Ok(find_engine(dir).is_some()
        && find_model(dir, TALKER).is_some()
        && find_model(dir, CODEC).is_some())
}

/// Delete the engine (its folder, if it came in one), but never the voice —
/// that is a separate download with a separate button.
pub fn delete_tts_engine() -> Result<(), String> {
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

fn health() -> bool {
    matches!(http(PORT, "GET", "/health", None, 2), Ok((200, _)))
}

/// Stop the engine now. The next sentence starts it again.
pub fn stop_tts() {
    let _g = LIFECYCLE.lock().unwrap();
    kill();
}

fn kill() {
    if let Some(mut child) = server().lock().unwrap().take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

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

fn speak(line: &str, voice: &str) -> Result<Vec<u8>, String> {
    let _busy = InFlight::new();
    ensure()?;
    // A bound on frames (12.5 a second) at a slow reading pace, so a sentence
    // the model will not finish cannot run on into a minute of noise.
    let frames = (line.chars().count() * 6 + 40).min(900);
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

//! Local text-to-speech. sherpa-onnx running a Kokoro multilingual voice is run
//! as a one-shot child per utterance: feed it a sentence, it writes a WAV, we
//! hand the bytes back to Flutter to play. Deliberately not compiled in: the
//! engine and the voice are separate downloads the user installs (and can
//! delete) from the AI page, and nothing is ever uploaded — synthesis is
//! entirely on-device.
//!
//! Why Kokoro (and not Piper, and not the plainer MeloTTS before it): Piper's
//! Chinese front-end is espeak-ng, which has no word segmentation and reads
//! character by character, so it neither phrases nor pauses. MeloTTS fixed the
//! phrasing but ships a single, conversational female voice — it sounds like
//! everyday speech, not reading. Kokoro carries a real Chinese front-end *and*
//! bundles eight Chinese speakers (four male, four female) in one voices.bin,
//! so the user can pick a male narration voice via `--sid` with no extra
//! download — as close to a "storyteller" read as a local model gets.
//!
//! Mirrors the llama-server arrangement in [`crate::api::ai`]: a data dir the
//! binary and weights live in, shallow file discovery, and Windows spawns that
//! never flash a console. It is not a server — each call spawns, synthesizes,
//! and exits.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

static TTS_DIR: OnceLock<PathBuf> = OnceLock::new();

#[cfg(windows)]
const TTS_EXE: &str = "sherpa-onnx-offline-tts.exe";
#[cfg(not(windows))]
const TTS_EXE: &str = "sherpa-onnx-offline-tts";

/// Kokoro's one distinctive file — the packed speaker embeddings. Keying voice
/// detection on this (rather than the generic `model.onnx`) means a leftover
/// MeloTTS install is not mistaken for a Kokoro voice. Its siblings (model.onnx,
/// tokens.txt, espeak-ng-data/, lexicon-*.txt, *-zh.fst) are found relative to
/// it.
const VOICE_MARKER: &str = "voices.bin";

/// Called once at startup with `<app-support>/tts`. The sherpa-onnx binary (and
/// the DLLs its archive brings) and the extracted voice folder live here; the
/// user can also drop files in by hand.
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

/// Find a file by exact name anywhere within `depth` levels, dirs visited in
/// sorted order for determinism. Both downloads extract into their own top
/// folder, so the binary and the model sit a couple of levels down.
fn find_named(dir: &Path, name: &str, depth: u32) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut subdirs = Vec::new();
    for e in entries.flatten() {
        let p = e.path();
        if p.is_file() && p.file_name().is_some_and(|n| n == name) {
            return Some(p);
        }
        if p.is_dir() {
            subdirs.push(p);
        }
    }
    if depth == 0 {
        return None;
    }
    subdirs.sort();
    subdirs
        .into_iter()
        .find_map(|d| find_named(&d, name, depth - 1))
}

fn find_engine(dir: &Path) -> Option<PathBuf> {
    find_named(dir, TTS_EXE, 4)
}

/// The installed voice, located by its `voices.bin`.
fn find_voice(dir: &Path) -> Option<PathBuf> {
    find_named(dir, VOICE_MARKER, 4)
}

/// The directory directly under `base` that contains `target` (which may sit
/// deeper) — i.e. the archive's own top folder. Used to size and to cleanly
/// delete a whole install without touching the other one.
fn top_folder(base: &Path, target: &Path) -> Option<PathBuf> {
    let rel = target.strip_prefix(base).ok()?;
    let first = rel.components().next()?;
    Some(base.join(first.as_os_str()))
}

fn file_bytes(p: &Path) -> i64 {
    std::fs::metadata(p).map(|m| m.len() as i64).unwrap_or(0)
}

fn dir_bytes(p: &Path) -> i64 {
    if p.is_file() {
        return file_bytes(p);
    }
    std::fs::read_dir(p)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| dir_bytes(&e.path()))
        .sum()
}

#[derive(Debug, Clone)]
pub struct TtsStatus {
    pub dir: String,
    /// The sherpa-onnx binary is present.
    pub engine: bool,
    /// The installed voice folder's name (e.g. `kokoro-multi-lang-v1_0`), or absent.
    pub voice: Option<String>,
    pub engine_bytes: i64,
    pub voice_bytes: i64,
}

pub fn tts_status() -> Result<TtsStatus, String> {
    let dir = tts_dir()?;
    let engine = find_engine(dir);
    let voice = find_voice(dir);
    let voice_root = voice.as_deref().and_then(|m| top_folder(dir, m));
    Ok(TtsStatus {
        dir: dir.display().to_string(),
        engine: engine.is_some(),
        voice: voice_root
            .as_deref()
            .and_then(|p| p.file_name().map(|s| s.to_string_lossy().into_owned())),
        engine_bytes: engine
            .as_deref()
            .and_then(|e| top_folder(dir, e))
            .map(|p| dir_bytes(&p))
            .unwrap_or(0),
        voice_bytes: voice_root.map(|p| dir_bytes(&p)).unwrap_or(0),
    })
}

/// True when both the binary and a voice are present — the only state in which
/// [`synth`] can succeed.
pub fn tts_ready() -> Result<bool, String> {
    let dir = tts_dir()?;
    Ok(find_engine(dir).is_some() && find_voice(dir).is_some())
}

/// Delete the sherpa-onnx binary and its bundled DLLs (the engine's top folder),
/// but never the voice — that is a separate download with a separate button.
pub fn delete_tts_engine() -> Result<(), String> {
    let dir = tts_dir()?;
    let exe = find_engine(dir).ok_or("朗读引擎未安装")?;
    let root = top_folder(dir, &exe).unwrap_or(exe);
    remove(&root)
}

/// Delete the installed voice folder.
pub fn delete_tts_voice() -> Result<(), String> {
    let dir = tts_dir()?;
    let voice = find_voice(dir).ok_or("语音未安装")?;
    let root = top_folder(dir, &voice).unwrap_or(voice);
    remove(&root)
}

fn remove(p: &Path) -> Result<(), String> {
    if p.is_dir() {
        std::fs::remove_dir_all(p).map_err(|e| format!("删除失败: {e}"))
    } else {
        std::fs::remove_file(p).map_err(|e| format!("删除失败: {e}"))
    }
}

/// A per-process counter so concurrent synth calls (the player renders the whole
/// chapter ahead of playback) never collide on a temp path.
fn next_tmp() -> PathBuf {
    static N: AtomicU64 = AtomicU64::new(0);
    let n = N.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("novel_tts_{}_{n}.wav", std::process::id()))
}

/// A voice as the caller names it: `"<model>-<sid>"`, e.g. `kokoro-49`. The
/// model half picks which family of sherpa flags to build, the sid half picks
/// the speaker within it. Naming voices this way (rather than by a bare integer)
/// is what lets a second Chinese model be added without every cached chapter
/// silently changing meaning: the cache directory carries the model name too.
fn parse_voice(voice: &str) -> Result<(&str, i32), String> {
    let (model, sid) = voice.rsplit_once('-').ok_or("音色标识无效")?;
    let sid: i32 = sid.parse().map_err(|_| "音色标识无效".to_string())?;
    Ok((model, sid.max(0)))
}

/// Synthesize one utterance to WAV bytes. `length_scale` sets pace: 1.0 is the
/// voice's natural speed, larger is slower (so the caller passes 1.0 / speed).
/// `voice` is a `"<model>-<sid>"` key — see [`parse_voice`]. One short sentence
/// per call: the pre-processor drives sentence by sentence, which keeps the
/// highlight fine-grained and makes a whole chapter resumable mid-render.
pub fn synth(text: String, length_scale: f64, voice: String) -> Result<Vec<u8>, String> {
    let (model, sid) = parse_voice(&voice)?;
    match model {
        "kokoro" => synth_kokoro(text, length_scale, sid),
        other => Err(format!("未知音色模型: {other}")),
    }
}

fn synth_kokoro(text: String, length_scale: f64, sid: i32) -> Result<Vec<u8>, String> {
    let dir = tts_dir()?;
    let exe = find_engine(dir).ok_or("朗读引擎未安装（缺 sherpa-onnx）")?;
    let voices = find_voice(dir).ok_or("中文语音未安装（缺 voices.bin）")?;
    let mdir = voices.parent().ok_or("语音目录异常")?;
    let model = mdir.join("model.onnx");

    let line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.is_empty() {
        return Err("空文本".into());
    }

    // Kokoro's Chinese front-end: a combined pinyin lexicon (Chinese + English
    // so inline English still reads) and the date/number rule FSTs. Include only
    // the files that are actually present so a repackaged voice cannot break the
    // command.
    let lexicons: Vec<String> = ["lexicon-us-en.txt", "lexicon-zh.txt"]
        .iter()
        .map(|f| mdir.join(f))
        .filter(|p| p.exists())
        .map(|p| p.display().to_string())
        .collect();
    let fsts: Vec<String> = ["date-zh.fst", "number-zh.fst"]
        .iter()
        .map(|f| mdir.join(f))
        .filter(|p| p.exists())
        .map(|p| p.display().to_string())
        .collect();

    let out = next_tmp();
    let mut cmd = Command::new(&exe);
    cmd.arg(format!("--kokoro-model={}", model.display()))
        .arg(format!("--kokoro-voices={}", voices.display()))
        .arg(format!(
            "--kokoro-tokens={}",
            mdir.join("tokens.txt").display()
        ))
        .arg(format!(
            "--kokoro-data-dir={}",
            mdir.join("espeak-ng-data").display()
        ));
    if !lexicons.is_empty() {
        cmd.arg(format!("--kokoro-lexicon={}", lexicons.join(",")));
    }
    if !fsts.is_empty() {
        cmd.arg(format!("--tts-rule-fsts={}", fsts.join(",")));
    }
    cmd.arg(format!(
        "--kokoro-length-scale={:.2}",
        length_scale.clamp(0.3, 3.0)
    ))
    .arg(format!("--sid={sid}"))
    .arg("--num-threads=2")
    .arg(format!("--output-filename={}", out.display()))
    // The text to speak is a positional argument.
    .arg(&line)
    // Run from the binary's own folder so it finds onnxruntime.dll and the
    // other sherpa DLLs sitting next to it.
    .current_dir(exe.parent().unwrap_or(dir))
    .stdin(Stdio::null())
    .stdout(Stdio::null())
    .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }

    // Spawn rather than `status()` so the child can be adopted first: synthesis
    // is short, but a crash mid-sentence should not leave one behind either.
    let mut child = cmd.spawn().map_err(|e| format!("启动朗读引擎失败: {e}"))?;
    crate::job::adopt(&child);
    let status = child.wait().map_err(|e| format!("朗读引擎异常: {e}"))?;
    if !status.success() {
        let _ = std::fs::remove_file(&out);
        return Err("语音合成失败".into());
    }
    let bytes = std::fs::read(&out).map_err(|e| format!("读取音频失败: {e}"))?;
    let _ = std::fs::remove_file(&out);
    if bytes.is_empty() {
        return Err("语音合成为空".into());
    }
    Ok(bytes)
}

/// Extract a `.tar.bz2` (how the sherpa-onnx binary and voice ship) into
/// `dest_dir`, preserving the archive's own top folder. Pure-Rust bzip2 so no C
/// toolchain is needed, and done here rather than in Dart so the large model
/// decompress does not block the UI isolate.
pub fn extract_tar_bz2(archive_path: String, dest_dir: String) -> Result<(), String> {
    let f = std::fs::File::open(&archive_path).map_err(|e| format!("打开压缩包失败: {e}"))?;
    let dec = bzip2_rs::DecoderReader::new(std::io::BufReader::new(f));
    std::fs::create_dir_all(&dest_dir).map_err(|e| format!("建目录失败: {e}"))?;
    tar::Archive::new(dec)
        .unpack(&dest_dir)
        .map_err(|e| format!("解压失败: {e}"))
}

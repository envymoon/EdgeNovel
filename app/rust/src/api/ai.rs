//! The local AI engine. A llama-server process managed as a child, spoken to
//! over loopback HTTP — deliberately not a compiled-in binding: the engine
//! updates independently of the app, crashes without taking the reader down,
//! and is swappable for anything speaking the same API (on Android it will be
//! the same llama.cpp behind a different launcher).
//!
//! The model only ever gets closed tasks: bounded input, bounded output, a
//! verifiable shape. Free generation is not on the menu.

use crate::api::book::{self, SearchHit};
use crate::frb_generated::StreamSink;
use novel_core::chunk;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// The chat model answers here; the embedder, a separate llama-server with a
/// separate model, answers next door. One process cannot serve two models, and
/// the embedder is small enough (~50 MB) that keeping both up costs nothing.
const PORT: u16 = 8737;
const EMBED_PORT: u16 = 8738;

#[cfg(windows)]
const ENGINE_EXE: &str = "llama-server.exe";
#[cfg(not(windows))]
const ENGINE_EXE: &str = "llama-server";

static AI_DIR: OnceLock<PathBuf> = OnceLock::new();
/// One flag per long-running pass. Enrichment and indexing are different
/// features on different models; a shared flag would let stopping one kill the
/// other halfway through a chapter.
static CANCEL: AtomicBool = AtomicBool::new(false);
static CANCEL_INDEX: AtomicBool = AtomicBool::new(false);

/// Cross-platform policy passed in by the Flutter layer. The UI owns persistence;
/// Rust owns the actual inference knobs. Keeping this contract free of Windows,
/// Android, or iOS types lets every platform feed the same queue later.
#[derive(Debug, Clone)]
pub struct AiRuntimeConfig {
    /// 0 = quiet, 1 = balanced, 2 = fast.
    pub mode: u8,
    /// 0 = automatic, 1 = CPU only, 2 = GPU preferred.
    pub backend: u8,
    /// Zero lets the engine choose a profile-derived ceiling.
    pub thread_limit: u32,
    /// 0 = conservative, 1 = balanced, 2 = performance.
    pub thermal_bias: u8,
    /// Zero when the platform adapter cannot report physical memory.
    pub total_memory_mb: u64,
}

impl Default for AiRuntimeConfig {
    fn default() -> Self {
        Self {
            mode: 0,
            backend: 0,
            thread_limit: 0,
            thermal_bias: 1,
            total_memory_mb: 0,
        }
    }
}

fn runtime_config() -> &'static Mutex<AiRuntimeConfig> {
    static C: OnceLock<Mutex<AiRuntimeConfig>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(AiRuntimeConfig::default()))
}

pub fn set_ai_runtime_config(
    mode: u8,
    backend: u8,
    thread_limit: u32,
    thermal_bias: u8,
    total_memory_mb: u64,
) {
    *runtime_config().lock().unwrap() = AiRuntimeConfig {
        mode: mode.min(2),
        backend: backend.min(2),
        thread_limit: thread_limit.min(64),
        thermal_bias: thermal_bias.min(2),
        total_memory_mb,
    };
}

/// Platform facts used by the shared queue controller. Android and iOS will
/// provide these through their native adapters; Windows is implemented here so
/// the policy can be exercised before the mobile shells exist.
#[derive(Debug, Clone)]
pub struct AiDeviceState {
    pub platform: String,
    pub charging: Option<bool>,
    pub battery_percent: Option<u8>,
    pub idle_seconds: Option<u32>,
    pub logical_cores: u32,
    pub total_memory_mb: Option<u64>,
    /// Windows has no dependable system-wide thermal state API. Mobile adapters
    /// will report nominal/fair/serious/critical here.
    pub thermal_state: String,
}

#[cfg(windows)]
#[repr(C)]
struct SystemPowerStatus {
    ac_line_status: u8,
    battery_flag: u8,
    battery_life_percent: u8,
    system_status_flag: u8,
    battery_life_time: u32,
    battery_full_life_time: u32,
}

#[cfg(windows)]
#[repr(C)]
struct LastInputInfo {
    cb_size: u32,
    dw_time: u32,
}

#[cfg(windows)]
#[repr(C)]
struct MemoryStatusEx {
    dw_length: u32,
    dw_memory_load: u32,
    ull_total_phys: u64,
    ull_avail_phys: u64,
    ull_total_page_file: u64,
    ull_avail_page_file: u64,
    ull_total_virtual: u64,
    ull_avail_virtual: u64,
    ull_avail_extended_virtual: u64,
}

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn GetSystemPowerStatus(status: *mut SystemPowerStatus) -> i32;
    fn GetTickCount() -> u32;
    fn GlobalMemoryStatusEx(status: *mut MemoryStatusEx) -> i32;
}

#[cfg(windows)]
#[link(name = "user32")]
extern "system" {
    fn GetLastInputInfo(info: *mut LastInputInfo) -> i32;
}

pub fn ai_device_state() -> AiDeviceState {
    let cores = std::thread::available_parallelism()
        .map(|n| n.get() as u32)
        .unwrap_or(1);

    #[cfg(windows)]
    {
        let mut power = SystemPowerStatus {
            ac_line_status: 255,
            battery_flag: 255,
            battery_life_percent: 255,
            system_status_flag: 0,
            battery_life_time: 0,
            battery_full_life_time: 0,
        };
        let power_ok = unsafe { GetSystemPowerStatus(&mut power) } != 0;
        let no_battery = power_ok && power.battery_flag & 128 != 0;
        let charging = if !power_ok || no_battery || power.ac_line_status == 255 {
            None
        } else {
            Some(power.ac_line_status == 1)
        };
        let battery_percent = if !power_ok || no_battery || power.battery_life_percent == 255 {
            None
        } else {
            Some(power.battery_life_percent.min(100))
        };

        let mut input = LastInputInfo {
            cb_size: std::mem::size_of::<LastInputInfo>() as u32,
            dw_time: 0,
        };
        let idle_seconds = if unsafe { GetLastInputInfo(&mut input) } != 0 {
            let tick = unsafe { GetTickCount() };
            Some(tick.wrapping_sub(input.dw_time) / 1000)
        } else {
            None
        };

        let mut memory = MemoryStatusEx {
            dw_length: std::mem::size_of::<MemoryStatusEx>() as u32,
            dw_memory_load: 0,
            ull_total_phys: 0,
            ull_avail_phys: 0,
            ull_total_page_file: 0,
            ull_avail_page_file: 0,
            ull_total_virtual: 0,
            ull_avail_virtual: 0,
            ull_avail_extended_virtual: 0,
        };
        let total_memory_mb = if unsafe { GlobalMemoryStatusEx(&mut memory) } != 0 {
            Some(memory.ull_total_phys / 1024 / 1024)
        } else {
            None
        };

        return AiDeviceState {
            platform: "windows".into(),
            charging,
            battery_percent,
            idle_seconds,
            logical_cores: cores,
            total_memory_mb,
            thermal_state: "unavailable".into(),
        };
    }

    #[cfg(not(windows))]
    AiDeviceState {
        platform: std::env::consts::OS.into(),
        charging: None,
        battery_percent: None,
        idle_seconds: None,
        logical_cores: cores,
        total_memory_mb: None,
        thermal_state: "unavailable".into(),
    }
}

fn engine_child() -> &'static Mutex<Option<Child>> {
    static C: OnceLock<Mutex<Option<Child>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

fn engine_context() -> &'static Mutex<Option<u32>> {
    static C: OnceLock<Mutex<Option<u32>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

fn embed_child() -> &'static Mutex<Option<Child>> {
    static C: OnceLock<Mutex<Option<Child>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// Called once at startup with `<app-support>/ai`. Engine binaries and model
/// weights live there; the user can also drop files in by hand.
pub fn init_ai(dir: String) -> Result<(), String> {
    let p = PathBuf::from(dir);
    std::fs::create_dir_all(&p).map_err(|e| format!("建 AI 目录失败: {e}"))?;
    let _ = AI_DIR.set(p);
    Ok(())
}

fn ai_dir() -> Result<&'static Path, String> {
    AI_DIR
        .get()
        .map(|p| p.as_path())
        .ok_or_else(|| "AI 目录未初始化".into())
}

/// The engine zip extracts with its own layout; search shallowly instead of
/// assuming one.
fn find_engine(dir: &Path) -> Option<PathBuf> {
    fn walk(dir: &Path, depth: u32) -> Option<PathBuf> {
        let entries = std::fs::read_dir(dir).ok()?;
        let mut dirs = Vec::new();
        for e in entries.flatten() {
            let p = e.path();
            if p.is_file() && p.file_name().is_some_and(|n| n == ENGINE_EXE) {
                return Some(p);
            }
            if p.is_dir() {
                dirs.push(p);
            }
        }
        if depth == 0 {
            return None;
        }
        dirs.into_iter().find_map(|d| walk(&d, depth - 1))
    }
    walk(dir, 2)
}

/// Which .gguf is which. The embedder names itself (bge / embed / gte / e5) —
/// so the user drops two files into one folder and nothing needs configuring.
fn is_embed_model(p: &Path) -> bool {
    let n = p
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    ["bge", "embed", "gte", "e5-"].iter().any(|k| n.contains(k))
}

/// First matching .gguf in the AI directory, by name for determinism.
fn find_gguf(dir: &Path, embed: bool) -> Option<PathBuf> {
    let mut models: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.extension()
                .is_some_and(|x| x.eq_ignore_ascii_case("gguf"))
        })
        .filter(|p| is_embed_model(p) == embed)
        .collect();
    models.sort();
    models.into_iter().next()
}

fn find_model(dir: &Path) -> Option<PathBuf> {
    find_gguf(dir, false)
}

#[derive(Debug, Clone)]
pub struct AiStatus {
    pub dir: String,
    pub engine: bool,
    pub model: Option<String>,
    /// The embedding model, installed separately: semantic search needs it,
    /// summaries and moods do not. Absent is a normal state, not an error.
    pub embed_model: Option<String>,
    /// Bytes on disk, so the page offering to delete something can say what it
    /// is worth deleting.
    pub engine_bytes: i64,
    pub model_bytes: i64,
    pub embed_bytes: i64,
    pub running: bool,
}

fn file_bytes(p: Option<PathBuf>) -> i64 {
    p.and_then(|p| std::fs::metadata(p).ok())
        .map(|m| m.len() as i64)
        .unwrap_or(0)
}

/// Engine files only. Model downloads, rollback copies and their tiny records
/// share this directory, but deleting llama.cpp must never erase them.
fn is_engine_entry(p: &Path) -> bool {
    let name = p
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    !p.extension()
        .is_some_and(|x| x.eq_ignore_ascii_case("gguf"))
        && !name.starts_with(".novel-")
        && !name.starts_with("novel-chat-")
        && !name.starts_with("novel-embed-")
}

fn engine_files(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| is_engine_entry(p))
        .collect()
}

#[cfg(test)]
mod engine_file_tests {
    use super::is_engine_entry;
    use std::path::Path;

    #[test]
    fn engine_delete_filter_preserves_models_and_rollback_data() {
        assert!(is_engine_entry(Path::new("llama-server.exe")));
        assert!(is_engine_entry(Path::new("ggml-vulkan.dll")));
        assert!(!is_engine_entry(Path::new("Qwen3-0.6B-Q8_0.gguf")));
        assert!(!is_engine_entry(Path::new(
            "novel-chat-previous.gguf.rollback"
        )));
        assert!(!is_engine_entry(Path::new(".novel-chat-model.json")));
        assert!(!is_engine_entry(Path::new(
            "novel-embed-current.gguf.download"
        )));
    }
}

fn dir_bytes(p: &Path) -> i64 {
    if p.is_file() {
        return std::fs::metadata(p).map(|m| m.len() as i64).unwrap_or(0);
    }
    std::fs::read_dir(p)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| dir_bytes(&e.path()))
        .sum()
}

pub fn ai_status() -> Result<AiStatus, String> {
    let dir = ai_dir()?;
    Ok(AiStatus {
        dir: dir.display().to_string(),
        engine: find_engine(dir).is_some(),
        model: find_model(dir)
            .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned())),
        embed_model: find_gguf(dir, true)
            .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned())),
        engine_bytes: engine_files(dir).iter().map(|p| dir_bytes(p)).sum(),
        model_bytes: file_bytes(find_model(dir)),
        embed_bytes: file_bytes(find_gguf(dir, true)),
        running: health(PORT) || health(EMBED_PORT),
    })
}

/// Delete an installed model. The engine holds the file open while it runs, so
/// stop it first — on Windows the delete simply fails otherwise.
///
/// Vectors already computed are left alone: they are still correct, and
/// re-installing the same model makes them usable again without re-indexing.
pub fn delete_model(embed: bool) -> Result<(), String> {
    let path = find_gguf(ai_dir()?, embed).ok_or("模型未安装")?;
    stop_ai();
    std::fs::remove_file(&path).map_err(|e| format!("删除失败: {e}"))
}

/// Delete the engine: the binary and everything that shipped with it, but never
/// a model — those are separate downloads with separate delete buttons.
pub fn delete_engine() -> Result<(), String> {
    let dir = ai_dir()?;
    stop_ai();
    for p in engine_files(dir) {
        let r = if p.is_dir() {
            std::fs::remove_dir_all(&p)
        } else {
            std::fs::remove_file(&p)
        };
        r.map_err(|e| format!("删除失败: {e}"))?;
    }
    Ok(())
}

fn health(port: u16) -> bool {
    matches!(http(port, "GET", "/health", None, 2), Ok((200, _)))
}

/// Bring an engine up if it is not already answering. An orphan from a previous
/// run that still holds the port is an engine, not an error — reuse it.
///
/// Both models come up the same way; only the model file and a couple of flags
/// differ, so the spawn lives in one place and the callers say what they need.
///
/// `waiting` is called once a second while the model loads, with the seconds
/// spent so far. A cold load off a spinning disk can take most of a minute, and
/// a caller that cannot say anything during it looks hung.
fn ensure(
    port: u16,
    slot: &'static Mutex<Option<Child>>,
    model: PathBuf,
    extra: &[&str],
    mut waiting: impl FnMut(u32),
) -> Result<(), String> {
    if health(port) {
        return Ok(());
    }
    let dir = ai_dir()?;
    let exe = find_engine(dir).ok_or("引擎未安装（缺 llama-server）")?;

    // The model and prompts stay identical between profiles. Only scheduling
    // pressure changes, so quiet mode never buys comfort by degrading results.
    let config = runtime_config().lock().unwrap().clone();
    let cores = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);
    let profile_threads = match config.mode {
        0 => 2,
        1 => (cores / 2).clamp(2, 8),
        _ => cores.saturating_sub(1).clamp(2, 16),
    };
    let mut threads = if config.thread_limit == 0 {
        profile_threads
    } else {
        (config.thread_limit as usize).clamp(1, cores.max(1))
    };
    if config.thread_limit == 0 {
        if config.total_memory_mb > 0 && config.total_memory_mb < 5120 {
            threads = threads.min(1);
        } else if config.total_memory_mb > 0 && config.total_memory_mb < 7168 {
            threads = threads.min(2);
        }
    }
    let gpu_layers = if config.backend == 1 { "0" } else { "99" };
    let priority = match config.mode {
        0 => "-1",
        1 => "0",
        _ => "1",
    };
    let poll = if config.mode == 2 { "50" } else { "0" };

    let mut cmd = Command::new(&exe);
    cmd.args(["-m"])
        .arg(&model)
        .args([
            "--port",
            &port.to_string(),
            "--host",
            "127.0.0.1",
            // Offload every layer when a GPU backend (Vulkan/CUDA) is present;
            // the CPU-only build simply ignores this.
            "-ngl",
            gpu_layers,
            "-t",
            &threads.to_string(),
            // Prompt ingestion must obey the same ceiling as generation.
            "-tb",
            &threads.to_string(),
            // One background task at a time. Parallel slots increase KV memory
            // and make two "quiet" jobs compete for the same thermal budget.
            "-np",
            "1",
            // Do not spin while the loaded model is waiting for the next
            // chapter. Keeping weights mapped costs memory, not active CPU.
            "--poll",
            poll,
            "--poll-batch",
            poll,
            // llama.cpp's own worker priority. Windows also sets the process
            // class below normal below; Android/Linux honour this flag.
            "--prio",
            priority,
            "--no-webui",
        ])
        .args(extra)
        .current_dir(exe.parent().unwrap_or(dir))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS
        cmd.creation_flags(0x0800_0000 | 0x0000_4000);
    }
    let child = cmd.spawn().map_err(|e| format!("启动引擎失败: {e}"))?;
    // Before anything else can go wrong: an engine that outlives the app holds
    // gigabytes for nobody. See [`crate::job`].
    crate::job::adopt(&child);
    *slot.lock().unwrap() = Some(child);

    // Model load is disk-bound; a large one on a cold disk takes a while.
    for tick in 0..240 {
        std::thread::sleep(Duration::from_millis(250));
        if health(port) {
            return Ok(());
        }
        if let Some(c) = slot.lock().unwrap().as_mut() {
            if let Ok(Some(status)) = c.try_wait() {
                return Err(format!("引擎退出: {status}"));
            }
        }
        if tick % 4 == 3 {
            waiting(tick as u32 / 4 + 1);
        }
    }
    Err("引擎启动超时".into())
}

fn stop_chat_engine() {
    if let Some(mut child) = engine_child().lock().unwrap().take() {
        let _ = child.kill();
        let _ = child.wait();
    }
    if health(PORT) {
        kill_port_holder(PORT);
    }
    *engine_context().lock().unwrap() = None;
}

/// The tuned generation features depend on the full 8K evidence window.
/// Runtime profiles may change scheduling pressure, never the information the
/// model can read.
fn ensure_engine() -> Result<(), String> {
    const CONTEXT: u32 = 8192;
    if health(PORT) && *engine_context().lock().unwrap() == Some(CONTEXT) {
        return Ok(());
    }
    if health(PORT) || engine_child().lock().unwrap().is_some() {
        stop_chat_engine();
    }
    let model = find_model(ai_dir()?).ok_or("模型未安装（缺 .gguf 文件）")?;
    let context_arg = CONTEXT.to_string();
    ensure(
        PORT,
        engine_child(),
        model,
        &["-c", &context_arg, "--jinja"],
        |_| {},
    )?;
    *engine_context().lock().unwrap() = Some(CONTEXT);
    Ok(())
}

/// The embedding model: semantic search. BGE pools on the CLS token — mean
/// pooling over the same weights measurably degrades retrieval — and a 512
/// context is all a 250-character chunk can ever need.
fn ensure_embedder() -> Result<(), String> {
    ensure_embedder_with(|_| {})
}

fn ensure_embedder_with(waiting: impl FnMut(u32)) -> Result<(), String> {
    let model = find_gguf(ai_dir()?, true).ok_or("嵌入模型未安装（缺 bge 等 .gguf）")?;
    ensure(
        EMBED_PORT,
        embed_child(),
        model,
        &[
            "--embeddings",
            "--pooling",
            "cls",
            "-c",
            "512",
            "-b",
            "512",
            "-ub",
            "512",
        ],
        waiting,
    )
}

fn background_rest(base_quiet_ms: u64, base_balanced_ms: u64) {
    let config = runtime_config().lock().unwrap().clone();
    let base = match config.mode {
        0 => base_quiet_ms,
        1 => base_balanced_ms,
        _ => 0,
    };
    let adjusted = match config.thermal_bias {
        0 => base.saturating_mul(2),
        1 => base,
        _ => base / 2,
    };
    if adjusted > 0 {
        std::thread::sleep(Duration::from_millis(adjusted));
    }
}

pub fn stop_ai() {
    stop_chat_engine();
    for (port, slot) in [(EMBED_PORT, embed_child())] {
        if let Some(mut c) = slot.lock().unwrap().take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        // An engine reused from a previous app run is nobody's child here. If the
        // port still answers after killing our own child, hunt the holder down by
        // PID — otherwise the stop button is a lie and the RAM stays taken.
        if health(port) {
            kill_port_holder(port);
        }
    }
}

#[cfg(windows)]
fn kill_port_holder(port: u16) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let Ok(out) = Command::new("netstat")
        .args(["-ano", "-p", "tcp"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    else {
        return;
    };
    let suffix = format!(":{port}");
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        // "  TCP  127.0.0.1:8737  0.0.0.0:0  LISTENING  1234"
        let mut f = line.split_whitespace();
        let (Some(_), Some(local), Some(_), Some(state), Some(pid)) =
            (f.next(), f.next(), f.next(), f.next(), f.next())
        else {
            continue;
        };
        if state == "LISTENING" && local.ends_with(&suffix) {
            let _ = Command::new("taskkill")
                .args(["/PID", pid, "/F"])
                .creation_flags(CREATE_NO_WINDOW)
                .status();
        }
    }
}

#[cfg(not(windows))]
fn kill_port_holder(_port: u16) {}

/// Minimal HTTP/1.1 over loopback. `Connection: close` + read-to-end keeps the
/// framing trivial; chunked bodies are de-chunked at the byte level, because a
/// chunk boundary happily lands inside a UTF-8 sequence.
fn http(
    port: u16,
    method: &str,
    path: &str,
    body: Option<&Value>,
    timeout_secs: u64,
) -> Result<(u16, Vec<u8>), String> {
    let mut s = TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_secs(2))
        .map_err(|e| format!("连不上引擎: {e}"))?;
    s.set_read_timeout(Some(Duration::from_secs(timeout_secs)))
        .ok();

    let body_s = body.map(|b| b.to_string()).unwrap_or_default();
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_s}",
        body_s.len(),
    );
    s.write_all(req.as_bytes())
        .map_err(|e| format!("请求失败: {e}"))?;

    let mut raw = Vec::new();
    s.read_to_end(&mut raw)
        .map_err(|e| format!("读取响应失败: {e}"))?;

    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("坏响应：没有头部结束符")?;
    let head = String::from_utf8_lossy(&raw[..split]).to_ascii_lowercase();
    let status: u16 = head
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or("坏响应：没有状态码")?;
    let rest = &raw[split + 4..];
    let body = if head.contains("transfer-encoding: chunked") {
        dechunk(rest)
    } else {
        rest.to_vec()
    };
    Ok((status, body))
}

fn dechunk(mut b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let Some(pos) = b.windows(2).position(|w| w == b"\r\n") else {
            break;
        };
        let size = std::str::from_utf8(&b[..pos])
            .ok()
            .and_then(|s| usize::from_str_radix(s.trim(), 16).ok())
            .unwrap_or(0);
        let start = pos + 2;
        if size == 0 || b.len() < start + size {
            break;
        }
        out.extend_from_slice(&b[start..start + size]);
        b = b.get(start + size + 2..).unwrap_or(&[]);
    }
    out
}

/// The tuned novel logic above this boundary is platform-independent. Windows
/// currently talks to a managed llama-server process; iOS will provide an
/// in-process llama.cpp implementation behind the same four operations.
trait LocalInferenceBackend: Sync {
    fn prepare_chat(&self) -> Result<(), String>;
    fn prepare_embeddings(&self) -> Result<(), String>;
    fn chat_completion(&self, body: &Value, timeout_secs: u64) -> Result<(u16, Vec<u8>), String>;
    fn embeddings(&self, body: &Value, timeout_secs: u64) -> Result<(u16, Vec<u8>), String>;
}

struct LlamaServerBackend;

impl LocalInferenceBackend for LlamaServerBackend {
    fn prepare_chat(&self) -> Result<(), String> {
        ensure_engine()
    }

    fn prepare_embeddings(&self) -> Result<(), String> {
        ensure_embedder()
    }

    fn chat_completion(&self, body: &Value, timeout_secs: u64) -> Result<(u16, Vec<u8>), String> {
        http(
            PORT,
            "POST",
            "/v1/chat/completions",
            Some(body),
            timeout_secs,
        )
    }

    fn embeddings(&self, body: &Value, timeout_secs: u64) -> Result<(u16, Vec<u8>), String> {
        http(
            EMBED_PORT,
            "POST",
            "/v1/embeddings",
            Some(body),
            timeout_secs,
        )
    }
}

static LLAMA_SERVER_BACKEND: LlamaServerBackend = LlamaServerBackend;

fn inference_backend() -> &'static dyn LocalInferenceBackend {
    &LLAMA_SERVER_BACKEND
}

/// One closed task: chapter excerpt in, one sentence out, temperature 0.
fn summarize_excerpt(excerpt: &str) -> Result<String, String> {
    let body = json!({
        "messages": [
            {
                "role": "system",
                "content": "你是小说章节摘要工具。用一句简体中文陈述句概括这一章发生的主要情节，不超过40个字。只输出这一句话：不要前缀、不要引号、不要解释、不要换行。"
            },
            {
                "role": "user",
                "content": format!("{excerpt}\n\n用一句话（不超过40字）概括本章情节。/no_think")
            }
        ],
        "temperature": 0.0,
        "max_tokens": 120,
    });
    let (status, resp) = inference_backend().chat_completion(&body, 300)?;
    if status != 200 {
        return Err(format!("引擎返回 {status}"));
    }
    let v: Value = serde_json::from_slice(&resp).map_err(|e| format!("引擎响应不是 JSON: {e}"))?;
    let content = v["choices"][0]["message"]["content"]
        .as_str()
        .ok_or("引擎响应缺少内容")?;
    Ok(clean_summary(content))
}

/// The model's paperwork, removed: think-block residue, wrapper quotes, label
/// prefixes, linebreaks. Then a hard cap — an over-long "summary" is the model
/// retelling, not summarizing.
fn clean_summary(raw: &str) -> String {
    let mut s = raw.trim();
    if let Some(end) = s.find("</think>") {
        s = s[end + "</think>".len()..].trim_start();
    }
    let s = s.replace(['\n', '\r'], " ");
    let s = s
        .trim()
        .trim_start_matches(['“', '"', '「'])
        .trim_end_matches(['”', '"', '」'])
        .trim_start_matches("摘要：")
        .trim_start_matches("本章")
        .trim();
    s.chars().take(60).collect()
}

/// The mood vocabulary. Closed on purpose: the model picks, never invents.
/// Anything it says outside this list is discarded — a missing label degrades
/// gracefully, a made-up one lies forever.
const MOODS: [&str; 8] = [
    "轻松", "紧张", "热血", "悲伤", "温馨", "悬疑", "平静", "压抑",
];

/// The second closed task on the same excerpt: one word from [MOODS], or None.
fn classify_mood(excerpt: &str) -> Result<Option<String>, String> {
    let body = json!({
        "messages": [
            {
                "role": "system",
                "content": "你是小说章节氛围分类工具。从这些词中选出最贴合这一章氛围的一个：轻松、紧张、热血、悲伤、温馨、悬疑、平静、压抑。只输出这一个词，不要解释。"
            },
            {
                "role": "user",
                "content": format!("{excerpt}\n\n本章氛围是哪一个词？/no_think")
            }
        ],
        "temperature": 0.0,
        "max_tokens": 32,
    });
    let (status, resp) = inference_backend().chat_completion(&body, 300)?;
    if status != 200 {
        return Err(format!("引擎返回 {status}"));
    }
    let v: Value = serde_json::from_slice(&resp).map_err(|e| format!("引擎响应不是 JSON: {e}"))?;
    let content = v["choices"][0]["message"]["content"].as_str().unwrap_or("");
    let cleaned = clean_summary(content);
    // First vocabulary word appearing in the reply wins ("答案是：紧张" still counts).
    let hit = MOODS
        .iter()
        .filter_map(|m| cleaned.find(m).map(|p| (p, *m)))
        .min();
    Ok(hit.map(|(_, m)| m.to_string()))
}

#[derive(Debug, Clone)]
pub struct EnrichProgress {
    /// Chapter just processed.
    pub index: u32,
    pub title: String,
    /// Chapters finished so far in this run / chapters this run set out to do.
    pub done: u32,
    pub total: u32,
    pub summary: Option<String>,
    pub error: Option<String>,
}

pub fn cancel_enrich() {
    CANCEL.store(true, Ordering::SeqCst);
}

/// Summarize every chapter of a book that has no summary yet, front to back,
/// streaming progress. Resumable by construction: finished chapters are on
/// disk, and a re-run only sees the missing ones.
pub fn enrich_book(
    path: String,
    book_id: i64,
    sink: StreamSink<EnrichProgress>,
) -> Result<(), String> {
    CANCEL.store(false, Ordering::SeqCst);
    inference_backend().prepare_chat()?;
    if !book::is_loaded(&path) {
        book::open_book(path.clone())?;
    }

    let missing: Vec<(i64, String, bool, bool)> = {
        let mut guard = book::store().lock().unwrap();
        let s = guard.as_mut().ok_or("数据库未初始化")?;
        s.chapters_needing_enrich(book_id)
            .map_err(|e| format!("{e}"))?
    };
    let total = missing.len() as u32;
    let model_tag = ai_status()?.model.unwrap_or_default();

    let mut consecutive_errors = 0;
    for (done, (idx, title, need_summary, need_mood)) in missing.into_iter().enumerate() {
        if CANCEL.load(Ordering::SeqCst) {
            break;
        }
        // One excerpt, up to two closed tasks over it. Each piece is written
        // only when it was missing, so a re-run never re-pays finished work.
        let result = book::chapter_excerpt(&path, idx as u32, 1400, 400).and_then(|ex| {
            let summary = if need_summary {
                Some(summarize_excerpt(&ex)?)
            } else {
                None
            };
            let mood = if need_mood { classify_mood(&ex)? } else { None };
            Ok((summary, mood))
        });

        let progress = match result {
            Ok((summary, mood)) => {
                consecutive_errors = 0;
                {
                    let mut guard = book::store().lock().unwrap();
                    let s = guard.as_mut().ok_or("数据库未初始化")?;
                    s.set_chapter_ai(
                        book_id,
                        idx,
                        summary.as_deref(),
                        mood.as_deref(),
                        &model_tag,
                    )
                    .map_err(|e| format!("{e}"))?;
                }
                EnrichProgress {
                    index: idx as u32,
                    title,
                    done: done as u32 + 1,
                    total,
                    summary,
                    error: None,
                }
            }
            Err(e) => {
                consecutive_errors += 1;
                EnrichProgress {
                    index: idx as u32,
                    title,
                    done: done as u32,
                    total,
                    summary: None,
                    error: Some(e),
                }
            }
        };
        // A dropped sink means the listener is gone; stop burning CPU for nobody.
        if sink.add(progress).is_err() {
            break;
        }
        if consecutive_errors >= 3 {
            return Err("连续 3 章失败，已停止".into());
        }
        // Advance in durable slices. The controller may stop us between any two
        // chapters; quiet mode also leaves the memory controller time to cool.
        background_rest(1800, 350);
    }
    Ok(())
}

// ── 人物关系标签 ─────────────────────────────────────────────────────────────
//
// The cast and the edges are counted by the rules (novel_core::cast); most edges
// carry a decisive appellation and are labelled there, for free. What is left —
// two people who clearly share scenes but never call each other anything, or a
// genuine tie between two appellations — is the one thing a model does here:
// read the evidence sentences and pick ONE label from the same closed set the
// rules use, or 不明.
//
// The recipe is the landmine judge's, because it is the one that survived
// measurement on this 0.6B: let it think, sample it three times, take the
// majority. A wide closed choice answered in one greedy shot collapses to a
// constant; reasoning tokens and a vote are what make it read the passage.

/// One chat turn, raw assistant text. Temperature is a parameter because the
/// vote needs the three samples to actually differ.
fn chat_once(
    system: &str,
    user: &str,
    max_tokens: u32,
    temperature: f32,
) -> Result<String, String> {
    let body = json!({
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
    });
    let (status, resp) = inference_backend().chat_completion(&body, 300)?;
    if status != 200 {
        return Err(format!("引擎返回 {status}"));
    }
    let v: Value = serde_json::from_slice(&resp).map_err(|e| format!("引擎响应不是 JSON: {e}"))?;
    Ok(v["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or("")
        .to_string())
}

/// The conclusion after a </think> block: the last allowed word in the tail. The
/// words appear inside the reasoning too, as hypotheses; the last one is the
/// verdict. No label in the set is a substring of another, so a plain scan is safe.
fn tail_pick(raw: &str, vocab: &[&'static str]) -> Option<&'static str> {
    let tail = raw.rsplit("</think>").next().unwrap_or(raw);
    vocab
        .iter()
        .filter_map(|m| tail.rfind(m).map(|p| (p, *m)))
        .max()
        .map(|(_, m)| m)
}

/// The answer after a thinking model's `</think>` block, cleaned up for display:
/// newlines collapsed, trimmed, and clipped so one over-eager pair can't write a
/// paragraph. Empty if the model produced nothing usable.
fn after_think(raw: &str, max_chars: usize) -> String {
    let tail = raw.rsplit("</think>").next().unwrap_or(raw);
    let one_line: String = tail.split_whitespace().collect::<Vec<_>>().join(" ");
    let s = one_line
        .trim()
        .trim_matches(|c| "。.！!；;：:\"“”".contains(c));
    let mut out: String = s.chars().take(max_chars).collect();
    if out.chars().count() < s.chars().count() {
        out.push('…');
    }
    out
}

/// One edge → one prose summary of how the pair get on, written from *all* of the
/// pair's co-occurrence scenes read together in a single pass, in chronological
/// order. This replaces the old pick-one-label-from-a-set: the small model could
/// not choose stably between near-synonyms (师徒/同门) or for pairs that are two
/// things at once (陈平安与宁姚 are both 师承 and 道侣), but describing what it
/// reads is a task it can do. The scenes are pre-sampled across the book by the
/// scan (reservoir sampling over relationship-bearing sentences, see
/// `cast::Reservoir`), so ~40 of them span first meeting to last and fit the 8k
/// window with room for thinking.
fn summarize_relation(a: &str, b: &str, evidence: &[(usize, String)]) -> Result<String, String> {
    if evidence.is_empty() {
        return Ok(format!("{a}与{b}有同场，但没有留下成句的原文可依据。"));
    }
    let system = format!(
        "你是小说情节整理助手。下面按时间先后给出【{a}】和【{b}】同场的多段原文，\
         请通读全部片段、前后联系起来，用一两句话（不超过 45 字）概括这两个人之间发生了什么、有哪些来往，\
         贯穿全书来看。要点：\
         只依据给出的片段，如实说他们一起做了什么、彼此怎么对待，不要编造片段里没有的情节；\
         不要给他们贴关系标签、也不要去判断两人算什么关系，只描述你从原文看到的交往本身；\
         尊称（殿下、大人）只是称呼，照实转述即可。\
         先在心里分析，最后只输出那一两句概括，不要复述原文、不要分点、不要加引号。"
    );
    let scenes: String = evidence
        .iter()
        .enumerate()
        .map(|(i, (_, t))| format!("{}. {t}", i + 1))
        .collect::<Vec<_>>()
        .join("\n");
    let user = format!(
        "原文片段（共 {} 段，按时间先后排列）：\n{scenes}\n\n\
         用一两句话概括【{a}】和【{b}】之间的来往。",
        evidence.len()
    );
    // One considered pass. A low temperature keeps it grounded; the retry is only
    // for the rare pass that comes back empty (all thinking, no answer).
    for _ in 0..2 {
        let raw = chat_once(&system, &user, 1200, 0.4)?;
        let summary = after_think(&raw, 60);
        if !summary.is_empty() {
            return Ok(summary);
        }
    }
    Ok(format!("{a}与{b}多次同场，模型没能概括出两人的来往。"))
}

/// One character → a short account of who they are, written from their own
/// sampled sentences read in chronological order.
///
/// Deliberately the same shape as [`summarize_relation`], and for the same
/// reason: asked to *classify* a character (主角/反派/配角) the small model
/// guesses from the name, but asked to describe what a stack of sentences shows
/// it stays on the page. So it is never asked what someone *is* — only what the
/// book says about them.
fn summarize_person(
    name: &str,
    aliases: &[String],
    evidence: &[(usize, String)],
) -> Result<String, String> {
    if evidence.is_empty() {
        return Ok(format!("{name}出场了，但没有留下成句的原文可依据。"));
    }
    let also = if aliases.is_empty() {
        String::new()
    } else {
        format!("（书中也称作 {}）", aliases.join("、"))
    };
    let system = format!(
        "你是小说人物档案整理助手。下面按时间先后给出提到【{name}】{also}的多段原文，\
         请通读全部片段、前后联系起来，用两三句话（不超过 80 字）介绍这个人物。要点：\
         优先说清楚 TA 的身份来历（出身、门派、职位、称号）、性情为人、以及经历过的重要转折；\
         只依据给出的片段，如实概括，片段里没提到的一律不写，不要编造、不要推测、不要联想到别的作品；\
         不要评价 TA 是主角还是配角、是好人还是坏人，只说原文里看得到的；\
         若片段实在看不出这个人是谁，就如实说「原文片段里看不出 TA 的来历」。\
         先在心里分析，最后只输出那两三句介绍，不要复述原文、不要分点、不要加引号。"
    );
    let scenes: String = evidence
        .iter()
        .enumerate()
        .map(|(i, (_, t))| format!("{}. {t}", i + 1))
        .collect::<Vec<_>>()
        .join("\n");
    let user = format!(
        "原文片段（共 {} 段，按时间先后排列）：\n{scenes}\n\n\
         用两三句话介绍【{name}】这个人物。",
        evidence.len()
    );
    for _ in 0..2 {
        let raw = chat_once(&system, &user, 1400, 0.4)?;
        let summary = after_think(&raw, 110);
        if !summary.is_empty() {
            return Ok(summary);
        }
    }
    Ok(format!("{name}多次出场，模型没能概括出 TA 的来历。"))
}

#[derive(Debug, Clone)]
pub struct DescribeProgress {
    /// The character just written up — Dart matches this to its node.
    pub name: String,
    pub background: String,
    pub done: u32,
    pub total: u32,
    pub error: Option<String>,
}

static CANCEL_DESCRIBE: AtomicBool = AtomicBool::new(false);

pub fn cancel_describe() {
    CANCEL_DESCRIBE.store(true, Ordering::SeqCst);
}

/// Write a background for every character in the graph, streaming each as it
/// lands. Same contract as [`label_relations`]: resumable, cancellable, and
/// whatever finished is on disk before the reader sees it.
pub fn describe_people(
    path: String,
    book_id: i64,
    up_to_chapter: i64,
    sink: StreamSink<DescribeProgress>,
) -> Result<(), String> {
    CANCEL_DESCRIBE.store(false, Ordering::SeqCst);
    inference_backend().prepare_chat()?;
    book::ensure_loaded(&path)?;

    let residual = book::residual_people(&path, book_id, up_to_chapter)?;
    let total = residual.len() as u32;

    let mut consecutive_errors = 0;
    for (done, (name, aliases, evidence)) in residual.into_iter().enumerate() {
        if CANCEL_DESCRIBE.load(Ordering::SeqCst) {
            break;
        }
        let (background, error) = match summarize_person(&name, &aliases, &evidence) {
            Ok(b) => {
                consecutive_errors = 0;
                let _ = book::remember_person(book_id, &name, &b);
                (b, None)
            }
            Err(e) => {
                consecutive_errors += 1;
                (String::new(), Some(e))
            }
        };
        let last = sink
            .add(DescribeProgress {
                name,
                background,
                done: done as u32 + 1,
                total,
                error,
            })
            .is_err();
        if last {
            break;
        }
        if consecutive_errors >= 3 {
            return Err("连续 3 位人物归纳失败，已停止".into());
        }
    }
    Ok(())
}

/// Throw away everything derived for this book's graph — the scan, the model's
/// verdicts on borderline names, and its relationship labels — so the next open
/// rebuilds from the text. The reader's 重置.
pub fn forget_relations(book_id: i64) -> Result<(), String> {
    book::forget_cast(book_id)
}

#[derive(Debug, Clone)]
pub struct RelabelProgress {
    /// The pair just summarized, by name — Dart matches this to its edge.
    pub a: String,
    pub b: String,
    /// The prose summary just written (field name kept for the bridge).
    pub label: String,
    pub done: u32,
    pub total: u32,
    pub error: Option<String>,
}

static CANCEL_RELABEL: AtomicBool = AtomicBool::new(false);

pub fn cancel_relabel() {
    CANCEL_RELABEL.store(true, Ordering::SeqCst);
}

/// Summarize every top edge up to the reader's chapter, streaming each as it
/// lands. Resumable within a run: cached pairs stream back instantly, and a
/// cancel leaves what is done in the cache for the next pass to keep.
pub fn label_relations(
    path: String,
    book_id: i64,
    up_to_chapter: i64,
    sink: StreamSink<RelabelProgress>,
) -> Result<(), String> {
    CANCEL_RELABEL.store(false, Ordering::SeqCst);
    inference_backend().prepare_chat()?;
    book::ensure_loaded(&path)?;

    let residual = book::residual_relations(&path, book_id, up_to_chapter)?;
    let total = residual.len() as u32;

    let mut consecutive_errors = 0;
    for (done, (a, b, evidence)) in residual.into_iter().enumerate() {
        if CANCEL_RELABEL.load(Ordering::SeqCst) {
            break;
        }
        let (label, error) = match summarize_relation(&a, &b, &evidence) {
            Ok(l) => {
                consecutive_errors = 0;
                // Straight to the database: a summary the reader waited for must
                // survive closing the app, not just closing the page.
                let _ = book::remember_relation(book_id, &a, &b, &l);
                (l, None)
            }
            Err(e) => {
                consecutive_errors += 1;
                (String::new(), Some(e))
            }
        };
        let last = sink
            .add(RelabelProgress {
                a,
                b,
                label,
                done: done as u32 + 1,
                total,
                error,
            })
            .is_err();
        if last {
            break;
        }
        if consecutive_errors >= 3 {
            return Err("连续 3 条关系判定失败，已停止".into());
        }
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct VetProgress {
    pub name: String,
    pub is_person: bool,
    pub done: u32,
    pub total: u32,
    pub error: Option<String>,
}

static CANCEL_VET: AtomicBool = AtomicBool::new(false);

pub fn cancel_vet() {
    CANCEL_VET.store(true, Ordering::SeqCst);
}

/// Is this candidate a character, or a common word that happens to stand where a
/// name stands (陈平安伸手道)? The statistics answer this for the easy ends and
/// hand over the middle; see `novel_core::cast::DENSITY_FLOOR`.
///
/// The two answers must not be prefixes of one another. 「是」/「不是」 would be
/// read backwards by [`tail_pick`], which scans for the last vocabulary word and
/// would find the 是 inside 不是.
fn is_a_person(name: &str, sample: &str) -> Result<bool, String> {
    const VOCAB: &[&str] = &["人物", "词语"];
    let system = "你在读一本中文网络小说。给你一个词，判断它是这本书里某个人物的称呼，\
还是一个普通词语。人物包括姓名、外号、代称（例如 陈平安、青衣小童、杨老头）。\
普通词语包括动作、时间、指代（例如 伸手、回头、后者、先前、比如）。\
想清楚后，最后只回答「人物」或「词语」两个词之一。";
    let user = if sample.is_empty() {
        format!("词：{name}\n它是人物还是词语？")
    } else {
        format!("词：{name}\n原文例句：{sample}\n它是人物还是词语？")
    };
    let (mut person, mut word) = (0, 0);
    for _ in 0..3 {
        let raw = chat_once(system, &user, 512, 0.7)?;
        match tail_pick(&raw, VOCAB) {
            Some("人物") => person += 1,
            Some("词语") => word += 1,
            _ => {}
        }
    }
    if person == 0 && word == 0 {
        return Err("模型没有给出可用判断".into());
    }
    // A tie keeps the candidate: the scan already thought it was a person, and
    // deleting someone real is worse than leaving one stray word on the canvas.
    Ok(person >= word)
}

/// Rule on every borderline candidate the model has not seen yet, streaming each
/// verdict. Verdicts are written to the database as they land, so a cancelled
/// run keeps what it paid for.
pub fn vet_names(
    path: String,
    book_id: i64,
    up_to_chapter: i64,
    sink: StreamSink<VetProgress>,
) -> Result<(), String> {
    CANCEL_VET.store(false, Ordering::SeqCst);
    inference_backend().prepare_chat()?;
    book::ensure_loaded(&path)?;

    let pending = book::unjudged_names(&path, book_id, up_to_chapter)?;
    let total = pending.len() as u32;
    let mut consecutive_errors = 0;

    for (done, (name, sample)) in pending.into_iter().enumerate() {
        if CANCEL_VET.load(Ordering::SeqCst) {
            break;
        }
        let (is_person, error) = match is_a_person(&name, &sample) {
            Ok(v) => {
                consecutive_errors = 0;
                let _ = book::remember_name(book_id, &name, v);
                (v, None)
            }
            Err(e) => {
                consecutive_errors += 1;
                (true, Some(e))
            }
        };
        let closed = sink
            .add(VetProgress {
                name,
                is_person,
                done: done as u32 + 1,
                total,
                error,
            })
            .is_err();
        if closed {
            break;
        }
        if consecutive_errors >= 3 {
            return Err("连续 3 个人名判定失败，已停止".into());
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Semantic search: an offline index of the book, queried only over what has
// been read.
// ---------------------------------------------------------------------------

/// BGE was trained with an instruction on the query side and none on the
/// document side. Embedding a query as if it were a passage costs real recall,
/// and it is one line to get right.
const QUERY_PREFIX: &str = "为这个句子生成表示以用于检索相关文章：";

/// Chunks per embedding request. The engine batches internally; the point here
/// is amortizing the HTTP round trip without building a megabyte-long body.
#[cfg(target_os = "android")]
const EMBED_BATCH: usize = 4;
#[cfg(not(target_os = "android"))]
const EMBED_BATCH: usize = 16;

/// Below this cosine, a "hit" is the index apologizing. Better to say nothing
/// was found than to send the reader to a chapter that has nothing to do with
/// the question.
const SCORE_FLOOR: f32 = 0.35;

/// Text in, unit vectors out. The only thing the model does for search.
fn embed(texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    let body = json!({ "input": texts, "model": "embedding" });
    let (status, resp) = inference_backend().embeddings(&body, 300)?;
    if status != 200 {
        return Err(format!("嵌入引擎返回 {status}"));
    }
    let v: Value = serde_json::from_slice(&resp).map_err(|e| format!("嵌入响应不是 JSON: {e}"))?;
    let data = v["data"].as_array().ok_or("嵌入响应缺少 data")?;
    if data.len() != texts.len() {
        return Err(format!(
            "嵌入数量不符：要 {}，得 {}",
            texts.len(),
            data.len()
        ));
    }

    let mut out = Vec::with_capacity(data.len());
    for d in data {
        let e = &d["embedding"];
        // Pooled output is a flat array. Some builds answer with one row per
        // token even when asked to pool; average those rather than failing.
        let mut vec: Vec<f32> = match e.as_array().and_then(|a| a.first()) {
            Some(Value::Array(_)) => {
                let rows = e.as_array().unwrap();
                let dim = rows[0].as_array().map(|r| r.len()).unwrap_or(0);
                let mut acc = vec![0.0f32; dim];
                for r in rows {
                    for (i, x) in r.as_array().ok_or("嵌入行不是数组")?.iter().enumerate() {
                        acc[i] += x.as_f64().unwrap_or(0.0) as f32;
                    }
                }
                acc
            }
            Some(_) => e
                .as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_f64().unwrap_or(0.0) as f32)
                .collect(),
            None => return Err("嵌入为空".into()),
        };
        if vec.is_empty() {
            return Err("嵌入为空".into());
        }
        chunk::normalize(&mut vec);
        out.push(vec);
    }
    Ok(out)
}

#[derive(Debug, Clone)]
pub struct IndexProgress {
    pub chapter: u32,
    pub title: String,
    pub done: u32,
    pub total: u32,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct IndexStatus {
    /// Chapters that already carry vectors.
    pub indexed: u32,
    pub total: u32,
    pub has_model: bool,
}

pub fn index_status(path: String, book_id: i64) -> Result<IndexStatus, String> {
    // Reachable from the shelf, where the book has never been opened.
    book::ensure_loaded(&path)?;
    let total = book::chapter_titles(&path)?.len() as u32;
    let indexed = {
        let mut guard = book::store().lock().unwrap();
        let s = guard.as_mut().ok_or("数据库未初始化")?;
        s.indexed_chapters(book_id)
            .map_err(|e| format!("{e}"))?
            .len() as u32
    };
    Ok(IndexStatus {
        indexed,
        total,
        has_model: find_gguf(ai_dir()?, true).is_some(),
    })
}

pub fn drop_index(book_id: i64) -> Result<(), String> {
    let guard = book::store().lock().unwrap();
    let s = guard.as_ref().ok_or("数据库未初始化")?;
    s.drop_index(book_id).map_err(|e| format!("{e}"))
}

/// Embed every chapter that has no vectors yet, front to back. Resumable by
/// construction, exactly like enrichment: what is on disk is done, and a re-run
/// after a crash or a cancel only sees what is left.
pub fn cancel_index() {
    CANCEL_INDEX.store(true, Ordering::SeqCst);
}

pub fn index_book(
    path: String,
    book_id: i64,
    sink: StreamSink<IndexProgress>,
) -> Result<(), String> {
    CANCEL_INDEX.store(false, Ordering::SeqCst);
    inference_backend().prepare_embeddings()?;
    book::ensure_loaded(&path)?;
    let titles = book::chapter_titles(&path)?;

    let done_already: std::collections::HashSet<i64> = {
        let mut guard = book::store().lock().unwrap();
        let s = guard.as_mut().ok_or("数据库未初始化")?;
        s.indexed_chapters(book_id)
            .map_err(|e| format!("{e}"))?
            .into_iter()
            .collect()
    };
    let todo: Vec<usize> = (0..titles.len())
        .filter(|i| !done_already.contains(&(*i as i64)))
        .collect();
    let total = todo.len() as u32;

    let mut consecutive_errors = 0;
    for (n, idx) in todo.into_iter().enumerate() {
        if CANCEL_INDEX.load(Ordering::SeqCst) {
            break;
        }
        let result = book::chapter_chunks(&path, idx as u32).and_then(|chunks| {
            let mut rows: Vec<(i64, i64, Vec<u8>)> = Vec::with_capacity(chunks.len());
            for batch in chunks.chunks(EMBED_BATCH) {
                if CANCEL_INDEX.load(Ordering::SeqCst) {
                    break;
                }
                let texts: Vec<String> = batch.iter().map(|c| c.text.clone()).collect();
                for (c, v) in batch.iter().zip(embed(&texts)?) {
                    rows.push((c.start as i64, c.end as i64, chunk::quantize(&v)));
                }
            }
            Ok(rows)
        });

        let progress = match result {
            Ok(rows) => {
                consecutive_errors = 0;
                {
                    let mut guard = book::store().lock().unwrap();
                    let s = guard.as_mut().ok_or("数据库未初始化")?;
                    s.set_chunks(book_id, idx as i64, &rows)
                        .map_err(|e| format!("{e}"))?;
                }
                IndexProgress {
                    chapter: idx as u32,
                    title: titles[idx].clone(),
                    done: n as u32 + 1,
                    total,
                    error: None,
                }
            }
            Err(e) => {
                consecutive_errors += 1;
                IndexProgress {
                    chapter: idx as u32,
                    title: titles[idx].clone(),
                    done: n as u32,
                    total,
                    error: Some(e),
                }
            }
        };
        if sink.add(progress).is_err() {
            break;
        }
        if consecutive_errors >= 3 {
            return Err("连续 3 章失败，已停止".into());
        }
        background_rest(1200, 250);
    }
    Ok(())
}

/// Search the book — but only the part of it the reader has already read.
///
/// `up_to_chapter` is the spoiler line, and it is enforced in SQL: chapters
/// beyond it are never loaded, so no ranking bug can leak one. A reader who
/// searches for a character they have not met yet gets nothing, which is the
/// correct answer.
pub fn semantic_search(
    path: String,
    book_id: i64,
    query: String,
    up_to_chapter: i64,
    k: u32,
) -> Result<Vec<SearchHit>, String> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(Vec::new());
    }
    inference_backend().prepare_embeddings()?;
    let q = embed(&[format!("{QUERY_PREFIX}{query}")])?
        .pop()
        .ok_or("查询嵌入失败")?;

    let rows = {
        let mut guard = book::store().lock().unwrap();
        let s = guard.as_mut().ok_or("数据库未初始化")?;
        s.chunk_vectors(book_id, up_to_chapter)
            .map_err(|e| format!("{e}"))?
    };
    if rows.is_empty() {
        return Err("这本书还没有建立索引".into());
    }

    let titles = book::chapter_titles(&path)?;
    let hits = chunk::rank(&q, &rows, k as usize, 2, SCORE_FLOOR);
    Ok(hits
        .into_iter()
        .map(|h| SearchHit {
            chapter: h.chapter as u32,
            title: titles.get(h.chapter as usize).cloned().unwrap_or_default(),
            start: h.start,
            text: book::snippet(&path, h.start, h.end, 90).unwrap_or_default(),
            score: h.score,
        })
        .collect())
}

// ── 排雷 ──────────────────────────────────────────────────────────────────
//
// A content-warning scan: the reader asks, before starting a book, whether it
// contains the thing they cannot stand. It is built out of exactly one part of
// the AI stack — retrieval — and deliberately not out of the other.
//
// The chat model is not used here, and that is a measured decision rather than
// a shortcut. Asked to judge whether a passage depicts a betrayal, Qwen3-0.6B
// scores 14/18 on a hand-written set at best, and its errors include reading a
// couple's own wedding night as adultery; every attempt to teach it the
// exclusion collapsed its recall to nearly zero. A verdict from it would be
// confidently wrong often enough to make a reader drop a book for a lie.
//
// So this feature returns passages and no verdict. The retriever is good at
// what it is actually good at — collecting a broad candidate set, removing
// verbatim repeats, and putting a small number of distinct passages in front of
// the reader. The reader, who can tell a wedding night from a betrayal in three
// seconds, does the judging. Nothing here ever says a book is clean: not finding
// a passage is not evidence of absence, and the UI says so.

/// A broad first pass gives repeated scenes room to be removed without leaving
/// the reader with only two or three results. This is intentionally fixed
/// rather than tied to the number of cards shown by the UI.
const LANDMINE_CANDIDATE_POOL: usize = 80;

/// Return the hit plus its immediately adjacent indexed chunks in the same
/// chapter. A relationship fact and the event it changes often straddle a
/// 250-character indexing boundary; showing only the winning chunk can remove
/// exactly the sentence a human needs in order to judge it.
fn landmine_context_spans(hit: &chunk::Hit, rows: &[(i64, i64, i64, Vec<u8>)]) -> Vec<(i64, i64)> {
    let previous = rows
        .iter()
        .filter(|(chapter, _, end, _)| *chapter == hit.chapter && *end <= hit.start)
        .max_by_key(|(_, _, end, _)| *end)
        .map(|(_, start, end, _)| (*start, *end));
    let next = rows
        .iter()
        .filter(|(chapter, start, _, _)| *chapter == hit.chapter && *start >= hit.end)
        .min_by_key(|(_, start, _, _)| *start)
        .map(|(_, start, end, _)| (*start, *end));

    let mut spans = Vec::with_capacity(3);
    if let Some(span) = previous {
        spans.push(span);
    }
    spans.push((hit.start, hit.end));
    if let Some(span) = next {
        spans.push(span);
    }
    spans
}

fn normalized_evidence(text: &str) -> Vec<char> {
    text.chars()
        .filter(|c| !c.is_whitespace() && !c.is_ascii_punctuation())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Conservative repeat detection, not an AI claim that two descriptions refer
/// to the same fictional event. We merge only substantial verbatim overlap:
/// either the normalized excerpts are identical, or they share an uninterrupted
/// run of 64 characters. Paraphrased recaps remain separate cards.
fn repeats_original(a: &[char], b: &[char]) -> bool {
    const EXACT_MIN: usize = 24;
    const SHARED_RUN: usize = 64;

    if a.len() >= EXACT_MIN && a == b {
        return true;
    }
    if a.len() < SHARED_RUN || b.len() < SHARED_RUN {
        return false;
    }

    let (shorter, longer) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    let windows: std::collections::HashSet<Vec<char>> =
        shorter.windows(SHARED_RUN).map(|w| w.to_vec()).collect();
    longer.windows(SHARED_RUN).any(|w| windows.contains(w))
}

fn landmine_context(
    path: &str,
    hit: &chunk::Hit,
    rows: &[(i64, i64, i64, Vec<u8>)],
) -> Result<(String, Vec<char>), String> {
    let spans = landmine_context_spans(hit, rows);
    let mut original = Vec::with_capacity(spans.len());
    for (start, end) in &spans {
        let text = book::snippet(path, *start, *end, 340)?;
        if !text.is_empty() {
            original.push(text);
        }
    }
    let joined = original.join("\n\n");
    let fingerprint = normalized_evidence(&joined);
    Ok((joined, fingerprint))
}

/// A landmine the scan knows how to look for. Fixed set, by request: an
/// arbitrary query would have an uncalibrated meaning and no honest way to
/// present its results.
#[derive(Debug, Clone)]
pub struct Landmine {
    pub id: String,
    pub name: String,
    /// What the reader is actually asking, in their words.
    pub note: String,
}

/// Several phrasings each: novels write the same event as 出轨, 私通, 失身 or
/// 被夺, and a single query sentence only finds the one it happens to resemble.
fn landmine_queries(id: &str) -> Option<&'static [&'static str]> {
    match id {
        "ntr" => Some(&[
            "她背着自己的男人和别人上了床",
            "妻子与其他男人私通、偷情",
            "他的女人被别的男人夺走、占有",
            "得知妻子出轨后他愤怒屈辱",
        ]),
        "chastity" => Some(&[
            "她已经不是处子之身，早就被别的男人碰过",
            "她向他坦白自己曾与他人有过关系",
            "他发现她并非完璧之身",
            "她的第一次给了另一个男人",
        ]),
        _ => None,
    }
}

pub fn landmines() -> Vec<Landmine> {
    vec![
        Landmine {
            id: "ntr".into(),
            name: "绿帽 / NTR".into(),
            note: String::new(),
        },
        Landmine {
            id: "chastity".into(),
            name: "女主非处".into(),
            note: String::new(),
        },
    ]
}

/// Where a scan has got to. The work is short but it is not instant — a cold
/// engine can take half a minute to load its weights, and a big book has to be
/// decoded and cut before anything can be read out of it. A screen that says
/// nothing for thirty seconds is indistinguishable from a screen that has hung,
/// which is exactly what it looked like before this existed.
#[derive(Debug, Clone)]
pub struct ScanProgress {
    /// What is happening now, in the reader's words.
    pub phase: String,
    /// Seconds spent so far in a phase that cannot know its own length; 0 in the
    /// ones that are quick. Nothing here fakes a percentage it does not have.
    pub waited: u32,
    /// Paragraphs being compared, once that number is known.
    pub total: u32,
    /// Set exactly once, on the final event. The scan is over when this arrives.
    pub hits: Option<Vec<SearchHit>>,
}

/// Scan the **whole book**, not the part already read.
///
/// Every other retrieval path in this app is capped at the reader's current
/// chapter, and that cap is the reason none of them can spoil anything. Here it
/// is off on purpose: a warning about chapter 700 is worthless to someone
/// standing at chapter 1, and telling them anyway is the entire point of the
/// feature. It is why nothing calls this unless the reader taps it by name.
pub fn scan_landmine(
    path: String,
    book_id: i64,
    id: String,
    k: u32,
    sink: StreamSink<ScanProgress>,
) -> Result<(), String> {
    let say = |phase: &str, waited: u32, total: u32| {
        let _ = sink.add(ScanProgress {
            phase: phase.into(),
            waited,
            total,
            hits: None,
        });
    };
    let queries = landmine_queries(&id).ok_or("未知的雷点")?;

    say("正在打开书籍…", 0, 0);
    book::ensure_loaded(&path)?;

    if !health(EMBED_PORT) {
        say("正在启动本机引擎…", 0, 0);
    }
    ensure_embedder_with(|secs| say("正在启动本机引擎…", secs, 0))?;

    say("正在理解要找的东西…", 0, 0);
    let qs = embed(
        &queries
            .iter()
            .map(|q| format!("{QUERY_PREFIX}{q}"))
            .collect::<Vec<_>>(),
    )?;

    say("正在读取全书索引…", 0, 0);
    let rows = {
        let mut guard = book::store().lock().unwrap();
        let s = guard.as_mut().ok_or("数据库未初始化")?;
        // i64::MAX: no spoiler cap. See above.
        s.chunk_vectors(book_id, i64::MAX)
            .map_err(|e| format!("{e}"))?
    };
    if rows.is_empty() {
        return Err("这本书还没有建立索引".into());
    }

    say("正在比对全书原文…", 0, rows.len() as u32);
    let titles = book::chapter_titles(&path)?;
    let display_k = (k as usize).clamp(1, 12);
    // Keep two candidates per chapter in the broad pass. Nearby duplicates are
    // removed from their expanded original text below, while two genuinely
    // separate scenes in one long chapter are allowed to survive.
    let candidates = chunk::rank_multi(&qs, &rows, LANDMINE_CANDIDATE_POOL.max(display_k), 2);
    let mut fingerprints: Vec<Vec<char>> = Vec::new();
    let mut hits: Vec<SearchHit> = Vec::with_capacity(display_k);
    for h in candidates {
        let (text, fingerprint) = landmine_context(&path, &h, &rows)?;
        if fingerprint.is_empty()
            || fingerprints
                .iter()
                .any(|seen| repeats_original(&fingerprint, seen))
        {
            continue;
        }
        fingerprints.push(fingerprint);
        hits.push(SearchHit {
            chapter: h.chapter as u32,
            title: titles.get(h.chapter as usize).cloned().unwrap_or_default(),
            start: h.start,
            text,
            score: h.score,
        });
        if hits.len() == display_k {
            break;
        }
    }

    let _ = sink.add(ScanProgress {
        phase: "完成".into(),
        waited: 0,
        total: rows.len() as u32,
        hits: Some(hits),
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_summary_strips_residue() {
        assert_eq!(
            clean_summary("<think>\n\n</think>\n\n“主角赢了。”"),
            "主角赢了。"
        );
        assert_eq!(clean_summary("摘要：他走了。\n多余行"), "他走了。 多余行");
    }

    #[test]
    fn landmine_context_includes_one_neighbor_on_each_side() {
        let rows = vec![
            (3, 10, 20, Vec::new()),
            (3, 20, 30, Vec::new()),
            (3, 30, 40, Vec::new()),
            (4, 40, 50, Vec::new()),
        ];
        let hit = chunk::Hit {
            chapter: 3,
            start: 20,
            end: 30,
            score: 0.8,
        };
        assert_eq!(
            landmine_context_spans(&hit, &rows),
            vec![(10, 20), (20, 30), (30, 40)]
        );
    }

    #[test]
    fn repeat_detection_requires_substantial_verbatim_text() {
        let shared = "这是一段跨越章节边界后被下一章重复刊载的原文，用于确认它确实是同一处内容而不是相似主题。";
        let a = normalized_evidence(&format!("{shared}{shared}第一处结尾"));
        let b = normalized_evidence(&format!("第二处开头{shared}{shared}"));
        let paraphrase = normalized_evidence(
            "这段话谈论近似的情节和相同的人物，但它没有照抄连续原句，因此必须作为独立候选保留。",
        );
        assert!(repeats_original(&a, &b));
        assert!(!repeats_original(&a, &paraphrase));
    }

    /// Needs a live llama-server on the port (any model). Run explicitly:
    /// `cargo test live_engine -- --ignored`
    #[test]
    #[ignore]
    fn live_engine_roundtrip() {
        let s = summarize_excerpt("王小明在山下捡到一把剑，剑里住着一位老爷爷。老爷爷说要收他为徒，王小明拜师后连夜进山修炼。").unwrap();
        println!("summary: {s}");
        assert!(!s.is_empty() && s.chars().count() <= 60);
    }
}

#[cfg(test)]
mod spawn_tests {
    use super::*;

    /// Exercises the real spawn path: needs engine+model installed and NO
    /// server already running. `cargo test live_spawn -- --ignored`
    #[test]
    #[ignore]
    fn live_spawn() {
        init_ai(std::env::var("NOVEL_AI_DIR").expect("set NOVEL_AI_DIR")).unwrap();
        assert!(!health(PORT), "kill the running server first");
        inference_backend().prepare_chat().unwrap();
        assert!(health(PORT));
        stop_ai();
    }
}

/// The second half of the calibration: can the 0.6B tell a landmine that
/// *happened* from one that is merely feared, threatened, rumoured or dreamt?
///
/// Retrieval cannot make this distinction — it matched all of them equally in
/// the first probe. If the classifier cannot either, the feature is a
/// false-positive machine and should not be built. The hard cases here are the
/// near-misses, not the positives.
///
///   cargo test probe_judge -- --ignored --nocapture
#[cfg(test)]
mod judge {
    use super::*;

    /// Deliberately *not* "does this book have 绿帽" — that is a compound
    /// question (did it happen AND to whom). The model gets only the first half;
    /// which character it happened to is a name check, and names are rules work.
    const VERDICTS: [&str; 3] = ["发生", "提及", "无关"];

    /// One turn against the chat model, returning the first vocabulary word it
    /// says. `vocab` is the closed answer set; anything else is a refusal.
    fn ask(
        system: &str,
        user: &str,
        vocab: &[&'static str],
        shots: &[(&str, &str)],
    ) -> Result<Option<&'static str>, String> {
        ask_n(system, user, vocab, shots, 16)
    }

    fn ask_n(
        system: &str,
        user: &str,
        vocab: &[&'static str],
        shots: &[(&str, &str)],
        max_tokens: u32,
    ) -> Result<Option<&'static str>, String> {
        let mut messages = vec![json!({"role": "system", "content": system})];
        for (q, a) in shots {
            messages.push(json!({"role": "user", "content": q}));
            messages.push(json!({"role": "assistant", "content": a}));
        }
        messages.push(json!({"role": "user", "content": user}));
        let body = json!({
            "messages": messages,
            "temperature": 0.0,
            "max_tokens": max_tokens,
        });
        let (status, resp) = inference_backend().chat_completion(&body, 300)?;
        if status != 200 {
            return Err(format!("引擎返回 {status}"));
        }
        let v: Value = serde_json::from_slice(&resp).map_err(|e| format!("非 JSON: {e}"))?;
        let content = v["choices"][0]["message"]["content"].as_str().unwrap_or("");
        let cleaned = clean_summary(content);
        Ok(vocab
            .iter()
            .filter_map(|m| cleaned.find(m).map(|p| (p, *m)))
            .min()
            .map(|(_, m)| m))
    }

    const EVENT: &str = "某个女性与她的丈夫或恋人以外的男性发生性关系";

    /// The original three-way question, kept as the baseline that failed.
    fn judge(passage: &str) -> Result<Option<String>, String> {
        let sys = format!(
            "你是小说情节判定工具。判断段落中『{EVENT}』这件事的状态，只能选一个词：\n发生 —— 段落里这件事确实发生了。\n提及 —— 只是怀疑、谣言、威胁、梦境或否认，并没有真的发生。\n无关 —— 段落与这件事无关（包括夫妻或恋人之间的亲密）。\n只输出这一个词，不要解释。"
        );
        let user = format!("{passage}\n\n判定：发生、提及，还是无关？/no_think");
        Ok(ask(&sys, &user, &VERDICTS, &[])?.map(|s| s.to_string()))
    }

    /// Same question, options reversed. If the answer flips with the order, the
    /// model was never reading the passage.
    fn judge_reversed(passage: &str) -> Result<Option<String>, String> {
        let sys = format!(
            "你是小说情节判定工具。判断段落中『{EVENT}』这件事的状态，只能选一个词：\n无关 —— 段落与这件事无关（包括夫妻或恋人之间的亲密）。\n提及 —— 只是怀疑、谣言、威胁、梦境或否认，并没有真的发生。\n发生 —— 段落里这件事确实发生了。\n只输出这一个词，不要解释。"
        );
        let user = format!("{passage}\n\n判定：无关、提及，还是发生？/no_think");
        Ok(ask(&sys, &user, &VERDICTS, &[])?.map(|s| s.to_string()))
    }

    /// Same three-way question, taught by example instead of by definition —
    /// which is how a 0.6B learns anything.
    fn judge_shots(passage: &str) -> Result<Option<String>, String> {
        let sys = format!("你是小说情节判定工具。判断段落中『{EVENT}』这件事的状态：发生、提及、无关。只输出一个词。");
        const SHOTS: &[(&str, &str)] = &[
            ("张三疑心妻子与邻居有染，却始终没有证据。/no_think", "提及"),
            (
                "她终于没有推开他，两人在客房里过了一夜。第二天她不敢看丈夫的眼睛。/no_think",
                "发生",
            ),
            ("少年在山中打坐修炼，一夜之间连破两境。/no_think", "无关"),
            ("成亲当晚，他与妻子相拥而眠。/no_think", "无关"),
        ];
        Ok(ask(&sys, &format!("{passage}/no_think"), &VERDICTS, SHOTS)?.map(|s| s.to_string()))
    }

    /// The one option the per-chapter tasks could never afford: let the model
    /// think. 排雷 judges a few dozen passages per book, not 1300 chapters — five
    /// seconds of reasoning per passage is free here. If Qwen3 can do this at
    /// all, this is where it shows.
    fn judge_thinking(passage: &str) -> Result<Option<String>, String> {
        judge_thinking_t(passage, 0.0)
    }

    fn judge_thinking_t(passage: &str, temperature: f32) -> Result<Option<String>, String> {
        let sys = format!(
            "你是小说情节判定工具。判断段落中『{EVENT}』这件事的状态。\n发生：段落里这件事确实发生了。\n提及：只是怀疑、谣言、威胁、梦境或否认，没有真的发生。\n无关：段落与这件事无关，包括夫妻或恋人之间的亲密。\n先简短思考，最后单独一行输出结论词。"
        );
        let user = format!("{passage}\n\n它属于：发生、提及，还是无关？");
        // Read the verdict from the tail: with thinking on, the words appear
        // inside the reasoning too, and the last one is the conclusion.
        let raw = ask_raw_t(&sys, &user, 400, temperature)?;
        Ok(verdict(&raw, &VERDICTS).map(|s| s.to_string()))
    }

    /// The conclusion is the last vocabulary word after the think block — the
    /// words also appear inside the reasoning, where they are hypotheses.
    fn verdict(raw: &str, vocab: &[&'static str]) -> Option<&'static str> {
        let tail = match raw.rfind("</think>") {
            Some(i) => &raw[i + "</think>".len()..],
            None => raw,
        };
        vocab
            .iter()
            .filter_map(|m| tail.rfind(m).map(|p| (p, *m)))
            .max()
            .map(|(_, m)| m)
    }

    /// The dominant false alarm is a couple's own wedding night read as
    /// adultery. So the affirmative verdict has to survive one more question —
    /// asked only of passages already judged 发生, which is a handful per book.
    fn judge_veto(passage: &str) -> Result<Option<String>, String> {
        judge_veto_t(passage, 0.0)
    }

    fn judge_veto_t(passage: &str, temperature: f32) -> Result<Option<String>, String> {
        let first = judge_thinking_t(passage, temperature)?;
        if first.as_deref() != Some("发生") {
            return Ok(first);
        }
        let raw = ask_raw_t(
            "你是小说段落判定工具。段落里发生了性关系。判断发生关系的这两个人是不是夫妻、未婚夫妻或男女朋友。先简短思考，最后单独一行输出：是 或 否。",
            &format!("{passage}\n\n发生关系的两人是夫妻或恋人吗？"),
            400,
            temperature,
        )?;
        // Their own partner: not a landmine, whatever the retriever thought.
        let couple = verdict(&raw, &["是", "否"]) == Some("是");
        Ok(Some(if couple { "无关" } else { "发生" }.into()))
    }

    /// Greedy decoding gives one sample of the model's opinion. Three sampled
    /// opinions and a majority is the cheapest variance reduction there is, and
    /// 排雷 — a few dozen passages per book — can afford it. Not optional, as it
    /// turns out: even at temperature 0 the batched GPU decode is not
    /// reproducible, and single verdicts flip between runs.
    fn judge_vote(passage: &str) -> Result<Option<String>, String> {
        let mut tally: std::collections::HashMap<String, u32> = Default::default();
        for _ in 0..3 {
            if let Some(v) = judge_strict_t(passage, 0.7)? {
                *tally.entry(v).or_default() += 1;
            }
        }
        Ok(tally.into_iter().max_by_key(|(_, n)| *n).map(|(v, _)| v))
    }

    /// The exclusion the model kept getting wrong — a couple's own wedding night
    /// — stated inside the question instead of asked as a follow-up. The
    /// follow-up failed because this model answers 是/否 questions from prior,
    /// not from the passage; it can only be trusted to *choose among named
    /// outcomes* after reasoning.
    fn judge_strict(passage: &str) -> Result<Option<String>, String> {
        judge_strict_t(passage, 0.0)
    }

    /// Last attempt at precision without a bigger model: keep the recall-heavy
    /// prompt that works, then send only its positives through a *named-choice*
    /// second question. The earlier veto failed because it was 是/否 — this model
    /// answers yes-or-no from prior. Given named outcomes to reason about, it
    /// reads the passage.
    fn judge_gate(passage: &str) -> Result<Option<String>, String> {
        const RELATION: [&str; 3] = ["夫妻恋人", "并非夫妻恋人", "没有性关系"];
        let mut tally: std::collections::HashMap<&str, u32> = Default::default();
        for _ in 0..3 {
            if let Some(v) = judge_thinking_t(passage, 0.7)? {
                *tally
                    .entry(match v.as_str() {
                        "发生" => "发生",
                        "提及" => "提及",
                        _ => "无关",
                    })
                    .or_default() += 1;
            }
        }
        let first = tally.into_iter().max_by_key(|(_, n)| *n).map(|(v, _)| v);
        if first != Some("发生") {
            return Ok(first.map(|s| s.to_string()));
        }

        let raw = ask_raw(
            "你是小说段落判定工具。先判断段落里有没有发生性关系；如果有，再判断发生关系的两人是什么关系。\n\
             从这三个词里选一个：\n\
             夫妻恋人 —— 发生关系的两人是夫妻、未婚夫妻或男女朋友。\n\
             并非夫妻恋人 —— 发生关系的两人不是夫妻也不是恋人。\n\
             没有性关系 —— 段落里没有发生性关系。\n\
             先简短思考，最后单独一行输出这一个词。",
            &format!("{passage}\n\n选哪个词？"),
            400,
        )?;
        // Only a betrayal is a landmine. Their own partner is a love scene, and
        // no sex at all means the first question was wrong.
        Ok(Some(
            match verdict(&raw, &RELATION) {
                Some("并非夫妻恋人") => "发生",
                _ => "无关",
            }
            .into(),
        ))
    }

    fn judge_strict_t(passage: &str, temperature: f32) -> Result<Option<String>, String> {
        let sys = "你是小说情节判定工具。判断段落里是否发生了『背叛性的性关系』——即某个女性与她的丈夫或恋人**以外**的男性发生了性关系。\n\
             按下面的规则选一个词：\n\
             发生 —— 段落里确实发生了这样的性关系（包括回忆或坦白中已经发生过的）。\n\
             提及 —— 只是怀疑、谣言、威胁、梦境、担心或否认，事情并没有真的发生。\n\
             无关 —— 段落与此无关。特别注意：夫妻之间、恋人之间、新婚洞房的性关系，一律判『无关』，因为那不是背叛。段落里没有任何性关系时，也判『无关』。\n\
             先简短思考：段落里有没有性关系？如果有，双方是不是夫妻或恋人？然后单独一行输出结论词。";
        let user = format!("{passage}\n\n结论是：发生、提及，还是无关？");
        let raw = ask_raw_t(sys, &user, 400, temperature)?;
        Ok(verdict(&raw, &VERDICTS).map(|s| s.to_string()))
    }

    fn ask_raw(system: &str, user: &str, max_tokens: u32) -> Result<String, String> {
        ask_raw_t(system, user, max_tokens, 0.0)
    }

    /// Voting needs the samples to differ, so temperature is a parameter — at
    /// 0.0 three votes are one vote counted three times.
    fn ask_raw_t(
        system: &str,
        user: &str,
        max_tokens: u32,
        temperature: f32,
    ) -> Result<String, String> {
        let body = json!({
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": temperature,
            "max_tokens": max_tokens,
        });
        let (status, resp) = inference_backend().chat_completion(&body, 300)?;
        if status != 200 {
            return Err(format!("引擎返回 {status}"));
        }
        let v: Value = serde_json::from_slice(&resp).map_err(|e| format!("非 JSON: {e}"))?;
        Ok(v["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("")
            .to_string())
    }

    /// Decomposed: two binary questions instead of one three-way. The first is
    /// nearly lexical (is there sex here at all?) and kills every clean passage
    /// before the hard question is ever asked.
    fn judge_two_step(passage: &str) -> Result<Option<String>, String> {
        const YN: [&str; 2] = ["是", "否"];
        let sexual = ask(
            "你是小说段落判定工具。判断段落里是否**已经发生**了性行为或性关系（怀疑、谣言、威胁、梦境不算）。只回答 是 或 否。",
            &format!("{passage}\n\n段落里是否已经发生了性行为？只答 是 或 否。/no_think"),
            &YN,
            &[
                ("两人在客房里过了一夜，她不敢再看他的眼睛。\n\n段落里是否已经发生了性行为？只答 是 或 否。/no_think", "是"),
                ("他怀疑妻子与人有染，却没有证据。\n\n段落里是否已经发生了性行为？只答 是 或 否。/no_think", "否"),
                ("他把她压在榻上，红烛燃了一夜。\n\n段落里是否已经发生了性行为？只答 是 或 否。/no_think", "是"),
                ("少年在山中打坐修炼，一夜连破两境。\n\n段落里是否已经发生了性行为？只答 是 或 否。/no_think", "否"),
            ],
        )?;
        if sexual != Some("是") {
            // Nothing happened: 提及 vs 无关 is a distinction the reader does not
            // care about here, so answer the safe one.
            return Ok(Some("无关".into()));
        }
        let married = ask(
            "你是小说段落判定工具。段落里发生了性关系。判断这两个人是不是夫妻或情侣。只回答 是 或 否。",
            &format!("{passage}\n\n发生关系的两人是夫妻或情侣吗？只答 是 或 否。/no_think"),
            &YN,
            &[
                ("洞房花烛夜，他掀开红盖头，与新婚妻子一夜缠绵。\n\n发生关系的两人是夫妻或情侣吗？只答 是 或 否。/no_think", "是"),
                ("丈夫出差那夜，她没有推开那个男人。\n\n发生关系的两人是夫妻或情侣吗？只答 是 或 否。/no_think", "否"),
            ],
        )?;
        Ok(Some(
            if married == Some("否") {
                "发生"
            } else {
                "无关"
            }
            .into(),
        ))
    }

    /// (expected, passage). The near-misses are written the way novels actually
    /// write them — suspicion, slander, threat, dream, denial — because that is
    /// what the retriever will hand the classifier from a book with no landmine.
    const CASES: &[(&str, &str)] = &[
        // 真的发生了
        ("发生", "王钧抱着惠茹走进哥哥的卧房，在大哥和大嫂常年同眠的床上要了她。惠茹咬着嘴唇，终究没有推开他。"),
        ("发生", "丈夫出差的那一夜，她终究还是没有推开那个男人。第二天醒来时，床单上一片狼藉，她怔怔地坐了很久。"),
        ("发生", "她红着脸，声音低得几乎听不见：“昨晚在酒店……我和陈总，做了。”"),
        ("发生", "苏婉终于向他坦白：那年在京城，她早已把身子给了萧公子，只是从未对人说起。"),
        ("发生", "屋内传来女人压抑的喘息声。李二郎一脚踹开房门，看见自己的妻子正伏在另一个男人身下。"),
        ("发生", "赵员外的小妾与府里的管家私通，被下人撞破，一时间闹得满城风雨。"),
        // 只是提及：怀疑、谣言、威胁、梦、否认、别人的故事
        ("提及", "他心里越想越不安：她这么晚还不回来，该不会是和那个男人在一起吧？"),
        ("提及", "城里有人造谣，说他的娘子早就跟隔壁的王秀才有染。他听完一拳砸在墙上，指节渗出血来。"),
        ("提及", "那恶霸狞笑道：“三日之内不交出灵石，我就把你的女人抢回府里，让你戴一辈子绿帽子。”"),
        ("提及", "她急得眼泪都掉了下来：“我没有！我和他清清白白，你为什么就是不信我？”"),
        ("提及", "他做了个噩梦，梦见妻子躺在别人怀里，笑着看他。惊醒时冷汗涔涔，身边人睡得正沉。"),
        ("提及", "说书人讲起前朝旧事：某位将军常年戍边，夫人与幕僚私通，最终双双被斩于市。众人听得唏嘘。"),
        // 无关：清水、修炼、以及最要命的——和自己伴侣的亲密
        ("无关", "周元盘坐调息，源气自毛孔涌入，苦修三月，他终于突破到太初境三重。"),
        ("无关", "夭夭轻笑一声，脸颊靠在他的肩膀上，两人并肩看着远处的落日，谁都没有说话。"),
        ("无关", "顾红衣咬着红唇，死死盯着源气光镜，手心里全是汗，连呼吸都放轻了。"),
        ("无关", "洞房花烛夜，他掀开红盖头，与新婚妻子相拥而眠，一夜缠绵。"),
        ("无关", "他与妻子恩爱多年，从未红过脸，街坊邻里都羡慕这一对。"),
        ("无关", "两人在酒楼里推杯换盏，聊起城中最近的粮价，一直聊到掌灯时分。"),
    ];

    type Strategy = fn(&str) -> Result<Option<String>, String>;

    #[test]
    #[ignore]
    fn probe_judge() {
        init_ai(std::env::var("NOVEL_AI_DIR").expect("set NOVEL_AI_DIR")).unwrap();
        inference_backend().prepare_chat().unwrap();

        let strategies: [(&str, Strategy); 2] = [
            ("思考模式（基线）", judge_thinking),
            ("三票 + 具名关系门", judge_gate),
        ];
        // Kept compiled as the record of what did not work: without reasoning
        // tokens this model answers from prior, not from the passage.
        let _ = (
            judge as Strategy,
            judge_reversed as Strategy,
            judge_shots as Strategy,
            judge_two_step as Strategy,
            judge_veto as Strategy,
            judge_strict as Strategy,
            judge_vote as Strategy,
        );

        for (name, run) in strategies {
            println!("\n════ {name} ════");
            let (mut right, mut false_alarm, mut missed) = (0, 0, 0);
            for (want, passage) in CASES {
                let got = run(passage).unwrap().unwrap_or_else(|| "??".into());
                let ok = got == *want;
                if ok {
                    right += 1;
                }
                // The costly mistake is not a missed landmine — it is calling an
                // innocent book guilty. Count the two directions separately.
                if got == "发生" && *want != "发生" {
                    false_alarm += 1;
                }
                if got != "发生" && *want == "发生" {
                    missed += 1;
                }
                if !ok {
                    let head: String = passage.chars().take(30).collect();
                    println!("  ✗ 期望{want} 得到{got}  {head}");
                }
            }
            // Only the 发生-or-not split reaches the user: 提及 and 无关 both mean
            // "no landmine here", and the reader never sees the difference.
            let positives = CASES.iter().filter(|(w, _)| *w == "发生").count();
            println!(
                "  三分类正确 {right}/{} · 排雷有效性：误报 {false_alarm}/{} · 漏报 {missed}/{positives}",
                CASES.len(),
                CASES.len() - positives
            );
        }
        stop_ai();
    }
}

/// Calibration probe for the content-warning ("排雷") feature. Not a feature and
/// not shipped — it answers one question before any of it gets built: does the
/// embedder actually separate a landmine passage from the rest of a novel?
///
/// It runs the production path exactly (same chunker, same query prefix, same
/// int8 quantization, same cosine), prints the top hits with their scores, and
/// leaves the judging to a human. If the retrieved passages are not on topic,
/// no amount of UI will make the feature honest.
///
///   $env:NOVEL_AI_DIR="…\ai"; $env:NOVEL_BOOK="…\bad\x.txt"
///   cargo test probe_landmines -- --ignored --nocapture
#[cfg(test)]
mod probe {
    use super::*;
    use novel_core::{book as corebook, decode, fingerprint};

    /// Several queries per landmine on purpose: one sentence is one point in the
    /// space, and 绿帽 shows up as 出轨 / 私通 / 失身 / 委身 / 被夺 — near-misses
    /// of each other, but not the same point.
    const PROBES: &[(&str, &[&str])] = &[
        (
            "绿帽",
            &[
                "她背着自己的男人和别人上了床",
                "妻子与其他男人私通、偷情",
                "他的女人被别的男人夺走、占有",
                "得知妻子出轨后他愤怒屈辱",
            ],
        ),
        (
            "女主非处",
            &[
                "她已经不是处子之身，早就被别的男人碰过",
                "她向他坦白自己曾与他人有过关系",
                "他发现她并非完璧，落红未见",
                "她的第一次给了另一个男人",
            ],
        ),
        // Negative control. Whatever this scores on a book with no landmine is
        // the noise floor the real probes have to beat.
        ("对照·无关", &["主角斩杀妖兽后打坐修炼，吸收灵气突破境界"]),
    ];

    #[test]
    #[ignore]
    fn probe_landmines() {
        init_ai(std::env::var("NOVEL_AI_DIR").expect("set NOVEL_AI_DIR")).unwrap();
        let path = std::env::var("NOVEL_BOOK").expect("set NOVEL_BOOK");
        let cap: usize = std::env::var("NOVEL_MAX_CHUNKS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(6000);

        let raw = std::fs::read(&path).unwrap();
        let d = decode::decode(&raw);
        let fp = fingerprint::fingerprint(d.encoding, &d.text);
        let b = corebook::build(&d.text, &fp);
        println!(
            "{path}\n  {} 章 · {} 字",
            b.chapters.len(),
            d.text.chars().count()
        );

        // Chunk the whole book, remembering which chapter each chunk came from.
        let mut chunks: Vec<(usize, chunk::Chunk)> = Vec::new();
        for c in &b.chapters {
            for ch in chunk::chunk_body(&d.text, c.body_start, c.span.end, chunk::TARGET_CHARS) {
                chunks.push((c.index, ch));
            }
        }
        // A long book would take an hour to embed and prove nothing extra; cap it
        // and say so, rather than quietly measuring a prefix.
        let total = chunks.len();
        if chunks.len() > cap {
            chunks.truncate(cap);
        }
        println!("  {} 块（共 {total}，测 {}）", total, chunks.len());

        inference_backend().prepare_embeddings().unwrap();

        // Document side: no prefix, then quantized to int8 exactly as the index
        // stores it — the probe must measure what production would score.
        let t0 = std::time::Instant::now();
        let mut packed: Vec<Vec<u8>> = Vec::with_capacity(chunks.len());
        for (i, batch) in chunks.chunks(EMBED_BATCH).enumerate() {
            let texts: Vec<String> = batch.iter().map(|(_, c)| c.text.clone()).collect();
            for v in embed(&texts).unwrap() {
                packed.push(chunk::quantize(&v));
            }
            if i % 20 == 0 {
                println!("    嵌入 {}/{}", packed.len(), chunks.len());
            }
        }
        println!("  嵌入耗时 {:?}", t0.elapsed());

        for (name, queries) in PROBES {
            println!("\n════ {name} ════");
            // Union over the landmine's queries: a chunk is as relevant as its
            // best-matching phrasing, not its average one.
            let mut best: Vec<f32> = vec![0.0; packed.len()];
            let mut which: Vec<usize> = vec![0; packed.len()];
            for (qi, q) in queries.iter().enumerate() {
                let qv = &embed(&[format!("{QUERY_PREFIX}{q}")]).unwrap()[0];
                for (i, p) in packed.iter().enumerate() {
                    let s = chunk::cosine(qv, p);
                    if s > best[i] {
                        best[i] = s;
                        which[i] = qi;
                    }
                }
            }
            let mut order: Vec<usize> = (0..packed.len()).collect();
            order.sort_by(|&a, &b| best[b].partial_cmp(&best[a]).unwrap());

            for &i in order.iter().take(20) {
                let (ci, c) = &chunks[i];
                let text: String = c.text.chars().take(90).collect();
                println!(
                    "{:.3}  第{}章 [q{}]  {}",
                    best[i],
                    ci + 1,
                    which[i],
                    text.replace('\n', " ")
                );
            }
            // The shape of the tail matters as much as the top: a landmine that
            // is really there shows a cliff, a phantom one shows a slope.
            let p = |k: usize| best[order[k.min(order.len() - 1)]];
            println!(
                "  分数分布：#1 {:.3} · #10 {:.3} · #50 {:.3} · #200 {:.3}",
                p(0),
                p(9),
                p(49),
                p(199)
            );
        }
        stop_ai();
    }
}

// ── 读者画像 ─────────────────────────────────────────────────────────────────
//
// The facts are counted here from reading_events, the library and the mood tags
// — never guessed. The prose is a pure template: every 唯美 sentence is written
// below by hand, the numbers are slotted in from the rules, and a rotating seed
// (from 换一篇) chooses among phrasings so the same data reads freshly each time.
// No model is involved — a 0.6B can't hold a second-person 唯美 register steady,
// and here the beauty has to be reliable, not occasionally lucky. Bonus: the
// portrait is instant and works even when the model isn't installed.

struct PortraitFacts {
    total_secs: i64,
    active_days: i64,
    streak: i64,
    longest_session_secs: i64,
    night_share: f64,
    dominant_bucket: &'static str,
    finished: usize,
    top_book: Option<(String, i64)>,
    top_genres: Vec<String>,
    top_authors: Vec<String>,
    top_moods: Vec<String>,
    /// Local month/day the reader's very first session began — the story's
    /// opening line. 0 when there are no events.
    first_month: i64,
    first_day: i64,
}

/// Civil date from a Unix timestamp, no chrono dependency (Howard Hinnant's
/// days→y/m/d). Only month and day are used, but the year keeps it correct.
fn ymd_from_epoch(secs: i64) -> (i64, i64, i64) {
    let z = secs.div_euclid(86400) + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn hour_bucket(h: i64) -> &'static str {
    match h {
        5..=7 => "清晨",
        8..=11 => "上午",
        12..=13 => "中午",
        14..=17 => "下午",
        18..=21 => "晚上",
        _ => "深夜",
    }
}

fn build_portrait_facts(
    s: &novel_core::store::Store,
    tz_secs: i64,
) -> Result<PortraitFacts, String> {
    use std::collections::{HashMap, HashSet};
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let events = s.events_since(0).map_err(|e| format!("{e}"))?;
    let mut total_secs = 0i64;
    let mut longest = 0i64;
    let mut by_book: HashMap<i64, i64> = HashMap::new();
    let mut by_bucket: HashMap<&'static str, i64> = HashMap::new();
    let mut night = 0i64;
    let mut days: HashSet<i64> = HashSet::new();
    let mut first_ts = i64::MAX;
    for (book_id, started, ended) in &events {
        let dur = (ended - started).max(0);
        total_secs += dur;
        longest = longest.max(dur);
        first_ts = first_ts.min(*started);
        *by_book.entry(*book_id).or_default() += dur;
        let local = started + tz_secs;
        let hour = local.rem_euclid(86400) / 3600;
        by_bucket
            .entry(hour_bucket(hour))
            .and_modify(|v| *v += dur)
            .or_insert(dur);
        if !(5..=21).contains(&hour) {
            night += dur;
        }
        days.insert(local.div_euclid(86400));
    }

    // Current streak: consecutive local days ending today (or yesterday, so a
    // quiet today doesn't wipe it) that have any reading.
    let today = (now + tz_secs).div_euclid(86400);
    let mut streak = 0i64;
    let mut d = if days.contains(&today) {
        today
    } else {
        today - 1
    };
    while days.contains(&d) {
        streak += 1;
        d -= 1;
    }

    let dominant_bucket = by_bucket
        .iter()
        .max_by_key(|(_, v)| **v)
        .map(|(k, _)| *k)
        .unwrap_or("深夜");
    let night_share = if total_secs > 0 {
        night as f64 / total_secs as f64
    } else {
        0.0
    };

    // Library-side facts, weighted by how long each book was actually read.
    let books = s.library().map_err(|e| format!("{e}"))?;
    let mut genre_secs: HashMap<String, i64> = HashMap::new();
    let mut author_secs: HashMap<String, i64> = HashMap::new();
    let mut mood_count: HashMap<String, i64> = HashMap::new();
    let mut finished = 0usize;
    let mut top_book: Option<(String, i64)> = None;
    for b in &books {
        let secs = by_book.get(&b.id).copied().unwrap_or(0);
        if secs > 0 {
            if top_book.as_ref().map(|(_, t)| secs > *t).unwrap_or(true) {
                top_book = Some((b.title.clone(), secs));
            }
            if let Some(tags) = &b.genre_tags {
                for g in tags
                    .split(&[',', '，', '、', ' '][..])
                    .filter(|x| !x.trim().is_empty())
                {
                    *genre_secs.entry(g.trim().to_string()).or_default() += secs;
                }
            }
            if let Some(a) = &b.author {
                let a = a.trim();
                if !a.is_empty() && a != "佚名" && a != "未知" {
                    *author_secs.entry(a.to_string()).or_default() += secs;
                }
            }
        }
        // Progress classification uses last_chapter regardless of logged time:
        // a book read on another device still counts as read.
        if b.chapter_count > 0 {
            if b.last_chapter + 1 >= b.chapter_count {
                finished += 1;
            }
        }
        // Mood texture of what's been read: tags on chapters up to where the
        // reader has reached.
        if secs > 0 {
            if let Ok(moods) = s.chapter_moods(b.id) {
                for (idx, m) in moods {
                    if idx > b.last_chapter {
                        continue;
                    }
                    for tag in m
                        .split(&[',', '，', '、', ' '][..])
                        .filter(|x| !x.trim().is_empty())
                    {
                        *mood_count.entry(tag.trim().to_string()).or_default() += 1;
                    }
                }
            }
        }
    }

    let top_n = |m: HashMap<String, i64>, n: usize| -> Vec<String> {
        let mut v: Vec<(String, i64)> = m.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        v.into_iter().take(n).map(|(k, _)| k).collect()
    };

    Ok(PortraitFacts {
        total_secs,
        active_days: days.len() as i64,
        streak,
        longest_session_secs: longest,
        night_share,
        dominant_bucket,
        finished,
        top_book,
        top_genres: top_n(genre_secs, 3),
        top_authors: top_n(author_secs, 2),
        top_moods: top_n(mood_count, 3),
        first_month: if first_ts == i64::MAX {
            0
        } else {
            ymd_from_epoch(first_ts + tz_secs).1
        },
        first_day: if first_ts == i64::MAX {
            0
        } else {
            ymd_from_epoch(first_ts + tz_secs).2
        },
    })
}

fn fmt_dur(secs: i64) -> String {
    if secs < 3600 {
        format!("{} 分钟", (secs / 60).max(1))
    } else {
        let h = secs as f64 / 3600.0;
        if h >= 10.0 {
            format!("{} 小时", h.round() as i64)
        } else {
            format!("{h:.1} 小时")
        }
    }
}

impl PortraitFacts {
    /// Weave the counted facts into a short second-person 阅读小传. Pure template:
    /// every sentence is written here, the numbers are slotted in from the rules,
    /// and `seed` (rotated by 换一篇) picks among phrasings so the same data reads
    /// freshly each time — no model to wobble the register. Each sentence is
    /// self-contained (ends in 。), so a slot with no data is simply skipped
    /// without leaving a dangling clause.
    fn compose(&self, seed: u64) -> String {
        fn pick<'a>(pool: &[&'a str], seed: u64, salt: u64) -> &'a str {
            pool[(seed.wrapping_add(salt) % pool.len() as u64) as usize]
        }
        let mut s = String::new();

        // 1. 开篇：故事开始的那天。
        if self.first_month > 0 {
            s.push_str(
                &pick(
                    &[
                        "从 {M} 月 {D} 日翻开第一页起，你便与这里的故事有了牵绊。",
                        "故事要从 {M} 月 {D} 日说起——那天，你在这里读下了第一行字。",
                        "{M} 月 {D} 日，你合上现实，翻开了这里的第一个故事。",
                    ],
                    seed,
                    1,
                )
                .replace("{M}", &self.first_month.to_string())
                .replace("{D}", &self.first_day.to_string()),
            );
        } else {
            s.push_str(pick(
                &[
                    "你与这里的故事，早已相识。",
                    "不知从哪一天起，你就爱上了在这里读书。",
                ],
                seed,
                1,
            ));
        }

        // 2. 总时长 + 有书相伴的天数。
        s.push_str(
            &pick(
                &[
                    "至今，你已在字里行间停留了 {T}，散落在 {N} 个有书相伴的日子里。",
                    "到今天，你交给阅读的光阴累计有 {T}，落在 {N} 个日子之中。",
                    "算下来，你已读了 {T}，这些时光分布在 {N} 个日子里。",
                ],
                seed,
                2,
            )
            .replace("{T}", &fmt_dur(self.total_secs))
            .replace("{N}", &self.active_days.to_string()),
        );

        // 3. 节奏：偏爱的时段。
        if self.dominant_bucket == "深夜" || self.night_share >= 0.4 {
            s.push_str(pick(
                &[
                    "你偏爱在夜深时读书，万籁俱寂，故事才刚刚醒来。",
                    "夜色是你读书的底色——旁人入睡时，你正翻到最要紧的那一页。",
                ],
                seed,
                3,
            ));
        } else {
            s.push_str(
                &pick(
                    &[
                        "你习惯在{B}翻开书页，让文字陪你度过那段时光。",
                        "{B}是你与书相处最多的时候，安安静静，刚刚好。",
                    ],
                    seed,
                    3,
                )
                .replace("{B}", self.dominant_bucket),
            );
        }
        if self.streak >= 3 {
            s.push_str(
                &pick(
                    &[
                        "最近这 {S} 天，你一天也不曾落下。",
                        "连着 {S} 天，你都没有错过与书的约定。",
                    ],
                    seed,
                    4,
                )
                .replace("{S}", &self.streak.to_string()),
            );
        } else if self.longest_session_secs >= 1800 {
            s.push_str(
                &pick(
                    &[
                        "有一回，你一口气读了 {L}，舍不得停下。",
                        "你曾一头扎进故事里 {L}，浑然忘了时间。",
                    ],
                    seed,
                    4,
                )
                .replace("{L}", &fmt_dur(self.longest_session_secs)),
            );
        }

        // 4. 读的是什么：类型 / 情绪 / 作者。
        if !self.top_genres.is_empty() {
            s.push_str(
                &pick(
                    &[
                        "你的偏爱写在书目里——{G}，是你一次次回去的地方。",
                        "翻得最多的，是{G}这样的故事。",
                    ],
                    seed,
                    5,
                )
                .replace("{G}", &self.top_genres.join("、")),
            );
        }
        if !self.top_moods.is_empty() {
            s.push_str(
                &pick(
                    &["那些{Md}的段落，最能把你留住。", "你格外偏爱{Md}的滋味。"],
                    seed,
                    6,
                )
                .replace("{Md}", &self.top_moods.join("、")),
            );
        }
        if !self.top_authors.is_empty() {
            s.push_str(
                &pick(
                    &[
                        "{A} 的字，你读得格外投入。",
                        "遇上 {A}，你总愿意多留一会儿。",
                    ],
                    seed,
                    7,
                )
                .replace("{A}", &self.top_authors.join("、")),
            );
        }

        // 5. 宝藏之书。
        if let Some((title, secs)) = &self.top_book {
            s.push_str(
                &pick(
                    &[
                        "而在所有故事里，《{Bk}》是你的心头好，你为它停留了 {Bt}。",
                        "《{Bk}》大概是你的宝藏——{Bt} 的陪伴，别的书都比不上。",
                        "若要挑一本珍藏，那一定是《{Bk}》，你在它身上花了 {Bt}。",
                    ],
                    seed,
                    8,
                )
                .replace("{Bk}", title)
                .replace("{Bt}", &fmt_dur(*secs)),
            );
        }

        // 6. 结语。
        if self.finished > 0 {
            s.push_str(
                &pick(
                    &[
                        "你已读完 {F} 本，也曾在一些书前浅尝辄止——每一次翻开，都是一次出发。",
                        "这一路，你读完了 {F} 本书，剩下的故事，还在等你。",
                    ],
                    seed,
                    9,
                )
                .replace("{F}", &self.finished.to_string()),
            );
        } else {
            s.push_str(pick(
                &[
                    "还有很多故事在等你翻开，慢慢来，不必着急。",
                    "长夜与好书都还很长，愿你读得尽兴。",
                ],
                seed,
                9,
            ));
        }

        s
    }
}

/// A 阅读画像 paragraph, grounded entirely in counted facts. `angle` is a rotating
/// seed (advanced by 换一篇) that varies the phrasing; `tz_secs` is the reader's
/// UTC offset so session times and the opening date land on their local clock.
/// Pure template — no engine needed. Empty string when nothing has been read yet.
pub fn reader_portrait(angle: i32, tz_secs: i64) -> Result<String, String> {
    let facts = {
        let mut guard = book::store().lock().unwrap();
        let s = guard.as_mut().ok_or("数据库未初始化")?;
        build_portrait_facts(s, tz_secs)?
    };
    if facts.total_secs == 0 {
        return Ok(String::new());
    }
    let seed = (angle as i64).rem_euclid(9973) as u64;
    Ok(facts.compose(seed))
}

/// Can a 0.6B put a web novel in one of the thirteen boxes the Chinese web-novel
/// world actually uses — and does it beat a keyword lexicon, which costs nothing
/// and cannot hallucinate?
///
/// The lesson from the landmine probe is that a small model faced with a wide
/// closed choice tends to answer a constant, and that the only way to find out
/// is to run it against real books whose genre we already know. This one also
/// measures the rules, because if the rules win there is no reason to load a
/// model at all.
///
///   cargo test probe_genre -- --ignored --nocapture
#[cfg(test)]
mod genre {
    use super::*;
    use novel_core::{book as corebook, decode, fingerprint};

    /// The 起点 categories, as the user specified them.
    const GENRES: [&str; 13] = [
        "玄幻",
        "奇幻",
        "武侠",
        "仙侠",
        "都市",
        "现实",
        "历史",
        "军事",
        "游戏",
        "体育",
        "科幻",
        "悬疑灵异",
        "轻小说",
    ];

    /// Words that only one kind of book says. Not a description of the genre —
    /// a *discriminator*: 修炼 appears in every 玄幻 and every 仙侠, so it is
    /// worthless here, while 金丹 and 渡劫 are worth everything.
    const LEXICON: &[(&str, &[&str])] = &[
        (
            "玄幻",
            &[
                "斗气",
                "武魂",
                "魂力",
                "血脉之力",
                "神魂",
                "大陆",
                "帝境",
                "圣境",
                "源气",
            ],
        ),
        (
            "奇幻",
            &[
                "魔法",
                "法师",
                "骑士",
                "精灵",
                "矮人",
                "教廷",
                "领主",
                "德鲁伊",
                "魔王",
            ],
        ),
        (
            "武侠",
            &["江湖", "内力", "武林", "掌门", "轻功", "剑客", "内功心法"],
        ),
        (
            "仙侠",
            &[
                "修真", "筑基", "金丹", "元婴", "渡劫", "灵根", "道友", "洞府", "仙人", "法宝",
            ],
        ),
        (
            "都市",
            &[
                "手机",
                "微信",
                "公司",
                "老板",
                "警察局",
                "小区",
                "地铁",
                "医院",
                "股票",
            ],
        ),
        ("现实", &["工地", "打工", "下岗", "房贷", "工厂", "村支书"]),
        (
            "历史",
            &[
                "皇帝", "朝廷", "奏折", "太子", "丞相", "天子", "圣旨", "县令",
            ],
        ),
        (
            "军事",
            &[
                "部队",
                "连长",
                "步枪",
                "战场",
                "指挥部",
                "师长",
                "坦克",
                "特种兵",
            ],
        ),
        (
            "游戏",
            &[
                "副本",
                "玩家",
                "装备",
                "公会",
                "技能栏",
                "属性面板",
                "经验值",
                "NPC",
                "刷怪",
            ],
        ),
        (
            "体育",
            &["比赛", "教练", "球队", "进球", "联赛", "球场", "赛季"],
        ),
        (
            "科幻",
            &[
                "星舰",
                "机甲",
                "星际",
                "赛博",
                "义体",
                "纳米",
                "人工智能",
                "基因链",
                "虫族",
            ],
        ),
        (
            "悬疑灵异",
            &[
                "尸体", "凶手", "命案", "鬼魂", "阴气", "诡异", "灵异", "线索", "凶案",
            ],
        ),
        (
            "轻小说",
            &[
                "学园", "社团", "前辈", "学姐", "同学", "东京", "少女", "妹妹", "咖喱",
            ],
        ),
    ];

    /// Occurrences per million characters, so a 4-million-character book does not
    /// out-vote a 400-thousand-character one on volume alone.
    fn rule_scores(text: &str) -> Vec<(&'static str, f32)> {
        let chars = text.chars().count().max(1) as f32;
        let mut out: Vec<(&'static str, f32)> = LEXICON
            .iter()
            .map(|(g, words)| {
                let n: usize = words.iter().map(|w| text.matches(w).count()).sum();
                (*g, n as f32 * 1_000_000.0 / chars)
            })
            .collect();
        out.sort_by(|a, b| b.1.total_cmp(&a.1));
        out
    }

    /// One closed choice: thirteen names, output one of them, nothing else.
    fn ask_genre(title: &str, excerpt: &str, think: bool) -> Result<String, String> {
        let system = format!(
            "你是中文网络小说的分类器。只能从下面 13 个分类中选**一个**，直接输出分类名，不要解释。\n分类：{}",
            GENRES.join("、")
        );
        let user = format!(
            "{}【书名】{title}\n【正文片段】\n{excerpt}\n\n这本书属于哪个分类？",
            if think { "" } else { "/no_think " }
        );
        let body = json!({
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.0,
            "max_tokens": if think { 512 } else { 16 },
        });
        let (status, resp) = inference_backend().chat_completion(&body, 300)?;
        if status != 200 {
            return Err(format!("引擎返回 {status}"));
        }
        let v: Value = serde_json::from_slice(&resp).map_err(|e| e.to_string())?;
        let text = v["choices"][0]["message"]["content"].as_str().unwrap_or("");
        // Whatever it said, keep only the part after any reasoning block.
        let tail = text.rsplit("</think>").next().unwrap_or(text).trim();
        Ok(GENRES
            .iter()
            .find(|g| tail.contains(**g))
            .map(|g| g.to_string())
            .unwrap_or_else(|| {
                format!(
                    "??[{}]",
                    tail.replace('\n', " ").chars().take(20).collect::<String>()
                )
            }))
    }

    #[test]
    #[ignore]
    fn probe_genre() {
        init_ai(std::env::var("NOVEL_AI_DIR").expect("set NOVEL_AI_DIR")).unwrap();
        let dir = std::env::var("NOVEL_BOOKS").expect("set NOVEL_BOOKS");
        inference_backend().prepare_chat().unwrap();

        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == "txt"))
            .collect();
        files.sort();

        for path in files {
            let title = path.file_stem().unwrap().to_string_lossy().to_string();
            let raw = std::fs::read(&path).unwrap();
            let d = decode::decode(&raw);
            let fp = fingerprint::fingerprint(d.encoding, &d.text);
            let b = corebook::build(&d.text, &fp);
            if b.chapters.len() < 5 {
                continue;
            }

            println!("\n══════ {title}  ({} 章)", b.chapters.len());

            let rules = rule_scores(&d.text);
            println!(
                "  规则：{}",
                rules
                    .iter()
                    .take(4)
                    .map(|(g, s)| format!("{g} {s:.0}"))
                    .collect::<Vec<_>>()
                    .join("  ")
            );

            // Seven chapters spread across the book: a genre that only shows up
            // in chapter 1 is a prologue, not a genre.
            let picks: Vec<usize> = [0.02, 0.15, 0.30, 0.45, 0.60, 0.75, 0.90]
                .iter()
                .map(|f| ((b.chapters.len() - 1) as f32 * f) as usize)
                .collect();

            let mut votes: std::collections::HashMap<String, usize> = Default::default();
            let mut line = Vec::new();
            for i in picks {
                let c = &b.chapters[i];
                let body: String = d.text[c.body_start..c.span.end].chars().take(700).collect();
                let g = ask_genre(&title, &body, false).unwrap();
                *votes.entry(g.clone()).or_default() += 1;
                line.push(g);
            }
            println!("  模型逐章：{}", line.join(" | "));
            let mut v: Vec<_> = votes.into_iter().collect();
            v.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
            println!(
                "  模型投票：{}",
                v.iter()
                    .map(|(g, n)| format!("{g}×{n}"))
                    .collect::<Vec<_>>()
                    .join("  ")
            );

            // One shot with thinking, on a long excerpt from the middle of the
            // book — the strategy that rescued the landmine judge.
            let mid = &b.chapters[b.chapters.len() / 3];
            let body: String = d.text[mid.body_start..mid.span.end]
                .chars()
                .take(1200)
                .collect();
            match ask_genre(&title, &body, true) {
                Ok(g) => println!("  模型思考：{g}"),
                Err(e) => println!("  模型思考：失败 {e}"),
            }
        }
        stop_ai();
    }
}

/// Does the 0.6B label a relationship the rules could not? The rule labels are
/// already validated on real books (personaprobe); this probe measures only the
/// residue — the edges with no decisive appellation — because that is the only
/// thing the model is ever asked to do here. It prints, per book, every residual
/// pair with the model's label and the evidence it read, so a human who knows
/// the book can see whether the reads are right before any of it reaches the UI.
///
///   $env:NOVEL_AI_DIR="…\ai"; $env:NOVEL_BOOK="…\大王饶命.txt"; $env:NOVEL_UPTO=50
///   cargo test probe_relations -- --ignored --nocapture
#[cfg(test)]
mod relprobe {
    use super::*;
    use novel_core::{book as corebook, cast, decode, fingerprint};

    #[test]
    #[ignore]
    fn probe_relations() {
        init_ai(std::env::var("NOVEL_AI_DIR").expect("set NOVEL_AI_DIR")).unwrap();
        let path = std::env::var("NOVEL_BOOK").expect("set NOVEL_BOOK");
        let upto: usize = std::env::var("NOVEL_UPTO")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(50);

        let raw = std::fs::read(&path).unwrap();
        let d = decode::decode(&raw);
        let fp = fingerprint::fingerprint(d.encoding, &d.text);
        let b = corebook::build(&d.text, &fp);
        let n = upto.min(b.chapters.len());
        let cast = cast::scan(&d.text, &b.chapters, n);
        println!(
            "{path}\n  前 {n} 章 · 人物 {} · 关系 {}",
            cast.people.len(),
            cast.edges.len(),
        );

        inference_backend().prepare_chat().unwrap();
        let t0 = std::time::Instant::now();
        for e in &cast.edges {
            let (a, bn) = (&cast.people[e.a].name, &cast.people[e.b].name);
            let ev: Vec<(usize, String)> =
                e.evidence.iter().map(|(c, t)| (*c, t.clone())).collect();
            let summary = summarize_relation(a, bn, &ev).unwrap();
            println!("\n{a} ↔ {bn}  同现 {}\n  → {summary}", e.weight);
        }
        println!("\n用时 {:?}", t0.elapsed());
        stop_ai();
    }
}

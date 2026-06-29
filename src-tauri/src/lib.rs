//! `roll` — desktop shell that drives the native `roll-capture` sidecar.
//!
//! The Rust side owns no capture logic: it spawns the Swift `roll-capture`
//! process, streams its stderr into `roll://state` / `roll://log` events for the
//! UI, and stops it by writing a line to its stdin (a clean `finish()` that
//! flushes the mp4 — never a SIGKILL). When the take ends it reads the pack's
//! `manifest.json` back to report sync offsets.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};

#[derive(Serialize, Default)]
struct Device {
    index: u32,
    label: String,
    // displays carry their screen frame so the app can highlight them
    #[serde(skip_serializing_if = "Option::is_none")]
    x: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    y: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    w: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    h: Option<i64>,
}

#[derive(Serialize)]
struct Devices {
    displays: Vec<Device>,
    cameras: Vec<Device>,
    mics: Vec<Device>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecordConfig {
    display: u32,
    camera: Option<u32>,
    mic: Option<u32>,
    fps: u32,
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
struct LiveStats {
    #[serde(skip_serializing_if = "Option::is_none")]
    warmed_ms: Option<u64>,
    elapsed_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    screen_frames: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    camera_frames: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    clicks: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rows: Option<u32>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct StateEvent {
    state: String,
    stats: LiveStats,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Pack {
    id: String,
    dir: String,
    duration_ms: u64,
    sources: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rows: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    camera_sync_offset_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mic_sync_offset_ms: Option<f64>,
}

/// An in-flight take: the running sidecar plus what we need to stop it and
/// build the pack afterwards.
struct Active {
    child: Child,
    stdin: Option<ChildStdin>,
    dir: PathBuf,
    id: String,
    started: Instant,
}

#[derive(Default)]
struct RecorderState {
    active: Option<Active>,
}
struct AppState(Mutex<RecorderState>);

/// Locate the `roll-capture` binary: next to the app executable when bundled,
/// otherwise the release build inside the repo (dev).
fn sidecar_path() -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let p = dir.join("roll-capture");
            if p.exists() {
                return p;
            }
        }
    }
    let dev = Path::new(env!("CARGO_MANIFEST_DIR")).join("../capture-swift/.build/release/roll-capture");
    if dev.exists() {
        return dev;
    }
    PathBuf::from("roll-capture")
}

/// Where packs are written. `~/Movies/roll` — persistent and discoverable in
/// Finder, not buried in app-data or a temp dir that a reboot wipes.
fn recordings_root(app: &AppHandle) -> PathBuf {
    app.path()
        .video_dir()
        .or_else(|_| app.path().home_dir())
        .unwrap_or_else(|_| std::env::temp_dir())
        .join("roll")
}

// ---- device list parsing (`roll-capture --list`) ----
/// Parse a display line's "id=.. x=0 y=0 w=2560 h=1440" tail into a Device.
fn parse_display(index: u32, tail: &str) -> Device {
    let mut dev = Device { index, ..Default::default() };
    for kv in tail.split_whitespace() {
        if let Some((k, v)) = kv.split_once('=') {
            let n = v.parse::<i64>().ok();
            match k {
                "x" => dev.x = n,
                "y" => dev.y = n,
                "w" => dev.w = n,
                "h" => dev.h = n,
                _ => {}
            }
        }
    }
    dev.label = match (dev.w, dev.h) {
        (Some(w), Some(h)) => format!("{w}×{h}"),
        _ => "Display".to_string(),
    };
    dev
}

fn parse_devices(text: &str) -> Devices {
    let mut displays = Vec::new();
    let mut cameras = Vec::new();
    let mut mics = Vec::new();
    let mut section = "";
    for line in text.lines() {
        let t = line.trim();
        match t {
            "displays:" => section = "d",
            "cameras:" => section = "c",
            "mics:" => section = "m",
            _ => {
                if let Some(rest) = t.strip_prefix('[') {
                    if let Some((idx_s, label_s)) = rest.split_once(']') {
                        if let Ok(index) = idx_s.trim().parse::<u32>() {
                            let label = label_s.trim();
                            match section {
                                "d" => displays.push(parse_display(index, label)),
                                "c" => cameras.push(Device { index, label: label.to_string(), ..Default::default() }),
                                "m" => mics.push(Device { index, label: label.to_string(), ..Default::default() }),
                                _ => {}
                            }
                        }
                    }
                }
            }
        }
    }
    Devices { displays, cameras, mics }
}

// ---- stderr stream parsing (drives the live UI) ----
fn parse_warmed(line: &str) -> Option<u64> {
    let i = line.find("warmed in ")? + "warmed in ".len();
    let rest = &line[i..];
    let end = rest.find('s')?;
    rest[..end].trim().parse::<f64>().ok().map(|s| (s * 1000.0) as u64)
}

fn parse_progress(rest: &str, warmed_ms: Option<u64>) -> LiveStats {
    let mut s = LiveStats { warmed_ms, ..Default::default() };
    for kv in rest.split_whitespace() {
        if let Some((k, v)) = kv.split_once('=') {
            match k {
                "elapsed" => s.elapsed_ms = v.parse().unwrap_or(0),
                "screen" => s.screen_frames = v.parse().ok(),
                "camera" => s.camera_frames = v.parse().ok(),
                "clicks" => s.clicks = v.parse().ok(),
                "rows" => s.rows = v.parse().ok(),
                _ => {}
            }
        }
    }
    s
}

fn emit_state(app: &AppHandle, state: &str, stats: LiveStats) {
    let _ = app.emit("roll://state", StateEvent { state: state.to_string(), stats });
}

fn reader_loop(app: AppHandle, stderr: std::process::ChildStderr) {
    let mut warmed_ms: Option<u64> = None;
    for line in BufReader::new(stderr).lines().map_while(Result::ok) {
        if line.contains("warming up") {
            emit_state(&app, "warming", LiveStats::default());
        } else if line.starts_with("● recording") {
            warmed_ms = parse_warmed(&line);
            emit_state(&app, "recording", LiveStats { warmed_ms, ..Default::default() });
        } else if let Some(rest) = line.strip_prefix("progress ") {
            emit_state(&app, "recording", parse_progress(rest, warmed_ms));
        } else {
            let _ = app.emit("roll://log", line);
        }
    }
}

/// Last telemetry timestamp — a good proxy for take length when a pack was
/// written before the engine recorded `durationMs` in its manifest.
fn last_event_ms(dir: &Path) -> Option<u64> {
    let txt = std::fs::read_to_string(dir.join("metadata.jsonl")).ok()?;
    txt.lines()
        .rev()
        .find_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .and_then(|v| v.get("t_ms").and_then(|x| x.as_u64()))
}

fn build_pack(dir: &Path, id: &str, duration_ms: u64) -> Pack {
    let mut sources = Vec::new();
    for f in ["screen.mp4", "camera.mp4", "mic.m4a", "metadata.jsonl"] {
        if dir.join(f).exists() {
            sources.push(f.to_string());
        }
    }
    let rows = std::fs::read_to_string(dir.join("metadata.jsonl"))
        .ok()
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count() as u32);

    let (mut camera_sync_offset_ms, mut mic_sync_offset_ms, mut manifest_dur) = (None, None, None);
    if let Ok(txt) = std::fs::read_to_string(dir.join("manifest.json")) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
            camera_sync_offset_ms = v.get("cameraSyncOffsetMs").and_then(|x| x.as_f64());
            mic_sync_offset_ms = v.get("micSyncOffsetMs").and_then(|x| x.as_f64());
            manifest_dur = v.get("durationMs").and_then(|x| x.as_f64()).map(|d| d as u64);
        }
    }
    // live recordings pass a real duration; for listed past packs (duration_ms==0)
    // prefer the manifest, then fall back to the last event timestamp
    let duration_ms = if duration_ms > 0 {
        duration_ms
    } else {
        manifest_dur.or_else(|| last_event_ms(dir)).unwrap_or(0)
    };
    Pack {
        id: id.to_string(),
        dir: dir.to_string_lossy().into_owned(),
        duration_ms,
        sources,
        rows,
        camera_sync_offset_ms,
        mic_sync_offset_ms,
    }
}

#[derive(Serialize)]
struct PackDetail {
    manifest: serde_json::Value,
    events: Vec<serde_json::Value>,
}

/// A pack's manifest plus its telemetry rows, for the in-app inspector. Media
/// (screen/camera/mic) is loaded separately by the webview via the asset protocol.
#[tauri::command]
fn read_pack(dir: String) -> Result<PackDetail, String> {
    let p = Path::new(&dir);
    let manifest = std::fs::read_to_string(p.join("manifest.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(serde_json::Value::Null);
    let events = std::fs::read_to_string(p.join("metadata.jsonl"))
        .map(|t| t.lines().filter_map(|l| serde_json::from_str(l).ok()).collect())
        .unwrap_or_default();
    Ok(PackDetail { manifest, events })
}

/// Every pack on disk, newest first — the persistent library shown on launch.
#[tauri::command]
fn list_packs(app: AppHandle) -> Result<Vec<Pack>, String> {
    let root = recordings_root(&app);
    let mut packs = Vec::new();
    let entries = match std::fs::read_dir(&root) {
        Ok(e) => e,
        Err(_) => return Ok(packs), // no recordings dir yet
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if dir.is_dir() && name.starts_with("rec-") && dir.join("manifest.json").exists() {
            packs.push(build_pack(&dir, &name, 0));
        }
    }
    // rec-<epoch_ms>, so lexical sort on id is chronological; newest first
    packs.sort_by(|a, b| b.id.cmp(&a.id));
    Ok(packs)
}

// ---- commands ----
#[tauri::command]
fn list_devices() -> Result<Devices, String> {
    let out = Command::new(sidecar_path())
        .arg("--list")
        .output()
        .map_err(|e| format!("list devices: {e}"))?;
    Ok(parse_devices(&String::from_utf8_lossy(&out.stdout)))
}

#[tauri::command]
fn start_recording(app: AppHandle, state: State<AppState>, config: RecordConfig) -> Result<String, String> {
    let mut g = state.0.lock().unwrap();
    if g.active.is_some() {
        return Err("already recording".into());
    }

    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    let id = format!("rec-{epoch}");
    let dir = recordings_root(&app).join(&id);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

    let bin = sidecar_path();
    let mut cmd = Command::new(&bin);
    cmd.arg("--screen").arg(config.display.to_string());
    if let Some(c) = config.camera {
        cmd.arg("--cam").arg(c.to_string());
    }
    if let Some(m) = config.mic {
        cmd.arg("--mic").arg(m.to_string());
    }
    cmd.arg("--out").arg(&dir).arg("--fps").arg(config.fps.to_string());
    cmd.stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("spawn {}: {e}", bin.display()))?;
    if let Some(stderr) = child.stderr.take() {
        let app2 = app.clone();
        std::thread::spawn(move || reader_loop(app2, stderr));
    }
    let stdin = child.stdin.take();
    g.active = Some(Active {
        child,
        stdin,
        dir,
        id: id.clone(),
        started: Instant::now(),
    });
    Ok(id)
}

#[tauri::command]
fn stop_recording(app: AppHandle, state: State<AppState>) -> Result<Pack, String> {
    let mut active = {
        let mut g = state.0.lock().unwrap();
        g.active.take().ok_or("not recording")?
    };
    emit_state(
        &app,
        "saving",
        LiveStats {
            elapsed_ms: active.started.elapsed().as_millis() as u64,
            ..Default::default()
        },
    );
    // graceful stop: a line on stdin makes the engine run finish(); dropping the
    // handle then closes stdin (EOF) as a fallback trigger.
    if let Some(mut sin) = active.stdin.take() {
        let _ = sin.write_all(b"stop\n");
        let _ = sin.flush();
    }
    let _ = active.child.wait();
    let duration_ms = active.started.elapsed().as_millis() as u64;
    let pack = build_pack(&active.dir, &active.id, duration_ms);
    emit_state(&app, "idle", LiveStats::default());
    Ok(pack)
}

/// One-shot screenshot of a display as a `data:` PNG URL, for the in-app screen
/// preview thumbnail. Asks the sidecar (`--shot <i>`) for a downscaled base64 PNG.
#[tauri::command]
fn screen_shot(display: u32, width: Option<u32>) -> Result<String, String> {
    let w = width.unwrap_or(480);
    let out = Command::new(sidecar_path())
        .arg("--shot")
        .arg(display.to_string())
        .arg("--width")
        .arg(w.to_string())
        .output()
        .map_err(|e| format!("shot: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    let b64 = String::from_utf8_lossy(&out.stdout);
    let b64 = b64.trim();
    if b64.is_empty() {
        return Err("empty screenshot".into());
    }
    Ok(format!("data:image/png;base64,{b64}"))
}

#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        Command::new("open")
            .arg("-R")
            .arg(&path)
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = path;
    }
    Ok(())
}

/// Flash a transparent borderless overlay on the chosen physical display for a
/// moment, so you can confirm which screen is being captured (multi-monitor).
#[tauri::command]
fn highlight_display(app: AppHandle, x: i32, y: i32, w: i32, h: i32) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("highlight") {
        let _ = win.close();
    }
    let win = WebviewWindowBuilder::new(&app, "highlight", WebviewUrl::App("overlay.html".into()))
        .position(x as f64, y as f64)
        .inner_size(w as f64, h as f64)
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .focused(false)
        .skip_taskbar(true)
        .resizable(false)
        .build()
        .map_err(|e| e.to_string())?;
    let _ = win.set_ignore_cursor_events(true);

    let app2 = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(1300));
        if let Some(w) = app2.get_webview_window("highlight") {
            let _ = w.close();
        }
    });
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState(Mutex::new(RecorderState::default())))
        .invoke_handler(tauri::generate_handler![
            list_devices,
            list_packs,
            read_pack,
            start_recording,
            stop_recording,
            reveal,
            highlight_display,
            screen_shot
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_device_list() {
        let t = "displays:\n  [0] id=724071956 x=0 y=0 w=2560 h=1440\ncameras:\n  [0] FaceTime HD Camera\n  [1] iPhone\nmics:\n  [6] RØDE\n";
        let d = parse_devices(t);
        assert_eq!(d.displays.len(), 1);
        assert_eq!(d.displays[0].label, "2560×1440");
        assert_eq!(d.displays[0].w, Some(2560));
        assert_eq!(d.cameras.len(), 2);
        assert_eq!(d.cameras[1].label, "iPhone");
        assert_eq!(d.mics[0].index, 6);
    }

    #[test]
    fn parses_warmed_and_progress() {
        assert_eq!(
            parse_warmed("● recording 2560x1440@30 + camera + mic + meta  (warmed in 2.8s)"),
            Some(2800)
        );
        let s = parse_progress("elapsed=1234 screen=42 camera=48 clicks=3 rows=120", Some(2800));
        assert_eq!(s.elapsed_ms, 1234);
        assert_eq!(s.screen_frames, Some(42));
        assert_eq!(s.clicks, Some(3));
        assert_eq!(s.warmed_ms, Some(2800));
    }
}

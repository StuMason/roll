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
use tauri::{AppHandle, Emitter, Manager, State};

#[derive(Serialize)]
struct Device {
    index: u32,
    label: String,
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

fn recordings_root(app: &AppHandle) -> PathBuf {
    app.path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir())
        .join("recordings")
}

// ---- device list parsing (`roll-capture --list`) ----
fn display_label(raw: &str) -> String {
    // raw like "id=724071956  2560x1440" -> "2560×1440"
    raw.split_whitespace()
        .find(|s| s.contains('x'))
        .map(|res| res.replace('x', "×"))
        .unwrap_or_else(|| raw.to_string())
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
                                "d" => displays.push(Device { index, label: display_label(label) }),
                                "c" => cameras.push(Device { index, label: label.to_string() }),
                                "m" => mics.push(Device { index, label: label.to_string() }),
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

    let (mut camera_sync_offset_ms, mut mic_sync_offset_ms) = (None, None);
    if let Ok(txt) = std::fs::read_to_string(dir.join("manifest.json")) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
            camera_sync_offset_ms = v.get("cameraSyncOffsetMs").and_then(|x| x.as_f64());
            mic_sync_offset_ms = v.get("micSyncOffsetMs").and_then(|x| x.as_f64());
        }
    }
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState(Mutex::new(RecorderState::default())))
        .invoke_handler(tauri::generate_handler![
            list_devices,
            start_recording,
            stop_recording,
            reveal
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_device_list() {
        let t = "displays:\n  [0] id=724071956  2560x1440\ncameras:\n  [0] FaceTime HD Camera\n  [1] iPhone\nmics:\n  [6] RØDE\n";
        let d = parse_devices(t);
        assert_eq!(d.displays.len(), 1);
        assert_eq!(d.displays[0].label, "2560×1440");
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

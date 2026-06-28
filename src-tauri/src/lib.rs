//! `roll` — record once, hand the agent a queryable pack.
//!
//! This crate is the desktop shell: a source picker, a record button, and the
//! orchestration that owns the shared clock and writes the pack. The actual
//! pixels come from a [`capture::CaptureBackend`]; today that's the mock.

mod capture;
mod pack;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

use capture::CaptureBackend;
use pack::{Manifest, PackSource, RecordConfig, SourceInfo};

/// State of an in-flight take.
struct Active {
    dir: PathBuf,
    id: String,
    started: Instant,
    created_epoch_ms: u128,
    fps: u32,
    tick_stop: Arc<AtomicBool>,
}

#[derive(Default)]
struct RecorderState {
    backend: Option<Box<dyn CaptureBackend>>,
    active: Option<Active>,
}

impl RecorderState {
    /// Lazily construct the backend on first use.
    fn backend(&mut self) -> &mut Box<dyn CaptureBackend> {
        if self.backend.is_none() {
            self.backend = Some(capture::default_backend());
        }
        self.backend.as_mut().unwrap()
    }
}

struct AppState(Mutex<RecorderState>);

/// Returned to the frontend when a take stops.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecordingResult {
    id: String,
    dir: String,
    duration_ms: u128,
    sources: Vec<PackSource>,
}

fn recordings_root(app: &AppHandle) -> PathBuf {
    app.path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir())
        .join("recordings")
}

#[tauri::command]
fn backend_name(state: State<AppState>) -> String {
    let mut g = state.0.lock().unwrap();
    g.backend().name().to_string()
}

#[tauri::command]
fn list_sources(state: State<AppState>) -> Vec<SourceInfo> {
    let mut g = state.0.lock().unwrap();
    g.backend().available_sources()
}

#[tauri::command]
fn start_recording(
    app: AppHandle,
    state: State<AppState>,
    config: RecordConfig,
) -> Result<String, String> {
    let mut g = state.0.lock().unwrap();
    if g.active.is_some() {
        return Err("already recording".into());
    }

    let created_epoch_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis();
    let id = format!("rec-{created_epoch_ms}");
    let dir = recordings_root(&app).join(&id);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

    let started = Instant::now();
    g.backend()
        .start(&dir, &config)
        .map_err(|e| e.to_string())?;

    // Emit elapsed-time ticks to the UI until the take stops.
    let tick_stop = Arc::new(AtomicBool::new(false));
    {
        let app = app.clone();
        let tick_stop = tick_stop.clone();
        std::thread::spawn(move || {
            while !tick_stop.load(Ordering::Relaxed) {
                let _ = app.emit("roll://tick", started.elapsed().as_millis() as u64);
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
        });
    }

    g.active = Some(Active {
        dir,
        id: id.clone(),
        started,
        created_epoch_ms,
        fps: config.fps,
        tick_stop,
    });
    Ok(id)
}

#[tauri::command]
fn stop_recording(state: State<AppState>) -> Result<RecordingResult, String> {
    let mut g = state.0.lock().unwrap();
    let active = g.active.take().ok_or("not recording")?;
    active.tick_stop.store(true, Ordering::Relaxed);

    let sources = g.backend().stop().map_err(|e| e.to_string())?;
    let duration_ms = active.started.elapsed().as_millis();

    // Write the manifest — the index that makes the take a pack.
    let manifest = Manifest {
        version: "0.1".into(),
        id: active.id.clone(),
        created_epoch_ms: active.created_epoch_ms,
        fps: active.fps,
        clock: "monotonic; t=0 at record start; all sources & metadata share it".into(),
        sources: sources.clone(),
        metadata_file: "metadata.jsonl".into(),
    };
    std::fs::write(
        active.dir.join("manifest.json"),
        serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;

    Ok(RecordingResult {
        id: active.id,
        dir: active.dir.to_string_lossy().into_owned(),
        duration_ms,
        sources,
    })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState(Mutex::new(RecorderState::default())))
        .invoke_handler(tauri::generate_handler![
            backend_name,
            list_sources,
            start_recording,
            stop_recording
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

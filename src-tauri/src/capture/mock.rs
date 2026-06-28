//! Mock capture backend.
//!
//! Writes placeholder media files and a *real* `metadata.jsonl` of synthetic
//! click/key events on the shared clock. It produces nothing watchable, but it
//! exercises every other moving part — source selection, the clock, telemetry
//! writing, manifest assembly — on any platform, including this headless box.

use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::capture::CaptureBackend;
use crate::pack::{Event, PackSource, RecordConfig, SourceInfo, SourceKind};

#[derive(Default)]
pub struct MockBackend {
    stop: Option<Arc<AtomicBool>>,
    handle: Option<std::thread::JoinHandle<()>>,
    sources: Vec<PackSource>,
}

impl CaptureBackend for MockBackend {
    fn name(&self) -> &'static str {
        "mock — no real capture (gated on proof)"
    }

    fn available_sources(&self) -> Vec<SourceInfo> {
        vec![
            SourceInfo {
                kind: SourceKind::Screen,
                id: "mock-screen".into(),
                label: "Screen (mock)".into(),
            },
            SourceInfo {
                kind: SourceKind::Mic,
                id: "mock-mic".into(),
                label: "Microphone (mock)".into(),
            },
            SourceInfo {
                kind: SourceKind::Camera,
                id: "mock-camera".into(),
                label: "Camera (mock)".into(),
            },
        ]
    }

    fn start(&mut self, dir: &Path, config: &RecordConfig) -> std::io::Result<()> {
        // Placeholder media — the real bytes come from the Mac engine later.
        let mut sources = Vec::new();
        for &kind in &config.sources {
            let file = kind.file();
            std::fs::write(dir.join(file), b"")?;
            sources.push(PackSource {
                kind,
                file: file.to_string(),
                fps: config.fps,
                width: None,
                height: None,
                offset_ms: 0,
            });
        }
        self.sources = sources;

        // Synthetic telemetry on the shared clock -> metadata.jsonl.
        let path = dir.join("metadata.jsonl");
        let stop = Arc::new(AtomicBool::new(false));
        let t0 = Instant::now();
        let handle = {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let mut f = match File::create(&path) {
                    Ok(f) => f,
                    Err(_) => return,
                };
                let mut i: u64 = 0;
                while !stop.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(900));
                    if stop.load(Ordering::Relaxed) {
                        break;
                    }
                    let t_ms = t0.elapsed().as_millis() as u64;
                    let ev = if i % 3 == 2 {
                        Event::Key {
                            t_ms,
                            key: "Enter".into(),
                        }
                    } else {
                        Event::Click {
                            t_ms,
                            x: 200 + (i as i32 % 5) * 80,
                            y: 140 + (i as i32 % 3) * 60,
                            button: "left".into(),
                        }
                    };
                    if writeln!(f, "{}", serde_json::to_string(&ev).unwrap()).is_err() {
                        break;
                    }
                    let _ = f.flush();
                    i += 1;
                }
            })
        };
        self.stop = Some(stop);
        self.handle = Some(handle);
        Ok(())
    }

    fn stop(&mut self) -> std::io::Result<Vec<PackSource>> {
        if let Some(stop) = self.stop.take() {
            stop.store(true, Ordering::Relaxed);
        }
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        Ok(std::mem::take(&mut self.sources))
    }
}

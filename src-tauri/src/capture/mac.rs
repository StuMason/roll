//! Real macOS capture engine — STUB.
//!
//! When the proof says go, this is where the real work lands:
//!   - screen + system audio via ScreenCaptureKit (macOS 12.3+)
//!   - camera via AVFoundation, mic via CoreAudio
//!   - a global input monitor (clicks/keys/window focus) -> metadata.jsonl
//!   - VideoToolbox hardware H.264, 1080p30 screen / 720p30 camera
//!     (the settings that don't melt an Intel Mac under two encodes)
//!
//! All of it stamped against one shared clock. This file only compiles on
//! macOS and is not yet wired into `default_backend()`.

#![allow(dead_code)]

use std::path::Path;

use crate::capture::CaptureBackend;
use crate::pack::{PackSource, RecordConfig, SourceInfo};

#[derive(Default)]
pub struct MacBackend;

impl CaptureBackend for MacBackend {
    fn name(&self) -> &'static str {
        "macOS — ScreenCaptureKit (TODO)"
    }

    fn available_sources(&self) -> Vec<SourceInfo> {
        Vec::new()
    }

    fn start(&mut self, _dir: &Path, _config: &RecordConfig) -> std::io::Result<()> {
        unimplemented!("ScreenCaptureKit/AVFoundation capture — implement on a Mac")
    }

    fn stop(&mut self) -> std::io::Result<Vec<PackSource>> {
        unimplemented!("ScreenCaptureKit/AVFoundation capture — implement on a Mac")
    }
}

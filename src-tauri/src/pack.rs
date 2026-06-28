//! The pack contract.
//!
//! This is the hard boundary between `roll` (the recorder) and everything
//! downstream — the cruncher, and ultimately the editing agent. A take is a
//! directory:
//!
//! ```text
//! rec-<epoch>/
//!   screen.mp4        one source per file ...
//!   camera.mp4
//!   mic.m4a
//!   metadata.jsonl    ... input telemetry on the SAME clock as the rolls
//!   manifest.json     the index: what was recorded, fps, the shared clock
//! ```
//!
//! Everything here is serialized straight across the IPC boundary and onto
//! disk, so the JSON shape *is* the API. Keep `src/types.ts` in lockstep.

use serde::{Deserialize, Serialize};

/// The capture sources a take can contain. Serialized lowercase
/// (`"screen"`, `"camera"`, `"mic"`) to match the TS union.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    Screen,
    Camera,
    Mic,
}

impl SourceKind {
    /// Canonical filename for this source within a take directory.
    pub fn file(self) -> &'static str {
        match self {
            SourceKind::Screen => "screen.mp4",
            SourceKind::Camera => "camera.mp4",
            SourceKind::Mic => "mic.m4a",
        }
    }
}

/// A source the active backend can offer (shown in the UI source picker).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceInfo {
    pub kind: SourceKind,
    pub id: String,
    pub label: String,
}

/// What the frontend asks `start_recording` to capture.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordConfig {
    pub sources: Vec<SourceKind>,
    pub fps: u32,
}

/// A source that was actually written, with the facts the cruncher needs to
/// line it up against the others. `offset_ms` is this source's start relative
/// to the shared clock origin (0 = perfectly aligned, which is the goal).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackSource {
    pub kind: SourceKind,
    pub file: String,
    pub fps: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    pub offset_ms: i64,
}

/// `manifest.json` — the index that makes a take a *pack*.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub version: String,
    pub id: String,
    pub created_epoch_ms: u128,
    pub fps: u32,
    /// Human note describing the clock guarantee.
    pub clock: String,
    pub sources: Vec<PackSource>,
    pub metadata_file: String,
}

/// One row of `metadata.jsonl`. Tagged by `type`, with `t_ms` measured from
/// the shared clock origin. This is the schema the cruncher joins against
/// frame OCR and the transcript to build "action events".
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Click {
        t_ms: u64,
        x: i32,
        y: i32,
        button: String,
    },
    Key {
        t_ms: u64,
        key: String,
    },
    Window {
        t_ms: u64,
        app: String,
        title: String,
        action: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_kind_is_lowercase() {
        assert_eq!(
            serde_json::to_string(&SourceKind::Screen).unwrap(),
            "\"screen\""
        );
    }

    #[test]
    fn click_event_matches_capture_schema() {
        let ev = Event::Click {
            t_ms: 1234,
            x: 880,
            y: 210,
            button: "left".into(),
        };
        let v: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&ev).unwrap()).unwrap();
        assert_eq!(v["type"], "click");
        assert_eq!(v["t_ms"], 1234);
        assert_eq!(v["x"], 880);
        assert_eq!(v["button"], "left");
    }
}

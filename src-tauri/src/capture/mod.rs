//! Capture backends.
//!
//! `roll` keeps the platform capture engine behind one trait so the rest of
//! the app — UI, IPC, pack writing — never knows whether it's talking to a
//! real ScreenCaptureKit pipeline or the mock. That boundary is what lets us
//! build and run the whole thing on a headless Linux box today, and slot the
//! real macOS engine in later without touching anything else.

use std::path::Path;

use crate::pack::{PackSource, RecordConfig, SourceInfo};

pub mod mock;

#[cfg(target_os = "macos")]
pub mod mac;

/// A platform capture engine. Implementations own the shared-clock origin:
/// every source they write, and every telemetry row in `metadata.jsonl`,
/// must be stamped against the same `t=0`.
pub trait CaptureBackend: Send {
    /// Short label shown in the UI (which engine is live).
    fn name(&self) -> &'static str;

    /// Sources this backend can currently offer.
    fn available_sources(&self) -> Vec<SourceInfo>;

    /// Begin capturing `config.sources` into `dir`. Returns once capture is
    /// running; the clock origin is "now".
    fn start(&mut self, dir: &Path, config: &RecordConfig) -> std::io::Result<()>;

    /// Stop capture and return the sources that were written.
    fn stop(&mut self) -> std::io::Result<Vec<PackSource>>;
}

/// The backend the app runs with.
///
/// GATED: the real macOS engine (`mac::MacBackend`) is intentionally NOT wired
/// in yet. It is the one piece that can only be built and tested on a Mac, and
/// we only invest in it once the pack/join proof shows the differentiator is
/// real. Until then the mock runs on every platform so the full
/// record → pack loop is exercised end to end. To switch over later:
///
/// ```ignore
/// #[cfg(target_os = "macos")]
/// return Box::new(mac::MacBackend::default());
/// ```
pub fn default_backend() -> Box<dyn CaptureBackend> {
    Box::new(mock::MockBackend::default())
}

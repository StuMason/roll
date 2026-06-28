// Mirror of the Rust contract in src-tauri/src/pack.rs.
// Keep these in lockstep — this is the JS side of the IPC boundary.

export type SourceKind = "screen" | "camera" | "mic";

export interface SourceInfo {
  kind: SourceKind;
  id: string;
  label: string;
}

export interface RecordConfig {
  sources: SourceKind[];
  fps: number;
}

export interface PackSource {
  kind: SourceKind;
  file: string;
  fps: number;
  width?: number;
  height?: number;
  offsetMs: number;
}

export interface RecordingResult {
  id: string;
  dir: string;
  durationMs: number;
  sources: PackSource[];
}

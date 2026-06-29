// The JS side of the IPC boundary. Mirrors the Rust contract where it crosses
// (see src-tauri/src/lib.rs commands + events).

export interface Device {
  index: number;
  label: string;
  // displays carry their screen frame (for the highlight overlay)
  x?: number;
  y?: number;
  w?: number;
  h?: number;
}

export interface Devices {
  displays: Device[];
  cameras: Device[];
  mics: Device[];
}

export type RecState = "idle" | "warming" | "recording" | "saving";

export interface LiveStats {
  warmedMs?: number;
  elapsedMs: number;
  screenFrames?: number;
  cameraFrames?: number;
  clicks?: number;
  rows?: number;
}

export interface RecordConfig {
  display: number;
  camera: number | null;
  mic: number | null;
  fps: number;
}

export interface Pack {
  id: string;
  dir: string;
  durationMs: number;
  sources: string[]; // e.g. ["screen.mp4","camera.mp4","mic.m4a","metadata.jsonl"]
  rows?: number; // metadata rows
  cameraSyncOffsetMs?: number;
  micSyncOffsetMs?: number;
}

// Payload of the "roll://state" event the backend emits while a take runs.
export interface StateEvent {
  state: RecState;
  stats: LiveStats;
}

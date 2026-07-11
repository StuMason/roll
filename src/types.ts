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
  crunched?: boolean; // crunch.json sits next to the media
}

// Lifecycle of a one-click crunch run (see src-tauri/src/crunch.rs).
export type CrunchStatus = "taring" | "uploading" | "queued" | "processing" | "completed" | "failed";

// Payload of the "roll://crunch" event — one per status change / poll tick.
export interface CrunchEvent {
  take: string; // pack id
  dir: string;
  status: CrunchStatus;
  stage?: string; // unpack → extract_frames → ocr → transcribe → analyze → assemble
  done?: number; // ocr progress (the only stage with counts)
  total?: number;
  error?: string;
  jobId?: string;
}

// Payload of the "roll://state" event the backend emits while a take runs.
export interface StateEvent {
  state: RecState;
  stats: LiveStats;
}

// One telemetry row from metadata.jsonl. Shape varies by `type`; the common
// field is t_ms (ms since the shared t0). Loose by design.
export interface TEvent {
  type: "click" | "drag" | "cursor" | "key" | "scroll" | "app_focus" | string;
  t_ms: number;
  end_ms?: number;
  x?: number;
  y?: number;
  from?: [number, number];
  to?: [number, number];
  button?: string;
  mods?: string[];
  key?: string;
  dx?: number;
  dy?: number;
  app?: string;
  window?: string;
  ax?: { role?: string; label?: string; bounds?: number[] };
}

export interface PackDetail {
  // manifest.json verbatim (fps, t0, durationMs, sync offsets, display, …)
  manifest: Record<string, unknown> | null;
  events: TEvent[];
}

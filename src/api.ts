// One seam between the UI and the platform. In the real app these proxy to
// Tauri commands/events that drive the `roll-capture` sidecar. In a plain
// browser (vite dev, no Tauri) they fall back to a believable mock so the whole
// UI — including a simulated take — can be built and eyeballed without a Mac.

import type { Devices, Pack, RecordConfig, StateEvent } from "./types";

const isTauri =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export const ENGINE = isTauri ? "native · macOS" : "mock · dev";

// ---------------------------------------------------------------- real (Tauri)
async function tauri() {
  const core = await import("@tauri-apps/api/core");
  const event = await import("@tauri-apps/api/event");
  return { core, event };
}

// ---------------------------------------------------------------- mock (browser)
type Listener<T> = (payload: T) => void;
const stateListeners = new Set<Listener<StateEvent>>();
const logListeners = new Set<Listener<string>>();

const MOCK_DEVICES: Devices = {
  displays: [
    { index: 0, label: "Built-in Retina Display · 2560×1440" },
    { index: 1, label: "LG UltraFine · 3840×2160" },
  ],
  cameras: [
    { index: 0, label: "FaceTime HD Camera" },
    { index: 1, label: "Stu’s iPhone (Continuity)" },
    { index: 2, label: "Logitech C920" },
  ],
  mics: [
    { index: 0, label: "MacBook Pro Microphone" },
    { index: 1, label: "RØDE Connect System" },
    { index: 6, label: "Logitech C920 Mic" },
  ],
};

let mockTimer: ReturnType<typeof setInterval> | null = null;
let mockStart = 0;
let mockClicks = 0;

function emitState(e: StateEvent) {
  stateListeners.forEach((l) => l(e));
}

function mockBeginTake(cfg: RecordConfig) {
  // warm-up phase (Continuity Camera handshake), then recording with live stats.
  emitState({ state: "warming", stats: { elapsedMs: 0 } });
  mockClicks = 0;
  const warm = cfg.camera === 1 ? 2800 : 700; // phone dings in slower
  setTimeout(() => {
    mockStart = performance.now();
    emitState({ state: "recording", stats: { elapsedMs: 0, warmedMs: warm, screenFrames: 0, clicks: 0 } });
    mockTimer = setInterval(() => {
      const elapsed = performance.now() - mockStart;
      if (Math.random() < 0.4) mockClicks += 1;
      emitState({
        state: "recording",
        stats: {
          elapsedMs: elapsed,
          warmedMs: warm,
          screenFrames: Math.round((elapsed / 1000) * 24),
          cameraFrames: cfg.camera !== null ? Math.round((elapsed / 1000) * 28) : undefined,
          clicks: mockClicks,
        },
      });
    }, 250);
  }, warm);
}

function mockEndTake(cfg: RecordConfig): Pack {
  if (mockTimer) clearInterval(mockTimer);
  mockTimer = null;
  emitState({ state: "saving", stats: { elapsedMs: performance.now() - mockStart } });
  const durationMs = Math.max(1000, performance.now() - mockStart);
  const sources = ["screen.mp4"];
  if (cfg.camera !== null) sources.push("camera.mp4");
  if (cfg.mic !== null) sources.push("mic.m4a");
  sources.push("metadata.jsonl");
  setTimeout(() => emitState({ state: "idle", stats: { elapsedMs: 0 } }), 400);
  return {
    id: `rec-${Date.now()}`,
    dir: `~/Library/Application Support/dev.stumason.roll/recordings/rec-${Date.now()}`,
    durationMs,
    sources,
    rows: Math.round((durationMs / 1000) * 8) + mockClicks,
    cameraSyncOffsetMs: cfg.camera !== null ? -13 : undefined,
    micSyncOffsetMs: cfg.mic !== null ? -11 : undefined,
  };
}

// ---------------------------------------------------------------- public api
export async function listDevices(): Promise<Devices> {
  if (!isTauri) return MOCK_DEVICES;
  const { core } = await tauri();
  return core.invoke<Devices>("list_devices");
}

export async function startRecording(cfg: RecordConfig): Promise<void> {
  if (!isTauri) return void mockBeginTake(cfg);
  const { core } = await tauri();
  await core.invoke("start_recording", { config: cfg });
}

export async function stopRecording(cfg: RecordConfig): Promise<Pack> {
  if (!isTauri) return mockEndTake(cfg);
  const { core } = await tauri();
  return core.invoke<Pack>("stop_recording");
}

export async function reveal(dir: string): Promise<void> {
  if (!isTauri) {
    // eslint-disable-next-line no-console
    console.log("[mock] reveal", dir);
    return;
  }
  const { core } = await tauri();
  await core.invoke("reveal", { path: dir });
}

export async function onState(cb: Listener<StateEvent>): Promise<() => void> {
  if (!isTauri) {
    stateListeners.add(cb);
    return () => stateListeners.delete(cb);
  }
  const { event } = await tauri();
  const un = await event.listen<StateEvent>("roll://state", (e) => cb(e.payload));
  return un;
}

export async function onLog(cb: Listener<string>): Promise<() => void> {
  if (!isTauri) {
    logListeners.add(cb);
    return () => logListeners.delete(cb);
  }
  const { event } = await tauri();
  const un = await event.listen<string>("roll://log", (e) => cb(e.payload));
  return un;
}

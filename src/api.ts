// One seam between the UI and the platform. In the real app these proxy to
// Tauri commands/events that drive the `roll-capture` sidecar. In a plain
// browser (vite dev, no Tauri) they fall back to a believable mock so the whole
// UI — including a simulated take — can be built and eyeballed without a Mac.

import type { CrunchEvent, Devices, Pack, PackDetail, RecordConfig, StateEvent } from "./types";

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
const savedListeners = new Set<Listener<Pack>>();
const crunchListeners = new Set<Listener<CrunchEvent>>();

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

const MOCK_PACKS: Pack[] = [
  { id: "rec-1782764857110", dir: "~/Movies/roll/rec-1782764857110", durationMs: 89700, sources: ["screen.mp4", "camera.mp4", "mic.m4a", "metadata.jsonl"], rows: 555, cameraSyncOffsetMs: 5, micSyncOffsetMs: 2 },
  { id: "rec-1782762586924", dir: "~/Movies/roll/rec-1782762586924", durationMs: 26743, sources: ["screen.mp4", "camera.mp4", "mic.m4a", "metadata.jsonl"], rows: 312, cameraSyncOffsetMs: -58, micSyncOffsetMs: -75 },
];

// a believable slice of telemetry so the inspector can be built without a Mac
const MOCK_EVENTS = [
  { type: "app_focus", t_ms: 0, app: "Safari", window: "Pricing — Acme" },
  { type: "click", t_ms: 1200, x: 640, y: 320, button: "left", ax: { role: "AXButton", label: "Get started" } },
  { type: "scroll", t_ms: 3400, x: 700, y: 500, dx: 0, dy: -640 },
  { type: "key", t_ms: 5200, key: "cmd", mods: ["cmd"] },
  { type: "app_focus", t_ms: 6000, app: "VS Code", window: "api.ts — roll" },
  { type: "key", t_ms: 7100, key: "f", mods: [] },
  { type: "key", t_ms: 7250, key: "n", mods: [] },
  { type: "drag", t_ms: 9000, end_ms: 9600, from: [200, 300], to: [560, 300], button: "left" },
  { type: "click", t_ms: 12000, x: 880, y: 140, button: "left", ax: { role: "AXTextField", label: "Search" } },
  { type: "app_focus", t_ms: 15000, app: "Safari", window: "Docs — roll" },
  { type: "scroll", t_ms: 16000, x: 700, y: 500, dx: 0, dy: -1200 },
].map((e) => ({ ...e })) as import("./types").TEvent[];

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

function mockEndTake(cfg: RecordConfig): void {
  if (mockTimer) clearInterval(mockTimer);
  mockTimer = null;
  emitState({ state: "saving", stats: { elapsedMs: performance.now() - mockStart } });
  const durationMs = Math.max(1000, performance.now() - mockStart);
  const sources = ["screen.mp4"];
  if (cfg.camera !== null) sources.push("camera.mp4");
  if (cfg.mic !== null) sources.push("mic.m4a");
  sources.push("metadata.jsonl");
  const pack: Pack = {
    id: `rec-${Date.now()}`,
    dir: `~/Library/Application Support/dev.stumason.roll/recordings/rec-${Date.now()}`,
    durationMs,
    sources,
    rows: Math.round((durationMs / 1000) * 8) + mockClicks,
    cameraSyncOffsetMs: cfg.camera !== null ? -13 : undefined,
    micSyncOffsetMs: cfg.mic !== null ? -11 : undefined,
  };
  setTimeout(() => {
    savedListeners.forEach((l) => l(pack));
    emitState({ state: "idle", stats: { elapsedMs: 0 } });
  }, 400);
}

// A believable crunch run for browser dev: the full stage sequence with a
// ticking ocr progress bar, ~8s end to end.
function mockCrunch(pack: Pack) {
  const ev = (e: Partial<CrunchEvent>) =>
    crunchListeners.forEach((l) => l({ take: pack.id, dir: pack.dir, status: "processing", ...e } as CrunchEvent));
  const total = 242;
  let done = 0;
  ev({ status: "taring" });
  setTimeout(() => ev({ status: "uploading" }), 500);
  setTimeout(() => ev({ status: "queued", jobId: "mock1234" }), 1200);
  setTimeout(() => ev({ stage: "unpack", jobId: "mock1234" }), 2000);
  setTimeout(() => ev({ stage: "extract_frames", jobId: "mock1234" }), 2800);
  const ocr = setInterval(() => {
    done = Math.min(total, done + 34);
    ev({ stage: "ocr", done, total, jobId: "mock1234" });
    if (done >= total) clearInterval(ocr);
  }, 450);
  setTimeout(() => ev({ stage: "transcribe", jobId: "mock1234" }), 6600);
  setTimeout(() => ev({ stage: "analyze", jobId: "mock1234" }), 7300);
  setTimeout(() => ev({ stage: "assemble", jobId: "mock1234" }), 7800);
  setTimeout(() => ev({ status: "completed", jobId: "mock1234" }), 8200);
}

// ---------------------------------------------------------------- public api
export async function listDevices(): Promise<Devices> {
  if (!isTauri) return MOCK_DEVICES;
  const { core } = await tauri();
  return core.invoke<Devices>("list_devices");
}

export async function listPacks(): Promise<Pack[]> {
  if (!isTauri) return MOCK_PACKS;
  const { core } = await tauri();
  return core.invoke<Pack[]>("list_packs");
}

export async function readPack(dir: string): Promise<PackDetail> {
  if (!isTauri) return { manifest: { durationMs: 89700, fps: 30 }, events: MOCK_EVENTS };
  const { core } = await tauri();
  return core.invoke<PackDetail>("read_pack", { dir });
}

// Turn an on-disk pack file into a webview-loadable URL (asset protocol). Empty
// in the browser mock — there's no real media there.
export async function mediaSrc(dir: string, file: string): Promise<string> {
  if (!isTauri) return "";
  const { core } = await tauri();
  return core.convertFileSrc(`${dir}/${file}`);
}

export async function startRecording(cfg: RecordConfig): Promise<void> {
  if (!isTauri) return void mockBeginTake(cfg);
  const { core } = await tauri();
  await core.invoke("start_recording", { config: cfg });
}

export async function stopRecording(cfg: RecordConfig): Promise<void> {
  if (!isTauri) return mockEndTake(cfg);
  const { core } = await tauri();
  // fire-and-forget: the finished pack arrives via onSaved, idle via onState
  await core.invoke("stop_recording");
}

// Point the live preview (and the next take) at a camera, or null to release it.
export async function setPreviewCamera(index: number | null): Promise<void> {
  if (!isTauri) return; // browser mock has no real camera feed
  const { core } = await tauri();
  await core.invoke("set_preview_camera", { index });
}

// Point the mic level meter at a mic, or null to release it (levels via onLevel).
export async function setPreviewMic(index: number | null): Promise<void> {
  if (!isTauri) return;
  const { core } = await tauri();
  await core.invoke("set_preview_mic", { index });
}

export async function highlightDisplay(x: number, y: number, w: number, h: number): Promise<void> {
  if (!isTauri) {
    // eslint-disable-next-line no-console
    console.log("[mock] highlight display", x, y, w, h);
    return;
  }
  const { core } = await tauri();
  await core.invoke("highlight_display", { x, y, w, h });
}

export async function screenShot(display: number, width = 480): Promise<string | null> {
  if (!isTauri) return null; // no real screen grab in the browser mock
  const { core } = await tauri();
  try {
    return await core.invoke<string>("screen_shot", { display, width });
  } catch {
    return null;
  }
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

// Live camera preview frames (ready-to-render `data:` JPEG URLs) from the daemon.
export async function onFrame(cb: Listener<string>): Promise<() => void> {
  if (!isTauri) return () => {}; // no live feed in the browser mock
  const { event } = await tauri();
  const un = await event.listen<string>("roll://frame", (e) => cb(e.payload));
  return un;
}

// Live mic level (0..1 RMS) from the daemon's meter.
export async function onLevel(cb: Listener<number>): Promise<() => void> {
  if (!isTauri) return () => {};
  const { event } = await tauri();
  const un = await event.listen<number>("roll://level", (e) => cb(e.payload));
  return un;
}

// A finished pack, emitted when the daemon finalizes a take.
export async function onSaved(cb: Listener<Pack>): Promise<() => void> {
  if (!isTauri) {
    savedListeners.add(cb);
    return () => savedListeners.delete(cb);
  }
  const { event } = await tauri();
  const un = await event.listen<Pack>("roll://saved", (e) => cb(e.payload));
  return un;
}

// Kick off a crunch run for a pack (tar → upload → poll → crunch.json).
// Fire-and-forget: progress arrives via onCrunch.
export async function crunchPack(pack: Pack): Promise<void> {
  if (!isTauri) return void mockCrunch(pack);
  const { core } = await tauri();
  await core.invoke("crunch_pack", { dir: pack.dir });
}

// Live crunch status (one event per stage change / poll tick).
export async function onCrunch(cb: Listener<CrunchEvent>): Promise<() => void> {
  if (!isTauri) {
    crunchListeners.add(cb);
    return () => crunchListeners.delete(cb);
  }
  const { event } = await tauri();
  const un = await event.listen<CrunchEvent>("roll://crunch", (e) => cb(e.payload));
  return un;
}

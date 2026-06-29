import { useEffect, useMemo, useState } from "react";
import Dropdown, { Opt } from "./components/Dropdown";
import CameraPreview from "./components/CameraPreview";
import { ENGINE, listDevices, onState, reveal, startRecording, stopRecording } from "./api";
import type { Devices, LiveStats, Pack, RecState, RecordConfig } from "./types";

const FPS = [24, 30, 60];
const WINDOW_MS = 12000; // the transport's rolling window

const STATUS: Record<RecState, string> = {
  idle: "READY",
  warming: "STAND BY",
  recording: "ROLLING",
  saving: "SAVING",
};

function tc(ms: number, fps: number) {
  const t = Math.max(0, ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return {
    hms: `${p(Math.floor(t / 3600000))}:${p(Math.floor(t / 60000) % 60)}:${p(Math.floor(t / 1000) % 60)}`,
    ff: p(Math.floor(((t % 1000) / 1000) * fps)),
  };
}

// stable pseudo-spread of click ticks across the lane
function tickPositions(n: number): number[] {
  return Array.from({ length: Math.min(n, 60) }, (_, i) => (i * 137.508) % 96 + 2);
}

interface LaneProps {
  name: string;
  kind: "video" | "audio" | "meta";
  on: boolean;
  rolling: boolean;
  clicks?: number;
}
function Lane({ name, kind, on, rolling, clicks = 0 }: LaneProps) {
  const cls = `lane ${kind} ${!on ? "off" : rolling ? "rolling" : "armed"}`;
  return (
    <div className={cls}>
      <span className="lane-name">{name}</span>
      <div className="lane-track">
        {on && kind !== "audio" && kind !== "meta" && <span className="lane-fill" />}
        {on && kind === "audio" && (
          <div className="wave">
            {Array.from({ length: 44 }, (_, i) => (
              <i key={i} style={{ animationDelay: `${(i % 8) * 0.07}s` }} />
            ))}
          </div>
        )}
        {on && kind === "meta" && rolling &&
          tickPositions(clicks).map((p, i) => <span key={i} className="tick" style={{ left: `${p}%` }} />)}
      </div>
    </div>
  );
}

export default function App() {
  const [devices, setDevices] = useState<Devices | null>(null);
  const [display, setDisplay] = useState(0);
  const [camera, setCamera] = useState<number | null>(null);
  const [mic, setMic] = useState<number | null>(null);
  const [fps, setFps] = useState(30);

  const [state, setState] = useState<RecState>("idle");
  const [stats, setStats] = useState<LiveStats>({ elapsedMs: 0 });
  const [takes, setTakes] = useState<Pack[]>([]);
  const [showPreview, setShowPreview] = useState(true);

  useEffect(() => {
    listDevices().then((d) => {
      setDevices(d);
      setDisplay(d.displays[0]?.index ?? 0);
      setCamera(d.cameras[0]?.index ?? null);
      setMic(d.mics[0]?.index ?? null);
    });
    const un = onState((e) => {
      setState(e.state);
      setStats(e.stats);
    });
    return () => {
      un.then((f) => f());
    };
  }, []);

  const cfg: RecordConfig = useMemo(() => ({ display, camera, mic, fps }), [display, camera, mic, fps]);
  const busy = state !== "idle";
  const rolling = state === "recording";

  const displayOpts: Opt[] = (devices?.displays ?? []).map((d) => ({ value: d.index, label: d.label }));
  const cameraOpts: Opt[] = [{ value: null, label: "None" }, ...(devices?.cameras ?? []).map((d) => ({ value: d.index, label: d.label }))];
  const micOpts: Opt[] = [{ value: null, label: "None" }, ...(devices?.mics ?? []).map((d) => ({ value: d.index, label: d.label }))];

  const cameraLabel = devices?.cameras.find((c) => c.index === camera)?.label ?? "";
  const displayLabel = devices?.displays.find((d) => d.index === display)?.label ?? "Display";

  const time = tc(stats.elapsedMs, fps);
  const fillPct = rolling ? Math.min(100, (stats.elapsedMs / WINDOW_MS) * 100) : 0;
  const playheadLeft = `calc(82px + (100% - 100px) * ${fillPct / 100})`;

  async function roll() {
    await startRecording(cfg);
  }
  async function cut() {
    const pack = await stopRecording(cfg);
    setTakes((t) => [pack, ...t].slice(0, 8));
  }

  return (
    <main className="app">
      <header className="topbar">
        <div className="wordmark">
          <span className={`reel${rolling ? " live" : ""}`} />
          roll
        </div>
        <div className="status">
          <span className={`status-word ${state}`}>{STATUS[state]}</span>
          <span className="engine" title="active capture engine">{ENGINE}</span>
        </div>
      </header>

      <div className="body">
        {/* HERO — transport: timecode + the four sources on one playhead */}
        <section className={`transport${rolling ? " rolling" : ""}`}>
          <div className="tc-row">
            <div className={`timecode${rolling ? " live" : ""}`}>
              {time.hms}:<span className="ff">{time.ff}</span>
            </div>
            <div className="tc-side">
              <span className="chip">TAKE <b>{String(takes.length + 1).padStart(3, "0")}</b></span>
              <span className="chip"><b>{fps}</b> FPS</span>
              <span className={`reclamp${rolling ? " on" : ""}`}><span className="lamp" /> REC</span>
            </div>
            {state === "idle" && (
              <button className="roll roll-btn" onClick={roll}>
                <span className="rec-dot" /> ROLL
              </button>
            )}
            {state === "warming" && (
              <button className="roll standby roll-btn" onClick={cut}>
                <span className="spinner" /> STAND BY <small>sources speeding up</small>
              </button>
            )}
            {rolling && (
              <button className="roll cut roll-btn" onClick={cut}>
                <span className="rec-dot" /> CUT
              </button>
            )}
            {state === "saving" && (
              <button className="roll standby roll-btn" disabled>
                <span className="spinner" /> SAVING
              </button>
            )}
          </div>

          <div className="lanes">
            <Lane name="PICTURE" kind="video" on rolling={rolling} />
            <Lane name="CAMERA" kind="video" on={camera !== null} rolling={rolling} />
            <Lane name="SOUND" kind="audio" on={mic !== null} rolling={rolling} />
            <Lane name="META" kind="meta" on rolling={rolling} clicks={stats.clicks} />
            {rolling && <span className="playhead" style={{ left: playheadLeft }} />}
          </div>
        </section>

        {showPreview && (
          <section className="previews">
            <div className={`frame${rolling ? " rec" : ""}`}>
              <CameraPreview cameraIndex={camera} cameraLabel={cameraLabel} recording={rolling} />
            </div>
            <div className={`frame${rolling ? " rec" : ""}`}>
              <div className="screen-mock">
                <span className="screen-grid" />
                <span className="screen-cursor" />
              </div>
              <span className="frame-tag">PICTURE</span>
              <div className="frame-meta">{displayLabel}</div>
            </div>
          </section>
        )}

        <section className="rig">
          <div className="rig-head">
            <span className="eyebrow">SOURCES</span>
            <button className="ghost" onClick={() => setShowPreview((s) => !s)}>
              {showPreview ? "HIDE PREVIEW" : "SHOW PREVIEW"}
            </button>
          </div>
          <div className="slate-grid">
            <div className="field wide">
              <span className="field-label">PICTURE</span>
              <Dropdown value={display} options={displayOpts} onChange={(v) => setDisplay(v ?? 0)} disabled={busy} />
            </div>
            <div className="field">
              <span className="field-label">CAMERA</span>
              <Dropdown value={camera} options={cameraOpts} onChange={setCamera} disabled={busy} />
            </div>
            <div className="field">
              <span className="field-label">SOUND</span>
              <Dropdown value={mic} options={micOpts} onChange={setMic} disabled={busy} />
            </div>
            <div className="field">
              <span className="field-label">FRAME RATE</span>
              <div className="seg">
                {FPS.map((f) => (
                  <button key={f} className={f === fps ? "on" : ""} disabled={busy} onClick={() => setFps(f)}>{f}</button>
                ))}
              </div>
            </div>
          </div>
        </section>

        <section className="takes">
          <span className="eyebrow">TAKES</span>
          {takes.length === 0 ? (
            <p className="empty">No takes yet — call ROLL to print your first pack.</p>
          ) : (
            <ul>
              {takes.map((p, i) => (
                <li className="take-row" key={p.id}>
                  <span className="take-no">{String(takes.length - i).padStart(3, "0")}</span>
                  <span className="take-tc">{tc(p.durationMs, 30).hms}</span>
                  <span className="take-src">{p.sources.map((s) => s.replace(/\..+$/, "")).join(" · ")}</span>
                  <span className="take-tags">
                    {p.rows != null && <span className="tag">{p.rows} events</span>}
                    {p.cameraSyncOffsetMs != null && (
                      <span className={`tag ${Math.abs(p.cameraSyncOffsetMs) < 34 ? "lock" : "warn"}`}>
                        SYNC {p.cameraSyncOffsetMs > 0 ? "+" : ""}{p.cameraSyncOffsetMs}ms
                      </span>
                    )}
                  </span>
                  <button className="ghost sm" onClick={() => reveal(p.dir)}>REVEAL</button>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </main>
  );
}

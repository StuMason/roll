import { useEffect, useMemo, useState } from "react";
import Dropdown, { Opt } from "./components/Dropdown";
import CameraPreview from "./components/CameraPreview";
import { ENGINE, listDevices, onState, reveal, startRecording, stopRecording } from "./api";
import type { Devices, LiveStats, Pack, RecState, RecordConfig } from "./types";

const FPS = [24, 30, 60];

function clock(ms: number): string {
  const s = Math.floor(ms / 1000);
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

export default function App() {
  const [devices, setDevices] = useState<Devices | null>(null);
  const [display, setDisplay] = useState(0);
  const [camera, setCamera] = useState<number | null>(null);
  const [mic, setMic] = useState<number | null>(null);
  const [fps, setFps] = useState(30);

  const [state, setState] = useState<RecState>("idle");
  const [stats, setStats] = useState<LiveStats>({ elapsedMs: 0 });
  const [packs, setPacks] = useState<Pack[]>([]);
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

  const cfg: RecordConfig = useMemo(
    () => ({ display, camera, mic, fps }),
    [display, camera, mic, fps],
  );

  const busy = state !== "idle";
  const recording = state === "recording";

  const displayOpts: Opt[] = (devices?.displays ?? []).map((d) => ({ value: d.index, label: d.label }));
  const cameraOpts: Opt[] = [{ value: null, label: "None" }, ...(devices?.cameras ?? []).map((d) => ({ value: d.index, label: d.label }))];
  const micOpts: Opt[] = [{ value: null, label: "None" }, ...(devices?.mics ?? []).map((d) => ({ value: d.index, label: d.label }))];

  const cameraLabel = devices?.cameras.find((c) => c.index === camera)?.label ?? "";
  const displayLabel = devices?.displays.find((d) => d.index === display)?.label ?? "";

  async function start() {
    await startRecording(cfg);
  }
  async function stop() {
    const pack = await stopRecording(cfg);
    setPacks((p) => [pack, ...p].slice(0, 8));
  }

  return (
    <main className="app">
      <header className="titlebar" data-tauri-drag-region>
        <div className="brand">
          <span className={`reel${recording ? " live" : ""}`} />
          <span className="brand-name">roll</span>
        </div>
        <span className="engine" title="active capture engine">{ENGINE}</span>
      </header>

      <div className="body">
        {showPreview && (
          <section className="previews">
            <CameraPreview cameraIndex={camera} cameraLabel={cameraLabel} recording={recording} />
            <div className={`screen-card${recording ? " rec" : ""}`}>
              <div className="screen-mock">
                <span className="screen-grid" />
                <span className="screen-cursor" />
              </div>
              <div className="screen-meta">
                <span className="screen-name">{displayLabel || "Display"}</span>
                <span className="screen-sub">screen · captured at native res</span>
              </div>
              <span className="cam-badge">SCREEN</span>
            </div>
          </section>
        )}

        <section className="controls">
          <div className="row">
            <Dropdown label="Display" value={display} options={displayOpts} onChange={(v) => setDisplay(v ?? 0)} disabled={busy} />
            <button className="ghost" onClick={() => setShowPreview((s) => !s)}>
              {showPreview ? "Hide preview" : "Show preview"}
            </button>
          </div>
          <div className="row two">
            <Dropdown label="Camera" value={camera} options={cameraOpts} onChange={setCamera} disabled={busy} />
            <Dropdown label="Microphone" value={mic} options={micOpts} onChange={setMic} disabled={busy} />
          </div>
          <div className="field">
            <span className="field-label">Frame rate</span>
            <div className="seg">
              {FPS.map((f) => (
                <button key={f} className={f === fps ? "on" : ""} disabled={busy} onClick={() => setFps(f)}>
                  {f}
                </button>
              ))}
            </div>
          </div>
        </section>

        <section className={`recordbar ${state}`}>
          {state === "idle" && (
            <button className="record" onClick={start}>
              <span className="record-dot" /> Record
            </button>
          )}
          {state === "warming" && (
            <button className="record warming" onClick={stop}>
              <span className="spinner" /> Warming up…<small>connecting sources</small>
            </button>
          )}
          {recording && (
            <button className="record stop" onClick={stop}>
              <span className="stop-sq" /> Stop
            </button>
          )}
          {state === "saving" && (
            <div className="record saving"><span className="spinner" /> Saving pack…</div>
          )}

          <div className="readout">
            <span className={`time${recording ? " live" : ""}`}>{clock(stats.elapsedMs)}</span>
            {recording && (
              <div className="livestats">
                <span><b>{stats.screenFrames ?? 0}</b> frames</span>
                <span><b>{stats.clicks ?? 0}</b> clicks</span>
                {stats.warmedMs !== undefined && <span className="warmed">warmed {(stats.warmedMs / 1000).toFixed(1)}s</span>}
              </div>
            )}
          </div>
        </section>

        <section className="packs">
          <h2>Recent packs</h2>
          {packs.length === 0 ? (
            <p className="empty">No takes yet — hit record to write your first pack.</p>
          ) : (
            <ul>
              {packs.map((p) => (
                <li key={p.id}>
                  <span className="pack-time">{clock(p.durationMs)}</span>
                  <span className="pack-src">{p.sources.map((s) => s.replace(/\..+$/, "")).join(" · ")}</span>
                  <span className="pack-meta">
                    {p.rows != null && <span className="tag">{p.rows} events</span>}
                    {p.cameraSyncOffsetMs != null && (
                      <span className={`tag ${Math.abs(p.cameraSyncOffsetMs) < 34 ? "ok" : "warn"}`}>
                        sync {p.cameraSyncOffsetMs > 0 ? "+" : ""}{p.cameraSyncOffsetMs}ms
                      </span>
                    )}
                  </span>
                  <button className="ghost sm" onClick={() => reveal(p.dir)}>Reveal</button>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </main>
  );
}

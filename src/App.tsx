import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { SourceKind, RecordingResult } from "./types";

const ALL: { kind: SourceKind; label: string }[] = [
  { kind: "screen", label: "Screen" },
  { kind: "mic", label: "Microphone" },
  { kind: "camera", label: "Camera" },
];

function fmt(ms: number): string {
  const s = Math.floor(ms / 1000);
  const mm = String(Math.floor(s / 60)).padStart(2, "0");
  const ss = String(s % 60).padStart(2, "0");
  return `${mm}:${ss}`;
}

export default function App() {
  const [selected, setSelected] = useState<Set<SourceKind>>(new Set(["screen", "mic"]));
  const [recording, setRecording] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [last, setLast] = useState<RecordingResult | null>(null);
  const [backend, setBackend] = useState("");

  useEffect(() => {
    invoke<string>("backend_name").then(setBackend).catch(() => {});
    const un = listen<number>("roll://tick", (e) => setElapsed(e.payload));
    return () => {
      un.then((f) => f());
    };
  }, []);

  const toggle = (k: SourceKind) =>
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      return n;
    });

  async function start() {
    setElapsed(0);
    setLast(null);
    await invoke("start_recording", { config: { sources: [...selected], fps: 30 } });
    setRecording(true);
  }

  async function stop() {
    const res = await invoke<RecordingResult>("stop_recording");
    setRecording(false);
    setLast(res);
  }

  return (
    <main className="wrap">
      <header>
        <h1>
          <span className={recording ? "dot live" : "dot"} /> roll
        </h1>
        <span className="backend" title="active capture backend">
          {backend}
        </span>
      </header>

      <section className="sources">
        {ALL.map(({ kind, label }) => (
          <label key={kind} className={selected.has(kind) ? "on" : ""}>
            <input
              type="checkbox"
              checked={selected.has(kind)}
              disabled={recording}
              onChange={() => toggle(kind)}
            />
            {label}
          </label>
        ))}
      </section>

      <div className={recording ? "timer live" : "timer"}>{fmt(elapsed)}</div>

      {recording ? (
        <button className="btn stop" onClick={stop}>
          Stop
        </button>
      ) : (
        <button className="btn rec" disabled={selected.size === 0} onClick={start}>
          Record
        </button>
      )}

      {last && (
        <section className="result">
          <h2>last take · {fmt(last.durationMs)}</h2>
          <code className="dir">{last.dir}</code>
          <ul>
            {last.sources.map((s) => (
              <li key={s.kind}>
                <b>{s.kind}</b> → {s.file}
              </li>
            ))}
            <li>
              <b>events</b> → metadata.jsonl
            </li>
            <li>
              <b>manifest</b> → manifest.json
            </li>
          </ul>
        </section>
      )}
    </main>
  );
}

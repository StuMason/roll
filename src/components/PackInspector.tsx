import { useEffect, useMemo, useRef, useState } from "react";
import { mediaSrc, readPack, reveal } from "../api";
import type { Pack, PackDetail, TEvent } from "../types";

// one place for the event vocabulary — colour + short glyph, shared by the
// timeline ticks and the "now" readout so they always agree
const KIND: Record<string, { color: string; glyph: string }> = {
  click: { color: "#4ade80", glyph: "●" },
  drag: { color: "#2dd4bf", glyph: "↔" },
  key: { color: "#fbbf24", glyph: "⌨" },
  scroll: { color: "#5b8cff", glyph: "↕" },
  app_focus: { color: "#a78bfa", glyph: "▢" },
};
const TICK_KINDS = ["click", "drag", "scroll", "key"];

function clock(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

function describe(e: TEvent): string {
  switch (e.type) {
    case "click":
      return `click ${e.ax?.label ? `“${e.ax.label}”` : `${e.x},${e.y}`}`;
    case "drag":
      return `drag ${e.from?.join(",")} → ${e.to?.join(",")}`;
    case "key":
      return `key ${[...(e.mods ?? []), e.key].filter(Boolean).join("+")}`;
    case "scroll":
      return `scroll ${Math.abs(e.dy ?? 0) >= Math.abs(e.dx ?? 0) ? `${(e.dy ?? 0) < 0 ? "up" : "down"} ${Math.abs(e.dy ?? 0)}` : `${(e.dx ?? 0) < 0 ? "left" : "right"} ${Math.abs(e.dx ?? 0)}`}`;
    case "app_focus":
      return `→ ${e.app}${e.window ? ` · ${e.window}` : ""}`;
    default:
      return e.type;
  }
}

export default function PackInspector({ pack, onClose }: { pack: Pack; onClose: () => void }) {
  const [detail, setDetail] = useState<PackDetail | null>(null);
  const [src, setSrc] = useState<{ screen: string; camera: string; mic: string; sysaudio: string }>({ screen: "", camera: "", mic: "", sysaudio: "" });
  const [playing, setPlaying] = useState(false);
  const [now, setNow] = useState(0); // ms

  const screenRef = useRef<HTMLVideoElement>(null);
  const cameraRef = useRef<HTMLVideoElement>(null);
  const micRef = useRef<HTMLAudioElement>(null);
  const sysRef = useRef<HTMLAudioElement>(null);
  const raf = useRef<number>(0);

  const has = (f: string) => pack.sources.includes(f);
  const durationMs = (detail?.manifest?.durationMs as number) ?? pack.durationMs ?? 0;

  useEffect(() => {
    readPack(pack.dir).then(setDetail).catch(() => setDetail({ manifest: null, events: [] }));
    Promise.all([mediaSrc(pack.dir, "screen.mp4"), mediaSrc(pack.dir, "camera.mp4"), mediaSrc(pack.dir, "mic.m4a"), mediaSrc(pack.dir, "sysaudio.m4a")]).then(
      ([screen, camera, mic, sysaudio]) => setSrc({ screen, camera, mic, sysaudio }),
    );
  }, [pack.dir]);

  // all media share one clock: screen is master; camera + mic + system audio are
  // slaved and resynced if they drift more than a frame
  const slaves = () => [cameraRef.current, micRef.current, sysRef.current].filter(Boolean) as HTMLMediaElement[];

  function tick() {
    const m = screenRef.current;
    if (m) {
      setNow(m.currentTime * 1000);
      for (const s of slaves()) {
        // Only nudge a slave that's actually running (readyState≥2) and not
        // mid-seek. Hammering currentTime while an <audio> is still buffering its
        // play() stalls it entirely — that was the "no sound at all" bug.
        if (!s.seeking && s.readyState >= 2 && Math.abs(s.currentTime - m.currentTime) > 0.2) {
          s.currentTime = m.currentTime;
        }
      }
    }
    raf.current = requestAnimationFrame(tick);
  }

  function play() {
    screenRef.current?.play().catch(() => {});
    slaves().forEach((s) => {
      s.volume = 1; // audio elements: ensure audible (video slaves stay muted)
      s.play().catch(() => {});
    });
    setPlaying(true);
    cancelAnimationFrame(raf.current);
    raf.current = requestAnimationFrame(tick);
  }
  function pause() {
    screenRef.current?.pause();
    slaves().forEach((s) => s.pause());
    setPlaying(false);
    cancelAnimationFrame(raf.current);
  }
  function seekMs(ms: number) {
    const t = Math.max(0, Math.min(durationMs, ms)) / 1000;
    if (screenRef.current) screenRef.current.currentTime = t;
    slaves().forEach((s) => (s.currentTime = t));
    setNow(ms);
  }

  useEffect(() => () => cancelAnimationFrame(raf.current), []);

  // keyboard transport: space = play/pause, ←/→ = ±5s
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === " ") { e.preventDefault(); playing ? pause() : play(); }
      else if (e.key === "ArrowLeft") seekMs(now - 5000);
      else if (e.key === "ArrowRight") seekMs(now + 5000);
      else if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playing, now, durationMs]);

  const events = detail?.events ?? [];
  // app_focus events → contiguous segments across the timeline
  const segments = useMemo(() => {
    const af = events.filter((e) => e.type === "app_focus").sort((a, b) => a.t_ms - b.t_ms);
    return af.map((e, i) => ({ app: e.app ?? "", t: e.t_ms, end: af[i + 1]?.t_ms ?? durationMs }));
  }, [events, durationMs]);
  const ticks = useMemo(() => events.filter((e) => TICK_KINDS.includes(e.type)), [events]);

  const currentApp = useMemo(() => {
    let cur: TEvent | undefined;
    for (const e of events) if (e.type === "app_focus" && e.t_ms <= now) cur = e;
    return cur;
  }, [events, now]);
  const recent = useMemo(
    () => events.filter((e) => e.type !== "cursor" && e.type !== "app_focus" && e.t_ms <= now).slice(-5).reverse(),
    [events, now],
  );

  const pct = (ms: number) => `${durationMs ? (ms / durationMs) * 100 : 0}%`;

  return (
    <div className="inspector">
      <header className="insp-bar">
        <div className="insp-title">
          <button className="ghost sm" onClick={onClose}>← Library</button>
          <span className="insp-id">{pack.id}</span>
          <span className="insp-dur">{clock(durationMs)}</span>
        </div>
        <div className="insp-chips">
          {pack.rows != null && <span className="tag">{pack.rows} events</span>}
          {pack.cameraSyncOffsetMs != null && (
            <span className={`tag ${Math.abs(pack.cameraSyncOffsetMs) < 34 ? "ok" : "warn"}`}>
              cam {pack.cameraSyncOffsetMs > 0 ? "+" : ""}{Math.round(pack.cameraSyncOffsetMs)}ms
            </span>
          )}
          <button className="ghost sm" onClick={() => reveal(pack.dir)}>Reveal</button>
        </div>
      </header>

      <div className="insp-stage">
        <video ref={screenRef} className="insp-screen" src={src.screen} muted playsInline
               onClick={() => (playing ? pause() : play())}
               onEnded={() => setPlaying(false)} />
        {has("camera.mp4") && <video ref={cameraRef} className="insp-cam" src={src.camera} muted playsInline />}
        {has("mic.m4a") && <audio ref={micRef} src={src.mic} />}
        {has("sysaudio.m4a") && <audio ref={sysRef} src={src.sysaudio} />}

        <div className="insp-now">
          <span className="now-app">{currentApp ? `${currentApp.app}${currentApp.window ? ` · ${currentApp.window}` : ""}` : "—"}</span>
          <div className="now-events">
            {recent.length === 0 ? <span className="muted">no actions yet</span> : recent.map((e, i) => (
              <span key={i} className="now-ev" style={{ color: KIND[e.type]?.color }}>
                {KIND[e.type]?.glyph} {describe(e)}
              </span>
            ))}
          </div>
        </div>
      </div>

      <div className="insp-transport">
        <button className="play" onClick={() => (playing ? pause() : play())}>
          {playing ? "❚❚" : "▶"}
        </button>
        <span className="t">{clock(now)} <span className="muted">/ {clock(durationMs)}</span></span>

        <div className="timeline" onClick={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          seekMs(((e.clientX - r.left) / r.width) * durationMs);
        }}>
          <div className="tl-apps">
            {segments.map((s, i) => (
              <div key={i} className="tl-app" title={s.app}
                   style={{ left: pct(s.t), width: pct(s.end - s.t) }}>
                <span>{s.app}</span>
              </div>
            ))}
          </div>
          <div className="tl-events">
            {ticks.map((e, i) => (
              <div key={i}
                   className={`tl-tick ${e.type}`}
                   title={`${clock(e.t_ms)} — ${describe(e)}`}
                   onClick={(ev) => { ev.stopPropagation(); seekMs(e.t_ms); }}
                   style={{
                     left: pct(e.t_ms),
                     width: e.type === "drag" && e.end_ms ? pct(e.end_ms - e.t_ms) : undefined,
                     background: KIND[e.type]?.color,
                   }} />
            ))}
          </div>
          <div className="tl-head" style={{ left: pct(now) }} />
        </div>
      </div>
    </div>
  );
}

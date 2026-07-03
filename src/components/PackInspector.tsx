import { useEffect, useMemo, useRef, useState } from "react";
import { mediaSrc, readPack, reveal } from "../api";
import CrunchControl from "./CrunchControl";
import type { CrunchEvent, Pack, PackDetail, TEvent } from "../types";

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

export default function PackInspector({ pack, crunch, onClose }: { pack: Pack; crunch?: CrunchEvent; onClose: () => void }) {
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

  // Audio is the master clock — it plays perfectly smoothly, so we NEVER seek it
  // mid-playback (seeking an <audio> = an audible glitch). The video elements are
  // the ones nudged to match; a stuttering 1080p decode can hitch the picture but
  // must never drag the sound. Master = mic → sysaudio → screen (whatever exists).
  const audioEls = () => [micRef.current, sysRef.current].filter(Boolean) as HTMLMediaElement[];
  const videoEls = () => [screenRef.current, cameraRef.current].filter(Boolean) as HTMLMediaElement[];
  const allEls = () => [...videoEls(), ...audioEls()];
  const master = () => micRef.current ?? sysRef.current ?? screenRef.current;
  const lastNowMs = useRef(0);

  function tick() {
    const m = master();
    if (m) {
      const ms = m.currentTime * 1000;
      // throttle the React "now" update to ~20Hz — 60fps re-renders of the whole
      // timeline were themselves janking playback
      if (Math.abs(ms - lastNowMs.current) >= 50) {
        lastNowMs.current = ms;
        setNow(ms);
      }
      // nudge only the VIDEO to the (audio) master; audio is never touched here
      for (const v of videoEls()) {
        if (v !== m && !v.seeking && v.readyState >= 2 && Math.abs(v.currentTime - m.currentTime) > 0.25) {
          v.currentTime = m.currentTime;
        }
      }
    }
    raf.current = requestAnimationFrame(tick);
  }

  function play() {
    const t = master()?.currentTime ?? 0;
    allEls().forEach((e) => {
      if (Math.abs(e.currentTime - t) > 0.05) e.currentTime = t; // one sync, then free-run
      e.volume = 1;
      e.play().catch(() => {});
    });
    setPlaying(true);
    cancelAnimationFrame(raf.current);
    raf.current = requestAnimationFrame(tick);
  }
  function pause() {
    allEls().forEach((e) => e.pause());
    setPlaying(false);
    cancelAnimationFrame(raf.current);
  }
  function seekMs(ms: number) {
    const t = Math.max(0, Math.min(durationMs, ms)) / 1000;
    allEls().forEach((e) => (e.currentTime = t)); // explicit seek touches everything
    lastNowMs.current = ms;
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
          <CrunchControl pack={pack} ev={crunch} />
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

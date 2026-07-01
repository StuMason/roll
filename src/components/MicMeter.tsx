import { useEffect, useRef, useState } from "react";
import { onLevel } from "../api";

// Live mic VU bar, fed by the daemon's metering session (roll://level, 0..1 RMS).
// Fast attack / slow release so it reads like a real meter, gained on a perceptual
// curve because speech RMS is small. Shows whenever a mic is selected — idle and
// through recording.
export default function MicMeter({ active }: { active: boolean }) {
  const [level, setLevel] = useState(0);
  const smoothed = useRef(0);

  useEffect(() => {
    if (!active) {
      setLevel(0);
      return;
    }
    let un: (() => void) | undefined;
    let cancelled = false;
    onLevel((rms) => {
      if (cancelled) return;
      const disp = Math.min(1, Math.sqrt(Math.max(0, rms)) * 1.6);
      // fast attack, slow release
      smoothed.current = disp > smoothed.current ? disp : smoothed.current * 0.8 + disp * 0.2;
      setLevel(smoothed.current);
    }).then((u) => {
      if (cancelled) u();
      else un = u;
    });
    return () => {
      cancelled = true;
      un?.();
    };
  }, [active]);

  if (!active) return null;
  const pct = Math.round(level * 100);
  const color = pct > 85 ? "var(--rec)" : pct > 60 ? "#fbbf24" : "#4ade80";
  return (
    <div className="mic-meter" title="mic input level">
      <div className="mic-meter-fill" style={{ width: `${pct}%`, background: color }} />
    </div>
  );
}

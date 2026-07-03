import { crunchPack } from "../api";
import type { CrunchEvent, Pack } from "../types";

// Human labels for the pipeline stages crunch reports while processing.
const STAGE: Record<string, string> = {
  unpack: "unpacking",
  extract_frames: "frames",
  ocr: "ocr",
  transcribe: "transcribing",
  analyze: "analysing",
  assemble: "assembling",
};

// One take's crunch button + live status. The parent owns the event stream
// (one roll://crunch subscription in App) and passes this take's latest event.
export default function CrunchControl({ pack, ev }: { pack: Pack; ev?: CrunchEvent }) {
  const active = ev && ev.status !== "completed" && ev.status !== "failed";

  if (active) {
    // ocr is the only stage with counts — give it a real progress fill
    const pct = ev.stage === "ocr" && ev.total ? Math.round(((ev.done ?? 0) / ev.total) * 100) : null;
    const label =
      ev.status === "processing" || ev.status === "queued"
        ? ev.stage
          ? `${STAGE[ev.stage] ?? ev.stage}${pct !== null ? ` ${ev.done}/${ev.total}` : ""}`
          : ev.status
        : `${ev.status}…`; // taring… / uploading…
    return (
      <span
        className="tag crunching"
        title={ev.jobId ? `crunch job ${ev.jobId}` : "crunching…"}
        style={pct !== null ? { backgroundImage: `linear-gradient(90deg, rgba(91,140,255,.28) ${pct}%, transparent ${pct}%)` } : undefined}
      >
        <span className="crunch-spin" /> {label}
      </span>
    );
  }

  const crunched = pack.crunched || ev?.status === "completed";
  const failed = ev?.status === "failed";
  return (
    <>
      {crunched && <span className="tag ok">crunched</span>}
      {failed && (
        <span className="tag warn" title={ev?.error ?? "crunch failed"}>
          crunch failed
        </span>
      )}
      <button
        className="ghost sm"
        onClick={(e) => {
          e.stopPropagation();
          crunchPack(pack).catch(() => {});
        }}
        title={
          failed
            ? ev?.error ?? "retry crunch"
            : crunched
              ? "run crunch again (crunch keeps improving — re-runs replace crunch.json)"
              : "upload the pack to crunch and land crunch.json next to the media"
        }
      >
        {failed ? "Retry" : crunched ? "Re-crunch" : "Crunch"}
      </button>
    </>
  );
}

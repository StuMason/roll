import { useEffect, useRef, useState } from "react";
import { onFrame } from "../api";

interface Props {
  cameraIndex: number | null;
  cameraLabel: string;
  recording: boolean;
}

// Live camera preview, fed by the capture daemon's single camera session (the
// same one that records). No getUserMedia, no second camera client — the sidecar
// streams downscaled JPEG frames (`roll://frame`) and we just paint the latest
// one. This keeps the preview alive *during* recording with zero contention.
export default function CameraPreview({ cameraIndex, cameraLabel, recording }: Props) {
  const imgRef = useRef<HTMLImageElement>(null);
  const [hasFrame, setHasFrame] = useState(false);

  useEffect(() => {
    // dropping the camera clears the view; frames resume when one is selected
    if (cameraIndex === null) setHasFrame(false);
    let un: (() => void) | undefined;
    let cancelled = false;
    onFrame((dataUrl) => {
      if (cancelled || cameraIndex === null) return;
      if (imgRef.current) imgRef.current.src = dataUrl;
      setHasFrame(true);
    }).then((u) => {
      if (cancelled) u();
      else un = u;
    });
    return () => {
      cancelled = true;
      un?.();
    };
  }, [cameraIndex]);

  const showImg = hasFrame && cameraIndex !== null;
  return (
    <div className={`cam${recording ? " rec" : ""}`}>
      <img ref={imgRef} alt="camera preview" className={showImg ? "shown" : "hidden"} />
      {!showImg && (
        <div className="cam-fallback">
          <svg viewBox="0 0 48 48" width="40" height="40" aria-hidden>
            <circle cx="24" cy="19" r="8" fill="none" stroke="currentColor" strokeWidth="2.2" />
            <path d="M9 40c1.5-8 7.5-12 15-12s13.5 4 15 12" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
          </svg>
          <span className="cam-fallback-label">{cameraIndex === null ? "No camera" : cameraLabel}</span>
          {cameraIndex !== null && <span className="cam-fallback-sub">connecting…</span>}
        </div>
      )}
      <span className="cam-badge">CAM</span>
    </div>
  );
}

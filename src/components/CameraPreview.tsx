import { useEffect, useRef, useState } from "react";

interface Props {
  cameraIndex: number | null;
  cameraLabel: string;
  recording: boolean;
}

// Live camera preview via getUserMedia. WKWebView (Tauri) supports this with the
// camera usage string set; if it's blocked, or there's no camera selected, we
// render a deliberate placeholder so the frame still reads as "your camera here".
export default function CameraPreview({ cameraIndex, cameraLabel, recording }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [ok, setOk] = useState(false);

  useEffect(() => {
    let stream: MediaStream | null = null;
    setOk(false);
    if (cameraIndex === null || typeof navigator === "undefined" || !navigator.mediaDevices) return;
    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
        if (videoRef.current) {
          videoRef.current.srcObject = stream;
          setOk(true);
        }
      } catch {
        setOk(false);
      }
    })();
    return () => stream?.getTracks().forEach((t) => t.stop());
  }, [cameraIndex]);

  return (
    <div className={`cam${recording ? " rec" : ""}`}>
      <video ref={videoRef} autoPlay muted playsInline className={ok ? "shown" : "hidden"} />
      {!ok && (
        <div className="cam-fallback">
          <svg viewBox="0 0 48 48" width="40" height="40" aria-hidden>
            <circle cx="24" cy="19" r="8" fill="none" stroke="currentColor" strokeWidth="2.2" />
            <path d="M9 40c1.5-8 7.5-12 15-12s13.5 4 15 12" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
          </svg>
          <span className="cam-fallback-label">
            {cameraIndex === null ? "No camera" : cameraLabel}
          </span>
          {cameraIndex !== null && <span className="cam-fallback-sub">preview shows on device</span>}
        </div>
      )}
      <span className="cam-badge">CAM</span>
    </div>
  );
}

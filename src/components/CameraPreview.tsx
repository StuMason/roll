import { useEffect, useRef, useState } from "react";

interface Props {
  cameraIndex: number | null;
  cameraLabel: string;
  recording: boolean;
}

// Map the app's selected camera (from the Swift engine's device list) to a web
// deviceId so the preview shows the SAME camera you picked — getUserMedia's
// default would otherwise always show the first camera regardless of the dropdown.
function pickDeviceId(cams: MediaDeviceInfo[], label: string, index: number | null): string | undefined {
  const want = label.toLowerCase().trim();
  if (want) {
    const m = cams.find((c) => {
      const l = c.label.toLowerCase();
      const base = l.split("(")[0].trim(); // web labels often add "(05ac:8514)"
      return l.includes(want) || (base.length > 0 && want.includes(base));
    });
    if (m) return m.deviceId;
  }
  if (index != null && cams[index]) return cams[index].deviceId;
  return cams[0]?.deviceId;
}

// Live camera preview via getUserMedia (works in WKWebView with the camera usage
// string set). Re-runs when the selection changes so the picker drives the view.
export default function CameraPreview({ cameraIndex, cameraLabel, recording }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [ok, setOk] = useState(false);

  useEffect(() => {
    let stream: MediaStream | null = null;
    let cancelled = false;
    setOk(false);
    if (cameraIndex === null || typeof navigator === "undefined" || !navigator.mediaDevices) return;
    (async () => {
      try {
        let cams = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "videoinput");
        if (cams.every((c) => !c.label)) {
          // labels are empty until permission is granted — probe once
          const probe = await navigator.mediaDevices.getUserMedia({ video: true });
          probe.getTracks().forEach((t) => t.stop());
          cams = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "videoinput");
        }
        const deviceId = pickDeviceId(cams, cameraLabel, cameraIndex);
        stream = await navigator.mediaDevices.getUserMedia({
          video: deviceId ? { deviceId: { exact: deviceId } } : true,
        });
        if (cancelled) {
          stream.getTracks().forEach((t) => t.stop());
          return;
        }
        if (videoRef.current) {
          videoRef.current.srcObject = stream;
          setOk(true);
        }
      } catch {
        setOk(false);
      }
    })();
    return () => {
      cancelled = true;
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, [cameraIndex, cameraLabel]);

  return (
    <div className={`cam${recording ? " rec" : ""}`}>
      <video ref={videoRef} autoPlay muted playsInline className={ok ? "shown" : "hidden"} />
      {!ok && (
        <div className="cam-fallback">
          <svg viewBox="0 0 48 48" width="40" height="40" aria-hidden>
            <circle cx="24" cy="19" r="8" fill="none" stroke="currentColor" strokeWidth="2.2" />
            <path d="M9 40c1.5-8 7.5-12 15-12s13.5 4 15 12" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
          </svg>
          <span className="cam-fallback-label">{cameraIndex === null ? "No camera" : cameraLabel}</span>
          {cameraIndex !== null && <span className="cam-fallback-sub">preview shows on device</span>}
        </div>
      )}
      <span className="cam-badge">CAM</span>
    </div>
  );
}

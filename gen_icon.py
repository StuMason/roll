#!/usr/bin/env python3
"""Generate a 1024x1024 source icon (dark square, red record dot) with no
image deps — raw RGBA PNG via zlib. `tauri icon` expands it into every format."""
import struct, zlib, math, sys

N = 1024
bg = (14, 15, 18)        # near-black
dot = (229, 72, 77)      # record red
cx = cy = N / 2
r = N * 0.30

raw = bytearray()
for y in range(N):
    raw.append(0)  # PNG filter type 0 for this scanline
    for x in range(N):
        d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
        # smooth 1px edge
        t = max(0.0, min(1.0, (r - d) + 0.5))
        col = tuple(round(bg[i] * (1 - t) + dot[i] * t) for i in range(3))
        raw += bytes(col) + b"\xff"

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0))  # 8-bit RGBA
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")

out = sys.argv[1] if len(sys.argv) > 1 else "app-icon.png"
with open(out, "wb") as f:
    f.write(png)
print("wrote", out)

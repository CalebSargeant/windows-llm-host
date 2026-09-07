#!/usr/bin/env python3
"""Generate placeholder MSIX assets for the windows-llm-host GUI.

These are simple solid-color PNGs so the MSIX project builds. Replace them with
real branded artwork before publishing to the Microsoft Store. Re-run with:

    python3 gui/tools/generate-placeholder-assets.py
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

BG = (15, 23, 42)       # dark slate
ACCENT = (45, 212, 191)  # teal

# (filename, width, height) - the standard WinUI single-project asset set.
ASSETS = [
    ("Square44x44Logo.png", 44, 44),
    ("Square150x150Logo.png", 150, 150),
    ("Wide310x150Logo.png", 310, 150),
    ("SmallTile.png", 71, 71),
    ("LargeTile.png", 310, 310),
    ("StoreLogo.png", 50, 50),
    ("SplashScreen.png", 620, 300),
    ("LockScreenLogo.png", 24, 24),
]


def make_png(width: int, height: int) -> bytes:
    """Solid background with a centered accent square, encoded as a PNG (RGBA)."""
    inset_x = max(1, width // 5)
    inset_y = max(1, height // 5)

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None) per scanline
        for x in range(width):
            in_square = (inset_x <= x < width - inset_x) and (inset_y <= y < height - inset_y)
            r, g, b = ACCENT if in_square else BG
            raw += bytes((r, g, b, 255))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def main() -> None:
    out_dir = Path(__file__).resolve().parent.parent / "src" / "WindowsLlmHost.Gui" / "Assets"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, w, h in ASSETS:
        (out_dir / name).write_bytes(make_png(w, h))
        print(f"wrote {out_dir / name} ({w}x{h})")


if __name__ == "__main__":
    main()

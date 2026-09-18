#!/usr/bin/env python3
"""Draws the sample window's picture: assets/images/{32,16}/hello.png.

A speech balloon — a white rounded box with a navy outline and a tail, three
dots inside — drawn with the standard library only, so the tool runs on any
machine with python3. The shell's image packs take PNG files named
`<size>/<name>.png`; the window calls this one `<namespace>:images/hello`.

    python3 tools/hello_icon.py        # or `make icons`

Redraw your own picture with any tool you like: the pack only needs the two
sizes to be exact (32x32 and 16x16) and the file names to match.
"""
import struct
import sys
import zlib
from pathlib import Path

WHITE = (255, 255, 255, 255)
NAVY = (0, 0, 128, 255)
SHADOW = (128, 128, 128, 255)
CLEAR = (0, 0, 0, 0)


def png(width, height, rows):
    """Encodes RGBA rows (lists of 4-tuples) as a PNG file."""
    raw = b"".join(b"\x00" + bytes(channel for pixel in row for channel in pixel) for row in rows)

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def balloon(size):
    """The balloon at a given size; every measure is a share of the size."""
    rows = [[CLEAR] * size for _ in range(size)]
    box_left, box_top = 1, 1
    box_right, box_bottom = size - 2, size * 2 // 3          # exclusive
    radius = max(1, size // 8)

    def inside_box(x, y):
        if not (box_left <= x < box_right and box_top <= y < box_bottom):
            return False
        # Rounded corners: outside the quarter circles is outside the box.
        cx = box_left + radius if x < box_left + radius else (box_right - 1 - radius if x >= box_right - radius else x)
        cy = box_top + radius if y < box_top + radius else (box_bottom - 1 - radius if y >= box_bottom - radius else y)
        return (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius + radius

    def inside_tail(x, y):
        # A triangle under the box's left third, pointing down-left.
        top, bottom = box_bottom - 1, size - 2
        if not (top <= y <= bottom):
            return False
        left = box_left + size // 6
        width = max(1, (size // 4) * (bottom - y) // max(1, bottom - top))
        return left <= x < left + width + 1

    def inside(x, y):
        return inside_box(x, y) or inside_tail(x, y)

    for y in range(size):
        for x in range(size):
            if not inside(x, y):
                continue
            edge = any(not inside(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
            rows[y][x] = NAVY if edge else WHITE
    # The shadow, one pixel down and right, where nothing is drawn yet.
    for y in range(size - 1, 0, -1):
        for x in range(size - 1, 0, -1):
            if rows[y][x] == CLEAR and (rows[y - 1][x] == NAVY or rows[y][x - 1] == NAVY):
                rows[y][x] = SHADOW
    # Three dots on the box's middle row.
    dot = max(1, size // 12)
    middle = (box_top + box_bottom) // 2
    for index in range(3):
        cx = box_left + (box_right - box_left) * (index + 1) // 4
        for y in range(middle - dot // 2, middle - dot // 2 + dot):
            for x in range(cx - dot // 2, cx - dot // 2 + dot):
                if inside_box(x, y):
                    rows[y][x] = NAVY
    return rows


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent / "assets" / "images"
    for size in (32, 16):
        target = root / str(size) / "hello.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(png(size, size, balloon(size)))
        print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

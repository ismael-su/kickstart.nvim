#!/usr/bin/env python3
"""Generate test fixtures for inlineview.nvim.

Only the standard library is used. The PDF is hand-assembled (valid xref,
three pages of differing content) and the PNG/JPEG fixtures are produced by
rasterizing it with pdftoppm, so they are genuine encoder output rather than
synthetic headers. GIF/BMP/WebP are written byte-for-byte because the header
parsers are what the tests exercise.
"""

import os
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))


def out(name):
    return os.path.join(HERE, name)


# ---------------------------------------------------------------- PDF


def make_pdf(path, pages=3, width=595, height=842):
    """A minimal but spec-valid multi-page PDF with a distinct glyph per page."""
    objects = {}

    kids = " ".join(f"{4 + i} 0 R" for i in range(pages))
    objects[1] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objects[2] = (
        f"<< /Type /Pages /Count {pages} /Kids [{kids}] >>".encode()
    )
    objects[3] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

    for i in range(pages):
        page_obj = 4 + i
        content_obj = 4 + pages + i
        objects[page_obj] = (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] "
            f"/Resources << /Font << /F1 3 0 R >> >> "
            f"/Contents {content_obj} 0 R >>"
        ).encode()

        # Big page number plus a rectangle whose width varies per page, so a
        # human can tell at a glance that paging actually changed the render.
        stream = (
            f"BT /F1 220 Tf 150 450 Td (P{i + 1}) Tj ET\n"
            f"0.1 0.4 0.9 rg 60 120 {80 + i * 120} 60 re f\n"
            f"0 0 0 RG 4 w 40 40 {width - 80} {height - 80} re S\n"
        ).encode()
        objects[content_obj] = (
            b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream"
        )

    # Serialize with a real cross-reference table.
    buf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for num in sorted(objects):
        offsets[num] = len(buf)
        buf += f"{num} 0 obj\n".encode() + objects[num] + b"\nendobj\n"

    xref_at = len(buf)
    count = max(objects) + 1
    buf += f"xref\n0 {count}\n".encode()
    buf += b"0000000000 65535 f \n"
    for num in range(1, count):
        buf += f"{offsets[num]:010d} 00000 n \n".encode()
    buf += (
        f"trailer\n<< /Size {count} /Root 1 0 R >>\nstartxref\n{xref_at}\n%%EOF\n".encode()
    )

    with open(path, "wb") as f:
        f.write(bytes(buf))
    return path


# ---------------------------------------------------------------- PNG


def make_png(path, w, h):
    """Write an RGB PNG with a deterministic gradient."""

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type: none
        for x in range(w):
            raw += bytes(((x * 255) // max(w - 1, 1), (y * 255) // max(h - 1, 1), 128))

    body = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(body)
    return path


# ---------------------------------------------------------------- GIF / BMP / WebP


def make_gif(path, w, h):
    """GIF89a, single frame, 2-colour palette."""
    header = b"GIF89a" + struct.pack("<HH", w, h) + b"\xf0\x00\x00"
    palette = b"\xff\x00\x00\x00\x00\xff"
    gce = b"\x21\xf9\x04\x00\x00\x00\x00\x00"
    imgdesc = b"\x2c" + struct.pack("<HHHH", 0, 0, w, h) + b"\x00"
    # Minimal LZW stream: clear, one pixel index, end-of-information.
    lzw = b"\x02" + b"\x02\x4c\x01" + b"\x00"
    with open(path, "wb") as f:
        f.write(header + palette + gce + imgdesc + lzw + b"\x3b")
    return path


def make_bmp(path, w, h):
    """24-bit BITMAPINFOHEADER BMP."""
    row_pad = (-w * 3) % 4
    pixels = bytearray()
    for y in range(h):
        for x in range(w):
            pixels += bytes((x % 256, y % 256, 200))  # BGR
        pixels += b"\x00" * row_pad
    dib = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    offset = 14 + len(dib)
    header = b"BM" + struct.pack("<IHHI", offset + len(pixels), 0, 0, offset)
    with open(path, "wb") as f:
        f.write(header + dib + bytes(pixels))
    return path


def make_webp_lossless(path, w, h):
    """VP8L WebP. Dimensions are stored as 14-bit values, minus one."""
    bits = (w - 1) | ((h - 1) << 14)
    vp8l = b"\x2f" + struct.pack("<I", bits)
    chunk = b"VP8L" + struct.pack("<I", len(vp8l)) + vp8l
    riff = b"RIFF" + struct.pack("<I", 4 + len(chunk)) + b"WEBP" + chunk
    with open(path, "wb") as f:
        f.write(riff)
    return path


def make_webp_vp8x(path, w, h):
    """VP8X (extended) WebP: 24-bit canvas dimensions, minus one."""
    body = b"\x10\x00\x00\x00" + (w - 1).to_bytes(3, "little") + (h - 1).to_bytes(3, "little")
    chunk = b"VP8X" + struct.pack("<I", len(body)) + body
    riff = b"RIFF" + struct.pack("<I", 4 + len(chunk)) + b"WEBP" + chunk
    with open(path, "wb") as f:
        f.write(riff)
    return path


def main():
    made = []
    made.append(make_pdf(out("sample.pdf"), pages=3))
    made.append(make_png(out("gradient.png"), 200, 120))
    made.append(make_png(out("tall.png"), 60, 400))
    made.append(make_png(out("tiny.png"), 4, 4))
    made.append(make_gif(out("dot.gif"), 32, 24))
    made.append(make_bmp(out("block.bmp"), 16, 9))
    made.append(make_webp_lossless(out("lossless.webp"), 300, 200))
    made.append(make_webp_vp8x(out("extended.webp"), 640, 480))

    # Real JPEG, straight from poppler's encoder.
    if subprocess.run(["which", "pdftoppm"], capture_output=True).returncode == 0:
        subprocess.run(
            ["pdftoppm", "-jpeg", "-r", "20", "-f", "1", "-l", "1", "-singlefile",
             out("sample.pdf"), out("page1")],
            check=True,
        )
        made.append(out("page1.jpg"))
    else:
        print("warning: pdftoppm missing, skipping JPEG fixture", file=sys.stderr)

    for p in made:
        print(f"{os.path.getsize(p):>8}  {os.path.basename(p)}")


if __name__ == "__main__":
    main()

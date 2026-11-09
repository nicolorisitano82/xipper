#!/usr/bin/env python3
"""Upper-bound estimate of the 3.0 recompression (ROADMAP 3.0, phase E) on real files.

For each file, what XIZ stores today (zstd -19 and LZMA2 -9 on the file as it is) against the
file with its Deflate streams inflated and then compressed the same way:
  - ZIP containers (DOCX, XLSX, PPTX, EPUB, ODF): every deflated member inflated;
  - PNG: the IDAT stream inflated (filtered scanlines);
  - PDF: every /FlateDecode stream that inflates;
  - WAV / AIFF: FLAC -8 (the `flac` command) instead of inflating.
The rebuild data preflate needs to give back the exact Deflate bytes is not counted: about 0.01%
on zlib streams, more on other encoders, so the real gain is a little lower. Nothing is written
next to the files; only totals per type are printed, no file names.

Usage: python3 -I scripts/estimate-recompression.py [--exclude DIR]... DIR...
"""
import lzma, os, re, subprocess, sys, tempfile, zipfile, zlib
from compression import zstd
from concurrent.futures import ProcessPoolExecutor

ZIPS = {"docx", "xlsx", "pptx", "epub", "odt", "ods", "odp"}
KINDS = ZIPS | {"png", "pdf", "wav", "aif", "aiff"}
LIMIT = 64 << 20  # files XIZ would put in a frame of their own


def packed(data):
    """(zstd -19, LZMA2 -9) sizes, in 4 MiB blocks like XIZ frames."""
    z = x = 0
    for i in range(0, len(data), 4 << 20):
        b = data[i:i + (4 << 20)]
        z += min(len(b), len(zstd.compress(b, 19)))
        x += min(len(b), len(lzma.compress(b, format=lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA2, "preset": 9}])))
    return z, x


def inflate_zip(data, path):
    out = []
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            out.append(info.filename.encode() + z.read(info))  # names stand in for the headers
    return b"".join(out)


def inflate_png(data):
    pos, idat, rest = 8, [], [data[:8]]
    while pos + 8 <= len(data):
        n = int.from_bytes(data[pos:pos + 4], "big")
        kind = data[pos + 4:pos + 8]
        chunk = data[pos:pos + 12 + n]
        if kind == b"IDAT":
            idat.append(data[pos + 8:pos + 8 + n])
        else:
            rest.append(chunk)
        pos += 12 + n
    return b"".join(rest) + zlib.decompress(b"".join(idat))


STREAM = re.compile(rb"stream\r?\n")


def inflate_pdf(data):
    out, pos = [], 0
    for m in STREAM.finditer(data):
        if m.start() < pos:
            continue
        end = data.find(b"endstream", m.end())
        if end < 0:
            break
        head = data[max(0, m.start() - 300):m.start()]
        if b"FlateDecode" not in head:
            continue
        try:
            raw = zlib.decompressobj().decompress(data[m.end():end])
        except zlib.error:
            continue
        out += [data[pos:m.end()], raw]
        pos = end
    out.append(data[pos:])
    return b"".join(out)


def flac_size(path):
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "a.flac")
        r = subprocess.run(["flac", "-8", "-s", "--keep-foreign-metadata", "-o", out, path], capture_output=True)
        return os.path.getsize(out) if r.returncode == 0 else None


def measure(path):
    kind = path.rsplit(".", 1)[-1].lower()
    group = "office/epub/odf" if kind in ZIPS else "aiff" if kind == "aif" else kind
    try:
        data = open(path, "rb").read()
        now = packed(data)
        if kind in ("wav", "aif", "aiff"):
            f = flac_size(path)
            if f is None:
                return group, len(data), now, now, False
            return group, len(data), now, (f, f), True
        raw = inflate_zip(data, path) if kind in ZIPS else inflate_png(data) if kind == "png" else inflate_pdf(data)
        if len(raw) <= len(data) * 1.02:  # nothing (or almost nothing) was deflated
            return group, len(data), now, now, False
        return group, len(data), now, packed(raw), True
    except Exception:
        return group, len(data) if "data" in dir() else 0, None, None, False


def main(argv):
    excludes, roots = [], []
    it = iter(argv)
    for a in it:
        if a == "--exclude":
            excludes.append(os.path.realpath(next(it)))
        else:
            roots.append(a)
    files = []
    for root in roots:
        for d, dirs, names in os.walk(root):
            dirs[:] = [x for x in dirs if os.path.realpath(os.path.join(d, x)) not in excludes and not x.endswith((".app", ".photoslibrary"))]
            for n in names:
                p = os.path.join(d, n)
                if n.rsplit(".", 1)[-1].lower() in KINDS and os.path.isfile(p) and 4096 <= os.path.getsize(p) <= LIMIT:
                    files.append(p)
    totals = {}
    with ProcessPoolExecutor() as pool:
        for group, size, now, new, used in pool.map(measure, files, chunksize=4):
            t = totals.setdefault(group, [0] * 8)
            t[0] += 1
            t[1] += size
            if now is None:
                t[7] += 1
                continue
            t[2] += now[0]; t[3] += now[1]; t[4] += new[0]; t[5] += new[1]; t[6] += used
    print(f"{'type':<16}{'files':>6}{'MB':>9}{'zstd19 now':>12}{'LZMA2 now':>11}{'zstd19 new':>12}{'LZMA2 new':>11}{'gain':>8}{'used':>6}{'err':>5}")
    for g, t in sorted(totals.items()):
        mb = t[1] / 1e6
        pct = lambda v: f"{v / t[1] * 100:.1f}%" if t[1] else "-"
        gain = (1 - t[5] / t[3]) * 100 if t[3] else 0
        print(f"{g:<16}{t[0]:>6}{mb:>9.1f}{pct(t[2]):>12}{pct(t[3]):>11}{pct(t[4]):>12}{pct(t[5]):>11}{gain:>7.1f}%{t[6]:>6}{t[7]:>5}")
    print("gain: LZMA2 after recompression against LZMA2 today; used: files where it applies")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

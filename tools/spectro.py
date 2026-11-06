"""Draw log-spectrograms of 16 kHz mono WAVs, stacked, and report energy per 1 kHz band.
Usage: spectro.py out.png a.wav [b.wav ...]
"""
import cmath, math, struct, sys, wave
from PIL import Image, ImageDraw

N = 512
HOP = 128
WIN = [0.5 - 0.5 * math.cos(2 * math.pi * i / N) for i in range(N)]


def fft(a):
    n = len(a)
    if n == 1:
        return a
    e, o = fft(a[0::2]), fft(a[1::2])
    w = [cmath.exp(-2j * math.pi * k / n) * o[k] for k in range(n // 2)]
    return [e[k] + w[k] for k in range(n // 2)] + [e[k] - w[k] for k in range(n // 2)]


def spectrum(path):
    with wave.open(path, "rb") as w:
        raw = w.readframes(w.getnframes())
    x = struct.unpack("<%dh" % (len(raw) // 2), raw)
    cols = []
    for t in range(0, len(x) - N, HOP):
        X = fft([complex(x[t + i] * WIN[i]) for i in range(N)])
        cols.append([abs(X[k]) ** 2 for k in range(N // 2)])
    return cols


def main():
    out, paths = sys.argv[1], sys.argv[2:]
    specs = [spectrum(p) for p in paths]
    width = max(len(c) for c in specs)
    img = Image.new("RGB", (width, (N // 2 + 16) * len(specs)), "white")
    draw = ImageDraw.Draw(img)
    for row, (path, cols) in enumerate(zip(paths, specs)):
        top = row * (N // 2 + 16)
        draw.text((2, top + 2), path, fill="black")
        for x, col in enumerate(cols):
            for k, p in enumerate(col):
                db = 10 * math.log10(p + 1.0)
                v = max(0, min(255, int((db - 70) * 255 / 70)))
                img.putpixel((x, top + 16 + N // 2 - 1 - k), (v, v, v))
        bands = [0.0] * 8
        for col in cols:
            for k, p in enumerate(col):
                bands[min(7, k * 8 // (N // 2))] += p
        total = sum(bands) or 1.0
        print(path, "energy % per 1 kHz band:", " ".join("%.2f" % (100 * b / total) for b in bands))
    img.save(out)


if __name__ == "__main__":
    main()

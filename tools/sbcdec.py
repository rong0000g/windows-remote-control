"""Decode voicecap logs: 20-byte headerless SBC frames (8 subbands, 16 blocks, mono).
Usage: sbcdec.py selftest | sbcdec.py <log> <outdir> [snr|loudness] [bitpool]
"""
import math, os, sys, wave

M = 8
BLOCKS = 16
HALF = [0.0, 1.56575398e-04, 3.43256425e-04, 5.54620202e-04, 8.23919506e-04, 1.13992507e-03,
        1.47640169e-03, 1.78371725e-03, 2.01182542e-03, 2.10371989e-03, 1.99454554e-03,
        1.61656283e-03, 9.02154502e-04, -1.78805361e-04, -1.64973098e-03, -3.49717454e-03,
        -5.65949473e-03, -8.02941163e-03, -1.04584443e-02, -1.27472335e-02, -1.46525263e-02,
        -1.59045603e-02, -1.62208471e-02, -1.53184106e-02, -1.29371806e-02, -8.85757540e-03,
        -2.92408442e-03, 4.91578024e-03, 1.46404076e-02, 2.61098752e-02, 3.90751381e-02,
        5.31873032e-02, 6.79989431e-02, 8.29847578e-02, 9.75753918e-02, 1.11196689e-01,
        1.23264548e-01, 1.33264415e-01, 1.40753505e-01, 1.45389847e-01, 1.46955068e-01]
H = HALF + HALF[-2::-1]
H = (H + [0.0] * 80)[:80]
SYN = [[M * H[n] * math.cos((k + 0.5) * (n + 4) * math.pi / M) for n in range(80)] for k in range(M)]
ANA = [[H[n] * math.cos((k + 0.5) * (n - 4) * math.pi / M) for n in range(80)] for k in range(M)]
OFFSET_16K = [-2, 0, 0, 0, 0, 0, 0, 1]


def allocate(sf, bitpool, method):
    if method == "snr":
        need = list(sf)
    else:
        need = []
        for s, off in zip(sf, OFFSET_16K):
            if s == 0:
                need.append(-5)
            else:
                loud = s - off
                need.append(int(loud / 2) if loud > 0 else loud)
    bitslice = max(need) + 1
    bitcount = slicecount = 0
    while True:
        bitslice -= 1
        bitcount += slicecount
        slicecount = 0
        for b in need:
            if bitslice + 1 < b < bitslice + 16:
                slicecount += 1
            elif b == bitslice + 1:
                slicecount += 2
        if bitcount + slicecount >= bitpool:
            break
    if bitcount + slicecount == bitpool:
        bitcount += slicecount
        bitslice -= 1
    bits = [0 if b < bitslice + 2 else min(b - bitslice, 16) for b in need]
    sb = 0
    while bitcount < bitpool and sb < M:
        if 2 <= bits[sb] < 16:
            bits[sb] += 1
            bitcount += 1
        elif need[sb] == bitslice + 1 and bitpool > bitcount + 1:
            bits[sb] = 2
            bitcount += 2
        sb += 1
    sb = 0
    while bitcount < bitpool and sb < M:
        if bits[sb] < 16:
            bits[sb] += 1
            bitcount += 1
        sb += 1
    return bits


def unpack(frame, bitpool, method):
    """Return BLOCKS rows of M subband samples from one 20-byte frame."""
    sf = []
    for b in frame[:4]:
        sf += [b >> 4, b & 15]
    bits = allocate(sf, bitpool, method)
    stream = int.from_bytes(frame[4:], "big")
    left = (len(frame) - 4) * 8
    rows = []
    for _ in range(BLOCKS):
        row = [0.0] * M
        for sb in range(M):
            n = bits[sb]
            if n == 0:
                continue
            left -= n
            value = (stream >> left) & ((1 << n) - 1)
            row[sb] = (2.0 ** (sf[sb] + 1)) * ((value * 2 + 1) / ((1 << n) - 1) - 1)
        rows.append(row)
    return rows


def synthesize(rows):
    out = [0.0] * (len(rows) * M + 80)
    for t, row in enumerate(rows):
        base = t * M
        for k, s in enumerate(row):
            if s == 0.0:
                continue
            f = SYN[k]
            for n in range(80):
                out[base + n] += s * f[n]
    return out


def analyze(x):
    rows = []
    for t in range(0, len(x) - 80, M):
        seg = x[t:t + 80]
        rows.append([sum(seg[79 - n] * ANA[k][n] for n in range(80)) for k in range(M)])
    return rows


def selftest():
    print("prototype sum (expect about 2):", round(sum(H), 5), "peak", H[40])
    fs = 16000
    x = [8000 * math.sin(2 * math.pi * 440 * n / fs) + 4000 * math.sin(2 * math.pi * 2300 * n / fs) for n in range(4000)]
    y = synthesize(analyze(x))
    best = None
    for d in range(-100, 200):
        xy = sum(x[n] * y[n + d] for n in range(1000, 3000))
        yy = sum(y[n + d] * y[n + d] for n in range(1000, 3000)) or 1.0
        gain = xy / yy
        sig = sum(x[n] * x[n] for n in range(1000, 3000))
        err = sum((gain * y[n + d] - x[n]) ** 2 for n in range(1000, 3000))
        snr = 10 * math.log10(sig / max(err, 1e-9))
        if best is None or snr > best[0]:
            best = (snr, d, gain)
    print("reconstruction SNR %.1f dB at delay %d samples, gain needed %.4f" % best)


def read_bursts(path):
    bursts, cur, prev = [], [], None
    for line in open(path, encoding="utf-8"):
        if line.startswith("#"):
            continue
        parts = line.split()
        data = bytes.fromhex(parts[3])
        if len(data) != 21 or data[0] != 0xFD:
            continue
        t = int(parts[1])
        if prev is not None and t - prev > 300 and cur:
            bursts.append(cur)
            cur = []
        cur.append(data[1:])
        prev = t
    if cur:
        bursts.append(cur)
    return bursts


def roughness(pcm):
    """High-frequency share of the signal; wrong settings produce buzzy noise and a high value."""
    d = sum(abs(pcm[i] - pcm[i - 1]) for i in range(1, len(pcm)))
    a = sum(abs(v) for v in pcm) or 1.0
    return d / a


def main():
    if sys.argv[1] == "selftest":
        selftest()
        return
    log, outdir = sys.argv[1], sys.argv[2]
    method = sys.argv[3] if len(sys.argv) > 3 else "loudness"
    bitpool = int(sys.argv[4]) if len(sys.argv) > 4 else 8
    os.makedirs(outdir, exist_ok=True)
    for i, frames in enumerate(read_bursts(log), 1):
        rows = []
        for f in frames:
            rows += unpack(f, bitpool, method)
        pcm = synthesize(rows)
        peak = max(abs(v) for v in pcm) or 1.0
        rms = math.sqrt(sum(v * v for v in pcm) / len(pcm))
        gain = min(1.0, 30000.0 / peak)
        path = os.path.join(outdir, "burst%d.wav" % i)
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(b"".join(int(max(-32768, min(32767, v * gain))).to_bytes(2, "little", signed=True) for v in pcm))
        print("%s %.2fs frames=%d peak=%d rms=%d roughness=%.3f" % (path, len(pcm) / 16000, len(frames), peak, rms, roughness(pcm)))


if __name__ == "__main__":
    main()

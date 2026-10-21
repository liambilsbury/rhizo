#!/usr/bin/env python3
"""Print statistics for a WAV file"""

import math
import struct
import sys
import wave

USAGE = """Usage:
  wavstat.py <file.wav>
  wavstat.py <file.wav> --tones 440 880"""


def read_mono(path):
    """return mono samples and the sample rate"""
    with wave.open(path, "rb") as w:
        channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    if width == 2:
        fmt = "<%dh" % (len(frames) // 2)
        scale = 32768.0
    elif width == 4:
        fmt = "<%di" % (len(frames) // 4)
        scale = 2147483648.0
    else:
        raise SystemExit("wavstat: unsupported sample width %d bytes" % width)
    raw = struct.unpack(fmt, frames)
    if channels > 1:
        mono = [sum(raw[i:i + channels]) / (channels * scale)
                for i in range(0, len(raw) - channels + 1, channels)]
    else:
        mono = [s / scale for s in raw]
    return mono, rate


def rms(samples):
    """return the root mean square of the samples"""
    if not samples:
        return 0.0
    return math.sqrt(sum(s * s for s in samples) / len(samples))


BLOCK = 4800


def goertzel_power(samples, rate, freq):
    """return the mean energy at one frequency"""
    n = len(samples)
    if n < BLOCK:
        return 0.0
    block = min(BLOCK, int(rate // 10) or BLOCK)
    k = int(0.5 + (block * freq) / rate)
    omega = (2.0 * math.pi * k) / block
    coeff = 2.0 * math.cos(omega)
    window = [0.5 - 0.5 * math.cos(2.0 * math.pi * i / (block - 1)) for i in range(block)]

    total = 0.0
    blocks = 0
    for start in range(0, n - block + 1, block):
        s_prev = s_prev2 = 0.0
        for i in range(block):
            s = samples[start + i] * window[i] + coeff * s_prev - s_prev2
            s_prev2 = s_prev
            s_prev = s
        power = s_prev2 * s_prev2 + s_prev * s_prev - coeff * s_prev * s_prev2
        total += power / (block * block)
        blocks += 1
    return total / blocks if blocks else 0.0


def dominant_frequency(samples, rate, lo=100.0, hi=4000.0):
    """return the strongest frequency and its power"""
    limit = min(len(samples), rate * 2)
    body = samples[:limit]
    step = rate / float(min(BLOCK, int(rate // 10) or BLOCK))
    best_f, best_p = 0.0, 0.0
    f = lo
    while f <= hi:
        p = goertzel_power(body, rate, f)
        if p > best_p:
            best_p, best_f = p, f
        f += step
    return best_f, best_p


def main(argv):
    """print statistics for a WAV file"""
    if len(argv) < 2:
        print(__doc__ + "\n\n" + USAGE)
        return 2
    path = argv[1]
    tones = []
    if "--tones" in argv:
        tones = [float(t) for t in argv[argv.index("--tones") + 1:]]

    samples, rate = read_mono(path)
    if not samples:
        print("frames 0")
        print("rms 0.000000")
        return 1
    skip = min(len(samples) // 4, int(rate * 0.2))
    body = samples[skip:]

    peak = max(abs(s) for s in body)
    print("frames %d" % len(body))
    print("rate %d" % rate)
    print("duration %.3f" % (len(body) / float(rate)))
    print("rms %.6f" % rms(body))
    print("peak %.6f" % peak)

    freq, power = dominant_frequency(body, rate)
    print("dominant_hz %.1f" % freq)
    print("dominant_power %.9f" % power)

    if tones:
        powers = [(t, goertzel_power(body, rate, t)) for t in tones]
        total = sum(p for _, p in powers) or 1e-30
        for t, p in powers:
            print("tone_%d_power %.9f" % (int(t), p))
            print("tone_%d_share %.4f" % (int(t), p / total))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

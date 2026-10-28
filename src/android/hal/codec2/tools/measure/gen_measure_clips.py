#!/usr/bin/env python3
"""make the VP9 and AV1 measurement clips and their clips.tsv manifest"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "clips")
FRAMES = 30
WARM = 64
REF_W = 3840

CLIPS = [
    ("vp9", 320, 180, 596), ("vp9", 640, 360, 1588), ("vp9", 1280, 720, 2301), ("vp9", 1920, 1080, 5242),
    ("vp9", 3840, 2160, 15315),
    ("av1", 352, 288, 354), ("av1", 640, 360, 651), ("av1", 720, 480, 1201), ("av1", 1280, 720, 2417),
    ("av1", 1920, 1080, 5710), ("av1", 3840, 2160, 11900),
]

PRESETS = {
    "fine": dict(sprites=140, grain=4, tex=90, blur=0.6, sprite_tex=100, sblur=0.5, wave=14.0, wscale=2.0, vel=90.0,
                 soften=2.0),
    "smooth": dict(sprites=260, grain=3, tex=100, blur=1.6, sprite_tex=100, sblur=1.4, wave=20.0, wscale=3.0,
                   vel=140.0, soften=1.0),
}
PRESET = "fine"


def lcg(seed):
    """yield a deterministic sequence in [0, 1)"""
    x = seed
    while True:
        x = (1103515245 * x + 12345) & 0x7FFFFFFF
        yield x / 0x7FFFFFFF


def scene(w, h, sprites, grain, tex, blur, sprite_tex, sblur, wave, wscale, vel, soften, pan=6.0, coarse=100, seed=7):
    """return the lavfi graph that draws the scene at w x h"""
    f = w / REF_W
    k = 1 + (soften - 1) * min(1.0, max(0.0, (w - 1920) / (REF_W - 1920)))
    blur, sblur = round(blur * k, 3), round(sblur * k, 3)
    r = lcg(seed)
    bw, bh = w + ((int(512 * f) + 15) & ~15), h + ((int(384 * f) + 15) & ~15)
    parts = [
        f"color=c=0x4f7a3a:s={bw}x{bh}:r=30,noise=c0s={tex}:c1s={tex // 3}:c2s={tex // 3}:allf=u,"
        f"gblur=sigma={blur}[fine]",
        f"color=c=0x6a6a50:s={max(bw // 16, 16)}x{max(bh // 16, 16)}:r=30,noise=c0s={coarse}:c1s={coarse // 2}:"
        f"c2s={coarse // 2}:allf=u,scale={bw}x{bh}:flags=bicubic[coarse]",
        "[fine][coarse]blend=all_mode=average[ground]",
    ]
    x0, y0 = f"({64 * f:.2f}+{pan * f:.3f}*in)", f"({48 * f:.2f}+{pan * 0.37 * f:.3f}*in)"
    ex, ey = f"({w}+{4 * f:.2f}*sin(in/23))", f"({h}+{3 * f:.2f}*cos(in/19))"
    parts.append(f"[ground]perspective=x0='{x0}':y0='{y0}':x1='{x0}+{ex}':y1='{y0}+{2 * f:.2f}*sin(in/17)':"
                 f"x2='{x0}-{2 * f:.2f}*sin(in/13)':y2='{y0}+{ey}':x3='{x0}+{ex}':y3='{y0}+{ey}':eval=frame,"
                 f"scale={w}:{h}:flags=bicubic,format=gbrp[bgp]")
    qw, qh = max((w // 4) & ~1, 16), max((h // 4) & ~1, 16)
    for m, s in (("mx", 11), ("my", 12)):
        parts.append(f"perlin=s={qw}x{qh}:r=30:octaves=2:persistence=0.5:xscale={wscale * 4 / f:.3f}:"
                     f"yscale={wscale * 4 / f:.3f}:tscale=2:random_mode=seed:seed={s},"
                     f"lut=c0='clip(128+(val-145)*{wave * f / 33.0:.4f},0,255)',scale={w}:{h}:flags=bicubic,"
                     f"format=gbrp[{m}]")
    parts.append("[bgp][mx][my]displace=edge=smear,format=yuv444p[bg]")
    cur = "bg"
    for i in range(sprites):
        sw_ = max(int(w * (0.04 + 0.05 * next(r))) & ~1, 8)
        sh_ = max(int(sw_ * (1.6 + 1.2 * next(r))) & ~1, 8)
        hue = int(360 * next(r))
        vx, vy = (next(r) - 0.5) * vel * f, (next(r) - 0.5) * vel * f / 4
        px, py = next(r) * w, h * (0.15 + 0.7 * next(r))
        bob, ph = (6 + 10 * next(r)) * f, 6.283 * next(r)
        sx, sy = (2 + 6 * next(r)) * f, (3 + 9 * next(r)) * f
        turn = 4 + 4 * next(r)
        parts.append(f"color=c=0x8a5a3a:s={sw_ * 3}x{sh_ * 3}:r=30,hue=h={hue},noise=c0s={sprite_tex}:"
                     f"c1s={sprite_tex // 2}:c2s={sprite_tex // 2}:allf=u,gblur=sigma={sblur},"
                     f"crop={sw_}:{sh_}:x='mod({sx:.3f}*n,{sw_ * 2})':y='mod({sy:.3f}*n,{sh_ * 2})',"
                     f"rotate=a='0.7*sin(n/{turn:.2f}+{ph:.2f})'[s{i}]")
        parts.append(f"[{cur}][s{i}]overlay=x='mod({px:.1f}+({vx:.3f})*n,{w + sw_})-{sw_}':"
                     f"y='{py:.1f}+({vy:.3f})*n+{bob:.2f}*sin(n/3+{ph:.2f})':eval=frame[o{i}]")
        cur = f"o{i}"
    parts.append(f"[{cur}]format=yuv420p,noise=alls={grain}:allf=t,format=yuv420p[out0]")
    return ";".join(parts)


def encoder_args(codec, kbps):
    """return the ffmpeg encoder arguments for a codec and bitrate"""
    if codec == "vp9":
        return ["-c:v", "libvpx-vp9", "-b:v", f"{kbps}k", "-g", str(WARM)]
    return ["-c:v", "libaom-av1", "-b:v", f"{kbps}k", "-g", str(WARM), "-cpu-used", "4",
            "-aom-params", "enable-palette=0:enable-intrabc=0"]


def run(argv):
    """run a command and return its stdout"""
    r = subprocess.run(argv, capture_output=True)
    if r.returncode != 0:
        sys.exit(f"gen_measure_clips: {' '.join(argv)[:400]} failed: {r.stderr.decode(errors='replace')[-800:]}")
    return r.stdout


def ivf_frames(data):
    """split an IVF file into its header and frames"""
    if data[:4] != b"DKIF":
        sys.exit("gen_measure_clips: not an IVF file")
    hlen = struct.unpack_from("<H", data, 6)[0]
    frames, off = [], hlen
    while off + 12 <= len(data):
        size = struct.unpack_from("<I", data, off)[0]
        frames.append(data[off + 12:off + 12 + size])
        off += 12 + size
    return data[:hlen], frames


def ivf(header, frames):
    """build an IVF file of frames with timestamps from 0"""
    h = bytearray(header)
    struct.pack_into("<I", h, 24, len(frames))
    return bytes(h) + b"".join(struct.pack("<IQ", len(fr), i) + fr for i, fr in enumerate(frames))


def kbps_of(frames):
    """return a slice's bitrate at 30 fps"""
    return sum(len(f) for f in frames) * 8 * 30 / len(frames) / 1000


def make(codec, w, h, kbps, path, preset):
    """encode a clip slice at the CTS bitrate"""
    full = path + ".full"
    rate, tries, best, lo, hi = kbps, [], None, None, None
    for _ in range(6):
        run(["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
             scene(w, h, **PRESETS[preset]), "-frames:v", str(WARM + FRAMES), "-pix_fmt", "yuv420p"]
            + encoder_args(codec, rate) + ["-f", "ivf", full])
        header, frames = ivf_frames(open(full, "rb").read())
        os.unlink(full)
        if len(frames) != WARM + FRAMES:
            sys.exit(f"gen_measure_clips: {path}: the encode has {len(frames)} frames, want {WARM + FRAMES}")
        got = kbps_of(frames[WARM:])
        tries.append((rate, round(got)))
        if best is None or abs(got - kbps) < abs(best[0] - kbps):
            best = (got, header, frames[WARM:])
        if abs(got / kbps - 1) <= 0.02:
            break
        if got < kbps:
            lo = rate if lo is None or rate > lo else lo
        else:
            hi = rate if hi is None or rate < hi else hi
        nxt = (lo + hi) // 2 if lo is not None and hi is not None else round(rate * kbps / got)
        if nxt in [t[0] for t in tries]:
            break
        rate = max(1, nxt)
    got, header, kept = best
    if abs(got / kbps - 1) > 0.06:
        sys.exit(f"gen_measure_clips: {path}: no encoder target gives {kbps} kbit/s (target, slice: {tries})")
    print(f"gen_measure_clips: {os.path.basename(path)}: encoder targets and slice kbit/s {tries}", file=sys.stderr)
    data = ivf(header, kept)
    with open(path, "wb") as f:
        f.write(data)
    types = [t.split(",")[0] for t in run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                           "frame=pict_type", "-of", "csv=p=0", path]).decode().split()]
    if len(types) != FRAMES or types[0] != "I" or "I" in types[1:]:
        sys.exit(f"gen_measure_clips: {path} decodes as {types}, want a key frame then {FRAMES - 1} others")
    err = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-i", path, "-f", "null", "-"],
                         capture_output=True).stderr.decode(errors="replace").strip()
    if err:
        sys.exit(f"gen_measure_clips: {path} does not decode cleanly: {err[-400:]}")
    return data


def name(codec, w, h):
    return f"{codec}-{w}x{h}.ivf"


def generate(out, preset=PRESET, only=None, sizes=None):
    """write the clips and manifest into out"""
    os.makedirs(out, exist_ok=True)
    ver = run(["ffmpeg", "-hide_banner", "-version"]).decode().splitlines()[0]
    rows = ["# generated by gen_measure_clips.py; do not edit",
            f"# made with: {ver}; scene preset {preset}",
            "# file\tcodec\twidth\theight\tframes\tbytes\tsha256"]
    for codec, w, h, kbps in CLIPS:
        if (only and codec not in only) or (sizes and f"{w}x{h}" not in sizes):
            continue
        data = make(codec, w, h, kbps, os.path.join(out, name(codec, w, h)), preset)
        rows.append(f"{name(codec, w, h)}\t{codec}\t{w}\t{h}\t{FRAMES}\t{len(data)}\t"
                    f"{hashlib.sha256(data).hexdigest()}")
        print(f"gen_measure_clips: {name(codec, w, h)}: {len(data)} bytes ({len(data) * 8 * 30 // FRAMES // 1000} "
              f"kbit/s, target {kbps})", file=sys.stderr)
    text = "\n".join(rows) + "\n"
    with open(os.path.join(out, "clips.tsv"), "w") as f:
        f.write(text)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--preset", default=PRESET, choices=sorted(PRESETS))
    ap.add_argument("--only", action="append", choices=["vp9", "av1"], help="make only this codec's clips")
    ap.add_argument("--size", action="append", help="make only this size's clips (WxH)")
    a = ap.parse_args()
    if a.check:
        with tempfile.TemporaryDirectory() as tmp:
            text = generate(tmp, a.preset, a.only, a.size)
        have = open(os.path.join(a.out, "clips.tsv")).read() if os.path.exists(os.path.join(a.out, "clips.tsv")) else ""
        same = [l for l in text.splitlines() if not l.startswith("#")] == \
               [l for l in have.splitlines() if not l.startswith("#")]
        print("gen_measure_clips: %s %s" % (a.out, "matches" if same else "differs (encoder versions move bytes)"))
        return 0 if same else 1
    generate(a.out, a.preset, a.only, a.size)
    print(f"gen_measure_clips: wrote {a.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

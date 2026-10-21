#!/usr/bin/env python3
import struct
import sys
import tempfile
import zlib

def read_png(path):
    """read a PNG file"""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f'{path}: not a PNG')
    pos, idat, w, h, depth, color = 8, [], 0, 0, 0, 0
    while pos < len(data):
        ln = int.from_bytes(data[pos:pos + 4], 'big')
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w = int.from_bytes(body[0:4], 'big')
            h = int.from_bytes(body[4:8], 'big')
            depth, color = body[8], body[9]
            if body[12] != 0:
                raise SystemExit(f'{path}: interlaced PNG unsupported')
        elif typ == b'IDAT':
            idat.append(body)
        elif typ == b'IEND':
            break
        pos += 12 + ln
    if depth != 8 or color not in (2, 6):
        raise SystemExit(f'{path}: only 8-bit RGB/RGBA supported (depth={depth} color={color})')
    nch = 3 if color == 2 else 4
    raw = zlib.decompress(b''.join(idat))
    stride = w * nch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    ptr = 0
    for y in range(h):
        ft = raw[ptr]; ptr += 1
        line = bytearray(raw[ptr:ptr + stride]); ptr += stride
        if ft == 1:
            for i in range(nch, stride):
                line[i] = (line[i] + line[i - nch]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                b = prev[i]
                c = prev[i - nch] if i >= nch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif ft != 0:
            raise SystemExit(f'{path}: bad filter type {ft}')
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, nch, bytes(out)

def clip(region, w, h):
    """clip a region to the image"""
    if not region:
        return 0, 0, w, h
    x, y, rw, rh = (int(v) for v in region.split(','))
    x, y = max(0, x), max(0, y)
    return x, y, min(rw, w - x), min(rh, h - y)

def fits(box, w, h):
    """check the box fits the image"""
    x, y, rw, rh = box
    return x >= 0 and y >= 0 and rw > 0 and rh > 0 and x + rw <= w and y + rh <= h

def single_stats(path, region):
    """compute statistics for an image region"""
    w, h, n, px = read_png(path)
    box = (0, 0, w, h) if region is None else tuple(int(v) for v in region.split(','))
    if not fits(box, w, h):
        raise ValueError(f'region_outside_{w}x{h}')
    x, y, rw, rh = box
    sr = sg = sb = nonblack = total = 0
    distinct = set()
    for row in range(y, y + rh):
        o = row * w * n
        for col in range(x, x + rw):
            p = o + col * n
            r, g, b = px[p], px[p + 1], px[p + 2]
            sr += r; sg += g; sb += b
            total += 1
            if r + g + b > 24:
                nonblack += 1
            if len(distinct) < 4096:
                distinct.add((r >> 3, g >> 3, b >> 3))
    return {
        'size': f'{w}x{h}',
        'pixels': total,
        'mean_r': sr / total if total else 0,
        'mean_g': sg / total if total else 0,
        'mean_b': sb / total if total else 0,
        'nonblack': nonblack,
        'nonblack_pct': 100.0 * nonblack / total if total else 0,
        'distinct': len(distinct),
    }

def write_test_png(path, w, h, pixel):
    """write a solid-color RGB PNG"""
    def chunk(tag, data):
        """return a PNG chunk with its length and checksum"""
        body = tag + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)
    row = b'\x00' + bytes(pixel) * w
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(row * h, 9)))
        f.write(chunk(b'IEND', b''))

def selftest():
    """check region refusal on a fixture PNG"""
    bad = []
    with tempfile.TemporaryDirectory() as d:
        path = f'{d}/fixture.png'
        write_test_png(path, 20, 10, (200, 100, 50))

        try:
            stats = single_stats(path, '0,0,20,10')
        except ValueError as e:
            bad.append(f'region wholly inside was refused: {e}')
        else:
            if stats['pixels'] != 200 or stats['nonblack'] != 200:
                bad.append(f'region wholly inside: pixels={stats["pixels"]} nonblack={stats["nonblack"]}, want 200/200')

        try:
            single_stats(path, '9000,9000,640,480')
        except ValueError:
            pass
        else:
            bad.append('region wholly outside the image was not refused')

        try:
            single_stats(path, '15,5,20,20')
        except ValueError:
            pass
        else:
            bad.append('region partially outside the image was not refused')

        try:
            stats = single_stats(path, None)
        except ValueError as e:
            bad.append(f'whole-image default (no --region) was refused: {e}')
        else:
            if stats['pixels'] != 200:
                bad.append(f'whole-image default: pixels={stats["pixels"]}, want 200')

    if bad:
        for b in bad:
            print(f'selftest FAIL: {b}')
        sys.exit(1)
    print('selftest OK')

def main():
    """run the selftest or compare and measure the named images"""
    args = sys.argv[1:]
    if args and args[0] == '--selftest':
        selftest()
        return
    region = region2 = None
    if '--region' in args:
        i = args.index('--region')
        region = args[i + 1]
        del args[i:i + 2]
    if '--region2' in args:
        i = args.index('--region2')
        region2 = args[i + 1]
        del args[i:i + 2]
    diff = False
    if args and args[0] == '--diff':
        diff = True
        args = args[1:]

    if diff:
        wa, ha, na, a = read_png(args[0])
        wb, hb, nb, b = read_png(args[1])
        if region2 is not None:
            boxa = tuple(int(v) for v in region.split(',')) if region else (0, 0, wa, ha)
            boxb = tuple(int(v) for v in region2.split(','))
            if not fits(boxa, wa, ha):
                print(f'changed=1\nchanged_pct=100.0\nmean_abs_delta=255\nnote=region_outside_{wa}x{ha}')
                return
            if not fits(boxb, wb, hb):
                print(f'changed=1\nchanged_pct=100.0\nmean_abs_delta=255\nnote=region2_outside_{wb}x{hb}')
                return
            if boxa[2:] != boxb[2:]:
                print('changed=1\nchanged_pct=100.0\nmean_abs_delta=255\nnote=region_sizes_differ')
                return
            x, y, rw, rh = boxa
            x2, y2 = boxb[0], boxb[1]
        else:
            if (wa, ha) != (wb, hb):
                print(f'changed=1\nchanged_pct=100.0\nmean_abs_delta=255\nnote=dimensions_differ_{wa}x{ha}_vs_{wb}x{hb}')
                return
            x, y, rw, rh = clip(region, wa, ha)
            x2, y2 = x, y
        changed = total = acc = 0
        for row in range(rh):
            oa, ob = (y + row) * wa * na, (y2 + row) * wb * nb
            for col in range(rw):
                pa, pb = oa + (x + col) * na, ob + (x2 + col) * nb
                d = abs(a[pa] - b[pb]) + abs(a[pa + 1] - b[pb + 1]) + abs(a[pa + 2] - b[pb + 2])
                acc += d
                total += 1
                if d > 24:
                    changed += 1
        print(f'pixels={total}')
        print(f'changed={changed}')
        print(f'changed_pct={100.0 * changed / total if total else 0:.3f}')
        print(f'mean_abs_delta={acc / total / 3 if total else 0:.3f}')
        return

    try:
        stats = single_stats(args[0], region)
    except ValueError as e:
        print(f'error={e}', file=sys.stderr)
        sys.exit(1)
    print(f'size={stats["size"]}')
    print(f'pixels={stats["pixels"]}')
    print(f'mean_r={stats["mean_r"]:.2f}')
    print(f'mean_g={stats["mean_g"]:.2f}')
    print(f'mean_b={stats["mean_b"]:.2f}')
    print(f'nonblack={stats["nonblack"]}')
    print(f'nonblack_pct={stats["nonblack_pct"]:.3f}')
    print(f'distinct={stats["distinct"]}')

if __name__ == '__main__':
    main()

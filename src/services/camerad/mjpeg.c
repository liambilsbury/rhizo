// decode baseline MJPEG camera frames
#include "mjpeg.h"

#include <stdlib.h>
#include <string.h>

#define MAX_DIM 8192
#define LUT_BITS 9
#define MAX_COMPONENTS 3

static const uint8_t ZIGZAG[64] = {
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,  12, 19, 26, 33, 40, 48,
    41, 34, 27, 20, 13, 6,  7,  14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23,
    30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

static const uint8_t STD_DC_LUMA_BITS[16] = {0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0};
static const uint8_t STD_DC_CHROMA_BITS[16] = {0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0};
static const uint8_t STD_DC_VALS[12] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
static const uint8_t STD_AC_LUMA_BITS[16] = {0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d};
static const uint8_t STD_AC_LUMA_VALS[162] = {
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71,
    0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
    0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83,
    0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
    0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
};
static const uint8_t STD_AC_CHROMA_BITS[16] = {0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77};
static const uint8_t STD_AC_CHROMA_VALS[162] = {
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22,
    0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
    0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36,
    0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
    0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
    0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba,
    0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
};

// a Huffman decoding table
struct huff {
    uint8_t lut_len[1 << LUT_BITS];
    uint8_t lut_sym[1 << LUT_BITS];
    int32_t maxcode[17];
    int32_t valoff[17];
    uint8_t vals[256];
    int count;
};

struct component {
    int id;
    int h, v;
    int tq;
    int td, ta;
    int pred;
    int stride;
    int rows;
    uint8_t *plane;
};

struct mjpeg_decoder {
    struct huff std_dc[2], std_ac[2];
    struct huff dht_dc[4], dht_ac[4];
    int dht_dc_set[4], dht_ac_set[4];
    uint16_t quant[4][64];
    int quant_set[4];
    int width, height, ncomp, hmax, vmax, restart;
    struct component comp[MAX_COMPONENTS];
    uint8_t *planes;
    size_t planes_cap;
};

// the entropy-coded segment bit reader
struct bits {
    const uint8_t *p, *end;
    uint64_t acc;
    int n;
    int pad;
    int marker;
    int overrun;
};

// build a Huffman table from BITS and HUFFVAL
static int huff_build(struct huff *h, const uint8_t bits[16], const uint8_t *vals, int nvals)
{
    int count = 0;
    for (int l = 0; l < 16; l++) {
        count += bits[l];
    }
    if (count > 256 || count != nvals || count == 0) {
        return -1;
    }
    memset(h->lut_len, 0, sizeof(h->lut_len));
    memcpy(h->vals, vals, (size_t)count);
    h->count = count;
    int32_t code = 0;
    int k = 0;
    for (int l = 1; l <= 16; l++) {
        int n = bits[l - 1];
        if (code + n > (1 << l) - (l == 16 ? 1 : 0)) {
            return -1;
        }
        h->valoff[l] = k - code;
        h->maxcode[l] = n ? code + n - 1 : -1;
        for (int i = 0; i < n; i++, k++, code++) {
            if (l <= LUT_BITS) {
                int shift = LUT_BITS - l;
                for (int j = 0; j < (1 << shift); j++) {
                    h->lut_len[(code << shift) | j] = (uint8_t)l;
                    h->lut_sym[(code << shift) | j] = vals[k];
                }
            }
        }
        code <<= 1;
    }
    return 0;
}

// fill the bit accumulator to at least 57 bits
static void fill(struct bits *b)
{
    while (b->n <= 56) {
        if (b->marker == 0 && b->p < b->end) {
            uint32_t byte = *b->p;
            if (byte == 0xff) {
                if (b->p + 1 >= b->end) {
                    b->marker = 0x100;
                    continue;
                }
                uint8_t next = b->p[1];
                if (next == 0x00) {
                    b->p += 2;
                } else if (next == 0xff) {
                    b->p++;
                    continue;
                } else {
                    b->marker = next;
                    continue;
                }
            } else {
                b->p++;
            }
            b->acc |= (uint64_t)byte << (56 - b->n);
            b->n += 8;
            continue;
        }
        if (b->marker == 0) {
            b->marker = 0x100;
        }
        b->n += 8;
        b->pad += 8;
    }
}

// drop k <= 32 bits from the accumulator
static inline void consume(struct bits *b, int k)
{
    int real = b->n - b->pad;
    if (k > real) {
        b->overrun = 1;
        b->pad -= k - real;
    }
    b->acc <<= k;
    b->n -= k;
}

// return the next k bits, 1 <= k <= 16
static inline uint32_t get_bits(struct bits *b, int k)
{
    if (b->n < k) {
        fill(b);
    }
    uint32_t v = (uint32_t)(b->acc >> (64 - k));
    consume(b, k);
    return v;
}

// return a k-bit magnitude as a signed value
static inline int extend(uint32_t v, int k)
{
    return v < (1u << (k - 1)) ? (int)v - (int)((1u << k) - 1) : (int)v;
}

// decode a Huffman symbol, or -1 on an unknown code
static inline int huff_decode(struct bits *b, const struct huff *h)
{
    if (b->n < 16) {
        fill(b);
    }
    uint32_t look = (uint32_t)(b->acc >> (64 - LUT_BITS));
    int len = h->lut_len[look];
    if (len != 0) {
        consume(b, len);
        return h->lut_sym[look];
    }
    uint32_t code16 = (uint32_t)(b->acc >> 48);
    for (int l = LUT_BITS + 1; l <= 16; l++) {
        int32_t code = (int32_t)(code16 >> (16 - l));
        if (code <= h->maxcode[l]) {
            int idx = h->valoff[l] + code;
            if (idx < 0 || idx >= h->count) {
                return -1;
            }
            consume(b, l);
            return h->vals[idx];
        }
    }
    return -1;
}

#define CONST_BITS 12
#define PASS1_BITS 2
#define FIX(x) ((int32_t)((x) * (1 << CONST_BITS) + 0.5))
#define C1 FIX(0.980785280)
#define C2 FIX(0.923879533)
#define C3 FIX(0.831469612)
#define C4 FIX(0.707106781)
#define C5 FIX(0.555570233)
#define C6 FIX(0.382683432)
#define C7 FIX(0.195090322)

// clamp to a byte
static inline uint8_t clamp8(int32_t v)
{
    return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}

// compute an 8-point fixed-point inverse DCT pass into OUT
#define IDCT8(X0, X1, X2, X3, X4, X5, X6, X7, OUT)                                                             \
    do {                                                                                                       \
        int32_t a0 = ((X0) + (X4)) * C4, a1 = ((X0) - (X4)) * C4;                                              \
        int32_t b0 = (X2) * C2 + (X6) * C6, b1 = (X2) * C6 - (X6) * C2;                                        \
        int32_t e0 = a0 + b0, e3 = a0 - b0, e1 = a1 + b1, e2 = a1 - b1;                                        \
        int32_t o0 = (X1) * C1 + (X3) * C3 + (X5) * C5 + (X7) * C7;                                            \
        int32_t o1 = (X1) * C3 - (X3) * C7 - (X5) * C1 - (X7) * C5;                                            \
        int32_t o2 = (X1) * C5 - (X3) * C1 + (X5) * C7 + (X7) * C3;                                            \
        int32_t o3 = (X1) * C7 - (X3) * C5 + (X5) * C3 - (X7) * C1;                                            \
        OUT(0, e0 + o0);                                                                                       \
        OUT(7, e0 - o0);                                                                                       \
        OUT(1, e1 + o1);                                                                                       \
        OUT(6, e1 - o1);                                                                                       \
        OUT(2, e2 + o2);                                                                                       \
        OUT(5, e2 - o2);                                                                                       \
        OUT(3, e3 + o3);                                                                                       \
        OUT(4, e3 - o3);                                                                                       \
    } while (0)

#define ROW_SHIFT (CONST_BITS - PASS1_BITS)
#define COL_SHIFT (CONST_BITS + PASS1_BITS + 2)

// transform a dequantized block into 8x8 samples at out
static void idct_block(const int32_t *coef, unsigned rows, unsigned rows_ac, uint8_t *out, int stride)
{
    int32_t tmp[64];
    if (rows == 1 && rows_ac == 0) {
        int32_t t = (coef[0] * C4 + (1 << (ROW_SHIFT - 1))) >> ROW_SHIFT;
        uint8_t v = clamp8(((t * C4 + (1 << (COL_SHIFT - 1))) >> COL_SHIFT) + 128);
        for (int y = 0; y < 8; y++) {
            memset(out + y * stride, v, 8);
        }
        return;
    }
    for (int r = 0; r < 8; r++) {
        const int32_t *c = coef + r * 8;
        int32_t *t = tmp + r * 8;
        if (!(rows & (1u << r))) {
            memset(t, 0, 8 * sizeof(*t));
            continue;
        }
        if (!(rows_ac & (1u << r))) {
            int32_t dc = (c[0] * C4 + (1 << (ROW_SHIFT - 1))) >> ROW_SHIFT;
            for (int x = 0; x < 8; x++) {
                t[x] = dc;
            }
            continue;
        }
#define ROW_OUT(i, v) t[i] = ((v) + (1 << (ROW_SHIFT - 1))) >> ROW_SHIFT
        IDCT8(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], ROW_OUT);
#undef ROW_OUT
    }
    if (rows == 1) {
        for (int x = 0; x < 8; x++) {
            uint8_t v = clamp8(((tmp[x] * C4 + (1 << (COL_SHIFT - 1))) >> COL_SHIFT) + 128);
            for (int y = 0; y < 8; y++) {
                out[y * stride + x] = v;
            }
        }
        return;
    }
    for (int x = 0; x < 8; x++) {
        const int32_t *t = tmp + x;
#define COL_OUT(i, v) out[(i) * stride + x] = clamp8((((v) + (1 << (COL_SHIFT - 1))) >> COL_SHIFT) + 128)
        IDCT8(t[0], t[8], t[16], t[24], t[32], t[40], t[48], t[56], COL_OUT);
#undef COL_OUT
    }
}

// read a big-endian 16-bit value
static inline int be16(const uint8_t *p)
{
    return (p[0] << 8) | p[1];
}

// parse the quantization tables of a DQT segment
static const char *parse_dqt(struct mjpeg_decoder *d, const uint8_t *p, int len)
{
    while (len > 0) {
        int pq = p[0] >> 4, tq = p[0] & 15;
        int need = 1 + 64 * (pq ? 2 : 1);
        if (pq > 1 || tq > 3 || len < need) {
            return "bad DQT";
        }
        for (int k = 0; k < 64; k++) {
            int q = pq ? be16(p + 1 + 2 * k) : p[1 + k];
            if (q == 0) {
                return "zero quantizer in DQT";
            }
            d->quant[tq][k] = (uint16_t)q;
        }
        d->quant_set[tq] = 1;
        p += need;
        len -= need;
    }
    return NULL;
}

// parse the Huffman tables of a DHT segment
static const char *parse_dht(struct mjpeg_decoder *d, const uint8_t *p, int len)
{
    while (len > 0) {
        if (len < 17) {
            return "short DHT";
        }
        int tc = p[0] >> 4, th = p[0] & 15;
        if (tc > 1 || th > 3) {
            return "bad DHT class or id";
        }
        int count = 0;
        for (int l = 0; l < 16; l++) {
            count += p[1 + l];
        }
        if (count > 256 || len < 17 + count) {
            return "bad DHT length";
        }
        struct huff *h = tc ? &d->dht_ac[th] : &d->dht_dc[th];
        if (huff_build(h, p + 1, p + 17, count) != 0) {
            return "DHT codes overflow";
        }
        if (tc) {
            d->dht_ac_set[th] = 1;
        } else {
            d->dht_dc_set[th] = 1;
        }
        p += 17 + count;
        len -= 17 + count;
    }
    return NULL;
}

// parse the frame size and components of a SOF0/SOF1 segment
static const char *parse_sof(struct mjpeg_decoder *d, const uint8_t *p, int len)
{
    if (len < 6) {
        return "short SOF";
    }
    if (p[0] != 8) {
        return "not 8-bit";
    }
    d->height = be16(p + 1);
    d->width = be16(p + 3);
    d->ncomp = p[5];
    if (d->height == 0 || d->width == 0 || d->height > MAX_DIM || d->width > MAX_DIM) {
        return "bad frame size";
    }
    if ((d->ncomp != 1 && d->ncomp != 3) || len < 6 + 3 * d->ncomp) {
        return "not one or three components";
    }
    d->hmax = d->vmax = 1;
    for (int i = 0; i < d->ncomp; i++) {
        struct component *c = &d->comp[i];
        c->id = p[6 + 3 * i];
        c->h = p[7 + 3 * i] >> 4;
        c->v = p[7 + 3 * i] & 15;
        c->tq = p[8 + 3 * i];
        if (c->h < 1 || c->h > 2 || c->v < 1 || c->v > 2 || c->tq > 3) {
            return "unsupported sampling or quantizer";
        }
        for (int j = 0; j < i; j++) {
            if (d->comp[j].id == c->id) {
                return "repeated component id";
            }
        }
        if (c->h > d->hmax) {
            d->hmax = c->h;
        }
        if (c->v > d->vmax) {
            d->vmax = c->v;
        }
    }
    if (d->ncomp == 1) {
        d->comp[0].h = d->comp[0].v = d->hmax = d->vmax = 1;
    } else if (d->comp[0].h != d->hmax || d->comp[0].v != d->vmax) {
        return "unsupported sampling (chroma finer than luma)";
    }
    return NULL;
}

// size the component planes in whole MCUs
static const char *alloc_planes(struct mjpeg_decoder *d)
{
    int mcus_x = (d->width + 8 * d->hmax - 1) / (8 * d->hmax);
    int mcus_y = (d->height + 8 * d->vmax - 1) / (8 * d->vmax);
    size_t total = 0;
    for (int i = 0; i < d->ncomp; i++) {
        struct component *c = &d->comp[i];
        c->stride = mcus_x * c->h * 8;
        c->rows = mcus_y * c->v * 8;
        total += (size_t)c->stride * (size_t)c->rows;
    }
    if (total > d->planes_cap) {
        uint8_t *p = realloc(d->planes, total);
        if (p == NULL) {
            return "out of memory";
        }
        d->planes = p;
        d->planes_cap = total;
    }
    size_t off = 0;
    for (int i = 0; i < d->ncomp; i++) {
        d->comp[i].plane = d->planes + off;
        off += (size_t)d->comp[i].stride * (size_t)d->comp[i].rows;
    }
    return NULL;
}

// step over the restart marker RSTn and reset the DC values
static const char *take_restart(struct mjpeg_decoder *d, struct bits *b, int n)
{
    const uint8_t *p = b->p;
    if (b->marker == 0) {
        while (p + 1 < b->end && p[0] == 0xff && p[1] == 0xff) {
            p++;
        }
    }
    if (p + 1 >= b->end || p[0] != 0xff || p[1] != 0xd0 + n) {
        return "missing restart marker";
    }
    b->p = p + 2;
    b->acc = 0;
    b->n = 0;
    b->pad = 0;
    b->marker = 0;
    for (int i = 0; i < d->ncomp; i++) {
        d->comp[i].pred = 0;
    }
    return NULL;
}

// decode a block's dequantized coefficients into coef
static const char *decode_block(struct bits *b, const struct huff *dc, const struct huff *ac, const uint16_t *q,
                                int *pred, int32_t *coef, unsigned *rows, unsigned *rows_ac)
{
    int s = huff_decode(b, dc);
    if (s < 0 || s > 11) {
        return "bad DC code";
    }
    int diff = s ? extend(get_bits(b, s), s) : 0;
    int p = *pred + diff;
    p = p < -32768 ? -32768 : p > 32767 ? 32767 : p;
    *pred = p;
    int32_t v = p * (int32_t)q[0];
    coef[0] = v < -2048 ? -2048 : v > 2047 ? 2047 : v;
    *rows = 1;
    *rows_ac = 0;
    for (int k = 1; k < 64;) {
        int rs = huff_decode(b, ac);
        if (rs < 0) {
            return "bad AC code";
        }
        int r = rs >> 4;
        s = rs & 15;
        if (s == 0) {
            if (r != 15) {
                break;
            }
            k += 16;
            continue;
        }
        k += r;
        if (k > 63 || s > 10) {
            return "AC coefficient out of range";
        }
        int n = ZIGZAG[k];
        v = extend(get_bits(b, s), s) * (int32_t)q[k];
        coef[n] = v < -2048 ? -2048 : v > 2047 ? 2047 : v;
        *rows |= 1u << (n >> 3);
        if (n & 7) {
            *rows_ac |= 1u << (n >> 3);
        }
        k++;
    }
    return NULL;
}

// decode an SOS segment's interleaved scan into the planes
static const char *decode_scan(struct mjpeg_decoder *d, const uint8_t *p, int len, const uint8_t *data_start,
                               const uint8_t *end)
{
    if (d->width == 0) {
        return "SOS before SOF";
    }
    if (len < 1 || p[0] != d->ncomp || len < 1 + 2 * d->ncomp + 3) {
        return "scan does not interleave every component";
    }
    const struct huff *dc[MAX_COMPONENTS], *ac[MAX_COMPONENTS];
    for (int i = 0; i < d->ncomp; i++) {
        int id = p[1 + 2 * i], td = p[2 + 2 * i] >> 4, ta = p[2 + 2 * i] & 15;
        if (id != d->comp[i].id) {
            return "scan component order differs from the frame's";
        }
        if (td > 3 || ta > 3) {
            return "bad scan table";
        }
        if (d->dht_dc_set[td]) {
            dc[i] = &d->dht_dc[td];
        } else if (td <= 1) {
            dc[i] = &d->std_dc[td];
        } else {
            return "scan names an undefined DC table";
        }
        if (d->dht_ac_set[ta]) {
            ac[i] = &d->dht_ac[ta];
        } else if (ta <= 1) {
            ac[i] = &d->std_ac[ta];
        } else {
            return "scan names an undefined AC table";
        }
        if (!d->quant_set[d->comp[i].tq]) {
            return "component names an undefined quantizer";
        }
        d->comp[i].pred = 0;
    }
    const uint8_t *tail = p + 1 + 2 * d->ncomp;
    if (tail[0] != 0 || tail[1] != 63 || tail[2] != 0) {
        return "not a sequential scan";
    }
    const char *err = alloc_planes(d);
    if (err != NULL) {
        return err;
    }
    int mcus_x = (d->width + 8 * d->hmax - 1) / (8 * d->hmax);
    int mcus_y = (d->height + 8 * d->vmax - 1) / (8 * d->vmax);
    struct bits b = {data_start, end, 0, 0, 0, 0, 0};
    int32_t coef[64];
    memset(coef, 0, sizeof(coef));
    int done = 0, next_rst = 0;
    for (int my = 0; my < mcus_y; my++) {
        for (int mx = 0; mx < mcus_x; mx++) {
            if (d->restart && done > 0 && done % d->restart == 0) {
                if ((err = take_restart(d, &b, next_rst)) != NULL) {
                    return err;
                }
                next_rst = (next_rst + 1) & 7;
            }
            for (int i = 0; i < d->ncomp; i++) {
                struct component *c = &d->comp[i];
                const uint16_t *q = d->quant[c->tq];
                for (int v = 0; v < c->v; v++) {
                    for (int h = 0; h < c->h; h++) {
                        unsigned rows, rows_ac;
                        err = decode_block(&b, dc[i], ac[i], q, &c->pred, coef, &rows, &rows_ac);
                        if (err != NULL) {
                            return err;
                        }
                        uint8_t *out = c->plane + (size_t)((my * c->v + v) * 8) * (size_t)c->stride +
                                       (size_t)((mx * c->h + h) * 8);
                        idct_block(coef, rows, rows_ac, out, c->stride);
                        for (int r = 0; r < 8; r++) {
                            if (rows & (1u << r)) {
                                memset(coef + r * 8, 0, 8 * sizeof(coef[0]));
                            }
                        }
                    }
                }
            }
            if (b.overrun) {
                return "truncated scan";
            }
            done++;
        }
    }
    return NULL;
}

// write the planes to dst as packed I420
static void write_i420(const struct mjpeg_decoder *d, uint8_t *dst)
{
    int w = d->width, h = d->height, cw = w / 2, ch = h / 2;
    const struct component *y = &d->comp[0];
    for (int r = 0; r < h; r++) {
        memcpy(dst + (size_t)r * w, y->plane + (size_t)r * y->stride, (size_t)w);
    }
    uint8_t *du = dst + (size_t)w * h, *dv = du + (size_t)cw * ch;
    if (d->ncomp == 1) {
        memset(du, 128, (size_t)cw * ch * 2);
        return;
    }
    for (int k = 1; k <= 2; k++) {
        const struct component *c = &d->comp[k];
        int fx = 2 * c->h / d->hmax, fy = 2 * c->v / d->vmax;
        uint8_t *o = k == 1 ? du : dv;
        for (int r = 0; r < ch; r++) {
            const uint8_t *s0 = c->plane + (size_t)(r * fy) * c->stride;
            const uint8_t *s1 = fy == 2 ? s0 + c->stride : s0;
            uint8_t *orow = o + (size_t)r * cw;
            if (fx == 1 && fy == 1) {
                memcpy(orow, s0, (size_t)cw);
            } else if (fx == 1) {
                for (int x = 0; x < cw; x++) {
                    orow[x] = (uint8_t)((s0[x] + s1[x] + 1) >> 1);
                }
            } else {
                for (int x = 0; x < cw; x++) {
                    orow[x] = (uint8_t)((s0[2 * x] + s0[2 * x + 1] + s1[2 * x] + s1[2 * x + 1] + 2) >> 2);
                }
            }
        }
    }
}

struct mjpeg_decoder *mjpeg_decoder_new(void)
{
    struct mjpeg_decoder *d = calloc(1, sizeof(*d));
    if (d == NULL) {
        return NULL;
    }
    if (huff_build(&d->std_dc[0], STD_DC_LUMA_BITS, STD_DC_VALS, 12) != 0 ||
        huff_build(&d->std_dc[1], STD_DC_CHROMA_BITS, STD_DC_VALS, 12) != 0 ||
        huff_build(&d->std_ac[0], STD_AC_LUMA_BITS, STD_AC_LUMA_VALS, 162) != 0 ||
        huff_build(&d->std_ac[1], STD_AC_CHROMA_BITS, STD_AC_CHROMA_VALS, 162) != 0) {
        free(d);
        return NULL;
    }
    return d;
}

void mjpeg_decoder_free(struct mjpeg_decoder *d)
{
    if (d != NULL) {
        free(d->planes);
        free(d);
    }
}

int mjpeg_decode(struct mjpeg_decoder *d, const uint8_t *data, size_t size, uint32_t width, uint32_t height,
                 uint8_t *dst, const char **why)
{
    const char *err = NULL;
    memset(d->dht_dc_set, 0, sizeof(d->dht_dc_set));
    memset(d->dht_ac_set, 0, sizeof(d->dht_ac_set));
    memset(d->quant_set, 0, sizeof(d->quant_set));
    d->width = d->height = d->ncomp = d->restart = 0;
    if (size < 4 || data[0] != 0xff || data[1] != 0xd8) {
        *why = "no SOI";
        return -1;
    }
    const uint8_t *end = data + size;
    const uint8_t *p = data + 2;
    for (;;) {
        if (p >= end || *p != 0xff) {
            *why = "expected a marker";
            return -1;
        }
        while (p < end && *p == 0xff) {
            p++;
        }
        if (p >= end) {
            *why = "truncated before a marker";
            return -1;
        }
        int marker = *p++;
        if (marker == 0xd8 || marker == 0xd9 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
            *why = marker == 0xd9 ? "EOI before any scan" : "stray marker";
            return -1;
        }
        if (end - p < 2) {
            *why = "truncated marker segment";
            return -1;
        }
        int len = be16(p);
        if (len < 2 || len > end - p) {
            *why = "marker segment overruns the frame";
            return -1;
        }
        const uint8_t *seg = p + 2;
        int seglen = len - 2;
        p += len;
        switch (marker) {
        case 0xc0:
        case 0xc1:
            if (d->width != 0) {
                err = "second SOF";
            } else {
                err = parse_sof(d, seg, seglen);
            }
            if (err == NULL && ((uint32_t)d->width != width || (uint32_t)d->height != height)) {
                err = "frame size differs from the stream's";
            }
            break;
        case 0xc4:
            err = parse_dht(d, seg, seglen);
            break;
        case 0xdb:
            err = parse_dqt(d, seg, seglen);
            break;
        case 0xdd:
            if (seglen != 2) {
                err = "bad DRI";
            } else {
                d->restart = be16(seg);
            }
            break;
        case 0xda:
            err = decode_scan(d, seg, seglen, p, end);
            if (err == NULL) {
                write_i420(d, dst);
                return 0;
            }
            break;
        default:
            if ((marker >= 0xe0 && marker <= 0xef) || marker == 0xfe) {
                break;
            }
            err = marker >= 0xc0 && marker <= 0xcf ? "not a baseline or extended Huffman JPEG"
                                                     : "unsupported marker";
            break;
        }
        if (err != NULL) {
            *why = err;
            return -1;
        }
    }
}

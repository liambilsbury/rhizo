#include "image_ops.h"

#include <math.h>
#include <string.h>

// scale, convert and encode I420 frames as JPEG

namespace rhizo::camera {
namespace {

constexpr int32_t kMaxDim = 4096;
constexpr int64_t kHalf = 1 << 15;
constexpr uint32_t kRound = 1u << 15;

// return true when a source view is within the size limits
bool ValidView(const I420View& v) {
  return v.data != nullptr && v.width > 0 && v.height > 0 && v.width <= kMaxDim && v.height <= kMaxDim;
}

// return true when a destination size is within the limits
bool ValidSize(int32_t w, int32_t h) {
  return w > 0 && h > 0 && w <= kMaxDim && h <= kMaxDim;
}

int32_t Min(int32_t a, int32_t b) { return a < b ? a : b; }
int32_t Max(int32_t a, int32_t b) { return a > b ? a : b; }

// mapping of destination samples onto a source axis
struct Axis {
  int64_t origin;
  int64_t num;
  int64_t den;
  int32_t lo;
  int32_t hi;
};

// return the clamped 16.16 source position of a destination sample
inline int64_t SourcePos(const Axis& a, int32_t j) {
  const int64_t p = a.origin + (((2 * static_cast<int64_t>(j) + 1) * a.num) << 16) / (2 * a.den) - kHalf;
  const int64_t lo = static_cast<int64_t>(a.lo) << 16, hi = static_cast<int64_t>(a.hi) << 16;
  return p < lo ? lo : p > hi ? hi : p;
}

// the horizontal taps of each destination column
struct Taps {
  uint16_t idx[kMaxDim];
  uint8_t frac[kMaxDim];
};

// compute the taps of dw destination columns
void MakeTaps(const Axis& ax, int32_t dw, Taps* t) {
  for (int32_t j = 0; j < dw; ++j) {
    const int64_t p = SourcePos(ax, j);
    t->idx[j] = static_cast<uint16_t>((p >> 16) - ax.lo);
    t->frac[j] = static_cast<uint8_t>(p >> 8);
  }
}

// scale a destination row from two blended source rows
void ScaleRow(const uint8_t* src, int32_t src_stride, const Axis& ax, const Taps& t, const Axis& ay, int32_t i,
              uint16_t* __restrict row, uint8_t* __restrict out, int32_t pixel_stride, int32_t dw) {
  const int32_t n = ax.hi - ax.lo + 1;
  const int64_t p = SourcePos(ay, i);
  const int32_t y0 = static_cast<int32_t>(p >> 16);
  const int32_t y1 = y0 < ay.hi ? y0 + 1 : y0;
  const uint32_t fy = static_cast<uint32_t>(p >> 8) & 255;
  const uint8_t* __restrict r0 = src + static_cast<ptrdiff_t>(y0) * src_stride + ax.lo;
  const uint8_t* __restrict r1 = src + static_cast<ptrdiff_t>(y1) * src_stride + ax.lo;
  if (fy == 0) {
    for (int32_t k = 0; k < n; ++k) row[k] = static_cast<uint16_t>(r0[k] << 8);
  } else {
    const uint32_t gy = 256 - fy;
    for (int32_t k = 0; k < n; ++k) row[k] = static_cast<uint16_t>(r0[k] * gy + r1[k] * fy);
  }
  row[n] = row[n - 1];
  const uint16_t* __restrict idx = t.idx;
  const uint8_t* __restrict frac = t.frac;
  for (int32_t j = 0; j < dw; ++j) {
    const uint32_t f = frac[j];
    const uint16_t* s = row + idx[j];
    out[static_cast<ptrdiff_t>(j) * pixel_stride] = static_cast<uint8_t>((s[0] * (256 - f) + s[1] * f + kRound) >> 16);
  }
}

// bilinear-scale a window of a source plane into a destination
void ScalePlane(const uint8_t* src, int32_t src_stride, const Axis& ax, const Axis& ay, uint8_t* dst,
                int32_t row_stride, int32_t pixel_stride, int32_t dw, int32_t dh) {
  Taps t;
  uint16_t row[kMaxDim + 1];
  MakeTaps(ax, dw, &t);
  for (int32_t i = 0; i < dh; ++i) {
    ScaleRow(src, src_stride, ax, t, ay, i, row, dst + static_cast<ptrdiff_t>(i) * row_stride, pixel_stride, dw);
  }
}

// a crop clamped to its source
struct Window {
  int32_t left;
  int32_t top;
  int32_t width;
  int32_t height;
};

// return false when a clamped crop is empty
bool ClampCrop(const I420View& src, const Rect& crop, Window* w) {
  const int64_t right = static_cast<int64_t>(crop.left) + crop.width;
  const int64_t bottom = static_cast<int64_t>(crop.top) + crop.height;
  w->left = Max(crop.left, 0);
  w->top = Max(crop.top, 0);
  if (w->left >= src.width || w->top >= src.height) return false;
  w->width = static_cast<int32_t>((right < src.width ? right : src.width) - w->left);
  w->height = static_cast<int32_t>((bottom < src.height ? bottom : src.height) - w->top);
  return w->width > 0 && w->height > 0;
}

// return the chroma samples that a luma span overlaps
void ChromaSpan(int32_t start, int32_t len, int32_t n, int32_t* lo, int32_t* hi) {
  *lo = Min(start / 2, n - 1);
  *hi = Max(*lo, Min((start + len - 1) / 2, n - 1));
}

// convert a YUV row to RGBA by full-range BT.601
void YuvRowToRgba(const uint8_t* __restrict y, const uint8_t* __restrict u, const uint8_t* __restrict v,
                  uint8_t* __restrict out, int32_t n) {
  for (int32_t j = 0; j < n; ++j) {
    const int32_t yy = (y[j] << 16) + static_cast<int32_t>(kRound);
    const int32_t cb = u[j] - 128, cr = v[j] - 128;
    const int32_t r = (yy + 91881 * cr) >> 16;
    const int32_t g = (yy - 22554 * cb - 46802 * cr) >> 16;
    const int32_t b = (yy + 116130 * cb) >> 16;
    out[4 * j] = static_cast<uint8_t>(r < 0 ? 0 : r > 255 ? 255 : r);
    out[4 * j + 1] = static_cast<uint8_t>(g < 0 ? 0 : g > 255 ? 255 : g);
    out[4 * j + 2] = static_cast<uint8_t>(b < 0 ? 0 : b > 255 ? 255 : b);
    out[4 * j + 3] = 255;
  }
}

// fill destination samples with a value
void FillPlane(uint8_t* dst, int32_t row_stride, int32_t pixel_stride, int32_t dw, int32_t dh, uint8_t v) {
  for (int32_t i = 0; i < dh; ++i) {
    uint8_t* out = dst + static_cast<ptrdiff_t>(i) * row_stride;
    for (int32_t j = 0; j < dw; ++j) out[static_cast<ptrdiff_t>(j) * pixel_stride] = v;
  }
}

constexpr uint8_t kLumaQuant[64] = {
    16, 11, 10, 16, 24,  40,  51,  61,  12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,  14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,  24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
};

constexpr uint8_t kChromaQuant[64] = {
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
};

constexpr uint8_t kDcLumaBits[16] = {0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0};
constexpr uint8_t kDcChromaBits[16] = {0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0};
constexpr uint8_t kDcVals[12] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};

constexpr uint8_t kAcLumaBits[16] = {0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125};
constexpr uint8_t kAcLumaVals[162] = {
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

constexpr uint8_t kAcChromaBits[16] = {0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119};
constexpr uint8_t kAcChromaVals[162] = {
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

// Huffman codes and sizes by symbol
struct HuffCodes {
  uint16_t code[256];
  uint8_t size[256];
};

// build Huffman codes from BITS and HUFFVAL
constexpr HuffCodes MakeCodes(const uint8_t (&bits)[16], const uint8_t* vals) {
  HuffCodes h{};
  uint32_t code = 0;
  int k = 0;
  for (int len = 1; len <= 16; ++len) {
    for (int i = 0; i < bits[len - 1]; ++i, ++k) {
      h.code[vals[k]] = static_cast<uint16_t>(code++);
      h.size[vals[k]] = static_cast<uint8_t>(len);
    }
    code <<= 1;
  }
  return h;
}

// return the symbol count of BITS
constexpr int CountBits(const uint8_t (&bits)[16]) {
  int n = 0;
  for (uint8_t b : bits) n += b;
  return n;
}

// return true when DC categories 0..11 have codes
constexpr bool CoversDc(const HuffCodes& h) {
  for (int s = 0; s <= 11; ++s)
    if (h.size[s] == 0) return false;
  return true;
}

// return true when EOB, ZRL and the run/size symbols have codes
constexpr bool CoversAc(const HuffCodes& h) {
  if (h.size[0x00] == 0 || h.size[0xf0] == 0) return false;
  for (int r = 0; r < 16; ++r)
    for (int s = 1; s <= 10; ++s)
      if (h.size[(r << 4) | s] == 0) return false;
  return true;
}

constexpr HuffCodes kDcLuma = MakeCodes(kDcLumaBits, kDcVals);
constexpr HuffCodes kDcChroma = MakeCodes(kDcChromaBits, kDcVals);
constexpr HuffCodes kAcLuma = MakeCodes(kAcLumaBits, kAcLumaVals);
constexpr HuffCodes kAcChroma = MakeCodes(kAcChromaBits, kAcChromaVals);
static_assert(CountBits(kDcLumaBits) == 12 && CountBits(kDcChromaBits) == 12, "DC BITS count 12 symbols");
static_assert(CountBits(kAcLumaBits) == 162 && CountBits(kAcChromaBits) == 162, "AC BITS count 162 symbols");
static_assert(CoversDc(kDcLuma) && CoversDc(kDcChroma), "every DC category has a code");
static_assert(CoversAc(kAcLuma) && CoversAc(kAcChroma), "every AC symbol has a code");

// the natural index of each zigzag position
struct ZigZag {
  uint8_t natural[64];
};

// build the zigzag order
constexpr ZigZag MakeZigZag() {
  ZigZag z{};
  int k = 0;
  for (int d = 0; d < 15; ++d) {
    for (int i = 0; i <= d; ++i) {
      const int row = d % 2 == 0 ? d - i : i;
      const int col = d - row;
      if (row < 8 && col < 8) z.natural[k++] = static_cast<uint8_t>(row * 8 + col);
    }
  }
  return z;
}

constexpr ZigZag kZigZag = MakeZigZag();
static_assert(kZigZag.natural[2] == 8 && kZigZag.natural[3] == 16 && kZigZag.natural[63] == 63,
              "zigzag starts 0, 1, 8, 16 and ends at 63");

// the 8-point DCT-II matrix and its transpose
struct DctBasis {
  float m[8][8];
  float t[8][8];
};

// return the DCT basis
const DctBasis& Basis() {
  static const DctBasis basis = [] {
    constexpr double kPi = 3.14159265358979323846;
    DctBasis b{};
    for (int u = 0; u < 8; ++u) {
      for (int x = 0; x < 8; ++x) {
        const double c = (u == 0 ? sqrt(0.5) : 1.0) * 0.5 * cos((2 * x + 1) * u * kPi / 16);
        b.m[u][x] = static_cast<float>(c);
        b.t[x][u] = static_cast<float>(c);
      }
    }
    return b;
  }();
  return basis;
}

// load a level-shifted 8x8 block with edge pixels repeated
void LoadBlock(const uint8_t* plane, int32_t w, int32_t h, int32_t x0, int32_t y0, float* blk) {
  if (w <= 0 || h <= 0) {
    for (int k = 0; k < 64; ++k) blk[k] = 0.0f;
    return;
  }
  if (x0 + 8 <= w && y0 + 8 <= h) {
    for (int r = 0; r < 8; ++r) {
      const uint8_t* s = plane + static_cast<ptrdiff_t>(y0 + r) * w + x0;
      for (int c = 0; c < 8; ++c) blk[r * 8 + c] = static_cast<float>(s[c]) - 128.0f;
    }
    return;
  }
  for (int r = 0; r < 8; ++r) {
    const uint8_t* s = plane + static_cast<ptrdiff_t>(Min(y0 + r, h - 1)) * w;
    for (int c = 0; c < 8; ++c) blk[r * 8 + c] = static_cast<float>(s[Min(x0 + c, w - 1)]) - 128.0f;
  }
}

// compute the forward DCT of a block
void Fdct(const DctBasis& b, const float* in, float* out) {
  float tmp[64];
  for (int y = 0; y < 8; ++y) {
    float acc[8] = {};
    for (int x = 0; x < 8; ++x) {
      const float s = in[y * 8 + x];
      for (int u = 0; u < 8; ++u) acc[u] += s * b.t[x][u];
    }
    memcpy(tmp + y * 8, acc, sizeof(acc));
  }
  for (int v = 0; v < 8; ++v) {
    float acc[8] = {};
    for (int y = 0; y < 8; ++y) {
      const float c = b.m[v][y];
      for (int u = 0; u < 8; ++u) acc[u] += c * tmp[y * 8 + u];
    }
    memcpy(out + v * 8, acc, sizeof(acc));
  }
}

// a zigzag quantisation table and its natural-order reciprocals
struct Quant {
  uint8_t zigzag[64];
  float recip[64];
};

// scale a quantisation table by the IJG quality formula
void MakeQuant(const uint8_t* base, int quality, Quant* q) {
  const int scale = quality < 50 ? 5000 / quality : 200 - 2 * quality;
  uint8_t natural[64];
  for (int k = 0; k < 64; ++k) {
    const int v = (base[k] * scale + 50) / 100;
    natural[k] = static_cast<uint8_t>(v < 1 ? 1 : v > 255 ? 255 : v);
    q->recip[k] = 1.0f / static_cast<float>(natural[k]);
  }
  for (int k = 0; k < 64; ++k) q->zigzag[k] = natural[kZigZag.natural[k]];
}

// quantise coefficients into zigzag order within baseline ranges
void Quantize(const float* coef, const Quant& q, int16_t* zz) {
  int32_t nat[64];
  for (int k = 0; k < 64; ++k) {
    const float v = coef[k] * q.recip[k];
    nat[k] = static_cast<int32_t>(v + (v >= 0.0f ? 0.5f : -0.5f));
  }
  for (int k = 0; k < 64; ++k) {
    const int32_t v = nat[kZigZag.natural[k]];
    const int32_t lim = k == 0 ? 2047 : 1023;
    zz[k] = static_cast<int16_t>(v < -lim ? -lim : v > lim ? lim : v);
  }
}

// bounded output buffer with an overflow flag
struct Out {
  uint8_t* p;
  size_t pos;
  size_t cap;
  bool full;

  void Byte(uint8_t b) {
    if (pos < cap) {
      p[pos++] = b;
    } else {
      full = true;
    }
  }
  void Word(uint32_t v) {
    Byte(static_cast<uint8_t>(v >> 8));
    Byte(static_cast<uint8_t>(v));
  }
  void Bytes(const uint8_t* b, size_t n) {
    for (size_t i = 0; i < n; ++i) Byte(b[i]);
  }
};

// MSB-first bit writer with 0xFF byte stuffing
struct BitWriter {
  Out* out;
  uint64_t acc;
  int bits;

  // append up to 32 bits
  void Put(uint32_t value, int n) {
    acc = (acc << n) | value;
    bits += n;
    if (bits >= 32) {
      bits -= 32;
      Emit(static_cast<uint32_t>(acc >> bits));
    }
  }
  // write four stuffed bytes
  void Emit(uint32_t w) {
    const uint32_t inv = ~w;
    const bool has_ff = ((inv - 0x01010101u) & ~inv & 0x80808080u) != 0;
    if (!has_ff && out->pos + 4 <= out->cap) {
      uint8_t* d = out->p + out->pos;
      d[0] = static_cast<uint8_t>(w >> 24);
      d[1] = static_cast<uint8_t>(w >> 16);
      d[2] = static_cast<uint8_t>(w >> 8);
      d[3] = static_cast<uint8_t>(w);
      out->pos += 4;
      return;
    }
    for (int s = 24; s >= 0; s -= 8) {
      const uint8_t b = static_cast<uint8_t>(w >> s);
      out->Byte(b);
      if (b == 0xff) out->Byte(0);
    }
  }
  // pad the last byte with 1 bits
  void Finish() {
    const int pad = (8 - bits % 8) % 8;
    if (pad != 0) {
      acc = (acc << pad) | ((1u << pad) - 1);
      bits += pad;
    }
    while (bits >= 8) {
      bits -= 8;
      const uint8_t b = static_cast<uint8_t>(acc >> bits);
      out->Byte(b);
      if (b == 0xff) out->Byte(0);
    }
  }
};

// return the magnitude category of a nonzero value
inline int Category(int32_t v) {
  const uint32_t a = static_cast<uint32_t>(v < 0 ? -v : v);
  return 32 - __builtin_clz(a);
}

// write a Huffman symbol and its extra bits
inline void PutValue(BitWriter& bw, const HuffCodes& h, int symbol, int32_t v, int s) {
  const uint32_t extra = static_cast<uint32_t>(v < 0 ? v - 1 : v) & ((1u << s) - 1);
  bw.Put((static_cast<uint32_t>(h.code[symbol]) << s) | extra, h.size[symbol] + s);
}

// encode the coefficients of an 8x8 block
void EncodeBlock(BitWriter& bw, const int16_t* zz, int32_t* pred, const HuffCodes& dc, const HuffCodes& ac) {
  const int32_t diff = zz[0] - *pred;
  *pred = zz[0];
  if (diff == 0) {
    bw.Put(dc.code[0], dc.size[0]);
  } else {
    const int s = Category(diff);
    PutValue(bw, dc, s, diff, s);
  }
  int last = 63;
  while (last > 0 && zz[last] == 0) --last;
  int run = 0;
  for (int k = 1; k <= last; ++k) {
    const int32_t v = zz[k];
    if (v == 0) {
      ++run;
      continue;
    }
    while (run > 15) {
      bw.Put(ac.code[0xf0], ac.size[0xf0]);
      run -= 16;
    }
    const int s = Category(v);
    PutValue(bw, ac, (run << 4) | s, v, s);
    run = 0;
  }
  if (last < 63) bw.Put(ac.code[0x00], ac.size[0x00]);
}

// write a DHT table entry
void WriteHuffTable(Out& o, uint8_t class_id, const uint8_t (&bits)[16], const uint8_t* vals, int count) {
  o.Byte(class_id);
  o.Bytes(bits, 16);
  o.Bytes(vals, static_cast<size_t>(count));
}

// write the markers from SOI through SOS
void WriteHeaders(Out& o, int32_t w, int32_t h, const Quant& luma, const Quant& chroma) {
  o.Word(0xffd8);
  static const uint8_t kJfif[] = {0xff, 0xe0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00, 0x01, 0x01,
                                  0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00};
  o.Bytes(kJfif, sizeof(kJfif));
  o.Word(0xffdb);
  o.Word(2 + 2 * 65);
  o.Byte(0x00);
  o.Bytes(luma.zigzag, 64);
  o.Byte(0x01);
  o.Bytes(chroma.zigzag, 64);
  o.Word(0xffc0);
  o.Word(8 + 3 * 3);
  o.Byte(8);
  o.Word(static_cast<uint32_t>(h));
  o.Word(static_cast<uint32_t>(w));
  o.Byte(3);
  static const uint8_t kComponents[] = {1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1};
  o.Bytes(kComponents, sizeof(kComponents));
  o.Word(0xffc4);
  o.Word(2 + 4 * 17 + 12 + 12 + 162 + 162);
  WriteHuffTable(o, 0x00, kDcLumaBits, kDcVals, 12);
  WriteHuffTable(o, 0x10, kAcLumaBits, kAcLumaVals, 162);
  WriteHuffTable(o, 0x01, kDcChromaBits, kDcVals, 12);
  WriteHuffTable(o, 0x11, kAcChromaBits, kAcChromaVals, 162);
  o.Word(0xffda);
  o.Word(6 + 2 * 3);
  static const uint8_t kScan[] = {3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0};
  o.Bytes(kScan, sizeof(kScan));
}

}

// return the largest centred even crop of dst's aspect ratio
Rect CenterCropFor(int32_t src_width, int32_t src_height, int32_t dst_width, int32_t dst_height) {
  if (src_width <= 0 || src_height <= 0) return {0, 0, Max(src_width, 0), Max(src_height, 0)};
  if (dst_width <= 0 || dst_height <= 0) return {0, 0, src_width, src_height};
  const int64_t sw = src_width, sh = src_height, dw = dst_width, dh = dst_height;
  int64_t w = sw, h = sh;
  if (sw * dh > sh * dw) {
    w = (sh * dw + dh) / (2 * dh) * 2;
  } else {
    h = (sw * dh + dw) / (2 * dw) * 2;
  }
  const int64_t even_w = sw & ~int64_t{1}, even_h = sh & ~int64_t{1};
  w = w > even_w ? even_w : w;
  h = h > even_h ? even_h : h;
  if (w < 2) w = sw < 2 ? sw : 2;
  if (h < 2) h = sh < 2 ? sh : 2;
  const int64_t left = ((sw - w) / 2) & ~int64_t{1};
  const int64_t top = ((sh - h) / 2) & ~int64_t{1};
  return {static_cast<int32_t>(left), static_cast<int32_t>(top), static_cast<int32_t>(w), static_cast<int32_t>(h)};
}

// scale an I420 crop bilinearly into a 4:2:0 destination
void ScaleI420(const I420View& src, const Rect& crop, const YuvDest& dst) {
  Window win;
  if (!ValidView(src) || !ValidSize(dst.width, dst.height) || dst.y.data == nullptr || !ClampCrop(src, crop, &win)) {
    return;
  }
  const Axis ax{static_cast<int64_t>(win.left) << 16, win.width, dst.width, win.left, win.left + win.width - 1};
  const Axis ay{static_cast<int64_t>(win.top) << 16, win.height, dst.height, win.top, win.top + win.height - 1};
  ScalePlane(src.data, src.width, ax, ay, dst.y.data, dst.y.row_stride, dst.y.pixel_stride, dst.width,
             dst.height);

  const int32_t dcw = dst.width / 2, dch = dst.height / 2;
  if (dcw == 0 || dch == 0 || dst.cb.data == nullptr || dst.cr.data == nullptr) return;
  const int32_t pw = src.width / 2, ph = src.height / 2;
  if (pw == 0 || ph == 0) {
    FillPlane(dst.cb.data, dst.cb.row_stride, dst.cb.pixel_stride, dcw, dch, 128);
    FillPlane(dst.cr.data, dst.cr.row_stride, dst.cr.pixel_stride, dcw, dch, 128);
    return;
  }
  // JFIF sites chroma centred between its luma pair
  int32_t cx_lo, cx_hi, cy_lo, cy_hi;
  ChromaSpan(win.left, win.width, pw, &cx_lo, &cx_hi);
  ChromaSpan(win.top, win.height, ph, &cy_lo, &cy_hi);
  const Axis cx{static_cast<int64_t>(win.left) << 15, win.width, dst.width, cx_lo, cx_hi};
  const Axis cy{static_cast<int64_t>(win.top) << 15, win.height, dst.height, cy_lo, cy_hi};
  const uint8_t* u = src.data + static_cast<size_t>(src.width) * src.height;
  const uint8_t* v = u + static_cast<size_t>(pw) * ph;
  ScalePlane(u, pw, cx, cy, dst.cb.data, dst.cb.row_stride, dst.cb.pixel_stride, dcw, dch);
  ScalePlane(v, pw, cx, cy, dst.cr.data, dst.cr.row_stride, dst.cr.pixel_stride, dcw, dch);
}

// scale an I420 crop into a packed I420 buffer
void ScaleI420ToPacked(const I420View& src, const Rect& crop, uint8_t* dst, int32_t dst_width,
                       int32_t dst_height) {
  if (dst == nullptr || !ValidSize(dst_width, dst_height)) return;
  const int32_t cw = dst_width / 2, ch = dst_height / 2;
  uint8_t* u = dst + static_cast<size_t>(dst_width) * dst_height;
  uint8_t* v = u + static_cast<size_t>(cw) * ch;
  const YuvDest d{{dst, dst_width, 1}, {u, cw, 1}, {v, cw, 1}, dst_width, dst_height};
  ScaleI420(src, crop, d);
}

// scale an I420 crop into RGBA by full-range BT.601
void ScaleI420ToRgba(const I420View& src, const Rect& crop, uint8_t* dst, int32_t dst_row_stride_bytes,
                     int32_t dst_width, int32_t dst_height) {
  Window win;
  if (dst == nullptr || !ValidSize(dst_width, dst_height) || dst_row_stride_bytes < 4 * dst_width ||
      !ValidView(src) || !ClampCrop(src, crop, &win)) {
    return;
  }
  const Axis ax{static_cast<int64_t>(win.left) << 16, win.width, dst_width, win.left, win.left + win.width - 1};
  const Axis ay{static_cast<int64_t>(win.top) << 16, win.height, dst_height, win.top, win.top + win.height - 1};
  Taps luma_taps, chroma_taps;
  MakeTaps(ax, dst_width, &luma_taps);
  uint16_t row[kMaxDim + 1];
  uint8_t ys[kMaxDim], us[kMaxDim], vs[kMaxDim];

  const int32_t pw = src.width / 2, ph = src.height / 2;
  const bool has_chroma = pw > 0 && ph > 0;
  Axis cx{}, cy{};
  if (has_chroma) {
    int32_t lo, hi;
    ChromaSpan(win.left, win.width, pw, &lo, &hi);
    cx = {static_cast<int64_t>(win.left) << 15, win.width, 2 * static_cast<int64_t>(dst_width), lo, hi};
    ChromaSpan(win.top, win.height, ph, &lo, &hi);
    cy = {static_cast<int64_t>(win.top) << 15, win.height, 2 * static_cast<int64_t>(dst_height), lo, hi};
    MakeTaps(cx, dst_width, &chroma_taps);
  } else {
    memset(us, 128, static_cast<size_t>(dst_width));
    memset(vs, 128, static_cast<size_t>(dst_width));
  }
  const uint8_t* u = src.data + static_cast<size_t>(src.width) * src.height;
  const uint8_t* v = u + static_cast<size_t>(pw) * ph;
  for (int32_t i = 0; i < dst_height; ++i) {
    ScaleRow(src.data, src.width, ax, luma_taps, ay, i, row, ys, 1, dst_width);
    if (has_chroma) {
      ScaleRow(u, pw, cx, chroma_taps, cy, i, row, us, 1, dst_width);
      ScaleRow(v, pw, cx, chroma_taps, cy, i, row, vs, 1, dst_width);
    }
    YuvRowToRgba(ys, us, vs, dst + static_cast<ptrdiff_t>(i) * dst_row_stride_bytes, dst_width);
  }
}

// encode a baseline JFIF image, or return -1
ssize_t EncodeJpeg(const I420View& src, int quality, uint8_t* out, size_t cap) {
  if (!ValidView(src) || out == nullptr) return -1;
  quality = quality < 1 ? 1 : quality > 100 ? 100 : quality;
  Quant luma, chroma;
  MakeQuant(kLumaQuant, quality, &luma);
  MakeQuant(kChromaQuant, quality, &chroma);

  Out o{out, 0, cap, false};
  WriteHeaders(o, src.width, src.height, luma, chroma);
  if (o.full) return -1;

  const DctBasis& basis = Basis();
  const int32_t w = src.width, h = src.height, pw = w / 2, ph = h / 2;
  const uint8_t* y_plane = src.data;
  const uint8_t* u_plane = y_plane + static_cast<size_t>(w) * h;
  const uint8_t* v_plane = u_plane + static_cast<size_t>(pw) * ph;
  BitWriter bw{&o, 0, 0};
  int32_t pred_y = 0, pred_u = 0, pred_v = 0;
  float blk[64], coef[64];
  int16_t zz[64];
  for (int32_t my = 0; my < (h + 15) / 16; ++my) {
    for (int32_t mx = 0; mx < (w + 15) / 16; ++mx) {
      for (int b = 0; b < 4; ++b) {
        LoadBlock(y_plane, w, h, mx * 16 + (b & 1) * 8, my * 16 + (b >> 1) * 8, blk);
        Fdct(basis, blk, coef);
        Quantize(coef, luma, zz);
        EncodeBlock(bw, zz, &pred_y, kDcLuma, kAcLuma);
      }
      LoadBlock(u_plane, pw, ph, mx * 8, my * 8, blk);
      Fdct(basis, blk, coef);
      Quantize(coef, chroma, zz);
      EncodeBlock(bw, zz, &pred_u, kDcChroma, kAcChroma);
      LoadBlock(v_plane, pw, ph, mx * 8, my * 8, blk);
      Fdct(basis, blk, coef);
      Quantize(coef, chroma, zz);
      EncodeBlock(bw, zz, &pred_v, kDcChroma, kAcChroma);
    }
    if (o.full) return -1;
  }
  bw.Finish();
  o.Word(0xffd9);
  if (o.full) return -1;
  return static_cast<ssize_t>(o.pos);
}

}

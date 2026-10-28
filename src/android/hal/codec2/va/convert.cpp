#include "va/convert.h"

#include <string.h>

#include <algorithm>

namespace rhizo::c2va {

namespace {

// read an 8- or 16-bit sample high-aligned in 16 bits
inline uint16_t Read16(const uint8_t* row, int32_t offset, int32_t bytes) {
  if (bytes == 1) return static_cast<uint16_t>(row[offset] << 8);
  return static_cast<uint16_t>(row[offset] | (row[offset + 1] << 8));
}

inline void Write16(uint8_t* p, uint16_t v, int32_t bytes) {
  if (bytes == 1) {
    *p = static_cast<uint8_t>(v >> 8);
  } else {
    p[0] = static_cast<uint8_t>(v & 0xff);
    p[1] = static_cast<uint8_t>(v >> 8);
  }
}

bool IsNv12(const YuvDest& d) {
  int32_t step = 2 * d.bytes_per_sample;
  return d.cb.pixel_stride == step && d.cr.pixel_stride == step && d.cr.data == d.cb.data + d.bytes_per_sample &&
         d.cb.row_stride == d.cr.row_stride;
}

// RGB to YCbCr coefficients in 1/65536
struct Coeffs {
  int32_t kr, kg, kb;
  int32_t cb_r, cb_g, cb_b;
  int32_t cr_r, cr_g, cr_b;
};

Coeffs CoeffsFor(Matrix m) {
  double kr, kb;
  KrKbOf(m, &kr, &kb);
  double kg = 1.0 - kr - kb;
  auto q = [](double v) { return static_cast<int32_t>(v * 65536.0 + (v < 0 ? -0.5 : 0.5)); };
  Coeffs c;
  c.kr = q(kr);
  c.kg = q(kg);
  c.kb = q(kb);
  double sb = 1.0 / (2.0 * (1.0 - kb)), sr = 1.0 / (2.0 * (1.0 - kr));
  c.cb_r = q(-kr * sb);
  c.cb_g = q(-kg * sb);
  c.cb_b = q((1.0 - kb) * sb);
  c.cr_r = q((1.0 - kr) * sr);
  c.cr_g = q(-kg * sr);
  c.cr_b = q(-kb * sr);
  return c;
}

inline uint8_t Clamp8(int32_t v) { return static_cast<uint8_t>(v < 0 ? 0 : v > 255 ? 255 : v); }

}

Matrix MatrixFor(uint32_t mc, Matrix def) {
  switch (mc) {
    case 1: return Matrix::kBt709;
    case 4: return Matrix::kFcc;
    case 5:
    case 6: return Matrix::kBt601;
    case 7: return Matrix::kSmpte240m;
    case 9:
    case 10: return Matrix::kBt2020;
    default: return def;
  }
}

// return Kr and Kb for a matrix
void KrKbOf(Matrix m, double* kr, double* kb) {
  switch (m) {
    case Matrix::kBt709: *kr = 0.2126; *kb = 0.0722; return;
    case Matrix::kBt2020: *kr = 0.2627; *kb = 0.0593; return;
    case Matrix::kFcc: *kr = 0.30; *kb = 0.11; return;
    case Matrix::kSmpte240m: *kr = 0.212; *kb = 0.087; return;
    case Matrix::kBt601:
    default: *kr = 0.299; *kb = 0.114; return;
  }
}

void CopySemiPlanarToDest(const SemiPlanar& src, int32_t width, int32_t height, const YuvDest& dst) {
  int32_t w = std::min({width, src.width, dst.width});
  int32_t h = std::min({height, src.height, dst.height});
  if (w <= 0 || h <= 0) return;
  int32_t sb = src.bytes_per_sample, db = dst.bytes_per_sample;
  for (int32_t r = 0; r < h; r++) {
    const uint8_t* s = src.y + static_cast<int64_t>(r) * src.y_pitch;
    uint8_t* d = dst.y.data + static_cast<int64_t>(r) * dst.y.row_stride;
    if (sb == db && dst.y.pixel_stride == db) {
      memcpy(d, s, static_cast<size_t>(w) * db);
    } else {
      for (int32_t x = 0; x < w; x++) Write16(d + x * dst.y.pixel_stride, Read16(s, x * sb, sb), db);
    }
  }
  int32_t cw = (w + 1) / 2, ch = (h + 1) / 2;
  bool nv12 = IsNv12(dst);
  for (int32_t r = 0; r < ch; r++) {
    const uint8_t* s = src.uv + static_cast<int64_t>(r) * src.uv_pitch;
    uint8_t* dcb = dst.cb.data + static_cast<int64_t>(r) * dst.cb.row_stride;
    uint8_t* dcr = dst.cr.data + static_cast<int64_t>(r) * dst.cr.row_stride;
    if (sb == db && nv12) {
      memcpy(dcb, s, static_cast<size_t>(cw) * 2 * db);
      continue;
    }
    for (int32_t x = 0; x < cw; x++) {
      Write16(dcb + x * dst.cb.pixel_stride, Read16(s, (2 * x) * sb, sb), db);
      Write16(dcr + x * dst.cr.pixel_stride, Read16(s, (2 * x + 1) * sb, sb), db);
    }
  }
}

void CopySrcToSemiPlanar(const YuvSrc& src, const SemiPlanar& dst) {
  int32_t w = std::min(src.width, dst.width), h = std::min(src.height, dst.height);
  if (w <= 0 || h <= 0) return;
  int32_t db = dst.bytes_per_sample;
  for (int32_t r = 0; r < dst.height; r++) {
    const uint8_t* s = src.y.data + static_cast<int64_t>(std::min(r, h - 1)) * src.y.row_stride;
    uint8_t* d = dst.y + static_cast<int64_t>(r) * dst.y_pitch;
    if (db == 1 && src.y.pixel_stride == 1) {
      memcpy(d, s, static_cast<size_t>(w));
      if (dst.width > w) memset(d + w, s[w - 1], static_cast<size_t>(dst.width - w));
    } else {
      for (int32_t x = 0; x < dst.width; x++) {
        Write16(d + x * db, static_cast<uint16_t>(s[std::min(x, w - 1) * src.y.pixel_stride] << 8), db);
      }
    }
  }
  int32_t cw = (w + 1) / 2, ch = (h + 1) / 2;
  int32_t dcw = (dst.width + 1) / 2, dch = (dst.height + 1) / 2;
  for (int32_t r = 0; r < dch; r++) {
    int32_t sr = std::min(r, ch - 1);
    const uint8_t* scb = src.cb.data + static_cast<int64_t>(sr) * src.cb.row_stride;
    const uint8_t* scr = src.cr.data + static_cast<int64_t>(sr) * src.cr.row_stride;
    uint8_t* d = dst.uv + static_cast<int64_t>(r) * dst.uv_pitch;
    bool src_nv12 = src.cb.pixel_stride == 2 && src.cr.pixel_stride == 2 && scr == scb + 1;
    if (db == 1 && src_nv12) {
      memcpy(d, scb, static_cast<size_t>(cw) * 2);
      for (int32_t x = cw; x < dcw; x++) {
        d[2 * x] = scb[2 * (cw - 1)];
        d[2 * x + 1] = scb[2 * (cw - 1) + 1];
      }
      continue;
    }
    for (int32_t x = 0; x < dcw; x++) {
      int32_t sx = std::min(x, cw - 1);
      Write16(d + (2 * x) * db, static_cast<uint16_t>(scb[sx * src.cb.pixel_stride] << 8), db);
      Write16(d + (2 * x + 1) * db, static_cast<uint16_t>(scr[sx * src.cr.pixel_stride] << 8), db);
    }
  }
}

void RgbaToSemiPlanar(const uint8_t* rgba, int32_t row_stride, int32_t width, int32_t height, Matrix matrix,
                      bool full_range, const SemiPlanar& dst) {
  int32_t w = std::min(width, dst.width), h = std::min(height, dst.height);
  if (w <= 0 || h <= 0) return;
  Coeffs c = CoeffsFor(matrix);
  int32_t ys = full_range ? 65536 : (219 * 65536 + 127) / 255, yo = full_range ? 0 : 16;
  int32_t cs = full_range ? 65536 : (224 * 65536 + 127) / 255;
  int32_t db = dst.bytes_per_sample;
  for (int32_t r = 0; r < dst.height; r++) {
    const uint8_t* s = rgba + static_cast<int64_t>(std::min(r, h - 1)) * row_stride;
    uint8_t* d = dst.y + static_cast<int64_t>(r) * dst.y_pitch;
    for (int32_t x = 0; x < dst.width; x++) {
      const uint8_t* p = s + 4 * std::min(x, w - 1);
      int64_t yl = static_cast<int64_t>(c.kr) * p[0] + static_cast<int64_t>(c.kg) * p[1] +
                   static_cast<int64_t>(c.kb) * p[2];
      int32_t y = static_cast<int32_t>((yl * ys / 65536 + 32768) >> 16) + yo;
      Write16(d + x * db, static_cast<uint16_t>(Clamp8(y) << 8), db);
    }
  }
  int32_t dcw = (dst.width + 1) / 2, dch = (dst.height + 1) / 2;
  for (int32_t r = 0; r < dch; r++) {
    int32_t r0 = std::min(2 * r, h - 1), r1 = std::min(2 * r + 1, h - 1);
    const uint8_t* s0 = rgba + static_cast<int64_t>(r0) * row_stride;
    const uint8_t* s1 = rgba + static_cast<int64_t>(r1) * row_stride;
    uint8_t* d = dst.uv + static_cast<int64_t>(r) * dst.uv_pitch;
    for (int32_t x = 0; x < dcw; x++) {
      int32_t x0 = std::min(2 * x, w - 1), x1 = std::min(2 * x + 1, w - 1);
      int32_t sr = s0[4 * x0] + s0[4 * x1] + s1[4 * x0] + s1[4 * x1];
      int32_t sg = s0[4 * x0 + 1] + s0[4 * x1 + 1] + s1[4 * x0 + 1] + s1[4 * x1 + 1];
      int32_t sbl = s0[4 * x0 + 2] + s0[4 * x1 + 2] + s1[4 * x0 + 2] + s1[4 * x1 + 2];
      int64_t cb = static_cast<int64_t>(c.cb_r) * sr + static_cast<int64_t>(c.cb_g) * sg +
                   static_cast<int64_t>(c.cb_b) * sbl;
      int64_t cr = static_cast<int64_t>(c.cr_r) * sr + static_cast<int64_t>(c.cr_g) * sg +
                   static_cast<int64_t>(c.cr_b) * sbl;
      int64_t cbs = cb * cs / 65536, crs = cr * cs / 65536;
      int32_t u = 128 + static_cast<int32_t>((cbs + (cbs >= 0 ? 131072 : -131072)) / 262144);
      int32_t v = 128 + static_cast<int32_t>((crs + (crs >= 0 ? 131072 : -131072)) / 262144);
      Write16(d + (2 * x) * db, static_cast<uint16_t>(Clamp8(u) << 8), db);
      Write16(d + (2 * x + 1) * db, static_cast<uint16_t>(Clamp8(v) << 8), db);
    }
  }
}

void SemiPlanarToRgba(const SemiPlanar& src, Matrix matrix, bool full_range, uint8_t* rgba, int32_t row_stride,
                      int32_t dst_width, int32_t dst_height) {
  if (src.width <= 0 || src.height <= 0 || dst_width <= 0 || dst_height <= 0) return;
  double kr, kb;
  KrKbOf(matrix, &kr, &kb);
  double kg = 1.0 - kr - kb;
  double ys = full_range ? 1.0 : 255.0 / 219.0, cs = full_range ? 1.0 : 255.0 / 224.0;
  auto q = [](double v) { return static_cast<int32_t>(v * 65536.0 + 0.5); };
  int32_t y_mul = q(ys), rv = q(2 * (1 - kr) * cs), bu = q(2 * (1 - kb) * cs);
  int32_t gu = q(2 * (1 - kb) * kb / kg * cs), gv = q(2 * (1 - kr) * kr / kg * cs);
  int32_t y_off = full_range ? 0 : 16;
  int32_t sb = src.bytes_per_sample;
  for (int32_t r = 0; r < dst_height; r++) {
    int32_t sy = static_cast<int32_t>(static_cast<int64_t>(r) * src.height / dst_height);
    const uint8_t* yrow = src.y + static_cast<int64_t>(sy) * src.y_pitch;
    const uint8_t* crow = src.uv + static_cast<int64_t>(sy / 2) * src.uv_pitch;
    uint8_t* d = rgba + static_cast<int64_t>(r) * row_stride;
    for (int32_t x = 0; x < dst_width; x++) {
      int32_t sx = static_cast<int32_t>(static_cast<int64_t>(x) * src.width / dst_width);
      int32_t Y = sb == 1 ? yrow[sx] : yrow[2 * sx + 1];
      int32_t U = (sb == 1 ? crow[(sx / 2) * 2] : crow[(sx / 2) * 4 + 1]) - 128;
      int32_t V = (sb == 1 ? crow[(sx / 2) * 2 + 1] : crow[(sx / 2) * 4 + 3]) - 128;
      int64_t yy = static_cast<int64_t>(Y - y_off) * y_mul;
      d[4 * x] = Clamp8(static_cast<int32_t>((yy + static_cast<int64_t>(rv) * V + 32768) >> 16));
      d[4 * x + 1] =
          Clamp8(static_cast<int32_t>((yy - static_cast<int64_t>(gu) * U - static_cast<int64_t>(gv) * V + 32768) >> 16));
      d[4 * x + 2] = Clamp8(static_cast<int32_t>((yy + static_cast<int64_t>(bu) * U + 32768) >> 16));
      d[4 * x + 3] = 255;
    }
  }
}

}

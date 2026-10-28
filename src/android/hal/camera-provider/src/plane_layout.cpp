#include "plane_layout.h"

#include <string.h>

#include <algorithm>
#include <string>

namespace rhizo::camera {

namespace {

constexpr char kStandardMetadataTypeName[] = "android.hardware.graphics.common.StandardMetadataType";
constexpr int64_t kPlaneLayoutsType = 15;
constexpr int64_t kMaxPlanes = 4;
constexpr int64_t kMaxComponents = 8;

constexpr int64_t kComponentY = 1LL << 0;
constexpr int64_t kComponentCb = 1LL << 1;
constexpr int64_t kComponentCr = 1LL << 2;
constexpr int64_t kComponentR = 1LL << 10;
constexpr int64_t kComponentG = 1LL << 11;
constexpr int64_t kComponentB = 1LL << 12;
constexpr int64_t kComponentRaw = 1LL << 20;

// reader of the gralloc metadata encoding
class Reader {
 public:
  Reader(const uint8_t* p, size_t n) : p_(p), left_(n) {}
  bool i64(int64_t* v) {
    if (left_ < sizeof(*v)) return false;
    memcpy(v, p_, sizeof(*v));
    p_ += sizeof(*v);
    left_ -= sizeof(*v);
    return true;
  }
  bool str(std::string* s) {
    int64_t n;
    if (!i64(&n) || n < 0 || static_cast<uint64_t>(n) > left_ || n > 256) return false;
    s->assign(reinterpret_cast<const char*>(p_), static_cast<size_t>(n));
    p_ += n;
    left_ -= static_cast<size_t>(n);
    return true;
  }

 private:
  const uint8_t* p_;
  size_t left_;
};

// the position of an 8-bit component in a plane
struct Sample {
  bool found = false;
  int64_t offset = 0;
  int64_t stride = 0;
  int64_t step = 0;
};

// return true when a grid of samples stays inside mapped bytes
bool Fits(const Sample& s, int64_t w, int64_t h, size_t mapped) {
  if (s.offset < 0 || s.stride <= 0 || s.step <= 0 || w <= 0 || h <= 0) return false;
  int64_t last = s.offset + (h - 1) * s.stride + (w - 1) * s.step;
  return last < static_cast<int64_t>(mapped);
}

}

// decode an encoded PLANE_LAYOUTS value, or return false when malformed
bool DecodePlaneLayouts(const uint8_t* data, size_t size, std::vector<PlaneLayoutInfo>* out) {
  Reader r(data, size);
  std::string name;
  int64_t type, planes;
  if (!r.str(&name) || name != kStandardMetadataTypeName) return false;
  if (!r.i64(&type) || type != kPlaneLayoutsType) return false;
  if (!r.i64(&planes) || planes <= 0 || planes > kMaxPlanes) return false;
  out->clear();
  for (int64_t i = 0; i < planes; i++) {
    PlaneLayoutInfo p;
    int64_t components;
    if (!r.i64(&components) || components <= 0 || components > kMaxComponents) return false;
    for (int64_t c = 0; c < components; c++) {
      std::string typeName;
      int64_t ctype, off, bits;
      if (!r.str(&typeName) || !r.i64(&ctype) || !r.i64(&off) || !r.i64(&bits)) return false;
      p.componentTypes.push_back(ctype);
      p.componentOffsetBits.push_back(off);
      p.componentSizeBits.push_back(bits);
    }
    if (!r.i64(&p.offsetBytes) || !r.i64(&p.sampleIncrementBits) || !r.i64(&p.strideBytes) ||
        !r.i64(&p.widthSamples) || !r.i64(&p.heightSamples) || !r.i64(&p.totalSizeBytes)) {
      return false;
    }
    int64_t hsub, vsub;
    if (!r.i64(&hsub) || !r.i64(&vsub)) return false;
    out->push_back(std::move(p));
  }
  return true;
}

// describe a mapped buffer from its plane layouts, or return false
bool DescribePlanes(const std::vector<PlaneLayoutInfo>& planes, uint8_t* base, size_t mapped,
                    int32_t width, int32_t height, LockedBuffer* out) {
  Sample y, cb, cr, raw;
  int64_t rgbPlane = -1, rOff = -1, gOff = -1, bOff = -1;
  for (size_t i = 0; i < planes.size(); i++) {
    const PlaneLayoutInfo& p = planes[i];
    for (size_t c = 0; c < p.componentTypes.size(); c++) {
      int64_t type = p.componentTypes[c], offBits = p.componentOffsetBits[c];
      if (p.componentSizeBits[c] != 8 || offBits % 8 != 0 || p.sampleIncrementBits % 8 != 0) continue;
      Sample s{true, p.offsetBytes + offBits / 8, p.strideBytes, p.sampleIncrementBits / 8};
      if (type == kComponentY) y = s;
      else if (type == kComponentCb) cb = s;
      else if (type == kComponentCr) cr = s;
      else if (type == kComponentRaw) raw = s;
      else if (type == kComponentR || type == kComponentG || type == kComponentB) {
        if (rgbPlane >= 0 && rgbPlane != static_cast<int64_t>(i)) continue;
        rgbPlane = static_cast<int64_t>(i);
        if (type == kComponentR) rOff = offBits;
        if (type == kComponentG) gOff = offBits;
        if (type == kComponentB) bOff = offBits;
      }
    }
  }
  out->width = width;
  out->height = height;
  int64_t cw = width / 2 > 0 ? width / 2 : 1, ch = height / 2 > 0 ? height / 2 : 1;
  if (y.found && cb.found && cr.found) {
    if (!Fits(y, width, height, mapped) || !Fits(cb, cw, ch, mapped) || !Fits(cr, cw, ch, mapped)) return false;
    out->kind = LockedBuffer::Kind::kYuv;
    out->yuv.y = {base + y.offset, static_cast<int32_t>(y.stride), static_cast<int32_t>(y.step)};
    out->yuv.cb = {base + cb.offset, static_cast<int32_t>(cb.stride), static_cast<int32_t>(cb.step)};
    out->yuv.cr = {base + cr.offset, static_cast<int32_t>(cr.stride), static_cast<int32_t>(cr.step)};
    out->yuv.width = width;
    out->yuv.height = height;
    return true;
  }
  if (rgbPlane >= 0 && rOff == 0 && gOff == 8 && bOff == 16) {
    const PlaneLayoutInfo& p = planes[static_cast<size_t>(rgbPlane)];
    Sample s{true, p.offsetBytes, p.strideBytes, p.sampleIncrementBits / 8};
    if (p.sampleIncrementBits != 32 || !Fits(s, width, height, mapped)) return false;
    out->kind = LockedBuffer::Kind::kRgba;
    out->rgba = base + p.offsetBytes;
    out->rgbaStride = static_cast<int32_t>(p.strideBytes);
    return true;
  }
  if (raw.found) {
    if (raw.offset < 0 || raw.offset >= static_cast<int64_t>(mapped)) return false;
    size_t logical = static_cast<size_t>(width) * static_cast<size_t>(height > 0 ? height : 1);
    out->kind = LockedBuffer::Kind::kBlob;
    out->blob = base + raw.offset;
    out->blobSize = std::min(mapped - static_cast<size_t>(raw.offset), logical);
    return true;
  }
  return false;
}

}

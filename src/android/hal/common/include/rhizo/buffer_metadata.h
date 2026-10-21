#pragma once

#include <cutils/native_handle.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>

namespace rhizo {

// int slots of a buffer handle
enum HandleIntField : int {
  kMagic = 0,
  kVersion = 1,
  kWidth = 2,
  kHeight = 3,
  kPixelFormat = 4,
  kDrmFourcc = 5,
  kUsageHi = 6,
  kUsageLo = 7,
  kStride = 8,
  kModifierHi = 9,
  kModifierLo = 10,
  kLayerCount = 11,
  kAllocSizeHi = 12,
  kAllocSizeLo = 13,
  kBufferIdHi = 14,
  kBufferIdLo = 15,
  kChromaStride = 16,
  kOffsetV = 17,
  kOffsetU = 18,
  kNumInts = 19,
};

constexpr int kNameLenIndex = kNumInts;

constexpr int kNumFds = 1;
constexpr int32_t kHandleMagic = 0x5248495A;
constexpr int32_t kHandleVersion = 1;

// combine two 32-bit halves into a 64-bit value
inline uint64_t pack64(int32_t hi, int32_t lo) {
  return (static_cast<uint64_t>(static_cast<uint32_t>(hi)) << 32) |
         static_cast<uint32_t>(lo);
}
// split a 64-bit value into two 32-bit halves
inline void unpack64(uint64_t v, int32_t* hi, int32_t* lo) {
  *hi = static_cast<int32_t>(v >> 32);
  *lo = static_cast<int32_t>(v & 0xffffffffu);
}

// decoded buffer handle fields
struct DecodedHandle {
  int32_t width = 0;
  int32_t height = 0;
  int32_t pixelFormat = 0;
  int32_t drmFourcc = 0;
  uint64_t usage = 0;
  int32_t stride = 0;
  uint64_t modifier = 0;
  int32_t layerCount = 1;
  uint64_t allocSize = 0;
  uint64_t bufferId = 0;
  int32_t chromaStride = 0;
  int32_t offsetV = 0;
  int32_t offsetU = 0;
  std::string name;
  bool valid = false;
};

// parse the name trailer from the ints
inline void DecodeNameTrailer(const int32_t* ints, size_t count, DecodedHandle* d) {
  if (count <= static_cast<size_t>(kNumInts)) return;
  int32_t nameLen = ints[kNameLenIndex];
  if (nameLen <= 0 || nameLen > 128) return;
  size_t nameWords = (static_cast<size_t>(nameLen) + 3) / 4;
  if (count < static_cast<size_t>(kNameLenIndex) + 1 + nameWords) return;
  const char* bytes = reinterpret_cast<const char*>(ints + kNameLenIndex + 1);
  d->name.assign(bytes, static_cast<size_t>(nameLen));
}

// decode a handle from its ints
inline DecodedHandle DecodeInts(const int32_t* ints, size_t count) {
  DecodedHandle d;
  if (!ints || count < static_cast<size_t>(kNumInts)) return d;
  if (ints[kMagic] != kHandleMagic || ints[kVersion] != kHandleVersion) return d;
  d.width = ints[kWidth];
  d.height = ints[kHeight];
  d.pixelFormat = ints[kPixelFormat];
  d.drmFourcc = ints[kDrmFourcc];
  d.usage = pack64(ints[kUsageHi], ints[kUsageLo]);
  d.stride = ints[kStride];
  d.modifier = pack64(ints[kModifierHi], ints[kModifierLo]);
  d.layerCount = ints[kLayerCount];
  d.allocSize = pack64(ints[kAllocSizeHi], ints[kAllocSizeLo]);
  d.bufferId = pack64(ints[kBufferIdHi], ints[kBufferIdLo]);
  d.chromaStride = ints[kChromaStride];
  d.offsetV = ints[kOffsetV];
  d.offsetU = ints[kOffsetU];
  d.valid = true;
  DecodeNameTrailer(ints, count, &d);
  return d;
}

// decode a buffer handle into its fields
inline DecodedHandle Decode(const native_handle_t* h) {
  DecodedHandle d;
  if (!h || h->numFds != kNumFds || h->numInts < kNumInts) return d;
  const int32_t* p = h->data + kNumFds;
  if (p[kMagic] != kHandleMagic || p[kVersion] != kHandleVersion) return d;
  d.width = p[kWidth];
  d.height = p[kHeight];
  d.pixelFormat = p[kPixelFormat];
  d.drmFourcc = p[kDrmFourcc];
  d.usage = pack64(p[kUsageHi], p[kUsageLo]);
  d.stride = p[kStride];
  d.modifier = pack64(p[kModifierHi], p[kModifierLo]);
  d.layerCount = p[kLayerCount];
  d.allocSize = pack64(p[kAllocSizeHi], p[kAllocSizeLo]);
  d.bufferId = pack64(p[kBufferIdHi], p[kBufferIdLo]);
  d.chromaStride = p[kChromaStride];
  d.offsetV = p[kOffsetV];
  d.offsetU = p[kOffsetU];
  d.valid = true;
  DecodeNameTrailer(p, static_cast<size_t>(h->numInts), &d);
  return d;
}

// create a native_handle_t for a dmabuf
inline native_handle_t* Encode(int fd, int32_t width, int32_t height,
                                int32_t pixelFormat, int32_t drmFourcc,
                                uint64_t usage, int32_t stride,
                                uint64_t modifier, int32_t layerCount,
                                uint64_t allocSize, uint64_t bufferId,
                                int32_t chromaStride = 0, int32_t offsetV = 0,
                                int32_t offsetU = 0, const char* name = nullptr,
                                int32_t nameLen = 0) {
  int32_t clampedNameLen = (name && nameLen > 0) ? std::min(nameLen, 128) : 0;
  int32_t nameWords = clampedNameLen > 0 ? (clampedNameLen + 3) / 4 : 0;
  int32_t totalInts = kNumInts + (clampedNameLen > 0 ? 1 + nameWords : 0);
  native_handle_t* h = native_handle_create(kNumFds, totalInts);
  if (!h) return nullptr;
  h->data[0] = fd;
  int32_t* p = h->data + kNumFds;
  p[kMagic] = kHandleMagic;
  p[kVersion] = kHandleVersion;
  p[kWidth] = width;
  p[kHeight] = height;
  p[kPixelFormat] = pixelFormat;
  p[kDrmFourcc] = drmFourcc;
  unpack64(usage, &p[kUsageHi], &p[kUsageLo]);
  p[kStride] = stride;
  unpack64(modifier, &p[kModifierHi], &p[kModifierLo]);
  p[kLayerCount] = layerCount;
  unpack64(allocSize, &p[kAllocSizeHi], &p[kAllocSizeLo]);
  unpack64(bufferId, &p[kBufferIdHi], &p[kBufferIdLo]);
  p[kChromaStride] = chromaStride;
  p[kOffsetV] = offsetV;
  p[kOffsetU] = offsetU;
  if (clampedNameLen > 0) {
    p[kNameLenIndex] = clampedNameLen;
    char* dst = reinterpret_cast<char*>(p + kNameLenIndex + 1);
    memcpy(dst, name, static_cast<size_t>(clampedNameLen));
    size_t totalBytes = static_cast<size_t>(nameWords) * 4;
    if (totalBytes > static_cast<size_t>(clampedNameLen)) {
      memset(dst + clampedNameLen, 0, totalBytes - static_cast<size_t>(clampedNameLen));
    }
  }
  return h;
}

constexpr int32_t kPixelFormatRGBA8888 = 1;
constexpr int32_t kPixelFormatRGBX8888 = 2;
constexpr int32_t kPixelFormatRGB888 = 3;
constexpr int32_t kPixelFormatBGRA8888 = 5;
constexpr int32_t kPixelFormatRGB565 = 4;
constexpr int32_t kPixelFormatBLOB = 0x21;
constexpr int32_t kPixelFormatYCbCr420_888 = 0x23;
constexpr int32_t kPixelFormatYV12 = 0x32315659;

// check for YV12 or YCbCr 420 888
inline bool IsYuv420Flexible(int32_t pixelFormat) {
  return pixelFormat == kPixelFormatYV12 || pixelFormat == kPixelFormatYCbCr420_888;
}

constexpr int32_t kDrmFormatAbgr8888 = 0x34324241;
constexpr int32_t kDrmFormatXbgr8888 = 0x34324258;
constexpr int32_t kDrmFormatBgr888 = 0x34324742;
constexpr int32_t kDrmFormatArgb8888 = 0x34325241;
constexpr int32_t kDrmFormatRgb565 = 0x36314752;
constexpr int32_t kDrmFormatYvu420 = 0x32315659;
constexpr int32_t kDrmFormatInvalid = 0;

// map a pixel format to a DRM fourcc
inline bool PixelFormatToDrmFourcc(int32_t pf, int32_t* outFourcc,
                                    int32_t* outBytesPerPixel) {
  switch (pf) {
    case kPixelFormatRGBA8888:
      *outFourcc = kDrmFormatAbgr8888;
      *outBytesPerPixel = 4;
      return true;
    case kPixelFormatRGBX8888:
      *outFourcc = kDrmFormatXbgr8888;
      *outBytesPerPixel = 4;
      return true;
    case kPixelFormatRGB888:
      *outFourcc = kDrmFormatBgr888;
      *outBytesPerPixel = 3;
      return true;
    case kPixelFormatBGRA8888:
      *outFourcc = kDrmFormatArgb8888;
      *outBytesPerPixel = 4;
      return true;
    case kPixelFormatRGB565:
      *outFourcc = kDrmFormatRgb565;
      *outBytesPerPixel = 2;
      return true;
    case kPixelFormatBLOB:
      *outFourcc = kDrmFormatInvalid;
      *outBytesPerPixel = 1;
      return true;
    case kPixelFormatYCbCr420_888:
    case kPixelFormatYV12:
      *outFourcc = kDrmFormatYvu420;
      *outBytesPerPixel = 1;
      return true;
    default:
      return false;
  }
}

}

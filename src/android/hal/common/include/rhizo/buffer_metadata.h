#pragma once

#include <cutils/native_handle.h>
#include <algorithm>
#include <cstddef>
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
  kNumPlanes = 16,
  kPlaneTable = 17,
  kMetaFdIndex = 26,
  kNumInts = 27,
};

constexpr int kMaxPlanes = 3;
constexpr int kPlaneInts = 3;
constexpr int kPlaneFdIndex = 0;
constexpr int kPlaneOffset = 1;
constexpr int kPlaneStride = 2;
static_assert(kPlaneTable + kMaxPlanes * kPlaneInts == kMetaFdIndex, "the plane table ends before the meta fd");

constexpr int kNameLenIndex = kNumInts;

constexpr int kMaxPlaneFds = kMaxPlanes;
constexpr int kMaxFds = kMaxPlaneFds + 1;
constexpr int32_t kHandleMagic = 0x5248495A;
constexpr int32_t kHandleVersion = 3;

constexpr uint32_t kSharedMetadataMagic = 0x444D5A52;
constexpr uint32_t kSharedMetadataVersion = 1;
constexpr uint64_t kSharedMetadataBytes = 4096;
struct SharedMetadata {
  uint32_t magic;
  uint32_t version;
  int32_t dataspace;
  int32_t reserved;
};
static_assert(sizeof(SharedMetadata) == 16 && offsetof(SharedMetadata, dataspace) == 8, "Mesa reads offset 8");

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

struct PlaneSlot {
  int32_t fdIndex = 0;
  int32_t offset = 0;
  int32_t stride = 0;
};

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
  int32_t numFds = 0;
  int32_t planeFds = 0;
  int32_t metaFdIndex = -1;
  int32_t numPlanes = 0;
  PlaneSlot planes[kMaxPlanes];
  std::string name;
  bool valid = false;
};

// the fields a handle is encoded from
struct HandleFields {
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
  int32_t numPlanes = 1;
  PlaneSlot planes[kMaxPlanes];
  bool hasMetaFd = false;
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
inline DecodedHandle DecodeInts(const int32_t* ints, size_t count, int numFds = -1) {
  DecodedHandle d;
  if (!ints || count < static_cast<size_t>(kNumInts)) return d;
  if (ints[kMagic] != kHandleMagic || ints[kVersion] != kHandleVersion) return d;
  if (numFds == 0 || numFds > kMaxFds) return d;
  int32_t numPlanes = ints[kNumPlanes];
  if (numPlanes < 1 || numPlanes > kMaxPlanes) return d;
  int32_t named = 0;
  for (int p = 0; p < numPlanes; p++) {
    const int32_t* slot = ints + kPlaneTable + p * kPlaneInts;
    PlaneSlot s{slot[kPlaneFdIndex], slot[kPlaneOffset], slot[kPlaneStride]};
    if (s.fdIndex < 0 || s.fdIndex >= kMaxPlaneFds || s.offset < 0 || s.stride <= 0) return d;
    named = std::max(named, s.fdIndex + 1);
    d.planes[p] = s;
  }
  int32_t meta = ints[kMetaFdIndex];
  int32_t planeFds = numFds < 0 ? named : (meta >= 0 ? numFds - 1 : numFds);
  if (meta != -1 && meta != planeFds) return d;
  if (planeFds < 1 || planeFds > kMaxPlaneFds || named > planeFds) return d;
  d.numPlanes = numPlanes;
  d.numFds = numFds;
  d.planeFds = planeFds;
  d.metaFdIndex = meta;
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
  d.valid = true;
  DecodeNameTrailer(ints, count, &d);
  return d;
}

// decode a buffer handle into its fields
inline DecodedHandle Decode(const native_handle_t* h) {
  if (!h || h->numFds < 1 || h->numFds > kMaxFds || h->numInts < kNumInts) return DecodedHandle();
  return DecodeInts(h->data + h->numFds, static_cast<size_t>(h->numInts), h->numFds);
}

// create a native_handle_t that owns fds
inline native_handle_t* Encode(const HandleFields& f, const int* fds, int32_t numFds, const char* name = nullptr,
                               int32_t nameLen = 0) {
  int32_t planeFds = f.hasMetaFd ? numFds - 1 : numFds;
  if (numFds < 1 || numFds > kMaxFds || planeFds < 1 || planeFds > kMaxPlaneFds || f.numPlanes < 1 ||
      f.numPlanes > kMaxPlanes) {
    return nullptr;
  }
  for (int p = 0; p < f.numPlanes; p++) {
    if (f.planes[p].fdIndex < 0 || f.planes[p].fdIndex >= planeFds) return nullptr;
  }
  int32_t clampedNameLen = (name && nameLen > 0) ? std::min(nameLen, 128) : 0;
  int32_t nameWords = clampedNameLen > 0 ? (clampedNameLen + 3) / 4 : 0;
  int32_t totalInts = kNumInts + (clampedNameLen > 0 ? 1 + nameWords : 0);
  native_handle_t* h = native_handle_create(numFds, totalInts);
  if (!h) return nullptr;
  for (int i = 0; i < numFds; i++) h->data[i] = fds[i];
  int32_t* p = h->data + numFds;
  memset(p, 0, sizeof(int32_t) * static_cast<size_t>(totalInts));
  p[kMagic] = kHandleMagic;
  p[kVersion] = kHandleVersion;
  p[kWidth] = f.width;
  p[kHeight] = f.height;
  p[kPixelFormat] = f.pixelFormat;
  p[kDrmFourcc] = f.drmFourcc;
  unpack64(f.usage, &p[kUsageHi], &p[kUsageLo]);
  p[kStride] = f.stride;
  unpack64(f.modifier, &p[kModifierHi], &p[kModifierLo]);
  p[kLayerCount] = f.layerCount;
  unpack64(f.allocSize, &p[kAllocSizeHi], &p[kAllocSizeLo]);
  unpack64(f.bufferId, &p[kBufferIdHi], &p[kBufferIdLo]);
  p[kNumPlanes] = f.numPlanes;
  for (int i = 0; i < f.numPlanes; i++) {
    int32_t* slot = p + kPlaneTable + i * kPlaneInts;
    slot[kPlaneFdIndex] = f.planes[i].fdIndex;
    slot[kPlaneOffset] = f.planes[i].offset;
    slot[kPlaneStride] = f.planes[i].stride;
  }
  p[kMetaFdIndex] = f.hasMetaFd ? planeFds : -1;
  if (clampedNameLen > 0) {
    p[kNameLenIndex] = clampedNameLen;
    char* dst = reinterpret_cast<char*>(p + kNameLenIndex + 1);
    memcpy(dst, name, static_cast<size_t>(clampedNameLen));
  }
  return h;
}

constexpr int32_t kPixelFormatRGBA8888 = 1;
constexpr int32_t kPixelFormatRGBX8888 = 2;
constexpr int32_t kPixelFormatRGB888 = 3;
constexpr int32_t kPixelFormatBGRA8888 = 5;
constexpr int32_t kPixelFormatRGB565 = 4;
constexpr int32_t kPixelFormatBLOB = 0x21;
constexpr int32_t kPixelFormatImplementationDefined = 0x22;
constexpr int32_t kPixelFormatYCbCr420_888 = 0x23;
constexpr int32_t kPixelFormatYV12 = 0x32315659;

// check for YV12 or YCbCr 420 888
inline bool IsYuv420Flexible(int32_t pixelFormat) {
  return pixelFormat == kPixelFormatYV12 || pixelFormat == kPixelFormatYCbCr420_888;
}

constexpr uint64_t kUsageVideoEncoder = 1ULL << 16;
constexpr uint64_t kUsageCameraOutput = 1ULL << 17;
constexpr uint64_t kUsageCameraInput = 1ULL << 18;
constexpr uint64_t kUsageVideoDecoder = 1ULL << 22;
constexpr uint64_t kUsageYuvProducerOrConsumer =
    kUsageVideoEncoder | kUsageCameraOutput | kUsageCameraInput | kUsageVideoDecoder;

// return the format a requested format allocates with
inline int32_t ResolvePixelFormat(int32_t pixelFormat, uint64_t usage) {
  if (pixelFormat != kPixelFormatImplementationDefined) return pixelFormat;
  return (usage & kUsageYuvProducerOrConsumer) ? kPixelFormatYV12 : kPixelFormatRGBX8888;
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

// return plane p's size in samples
inline void PlaneSize(const DecodedHandle& d, int p, int32_t* width, int32_t* height) {
  bool chroma = d.drmFourcc == kDrmFormatYvu420 && p > 0;
  *width = chroma ? (d.width + 1) / 2 : d.width;
  *height = chroma ? (d.height + 1) / 2 : d.height;
}

// round v up to a power-of-two align
inline uint64_t AlignUp(uint64_t v, uint64_t align) { return (v + align - 1) & ~(align - 1); }

// CPU view layout of a locked buffer's plane fds
struct CpuLayout {
  int32_t numMaps = 0;
  uint64_t mapOffset[kMaxPlaneFds] = {};
  uint64_t mapLength[kMaxPlaneFds] = {};
  uint64_t span = 0;
};

// compute the CPU view layout
inline bool ComputeCpuLayout(const DecodedHandle& d, uint64_t page, CpuLayout* out) {
  CpuLayout l;
  int32_t numFds = d.planeFds;
  if (!d.valid || numFds < 1 || numFds > kMaxPlaneFds || page == 0 || (page & (page - 1)) != 0) return false;
  l.numMaps = numFds;
  uint64_t reach[kMaxPlaneFds] = {};
  for (int p = 0; p < d.numPlanes; p++) {
    int32_t w, h;
    PlaneSize(d, p, &w, &h);
    uint64_t end = static_cast<uint64_t>(d.planes[p].offset) +
                   static_cast<uint64_t>(d.planes[p].stride) * static_cast<uint64_t>(h > 0 ? h : 1);
    reach[d.planes[p].fdIndex] = std::max(reach[d.planes[p].fdIndex], end);
  }
  if (numFds == 1) {
    l.mapLength[0] = d.allocSize ? d.allocSize : reach[0];
    l.span = l.mapLength[0];
    if (reach[0] > l.span) return false;
  } else {
    uint64_t at = 0;
    for (int i = 0; i < numFds; i++) {
      if (reach[i] == 0) return false;
      l.mapOffset[i] = at;
      l.mapLength[i] = AlignUp(reach[i], page);
      at += l.mapLength[i];
    }
    l.span = at;
    if (d.allocSize != 0 && d.allocSize != l.span) return false;
  }
  *out = l;
  return true;
}

}

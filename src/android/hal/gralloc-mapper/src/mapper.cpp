#include <android/hardware/graphics/mapper/utils/IMapperProvider.h>
#include <cutils/native_handle.h>
#include <fcntl.h>
#include <log/log.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <vector>

#include "rhizo/buffer_metadata.h"
#include "rhizo/memfd_buffer.h"
#include "rhizo/virtgpu_transfer.h"

using vendor::mapper::IMapperProvider;
using vendor::mapper::IMapperV5Impl;

extern "C" int32_t ANDROID_HAL_MAPPER_VERSION = 5;

// check RHIZO_MAPPER_VERBOSE for verbose logging
static bool MapperVerbose() {
  static const bool on = [] {
    const char* v = getenv("RHIZO_MAPPER_VERBOSE");
    return v && *v && strcmp(v, "0") != 0;
  }();
  return on;
}

namespace {

// write a message to the kernel log
void klog(const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    dprintf(fd, "<5>rhizo-mapper: %s\n", msg);
    close(fd);
  }
}

constexpr char kStandardMetadataTypeName[] =
    "android.hardware.graphics.common.StandardMetadataType";

// AIDL standard metadata type values
enum StandardMetadataType : int64_t {
  BUFFER_ID = 1,
  NAME = 2,
  WIDTH = 3,
  HEIGHT = 4,
  LAYER_COUNT = 5,
  PIXEL_FORMAT_REQUESTED = 6,
  PIXEL_FORMAT_FOURCC = 7,
  PIXEL_FORMAT_MODIFIER = 8,
  USAGE = 9,
  ALLOCATION_SIZE = 10,
  PROTECTED_CONTENT = 11,
  COMPRESSION = 12,
  INTERLACED = 13,
  CHROMA_SITING = 14,
  PLANE_LAYOUTS = 15,
  CROP = 16,
  DATASPACE = 17,
  BLEND_MODE = 18,
  SMPTE2086 = 19,
  CTA861_3 = 20,
  SMPTE2094_40 = 21,
  SMPTE2094_10 = 22,
  STRIDE = 23,
};

// SMPTE 2086 HDR metadata values
struct Smpte2086Value {
  float primaryRedX, primaryRedY;
  float primaryGreenX, primaryGreenY;
  float primaryBlueX, primaryBlueY;
  float whitePointX, whitePointY;
  float maxLuminance, minLuminance;
};
struct Cta861_3Value {
  float maxContentLightLevel;
  float maxFrameAverageLightLevel;
};

// state of an imported buffer
struct ImportedBuffer {
  rhizo::DecodedHandle decoded;
  rhizo::CpuLayout cpu;
  rhizo::SharedMetadata* shared = nullptr;
  ino_t ino = 0;
  int32_t dataspace = 0;
  int32_t blendMode = 0;
  void* lockedData = nullptr;
  size_t lockedSize = 0;
  int lockCount = 0;
  bool lockedForWrite = false;
  bool xferFailLogged = false;
  bool keepMapping = false;
  void* keptData = nullptr;
  size_t keptSize = 0;
  std::optional<Smpte2086Value> smpte2086;
  std::optional<Cta861_3Value> cta861_3;
};

// log a failed virtgpu transfer, once per buffer
void LogTransferFailure(ImportedBuffer& ib, const char* what) {
  if (ib.xferFailLogged) return;
  ib.xferFailLogged = true;
  __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper", "%s: virtgpu transfer FAILED w=%d h=%d", what,
                      ib.decoded.width, ib.decoded.height);
}

// map the buffer's planes into a CPU view
void* MapCpuView(const native_handle_t* h, const rhizo::CpuLayout& cpu) {
  if (cpu.numMaps == 1) return mmap(nullptr, cpu.span, PROT_READ | PROT_WRITE, MAP_SHARED, h->data[0], 0);
  void* base = mmap(nullptr, cpu.span, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (base == MAP_FAILED) return MAP_FAILED;
  for (int i = 0; i < cpu.numMaps; i++) {
    void* want = static_cast<uint8_t*>(base) + cpu.mapOffset[i];
    void* got = mmap(want, cpu.mapLength[i], PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, h->data[i], 0);
    if (got != want) {
      int saved = errno;
      munmap(base, cpu.span);
      errno = saved;
      return MAP_FAILED;
    }
  }
  return base;
}

constexpr uint64_t kHostWriteUsage = (1ULL << 9) | (1ULL << 12) | (1ULL << 24) | (1ULL << 32);

// return true for a buffer the host's GPU can write
bool HostMayHoldNewerData(const rhizo::DecodedHandle& d) { return (d.usage & kHostWriteUsage) != 0; }

// return true for a memfd buffer with no host copy
bool InGuestMemory(const native_handle_t* h) { return h && h->numFds >= 1 && rhizo::IsShmemFile(h->data[0]); }

// a virtgpu transfer of a plane
struct TransferBox {
  int fd;
  int width;
  int height;
  int stride;
};

// return the virtgpu transfer boxes of a buffer
int TransferBoxes(const native_handle_t* h, const rhizo::DecodedHandle& d, TransferBox out[rhizo::kMaxPlanes]) {
  if (d.planeFds == 1) {
    out[0] = {h->data[0], d.width, d.height, d.stride};
    return 1;
  }
  int n = 0;
  for (int p = 0; p < d.numPlanes; p++) {
    int32_t w, ht;
    rhizo::PlaneSize(d, p, &w, &ht);
    out[n++] = {h->data[d.planes[p].fdIndex], w, ht, d.planes[p].stride};
  }
  return n;
}

// map a sealed one-page SharedMetadata memfd, or return null
rhizo::SharedMetadata* MapSharedMetadata(int fd) {
  if (!rhizo::IsShmemFile(fd) || !rhizo::ShmemImportAllowed(fd, rhizo::kSharedMetadataBytes)) return nullptr;
  void* p = mmap(nullptr, rhizo::kSharedMetadataBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (p == MAP_FAILED) return nullptr;
  auto* m = static_cast<rhizo::SharedMetadata*>(p);
  if (m->magic != rhizo::kSharedMetadataMagic || m->version != rhizo::kSharedMetadataVersion) {
    munmap(p, rhizo::kSharedMetadataBytes);
    return nullptr;
  }
  return m;
}

// never destroyed: a binder thread can still free a buffer while exit() runs static destructors
std::mutex& g_mutex = *new std::mutex;
std::unordered_map<buffer_handle_t, ImportedBuffer>& g_imported =
    *new std::unordered_map<buffer_handle_t, ImportedBuffer>;

// byte layout of a plane
struct PlaneInfo {
  int64_t offsetBytes;
  int64_t sampleIncrementBits;
  int64_t strideBytes;
  int32_t totalSizeBytes;
};

// return the bytes per pixel for a format
bool BytesPerPixelForFormat(int32_t pixelFormat, int32_t* outBpp) {
  switch (pixelFormat) {
    case rhizo::kPixelFormatRGBA8888:
    case rhizo::kPixelFormatRGBX8888:
      *outBpp = 4;
      return true;
    case rhizo::kPixelFormatRGB888:
      *outBpp = 3;
      return true;
    case rhizo::kPixelFormatBGRA8888:
      *outBpp = 4;
      return true;
    case rhizo::kPixelFormatRGB565:
      *outBpp = 2;
      return true;
    case rhizo::kPixelFormatBLOB:
      *outBpp = 1;
      return true;
    case rhizo::kPixelFormatYCbCr420_888:
    case rhizo::kPixelFormatYV12:
      *outBpp = 1;
      return true;
    default:
      return false;
  }
}

// return the format of the buffer's allocated layout
int32_t LayoutFormat(const rhizo::DecodedHandle& d) {
  return rhizo::ResolvePixelFormat(d.pixelFormat, d.usage);
}

// compute the single plane layout of a format for a stride
bool ComputePlaneLayout(int32_t pixelFormat, int32_t width, int32_t height,
                         int32_t stride, PlaneInfo* out) {
  int32_t bpp;
  if (!BytesPerPixelForFormat(pixelFormat, &bpp)) return false;
  out->offsetBytes = 0;
  out->sampleIncrementBits = static_cast<int64_t>(bpp) * 8;
  out->strideBytes = stride;
  out->totalSizeBytes = stride * (height > 0 ? height : 1);
  return true;
}

// color channel within a plane
struct ComponentSpec {
  int64_t typeValue;
  int64_t offsetBits;
  int64_t sizeBits;
};

constexpr int64_t kPlaneComponentY = 1LL << 0;
constexpr int64_t kPlaneComponentCB = 1LL << 1;
constexpr int64_t kPlaneComponentCR = 1LL << 2;
constexpr int64_t kPlaneComponentR = 1LL << 10;
constexpr int64_t kPlaneComponentG = 1LL << 11;
constexpr int64_t kPlaneComponentB = 1LL << 12;
constexpr int64_t kPlaneComponentRaw = 1LL << 20;
constexpr int64_t kPlaneComponentA = 1LL << 30;

// return the color components of a pixel format
bool GetPlaneComponents(int32_t pixelFormat, std::vector<ComponentSpec>* out) {
  switch (pixelFormat) {
    case rhizo::kPixelFormatRGBA8888:
      *out = {{kPlaneComponentR, 0, 8}, {kPlaneComponentG, 8, 8},
              {kPlaneComponentB, 16, 8}, {kPlaneComponentA, 24, 8}};
      return true;
    case rhizo::kPixelFormatRGBX8888:
      *out = {{kPlaneComponentR, 0, 8}, {kPlaneComponentG, 8, 8},
              {kPlaneComponentB, 16, 8}};
      return true;
    case rhizo::kPixelFormatRGB888:
      *out = {{kPlaneComponentR, 0, 8}, {kPlaneComponentG, 8, 8},
              {kPlaneComponentB, 16, 8}};
      return true;
    case rhizo::kPixelFormatBGRA8888:
      *out = {{kPlaneComponentR, 16, 8}, {kPlaneComponentG, 8, 8},
              {kPlaneComponentB, 0, 8}, {kPlaneComponentA, 24, 8}};
      return true;
    case rhizo::kPixelFormatRGB565:
      *out = {{kPlaneComponentB, 0, 5}, {kPlaneComponentG, 5, 6},
              {kPlaneComponentR, 11, 5}};
      return true;
    case rhizo::kPixelFormatBLOB:
      *out = {{kPlaneComponentRaw, 0, 8}};
      return true;
    default:
      return false;
  }
}

class MetaWriter {
 public:
  // write into a destination buffer of the given size
  MetaWriter(void* dest, size_t destSize)
      : dest_(static_cast<uint8_t*>(dest)), remaining_(destSize) {}

  // append a value to the destination buffer
  template <typename T>
  MetaWriter& raw(const T& v) {
    size_t n = sizeof(T);
    desired_ += n;
    if (dest_ != nullptr && n <= remaining_) {
      memcpy(dest_, &v, n);
      dest_ += n;
      remaining_ -= n;
    } else {
      dest_ = nullptr;
    }
    return *this;
  }
  // append a length-prefixed string
  MetaWriter& str(const char* s) {
    size_t len = strlen(s);
    raw<int64_t>(static_cast<int64_t>(len));
    desired_ += len;
    if (dest_ != nullptr && len <= remaining_) {
      memcpy(dest_, s, len);
      dest_ += len;
      remaining_ -= len;
    } else {
      dest_ = nullptr;
    }
    return *this;
  }
  // write the metadata type header
  MetaWriter& header(int64_t typeValue) {
    str(kStandardMetadataTypeName);
    return raw<int64_t>(typeValue);
  }
  // return the size needed for everything written
  int32_t desiredSize() const { return static_cast<int32_t>(desired_); }

 private:
  uint8_t* dest_;
  size_t remaining_;
  size_t desired_ = 0;
};

class MetaReader {
 public:
  // read from a source buffer of the given size
  MetaReader(const void* src, size_t size)
      : src_(static_cast<const uint8_t*>(src)), remaining_(size) {}

  // read a value of type T, or mark the reader as failed
  template <typename T>
  MetaReader& raw(T* out) {
    if (ok_ && remaining_ >= sizeof(T)) {
      memcpy(out, src_, sizeof(T));
      src_ += sizeof(T);
      remaining_ -= sizeof(T);
    } else {
      ok_ = false;
    }
    return *this;
  }
  // check the metadata type header
  bool checkHeader(int64_t expectedType) {
    int64_t nameLen = 0;
    raw(&nameLen);
    size_t wantLen = strlen(kStandardMetadataTypeName);
    if (!ok_ || static_cast<size_t>(nameLen) != wantLen || remaining_ < wantLen) {
      ok_ = false;
      return false;
    }
    if (memcmp(src_, kStandardMetadataTypeName, wantLen) != 0) {
      ok_ = false;
      return false;
    }
    src_ += wantLen;
    remaining_ -= wantLen;
    int64_t typeVal = 0;
    raw(&typeVal);
    if (!ok_ || typeVal != expectedType) {
      ok_ = false;
      return false;
    }
    return true;
  }
  // return whether all of the reads succeeded
  bool ok() const { return ok_; }

 private:
  const uint8_t* src_;
  size_t remaining_;
  bool ok_ = true;
};

// write a header and a fixed-width value
template <typename WireT>
int32_t EmitMeta(int64_t type, WireT value, void* destBuffer, size_t destBufferSize) {
  return MetaWriter(destBuffer, destBufferSize).header(type).raw(value).desiredSize();
}

constexpr char kRhizoInoTypeName[] = "rhizo.ino";
constexpr int64_t kRhizoInoTypeValue = 1;

// write the rhizo ino metadata
int32_t EmitRhizoIno(ino_t ino, void* destBuffer, size_t destBufferSize) {
  MetaWriter w(destBuffer, destBufferSize);
  w.str(kRhizoInoTypeName);
  w.raw<int64_t>(kRhizoInoTypeValue);
  return w.raw<uint64_t>(static_cast<uint64_t>(ino)).desiredSize();
}

// write an ExtendableType with value 0
int32_t EmitExtendableNone(int64_t type, const char* extendableTypeName,
                            void* destBuffer, size_t destBufferSize) {
  MetaWriter w(destBuffer, destBufferSize);
  w.header(type);
  w.str(extendableTypeName);
  return w.raw<int64_t>(0).desiredSize();
}

// read a header and a fixed-width value
template <typename WireT>
bool DecodeMeta(int64_t type, const void* metadata, size_t metadataSize, WireT* out) {
  MetaReader r(metadata, metadataSize);
  if (!r.checkHeader(type)) return false;
  r.raw(out);
  return r.ok();
}

// HAL for graphics buffer mapping
class RhizoMapperImpl final : public IMapperV5Impl {
 public:
  // copy and record the buffer handle
  AIMapper_Error importBuffer(const native_handle_t* handle,
                               buffer_handle_t* outBufferHandle) override {
    if (!handle) return AIMAPPER_ERROR_BAD_BUFFER;
    if (MapperVerbose()) __android_log_print(ANDROID_LOG_INFO, "rhizo-mapper",
                         "importBuffer: numFds=%d numInts=%d (want 1-%d/%d)", handle->numFds,
                         handle->numInts, rhizo::kMaxFds, rhizo::kNumInts);
    rhizo::DecodedHandle decoded = rhizo::Decode(handle);
    if (!decoded.valid) {
      bool ints = handle->numFds >= 0 && handle->numInts >= 2;
      __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper",
                           "importBuffer: Decode() failed, numFds=%d numInts=%d magic=0x%x version=%d "
                           "(want 1-%d fds, %d+ ints, 0x%x/%d)",
                           handle->numFds, handle->numInts,
                           ints ? handle->data[handle->numFds + rhizo::kMagic] : -1,
                           ints ? handle->data[handle->numFds + rhizo::kVersion] : -1, rhizo::kMaxFds,
                           rhizo::kNumInts, rhizo::kHandleMagic, rhizo::kHandleVersion);
      return AIMAPPER_ERROR_BAD_BUFFER;
    }
    rhizo::CpuLayout cpu;
    if (!rhizo::ComputeCpuLayout(decoded, static_cast<uint64_t>(getpagesize()), &cpu)) {
      __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper",
                          "importBuffer: %d planes in %d fds do not fit the %llu-byte allocSize", decoded.numPlanes,
                          decoded.numFds, static_cast<unsigned long long>(decoded.allocSize));
      return AIMAPPER_ERROR_BAD_BUFFER;
    }
    if (cpu.numMaps == 1) {
      if (!rhizo::ShmemImportAllowed(handle->data[0], decoded.allocSize)) {
        __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper",
                            "importBuffer: refused a shmem fd not sealed against shrinking or shorter than its "
                            "%llu-byte allocSize",
                            static_cast<unsigned long long>(decoded.allocSize));
        return AIMAPPER_ERROR_BAD_BUFFER;
      }
    } else {
      for (int i = 0; i < cpu.numMaps; i++) {
        if (!rhizo::ShmemImportAllowed(handle->data[i], cpu.mapLength[i])) {
          __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper",
                              "importBuffer: refused plane fd %d, a shmem fd shorter than the %llu bytes it maps",
                              i, static_cast<unsigned long long>(cpu.mapLength[i]));
          return AIMAPPER_ERROR_BAD_BUFFER;
        }
      }
    }
    if (MapperVerbose()) __android_log_print(ANDROID_LOG_INFO, "rhizo-mapper", "importBuffer: OK w=%d h=%d fds=%d",
                         decoded.width, decoded.height, handle->numFds);

    native_handle_t* cloned = native_handle_create(handle->numFds, handle->numInts);
    if (!cloned) return AIMAPPER_ERROR_NO_RESOURCES;
    for (int i = 0; i < handle->numFds; i++) {
      int dupFd = dup(handle->data[i]);
      if (dupFd < 0) {
        for (int j = 0; j < i; j++) close(cloned->data[j]);
        native_handle_delete(cloned);
        return AIMAPPER_ERROR_NO_RESOURCES;
      }
      cloned->data[i] = dupFd;
    }
    memcpy(cloned->data + handle->numFds, handle->data + handle->numFds,
           sizeof(int32_t) * static_cast<size_t>(handle->numInts));

    rhizo::SharedMetadata* shared = nullptr;
    if (decoded.metaFdIndex >= 0) {
      shared = MapSharedMetadata(cloned->data[decoded.metaFdIndex]);
      if (!shared) {
        __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper",
                            "importBuffer: fd %d is not a sealed shared-metadata page", decoded.metaFdIndex);
        native_handle_close(cloned);
        native_handle_delete(cloned);
        return AIMAPPER_ERROR_BAD_BUFFER;
      }
    }

    struct stat st {};
    ino_t ino = (fstat(cloned->data[0], &st) == 0) ? st.st_ino : 0;

    std::lock_guard<std::mutex> lock(g_mutex);
    ImportedBuffer& ib = g_imported[static_cast<buffer_handle_t>(cloned)];
    ib.decoded = decoded;
    ib.cpu = cpu;
    ib.shared = shared;
    ib.ino = ino;
    ib.keepMapping = rhizo::WantsGuestMemory(decoded.usage) && rhizo::IsShmemFile(cloned->data[0]);
    *outBufferHandle = static_cast<buffer_handle_t>(cloned);
    return AIMAPPER_ERROR_NONE;
  }

  // drop an imported buffer and delete its handle
  AIMapper_Error freeBuffer(buffer_handle_t buffer) override {
    native_handle_t* h = const_cast<native_handle_t*>(
        static_cast<const native_handle_t*>(buffer));
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      auto it = g_imported.find(buffer);
      if (it == g_imported.end()) return AIMAPPER_ERROR_BAD_BUFFER;
      if (it->second.lockedData && it->second.lockedData != it->second.keptData) {
        munmap(it->second.lockedData, it->second.lockedSize);
      }
      if (it->second.keptData) munmap(it->second.keptData, it->second.keptSize);
      if (it->second.shared) munmap(it->second.shared, rhizo::kSharedMetadataBytes);
      g_imported.erase(it);
    }
    native_handle_close(h);
    native_handle_delete(h);
    return AIMAPPER_ERROR_NONE;
  }

  // return the fd and int counts of a buffer handle
  AIMapper_Error getTransportSize(buffer_handle_t buffer, uint32_t* outNumFds,
                                   uint32_t* outNumInts) override {
    const native_handle_t* h = static_cast<const native_handle_t*>(buffer);
    if (!h) return AIMAPPER_ERROR_BAD_BUFFER;
    *outNumFds = h->numFds;
    *outNumInts = h->numInts;
    return AIMAPPER_ERROR_NONE;
  }

  static constexpr uint64_t kCpuReadMask = 0xfULL;
  static constexpr uint64_t kCpuWriteMask = 0xfULL << 4;

  // map the buffer for CPU access
  AIMapper_Error lock(buffer_handle_t buffer, uint64_t cpuUsage, ARect accessRegion,
                       int acquireFence, void** outData) override {
    if (MapperVerbose()) __android_log_print(ANDROID_LOG_INFO, "rhizo-mapper",
                         "lock: buffer=%p cpuUsage=0x%llx acquireFence=%d", buffer,
                         (unsigned long long)cpuUsage, acquireFence);
    if (acquireFence >= 0) {
      sync_wait_fd(acquireFence);
      close(acquireFence);
    }
    if (cpuUsage == 0) {
      __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper", "lock: BAD_VALUE cpuUsage==0");
      return AIMAPPER_ERROR_BAD_VALUE;
    }
    const native_handle_t* h = static_cast<const native_handle_t*>(buffer);
    if (!h || h->numFds < 1) {
      __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper", "lock: BAD_BUFFER h=%p", h);
      return AIMAPPER_ERROR_BAD_BUFFER;
    }

    std::lock_guard<std::mutex> lg(g_mutex);
    auto it = g_imported.find(buffer);
    if (it == g_imported.end()) {
      __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper",
                           "lock: buffer %p NOT in g_imported (size=%zu)", buffer,
                           g_imported.size());
      return AIMAPPER_ERROR_BAD_BUFFER;
    }
    ImportedBuffer& ib = it->second;

    if (accessRegion.left < 0 || accessRegion.top < 0 ||
        accessRegion.right > ib.decoded.width || accessRegion.bottom > ib.decoded.height ||
        accessRegion.left > accessRegion.right || accessRegion.top > accessRegion.bottom) {
      __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper",
                           "lock: BAD_VALUE accessRegion=(%d,%d,%d,%d) vs %dx%d",
                           accessRegion.left, accessRegion.top, accessRegion.right,
                           accessRegion.bottom, ib.decoded.width, ib.decoded.height);
      return AIMAPPER_ERROR_BAD_VALUE;
    }

    if (ib.lockCount > 0) {
      ib.lockCount++;
      ib.lockedForWrite = ib.lockedForWrite || (cpuUsage & kCpuWriteMask) != 0;
      *outData = ib.lockedData;
      return AIMAPPER_ERROR_NONE;
    }

    size_t size = static_cast<size_t>(ib.cpu.span);
    void* addr = ib.keptData ? ib.keptData : MapCpuView(h, ib.cpu);
    if (MapperVerbose()) __android_log_print(ANDROID_LOG_INFO, "rhizo-mapper",
                         "lock: w=%d h=%d stride=%d size=%zu fds=%d fd=%d -> addr=%p", ib.decoded.width,
                         ib.decoded.height, ib.decoded.stride, size, h->numFds, h->data[0], addr);
    if (addr == MAP_FAILED) {
      __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper", "lock: mmap FAILED errno=%d (%s)",
                           errno, strerror(errno));
      return AIMAPPER_ERROR_NO_RESOURCES;
    }

    if ((cpuUsage & kCpuReadMask) && HostMayHoldNewerData(ib.decoded) && !InGuestMemory(h) &&
        rhizo::VirtgpuTransferNeeded()) {
      TransferBox boxes[rhizo::kMaxPlanes];
      int n = TransferBoxes(h, ib.decoded, boxes);
      bool xferOk = true;
      for (int t = 0; t < n; t++) {
        if (!rhizo::VirtgpuTransferFromHost(boxes[t].fd, boxes[t].width, boxes[t].height, boxes[t].stride)) {
          xferOk = false;
        }
      }
      if (MapperVerbose()) __android_log_print(ANDROID_LOG_INFO, "rhizo-mapper", "lock: TransferFromHost -> %s",
                           xferOk ? "ok" : "FAILED");
      if (!xferOk) {
        LogTransferFailure(ib, "lock");
        munmap(addr, size);
        return AIMAPPER_ERROR_NO_RESOURCES;
      }
    }

    if (ib.keepMapping) {
      ib.keptData = addr;
      ib.keptSize = size;
    }
    ib.lockedData = addr;
    ib.lockedSize = size;
    ib.lockCount = 1;
    ib.lockedForWrite = (cpuUsage & kCpuWriteMask) != 0;
    *outData = addr;
    return AIMAPPER_ERROR_NONE;
  }

  // unmap the buffer
  AIMapper_Error unlock(buffer_handle_t buffer, int* releaseFence) override {
    const native_handle_t* h = static_cast<const native_handle_t*>(buffer);
    std::lock_guard<std::mutex> lg(g_mutex);
    auto it = g_imported.find(buffer);
    if (it == g_imported.end()) return AIMAPPER_ERROR_BAD_BUFFER;
    ImportedBuffer& ib = it->second;
    if (ib.lockCount <= 0) return AIMAPPER_ERROR_BAD_BUFFER;
    ib.lockCount--;
    bool xferFailed = false;
    if (ib.lockCount == 0) {
      if (ib.lockedForWrite && h && h->numFds >= 1 && !InGuestMemory(h) && rhizo::VirtgpuTransferNeeded()) {
        TransferBox boxes[rhizo::kMaxPlanes];
        int n = TransferBoxes(h, ib.decoded, boxes);
        bool xferOk = true;
        for (int t = 0; t < n; t++) {
          if (!rhizo::VirtgpuTransferToHost(boxes[t].fd, boxes[t].width, boxes[t].height, boxes[t].stride)) {
            xferOk = false;
          }
        }
        if (MapperVerbose()) __android_log_print(ANDROID_LOG_INFO, "rhizo-mapper", "unlock: TransferToHost -> %s",
                             xferOk ? "ok" : "FAILED");
        if (!xferOk) {
          LogTransferFailure(ib, "unlock");
          xferFailed = true;
        }
      }
      if (ib.lockedData) {
        if (ib.lockedData != ib.keptData) munmap(ib.lockedData, ib.lockedSize);
        ib.lockedData = nullptr;
      }
      ib.lockedForWrite = false;
    }
    *releaseFence = -1;
    return xferFailed ? AIMAPPER_ERROR_NO_RESOURCES : AIMAPPER_ERROR_NONE;
  }

  // check the locked buffer handle
  AIMapper_Error flushLockedBuffer(buffer_handle_t buffer) override {
    std::lock_guard<std::mutex> lg(g_mutex);
    auto it = g_imported.find(buffer);
    if (it == g_imported.end() || it->second.lockCount <= 0) return AIMAPPER_ERROR_BAD_BUFFER;
    return AIMAPPER_ERROR_NONE;
  }
  // copy host content into the locked buffer
  AIMapper_Error rereadLockedBuffer(buffer_handle_t buffer) override {
    const native_handle_t* h = static_cast<const native_handle_t*>(buffer);
    std::lock_guard<std::mutex> lg(g_mutex);
    auto it = g_imported.find(buffer);
    if (it == g_imported.end() || it->second.lockCount <= 0) return AIMAPPER_ERROR_BAD_BUFFER;
    if (h && h->numFds >= 1 && HostMayHoldNewerData(it->second.decoded) && !InGuestMemory(h) &&
        rhizo::VirtgpuTransferNeeded()) {
      ImportedBuffer& ib = it->second;
      TransferBox boxes[rhizo::kMaxPlanes];
      int n = TransferBoxes(h, ib.decoded, boxes);
      for (int t = 0; t < n; t++) {
        if (!rhizo::VirtgpuTransferFromHost(boxes[t].fd, boxes[t].width, boxes[t].height, boxes[t].stride)) {
          LogTransferFailure(ib, "rereadLockedBuffer");
          return AIMAPPER_ERROR_NO_RESOURCES;
        }
      }
    }
    return AIMAPPER_ERROR_NONE;
  }

  // return standard metadata and reject other metadata types
  int32_t getMetadata(buffer_handle_t buffer, AIMapper_MetadataType metadataType,
                       void* destBuffer, size_t destBufferSize) override {
    if (strcmp(metadataType.name, kStandardMetadataTypeName) == 0) {
      return getStandardMetadata(buffer, metadataType.value, destBuffer, destBufferSize);
    }
    return -AIMAPPER_ERROR_UNSUPPORTED;
  }

  // write a standard metadata value of an imported buffer
  int32_t getStandardMetadata(buffer_handle_t buffer, int64_t type, void* destBuffer,
                               size_t destBufferSize) override {
    std::lock_guard<std::mutex> lg(g_mutex);
    auto it = g_imported.find(buffer);
    if (it == g_imported.end()) {
      __android_log_print(ANDROID_LOG_ERROR, "rhizo-mapper",
                           "getStandardMetadata: buffer %p NOT in g_imported (size=%zu) type=%lld",
                           buffer, g_imported.size(), (long long)type);
      return -AIMAPPER_ERROR_BAD_BUFFER;
    }
    int32_t __ret = GetStandardMetadataImpl(it->second, type, destBuffer, destBufferSize);
    if (MapperVerbose()) __android_log_print(ANDROID_LOG_INFO, "rhizo-mapper",
                         "getStandardMetadata: type=%lld destBufferSize=%zu -> ret=%d",
                         (long long)type, destBufferSize, __ret);
    return __ret;
  }

  // write a standard metadata value
  int32_t GetStandardMetadataImpl(const ImportedBuffer& ib, int64_t type, void* destBuffer,
                                   size_t destBufferSize) {
    const rhizo::DecodedHandle& d = ib.decoded;

    switch (type) {
      case BUFFER_ID:
        return EmitMeta<uint64_t>(type, d.bufferId, destBuffer, destBufferSize);
      case NAME: {
        const std::string& realName = d.name.empty() ? std::string("rhizo-buffer") : d.name;
        MetaWriter w(destBuffer, destBufferSize);
        w.header(type);
        return w.str(realName.c_str()).desiredSize();
      }
      case WIDTH:
        return EmitMeta<uint64_t>(type, static_cast<uint64_t>(d.width), destBuffer,
                                   destBufferSize);
      case HEIGHT:
        return EmitMeta<uint64_t>(type, static_cast<uint64_t>(d.height), destBuffer,
                                   destBufferSize);
      case LAYER_COUNT:
        return EmitMeta<uint64_t>(type, static_cast<uint64_t>(d.layerCount), destBuffer,
                                   destBufferSize);
      case PIXEL_FORMAT_REQUESTED:
        return EmitMeta<int32_t>(type, d.pixelFormat, destBuffer, destBufferSize);
      case PIXEL_FORMAT_FOURCC:
        return EmitMeta<uint32_t>(type, static_cast<uint32_t>(d.drmFourcc), destBuffer,
                                   destBufferSize);
      case PIXEL_FORMAT_MODIFIER:
        return EmitMeta<uint64_t>(type, d.modifier, destBuffer, destBufferSize);
      case USAGE:
        return EmitMeta<int64_t>(type, static_cast<int64_t>(d.usage), destBuffer,
                                  destBufferSize);
      case ALLOCATION_SIZE:
        return EmitMeta<uint64_t>(type, d.allocSize, destBuffer, destBufferSize);
      case PROTECTED_CONTENT:
        return EmitMeta<uint64_t>(type, 0ULL, destBuffer, destBufferSize);
      case STRIDE: {
        int32_t bpp;
        if (!BytesPerPixelForFormat(LayoutFormat(d), &bpp) || bpp <= 0)
          return -AIMAPPER_ERROR_UNSUPPORTED;
        uint32_t pixelStride = static_cast<uint32_t>(d.stride / bpp);
        return EmitMeta<uint32_t>(type, pixelStride, destBuffer, destBufferSize);
      }
      case DATASPACE:
        return EmitMeta<int32_t>(type, ib.shared ? __atomic_load_n(&ib.shared->dataspace, __ATOMIC_ACQUIRE)
                                                 : ib.dataspace,
                                 destBuffer, destBufferSize);
      case BLEND_MODE:
        return EmitMeta<int32_t>(type, ib.blendMode, destBuffer, destBufferSize);
      case INTERLACED:
        return EmitExtendableNone(type, "android.hardware.graphics.common.Interlaced",
                                   destBuffer, destBufferSize);
      case COMPRESSION:
        return EmitExtendableNone(type, "android.hardware.graphics.common.Compression",
                                   destBuffer, destBufferSize);
      case CHROMA_SITING:
        return EmitExtendableNone(type, "android.hardware.graphics.common.ChromaSiting",
                                   destBuffer, destBufferSize);
      case CROP: {
        MetaWriter w(destBuffer, destBufferSize);
        w.header(type);
        w.raw<int64_t>(1);
        w.raw<int32_t>(0);
        w.raw<int32_t>(0);
        w.raw<int32_t>(static_cast<int32_t>(d.width));
        w.raw<int32_t>(static_cast<int32_t>(d.height));
        return w.desiredSize();
      }
      case PLANE_LAYOUTS: {
        static constexpr char kComponentTypeName[] =
            "android.hardware.graphics.common.PlaneLayoutComponentType";
        auto writePlane = [&](MetaWriter& w, int64_t componentType, int64_t offsetBytes,
                               int64_t strideBytes, int64_t widthSamples, int64_t heightSamples,
                               int64_t totalSizeBytes, int64_t hSub, int64_t vSub) {
          w.raw<int64_t>(1);
          w.str(kComponentTypeName);
          w.raw<int64_t>(componentType);
          w.raw<int64_t>(0);
          w.raw<int64_t>(8);
          w.raw<int64_t>(offsetBytes);
          w.raw<int64_t>(8);
          w.raw<int64_t>(strideBytes);
          w.raw<int64_t>(widthSamples);
          w.raw<int64_t>(heightSamples);
          w.raw<int64_t>(totalSizeBytes);
          w.raw<int64_t>(hSub);
          w.raw<int64_t>(vSub);
        };

        const int32_t layoutFormat = LayoutFormat(d);
        if (rhizo::IsYuv420Flexible(layoutFormat)) {
          if (d.numPlanes != 3) return -AIMAPPER_ERROR_UNSUPPORTED;
          static constexpr int64_t kComponents[3] = {kPlaneComponentY, kPlaneComponentCR, kPlaneComponentCB};
          MetaWriter w(destBuffer, destBufferSize);
          w.header(type);
          w.raw<int64_t>(3);
          for (int p = 0; p < 3; p++) {
            int32_t pw, ph;
            rhizo::PlaneSize(d, p, &pw, &ph);
            const rhizo::PlaneSlot& s = d.planes[p];
            int64_t offset = static_cast<int64_t>(ib.cpu.mapOffset[s.fdIndex]) + s.offset;
            int64_t size = static_cast<int64_t>(s.stride) * ph;
            int64_t sub = p == 0 ? 1 : 2;
            writePlane(w, kComponents[p], offset, s.stride, pw, ph, size, sub, sub);
          }
          return w.desiredSize();
        }

        std::vector<ComponentSpec> components;
        if (!GetPlaneComponents(layoutFormat, &components)) {
          return -AIMAPPER_ERROR_UNSUPPORTED;
        }
        PlaneInfo plane;
        if (!ComputePlaneLayout(layoutFormat, d.width, d.height, d.stride, &plane)) {
          return -AIMAPPER_ERROR_UNSUPPORTED;
        }
        MetaWriter w(destBuffer, destBufferSize);
        w.header(type);
        w.raw<int64_t>(1);
        w.raw<int64_t>(static_cast<int64_t>(components.size()));
        for (const auto& c : components) {
          w.str(kComponentTypeName);
          w.raw<int64_t>(c.typeValue);
          w.raw<int64_t>(c.offsetBits);
          w.raw<int64_t>(c.sizeBits);
        }
        w.raw<int64_t>(plane.offsetBytes);
        w.raw<int64_t>(plane.sampleIncrementBits);
        w.raw<int64_t>(plane.strideBytes);
        w.raw<int64_t>(static_cast<int64_t>(d.width));
        w.raw<int64_t>(static_cast<int64_t>(d.height));
        w.raw<int64_t>(plane.totalSizeBytes);
        w.raw<int64_t>(1);
        return w.raw<int64_t>(1).desiredSize();
      }
      case SMPTE2086: {
        if (!ib.smpte2086.has_value()) return 0;
        const Smpte2086Value& v = *ib.smpte2086;
        MetaWriter w(destBuffer, destBufferSize);
        w.header(type);
        w.raw<float>(v.primaryRedX).raw<float>(v.primaryRedY);
        w.raw<float>(v.primaryGreenX).raw<float>(v.primaryGreenY);
        w.raw<float>(v.primaryBlueX).raw<float>(v.primaryBlueY);
        w.raw<float>(v.whitePointX).raw<float>(v.whitePointY);
        w.raw<float>(v.maxLuminance);
        return w.raw<float>(v.minLuminance).desiredSize();
      }
      case CTA861_3: {
        if (!ib.cta861_3.has_value()) return 0;
        const Cta861_3Value& v = *ib.cta861_3;
        MetaWriter w(destBuffer, destBufferSize);
        w.header(type);
        w.raw<float>(v.maxContentLightLevel);
        return w.raw<float>(v.maxFrameAverageLightLevel).desiredSize();
      }
      case SMPTE2094_40:
      case SMPTE2094_10:
        return 0;
      default:
        return -AIMAPPER_ERROR_UNSUPPORTED;
    }
  }

  // set standard metadata and reject other metadata types
  AIMapper_Error setMetadata(buffer_handle_t buffer, AIMapper_MetadataType metadataType,
                              const void* metadata, size_t metadataSize) override {
    if (strcmp(metadataType.name, kStandardMetadataTypeName) == 0) {
      return setStandardMetadata(buffer, metadataType.value, metadata, metadataSize);
    }
    return AIMAPPER_ERROR_UNSUPPORTED;
  }

  // store a standard metadata value
  AIMapper_Error setStandardMetadata(buffer_handle_t buffer, int64_t type,
                                      const void* metadata, size_t metadataSize) override {
    std::lock_guard<std::mutex> lg(g_mutex);
    auto it = g_imported.find(buffer);
    if (it == g_imported.end()) return AIMAPPER_ERROR_BAD_BUFFER;
    switch (type) {
      case DATASPACE: {
        int32_t v;
        if (!DecodeMeta<int32_t>(type, metadata, metadataSize, &v)) return AIMAPPER_ERROR_BAD_VALUE;
        it->second.dataspace = v;
        if (it->second.shared) __atomic_store_n(&it->second.shared->dataspace, v, __ATOMIC_RELEASE);
        return AIMAPPER_ERROR_NONE;
      }
      case BLEND_MODE: {
        int32_t v;
        if (!DecodeMeta<int32_t>(type, metadata, metadataSize, &v)) return AIMAPPER_ERROR_BAD_VALUE;
        it->second.blendMode = v;
        return AIMAPPER_ERROR_NONE;
      }
      case SMPTE2086: {
        if (metadataSize == 0) {
          it->second.smpte2086.reset();
          return AIMAPPER_ERROR_NONE;
        }
        MetaReader r(metadata, metadataSize);
        if (!r.checkHeader(type)) return AIMAPPER_ERROR_BAD_VALUE;
        Smpte2086Value v{};
        r.raw(&v.primaryRedX).raw(&v.primaryRedY);
        r.raw(&v.primaryGreenX).raw(&v.primaryGreenY);
        r.raw(&v.primaryBlueX).raw(&v.primaryBlueY);
        r.raw(&v.whitePointX).raw(&v.whitePointY);
        r.raw(&v.maxLuminance).raw(&v.minLuminance);
        if (!r.ok()) return AIMAPPER_ERROR_BAD_VALUE;
        it->second.smpte2086 = v;
        return AIMAPPER_ERROR_NONE;
      }
      case CTA861_3: {
        if (metadataSize == 0) {
          it->second.cta861_3.reset();
          return AIMAPPER_ERROR_NONE;
        }
        MetaReader r(metadata, metadataSize);
        if (!r.checkHeader(type)) return AIMAPPER_ERROR_BAD_VALUE;
        Cta861_3Value v{};
        r.raw(&v.maxContentLightLevel).raw(&v.maxFrameAverageLightLevel);
        if (!r.ok()) return AIMAPPER_ERROR_BAD_VALUE;
        it->second.cta861_3 = v;
        return AIMAPPER_ERROR_NONE;
      }
      case SMPTE2094_40:
        return AIMAPPER_ERROR_NONE;
      case BUFFER_ID:
      case NAME:
      case WIDTH:
      case HEIGHT:
      case LAYER_COUNT:
      case PIXEL_FORMAT_REQUESTED:
      case USAGE:
        return AIMAPPER_ERROR_BAD_VALUE;
      default:
        return AIMAPPER_ERROR_UNSUPPORTED;
    }
  }

  // return the supported metadata types
  AIMapper_Error listSupportedMetadataTypes(
      const AIMapper_MetadataTypeDescription** outDescriptionList,
      size_t* outNumberOfDescriptions) override {
    static const AIMapper_MetadataTypeDescription kDescriptions[] = {
        {{kStandardMetadataTypeName, BUFFER_ID}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, NAME}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, WIDTH}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, HEIGHT}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, LAYER_COUNT}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, PIXEL_FORMAT_REQUESTED}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, PIXEL_FORMAT_FOURCC}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, PIXEL_FORMAT_MODIFIER}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, USAGE}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, ALLOCATION_SIZE}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, PROTECTED_CONTENT}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, COMPRESSION}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, INTERLACED}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, CHROMA_SITING}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, CROP}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, PLANE_LAYOUTS}, nullptr, true, false, {}},
        {{kStandardMetadataTypeName, DATASPACE}, nullptr, true, true, {}},
        {{kStandardMetadataTypeName, BLEND_MODE}, nullptr, true, true, {}},
        {{kStandardMetadataTypeName, SMPTE2086}, nullptr, true, true, {}},
        {{kStandardMetadataTypeName, CTA861_3}, nullptr, true, true, {}},
        {{kStandardMetadataTypeName, SMPTE2094_40}, nullptr, true, true, {}},
        {{kStandardMetadataTypeName, STRIDE}, nullptr, true, false, {}},
    };
    *outDescriptionList = kDescriptions;
    *outNumberOfDescriptions = sizeof(kDescriptions) / sizeof(kDescriptions[0]);
    return AIMAPPER_ERROR_NONE;
  }

  // return success for a dump request
  AIMapper_Error dumpBuffer(buffer_handle_t, AIMapper_DumpBufferCallback, void*) override {
    return AIMAPPER_ERROR_NONE;
  }

  // dump the metadata of each imported buffer
  AIMapper_Error dumpAllBuffers(AIMapper_BeginDumpBufferCallback beginDumpBufferCallback,
                                 AIMapper_DumpBufferCallback dumpBufferCallback,
                                 void* context) override {
    static constexpr int64_t kDumpTypes[] = {BUFFER_ID, NAME,  WIDTH,
                                              HEIGHT,    USAGE, ALLOCATION_SIZE};
    std::lock_guard<std::mutex> lg(g_mutex);
    for (const auto& entry : g_imported) {
      const ImportedBuffer& ib = entry.second;
      beginDumpBufferCallback(context);
      for (int64_t type : kDumpTypes) {
        int32_t wantSize = GetStandardMetadataImpl(ib, type, nullptr, 0);
        if (wantSize <= 0) continue;
        std::vector<uint8_t> value(wantSize);
        if (GetStandardMetadataImpl(ib, type, value.data(), value.size()) != wantSize) continue;
        dumpBufferCallback(context, {kStandardMetadataTypeName, type}, value.data(),
                            value.size());
      }
      int32_t inoSize = EmitRhizoIno(ib.ino, nullptr, 0);
      std::vector<uint8_t> inoValue(inoSize);
      EmitRhizoIno(ib.ino, inoValue.data(), inoValue.size());
      dumpBufferCallback(context, {kRhizoInoTypeName, kRhizoInoTypeValue}, inoValue.data(),
                          inoValue.size());
    }
    return AIMAPPER_ERROR_NONE;
  }

  // return an empty reserved region
  AIMapper_Error getReservedRegion(buffer_handle_t, void** outReservedRegion,
                                    uint64_t* outReservedSize) override {
    *outReservedRegion = nullptr;
    *outReservedSize = 0;
    return AIMAPPER_ERROR_NONE;
  }

 private:
  static void sync_wait_fd(int fd);
};

// poll the fence file descriptor
void RhizoMapperImpl::sync_wait_fd(int fd) {
  struct pollfd pfd{fd, POLLIN, 0};
  poll(&pfd, 1, 3000);
}

}

// load the mapper implementation
extern "C" AIMapper_Error AIMapper_loadIMapper(AIMapper** outImplementation) {
  static IMapperProvider<RhizoMapperImpl> provider;
  return provider.load(outImplementation);
}


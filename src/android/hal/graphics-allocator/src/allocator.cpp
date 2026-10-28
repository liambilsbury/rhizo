#include <gbm.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include "aidl/android/hardware/graphics/allocator/BnAllocator.h"

#include "rhizo/buffer_metadata.h"
#include "rhizo/memfd_buffer.h"
#include "rhizo/virtgpu_transfer.h"

using aidl::android::hardware::common::NativeHandle;
using aidl::android::hardware::graphics::allocator::AllocationResult;
using aidl::android::hardware::graphics::allocator::BnAllocator;
using aidl::android::hardware::graphics::allocator::BufferDescriptorInfo;
using ndk::ScopedAStatus;
using ndk::ScopedFileDescriptor;

namespace {

// write the message to kmsg
void klog(const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    dprintf(fd, "<5>rhizo-graphics-allocator: %s\n", msg);
    close(fd);
  }
}

// check RHIZO_ALLOC_RING for the allocation ring
bool AllocRingEnabled() {
  static const bool on = [] {
    const char* v = getenv("RHIZO_ALLOC_RING");
    return v && *v && strcmp(v, "0") != 0;
  }();
  return on;
}

constexpr int32_t kErrNoResources = 1;
constexpr int32_t kErrUnsupported = 2;

// return a service-specific error status with the code and message
ScopedAStatus allocationError(int32_t code, const char* msg) {
  return ScopedAStatus::fromServiceSpecificErrorWithMessage(code, msg);
}

constexpr uint64_t kUsageCpuReadOften = 1ULL << 1;
constexpr uint64_t kUsageCpuWriteOften = 3ULL << 4;
constexpr uint64_t kUsageGpuTexture = 1ULL << 8;
constexpr uint64_t kUsageGpuRenderTarget = 1ULL << 9;
constexpr uint64_t kUsageComposerOverlay = 1ULL << 11;
constexpr uint64_t kUsageComposerClientTarget = 1ULL << 12;
constexpr uint64_t kUsageProtected = 1ULL << 14;

// a GBM buffer object and its exported dmabuf
struct PlaneBo {
  struct gbm_bo* bo = nullptr;
  int fd = -1;
  int32_t stride = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  // destroy the bo and close its fd
  void Release() {
    if (fd >= 0) close(fd);
    if (bo) gbm_bo_destroy(bo);
    bo = nullptr;
    fd = -1;
  }
};

// create a bo, trying the linear modifier first
struct gbm_bo* CreateBo(struct gbm_device* gbm, uint32_t width, uint32_t height, uint32_t format, uint32_t flags) {
  uint64_t modifier = 0;
  struct gbm_bo* bo = gbm_bo_create_with_modifiers2(gbm, width, height, format, &modifier, 1, flags);
  if (!bo) bo = gbm_bo_create(gbm, width, height, format, flags);
  return bo;
}

// create and export a linear R8 bo for a plane
bool CreatePlaneBo(struct gbm_device* gbm, uint32_t width, uint32_t height, PlaneBo* out) {
  struct gbm_bo* bo = CreateBo(gbm, width, height, GBM_FORMAT_R8, GBM_BO_USE_LINEAR);
  if (!bo) {
    char buf[128];
    snprintf(buf, sizeof(buf), "gbm_bo_create failed for a %ux%u R8 plane", width, height);
    klog(buf);
    return false;
  }
  out->bo = bo;
  out->fd = gbm_bo_get_fd(bo);
  out->stride = static_cast<int32_t>(gbm_bo_get_stride(bo));
  out->width = width;
  out->height = height;
  if (out->fd < 0 || out->stride <= 0) {
    out->Release();
    return false;
  }
  return true;
}

// allocate a 4:2:0 buffer as three linear R8 bos
bool CreateYuv420Planes(struct gbm_device* gbm, uint32_t width, uint32_t height, PlaneBo planes[3]) {
  uint32_t lumaWidth = width, chromaWidth = width / 2;
  for (int attempt = 0; attempt < 3; attempt++) {
    bool ok = CreatePlaneBo(gbm, lumaWidth, height, &planes[0]) &&
              CreatePlaneBo(gbm, chromaWidth, height / 2, &planes[1]) &&
              CreatePlaneBo(gbm, chromaWidth, height / 2, &planes[2]);
    if (ok && planes[1].stride == planes[2].stride && planes[0].stride == 2 * planes[1].stride) return true;
    int32_t lumaStride = planes[0].stride, chromaStride = planes[1].stride;
    for (int p = 0; p < 3; p++) planes[p].Release();
    if (!ok || lumaStride <= 0 || chromaStride <= 0) return false;
    uint32_t target = static_cast<uint32_t>(std::max(lumaStride, 2 * chromaStride));
    lumaWidth = std::max(lumaWidth, target);
    chromaWidth = std::max(chromaWidth, target / 2);
  }
  klog("no luma pitch twice the chroma pitch after 3 tries");
  return false;
}

// zero a bo and its host copy
void ZeroFill(int drmFd, struct gbm_bo* bo, int boFd, uint64_t size, uint32_t width, uint32_t height,
              uint64_t bufferId, int32_t stride) {
  void* zaddr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, boFd, 0);
  if (zaddr == MAP_FAILED) {
    char buf[128];
    snprintf(buf, sizeof(buf), "zero-fill mmap failed errno=%d (%s) size=%llu", errno, strerror(errno),
             (unsigned long long)size);
    klog(buf);
    return;
  }
  memset(zaddr, 0, size);
  munmap(zaddr, size);
  if (!rhizo::VirtgpuTransferToHostHandle(drmFd, gbm_bo_get_handle(bo).u32, static_cast<int>(width),
                                          static_cast<int>(height))) {
    char buf[160];
    snprintf(buf, sizeof(buf), "zero-fill TransferToHost FAILED bufferId=%llu w=%u h=%u stride=%d",
             (unsigned long long)bufferId, width, height, stride);
    klog(buf);
  }
}

// make a buffer's sealed one-page shared-metadata memfd
int CreateSharedMetadata() {
  int fd = rhizo::CreateBufferMemfd("rhizo-metadata", rhizo::kSharedMetadataBytes);
  if (fd < 0) return -1;
  rhizo::SharedMetadata m{rhizo::kSharedMetadataMagic, rhizo::kSharedMetadataVersion, 0, 0};
  if (pwrite(fd, &m, sizeof(m), 0) != static_cast<ssize_t>(sizeof(m))) {
    close(fd);
    return -1;
  }
  return fd;
}

constexpr uint64_t kKnownUsageMask =
    0xfULL |
    (0xfULL << 4) |
    (1ULL << 8) |
    (1ULL << 9) |
    (1ULL << 11) |
    (1ULL << 12) |
    (1ULL << 14) |
    (1ULL << 15) |
    (1ULL << 16) |
    (1ULL << 17) |
    (1ULL << 18) |
    (1ULL << 20) |
    (1ULL << 22) |
    (1ULL << 23) |
    (1ULL << 24) |
    (1ULL << 25) |
    (1ULL << 26) |
    (1ULL << 27) |
    (0xfULL << 28) |
    (1ULL << 32) |
    (0xffffULL << 48);

class RhizoAllocator : public BnAllocator {
 public:
  // choose memfd buffers or the GBM render node
  RhizoAllocator() {
    const char* a = getenv("RHIZO_ALLOCATOR");
    memfd_ = a && strcmp(a, "memfd") == 0;
    if (memfd_) {
      klog("memfd buffers (RHIZO_ALLOCATOR=memfd), no render node opened");
      return;
    }
    fd_ = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (fd_ < 0) {
      klog("FATAL: cannot open /dev/dri/renderD128");
      return;
    }
    gbm_ = gbm_create_device(fd_);
    if (!gbm_) {
      klog("FATAL: gbm_create_device failed");
      return;
    }
    klog("gbm device created");
  }

  // return an unsupported error
  ScopedAStatus allocate(const std::vector<uint8_t>&, int32_t,
                          AllocationResult*) override {
    return allocationError(kErrUnsupported, "V1 allocate() not implemented; use allocate2");
  }

  // allocate GBM or memfd buffers and encode their handles
  ScopedAStatus allocate2(const BufferDescriptorInfo& descriptor, int32_t count,
                           AllocationResult* out) override {
    if (!ready()) return allocationError(kErrNoResources, "no GBM device");
    if (count <= 0) return allocationError(kErrUnsupported, "count <= 0");

    int32_t pixelFormat = static_cast<int32_t>(descriptor.format);
    uint64_t usage = static_cast<uint64_t>(descriptor.usage);
    if (usage & ~kKnownUsageMask) {
      return allocationError(kErrUnsupported, "unknown usage bits");
    }
    if (!descriptor.additionalOptions.empty()) {
      return allocationError(kErrUnsupported, "unknown additionalOptions");
    }
    if (usage & kUsageProtected) {
      return allocationError(kErrUnsupported, "PROTECTED unsupported in v1");
    }
    int32_t layoutFormat = rhizo::ResolvePixelFormat(pixelFormat, usage);
    int32_t drmFourcc, bytesPerPixel;
    bool isBlob = (layoutFormat == rhizo::kPixelFormatBLOB);
    bool isYuv420 = rhizo::IsYuv420Flexible(layoutFormat);
    bool isPacked24 = (layoutFormat == rhizo::kPixelFormatRGB888);
    uint32_t gbmFormat;
    if (isBlob) {
      gbmFormat = GBM_FORMAT_R8;
      drmFourcc = rhizo::kDrmFormatInvalid;
      bytesPerPixel = 1;
    } else if (!rhizo::PixelFormatToDrmFourcc(layoutFormat, &drmFourcc, &bytesPerPixel)) {
      return allocationError(kErrUnsupported, "unsupported PixelFormat");
    } else if (isYuv420 || isPacked24) {
      gbmFormat = GBM_FORMAT_R8;
    } else {
      gbmFormat = static_cast<uint32_t>(drmFourcc);
    }

    uint32_t flags = 0;
    if (usage & (kUsageCpuReadOften | kUsageCpuWriteOften)) flags |= GBM_BO_USE_LINEAR;
    if (usage & kUsageGpuRenderTarget) flags |= GBM_BO_USE_RENDERING;
    if (usage & (kUsageComposerOverlay | kUsageComposerClientTarget)) flags |= GBM_BO_USE_SCANOUT;
    if (flags == 0) flags = GBM_BO_USE_LINEAR;

    int32_t yv12LumaStride = 0, yv12ChromaStride = 0, yv12CrOffset = 0, yv12CbOffset = 0;
    if (isYuv420) {
      if (descriptor.width <= 0 || descriptor.height <= 0 || (descriptor.width % 2) != 0 ||
          (descriptor.height % 2) != 0) {
        return allocationError(kErrUnsupported, "YUV 4:2:0 requires positive even width/height");
      }
      auto alignUp16 = [](int32_t v) { return (v + 15) & ~15; };
      yv12LumaStride = alignUp16(descriptor.width);
      int64_t ySize = static_cast<int64_t>(yv12LumaStride) * descriptor.height;
      yv12ChromaStride = alignUp16(yv12LumaStride / 2);
      int64_t cSize = static_cast<int64_t>(yv12ChromaStride) * (descriptor.height / 2);
      yv12CrOffset = static_cast<int32_t>(ySize);
      yv12CbOffset = static_cast<int32_t>(ySize + cSize);
    }

    int32_t width = isBlob    ? std::max<int32_t>(descriptor.width, 1)
                    : isPacked24 ? descriptor.width * 3
                             : descriptor.width;
    int32_t height = isBlob ? 1 : descriptor.height;
    const uint64_t page = static_cast<uint64_t>(getpagesize());

    const bool memfd = memfd_ || rhizo::WantsGuestMemory(usage);
    std::vector<NativeHandle> buffers;
    buffers.reserve(count);
    int32_t stride = 0;

    for (int32_t i = 0; i < count; i++) {
      int fds[rhizo::kMaxFds] = {-1, -1, -1, -1};
      int32_t numFds = 1;
      rhizo::HandleFields f;
      f.width = isPacked24 ? descriptor.width : width;
      f.height = height;
      f.pixelFormat = pixelFormat;
      f.drmFourcc = drmFourcc;
      f.usage = usage;
      f.layerCount = descriptor.layerCount > 0 ? descriptor.layerCount : 1;
      ino_t allocRingIno = 0;
      static std::atomic<uint64_t> nextBufferId{1};
      uint64_t bufferId = nextBufferId.fetch_add(1);
      f.bufferId = bufferId;
      if (memfd) {
        int32_t unitBytes = isPacked24 ? 3 : (isBlob || isYuv420) ? 1 : bytesPerPixel;
        int32_t boStride = isYuv420 ? yv12LumaStride
                                    : rhizo::LinearStrideBytes(isPacked24 ? descriptor.width : width, unitBytes);
        if (boStride < 0) return allocationError(kErrUnsupported, "memfd row stride is not a positive int32");
        uint64_t allocSize = isYuv420 ? rhizo::MemfdYuv420Bytes(yv12LumaStride, yv12ChromaStride, descriptor.height)
                             : isBlob ? static_cast<uint64_t>(boStride)
                                      : rhizo::MemfdBufferBytes(boStride, height);
        if (!rhizo::MemfdBufferFits(allocSize)) {
          return allocationError(kErrUnsupported, "memfd buffer is empty or past INT32_MAX bytes");
        }
        fds[0] = rhizo::CreateBufferMemfd("rhizo-buffer", allocSize);
        if (fds[0] < 0) return allocationError(kErrNoResources, "memfd_create failed");
        f.stride = boStride;
        f.allocSize = allocSize;
        f.modifier = 0;
        if (isYuv420) {
          f.numPlanes = 3;
          f.planes[0] = {0, 0, yv12LumaStride};
          f.planes[1] = {0, yv12CrOffset, yv12ChromaStride};
          f.planes[2] = {0, yv12CbOffset, yv12ChromaStride};
        } else {
          f.numPlanes = 1;
          f.planes[0] = {0, 0, boStride};
        }
      } else if (isYuv420) {
        PlaneBo planes[3];
        if (!CreateYuv420Planes(gbm_, static_cast<uint32_t>(descriptor.width),
                                static_cast<uint32_t>(descriptor.height), planes)) {
          return allocationError(kErrNoResources, "GBM allocation of a 4:2:0 plane failed");
        }
        numFds = 3;
        f.numPlanes = 3;
        f.stride = planes[0].stride;
        f.modifier = gbm_bo_get_modifier(planes[0].bo);
        for (int p = 0; p < 3; p++) {
          f.planes[p] = {p, 0, planes[p].stride};
          uint64_t planeBytes = static_cast<uint64_t>(planes[p].stride) * planes[p].height;
          ZeroFill(fd_, planes[p].bo, planes[p].fd, planeBytes, planes[p].width, planes[p].height, bufferId,
                   planes[p].stride);
          fds[p] = planes[p].fd;
          planes[p].fd = -1;
          planes[p].Release();
        }
        rhizo::DecodedHandle layout;
        layout.valid = true;
        layout.width = f.width;
        layout.height = f.height;
        layout.drmFourcc = f.drmFourcc;
        layout.numFds = numFds;
        layout.planeFds = numFds;
        layout.numPlanes = f.numPlanes;
        for (int p = 0; p < 3; p++) layout.planes[p] = f.planes[p];
        rhizo::CpuLayout cpu;
        if (!rhizo::ComputeCpuLayout(layout, page, &cpu)) {
          for (int p = 0; p < 3; p++) close(fds[p]);
          return allocationError(kErrNoResources, "4:2:0 planes have no CPU layout");
        }
        f.allocSize = cpu.span;
      } else {
        PlaneBo plane;
        plane.bo = CreateBo(gbm_, width, height, gbmFormat, flags);
        if (!plane.bo) {
          char buf[128];
          snprintf(buf, sizeof(buf), "gbm_bo_create failed (%dx%d fmt=0x%x flags=0x%x)", width,
                   height, gbmFormat, flags);
          klog(buf);
          return allocationError(kErrNoResources, "GBM allocation failed");
        }
        plane.fd = gbm_bo_get_fd(plane.bo);
        if (plane.fd < 0) {
          plane.Release();
          return allocationError(kErrNoResources, "gbm_bo_get_fd failed");
        }
        int32_t boStride = static_cast<int32_t>(gbm_bo_get_stride(plane.bo));
        f.stride = boStride;
        f.modifier = gbm_bo_get_modifier(plane.bo);
        f.allocSize = static_cast<uint64_t>(boStride) * (height > 0 ? height : 1);
        f.numPlanes = 1;
        f.planes[0] = {0, 0, boStride};
        ZeroFill(fd_, plane.bo, plane.fd, f.allocSize, static_cast<uint32_t>(width),
                 static_cast<uint32_t>(height), bufferId, boStride);
        fds[0] = plane.fd;
        plane.fd = -1;
        plane.Release();
      }
      if (isYuv420) {
        int meta = CreateSharedMetadata();
        if (meta < 0) {
          for (int p = 0; p < numFds; p++) close(fds[p]);
          return allocationError(kErrNoResources, "shared metadata memfd failed");
        }
        fds[numFds++] = meta;
        f.hasMetaFd = true;
      }
      if (AllocRingEnabled()) {
        struct stat allocRingSt {};
        if (fstat(fds[0], &allocRingSt) == 0) allocRingIno = allocRingSt.st_ino;
      }

      size_t nameLen = strnlen(reinterpret_cast<const char*>(descriptor.name.data()),
                                descriptor.name.size());

      native_handle_t* nh = rhizo::Encode(f, fds, numFds, reinterpret_cast<const char*>(descriptor.name.data()),
                                          static_cast<int32_t>(nameLen));
      if (!nh) {
        for (int p = 0; p < numFds; p++) close(fds[p]);
        return allocationError(kErrNoResources, "native_handle_create failed");
      }
      if (AllocRingEnabled()) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "alloc ino=%llu id=%llu pid=%d size=%llu usage=0x%llx %dx%d fmt=0x%x name=%.*s",
                 (unsigned long long)allocRingIno, (unsigned long long)bufferId,
                 AIBinder_getCallingPid(), (unsigned long long)f.allocSize,
                 (unsigned long long)usage, descriptor.width, descriptor.height, pixelFormat,
                 static_cast<int>(nameLen), reinterpret_cast<const char*>(descriptor.name.data()));
        klog(buf);
      }

      NativeHandle aidlHandle;
      for (int p = 0; p < numFds; p++) aidlHandle.fds.emplace_back(ScopedFileDescriptor(nh->data[p]));
      aidlHandle.ints.assign(nh->data + numFds, nh->data + numFds + nh->numInts);
      native_handle_delete(nh);
      buffers.push_back(std::move(aidlHandle));
      stride = isYuv420 ? f.stride : f.stride / bytesPerPixel;
    }

    out->stride = stride;
    out->buffers = std::move(buffers);
    return ScopedAStatus::ok();
  }

  // answer whether a descriptor can be allocated
  ScopedAStatus isSupported(const BufferDescriptorInfo& descriptor, bool* out) override {
    int32_t pixelFormat = static_cast<int32_t>(descriptor.format);
    uint64_t usage = static_cast<uint64_t>(descriptor.usage);
    int32_t layoutFormat = rhizo::ResolvePixelFormat(pixelFormat, usage);
    int32_t fourcc, bpp;
    bool ok = ready() && descriptor.width > 0 &&
              (pixelFormat == rhizo::kPixelFormatBLOB ||
               (descriptor.height > 0 && rhizo::PixelFormatToDrmFourcc(layoutFormat, &fourcc, &bpp))) &&
              !(usage & kUsageProtected) && (usage & ~kKnownUsageMask) == 0 &&
              descriptor.additionalOptions.empty();
    *out = ok;
    return ScopedAStatus::ok();
  }

  // return rhizo as the mapper library suffix
  ScopedAStatus getIMapperLibrarySuffix(std::string* out) override {
    *out = "rhizo";
    return ScopedAStatus::ok();
  }

  // return whether buffers can be made
  bool ready() const { return memfd_ || gbm_ != nullptr; }

 private:
  int fd_ = -1;
  struct gbm_device* gbm_ = nullptr;
  bool memfd_ = false;
};

}

// register the allocator service and serve binder calls
int main() {
  klog("main() entered");
  auto device = ndk::SharedRefBase::make<RhizoAllocator>();
  if (!device->ready()) {
    klog("FATAL: allocator not ready (no GBM device, and RHIZO_ALLOCATOR is not memfd), exiting");
    return 1;
  }
  const std::string instance =
      std::string(RhizoAllocator::descriptor) + "/default";
  binder_status_t status =
      AServiceManager_addService(device->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    char buf[128];
    snprintf(buf, sizeof(buf), "addService FAILED status=%d", status);
    klog(buf);
    return 1;
  }
  klog("registered, joining thread pool");
  ABinderProcess_setThreadPoolMaxThreadCount(0);
  ABinderProcess_joinThreadPool();
  klog("joinThreadPool RETURNED (unexpected)");
  return 0;
}

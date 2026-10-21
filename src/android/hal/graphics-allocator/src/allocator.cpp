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
    int32_t drmFourcc, bytesPerPixel;
    bool isBlob = (pixelFormat == rhizo::kPixelFormatBLOB);
    bool isYuv420 = rhizo::IsYuv420Flexible(pixelFormat);
    bool isPacked24 = (pixelFormat == rhizo::kPixelFormatRGB888);
    uint32_t gbmFormat;
    if (isBlob) {
      gbmFormat = GBM_FORMAT_R8;
      drmFourcc = rhizo::kDrmFormatInvalid;
      bytesPerPixel = 1;
    } else if (!rhizo::PixelFormatToDrmFourcc(pixelFormat, &drmFourcc, &bytesPerPixel)) {
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
    int64_t yv12TotalSize = 0;
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
      yv12TotalSize = ySize + cSize * 2;
      yv12CrOffset = static_cast<int32_t>(ySize);
      yv12CbOffset = static_cast<int32_t>(ySize + cSize);
    }

    int32_t width = isBlob    ? std::max<int32_t>(descriptor.width, 1)
                    : isYuv420 ? static_cast<int32_t>(std::max<int64_t>(yv12TotalSize, 1))
                    : isPacked24 ? descriptor.width * 3
                             : descriptor.width;
    int32_t height = (isBlob || isYuv420) ? 1 : descriptor.height;

    std::vector<NativeHandle> buffers;
    buffers.reserve(count);
    int32_t stride = 0;

    for (int32_t i = 0; i < count; i++) {
      struct gbm_bo* bo = nullptr;
      int boFd = -1;
      int32_t boStride = 0;
      uint64_t boModifier = 0;
      uint64_t allocSize = 0;
      ino_t allocRingIno = 0;
      static std::atomic<uint64_t> nextBufferId{1};
      uint64_t bufferId = nextBufferId.fetch_add(1);
      if (memfd_) {
        int32_t unitBytes = isPacked24 ? 3 : (isBlob || isYuv420) ? 1 : bytesPerPixel;
        boStride = rhizo::LinearStrideBytes(isPacked24 ? descriptor.width : width, unitBytes);
        if (boStride < 0) return allocationError(kErrUnsupported, "memfd row stride is not a positive int32");
        allocSize = isYuv420 ? rhizo::MemfdYuv420Bytes(yv12LumaStride, yv12ChromaStride, descriptor.height)
                    : isBlob ? static_cast<uint64_t>(boStride)
                             : rhizo::MemfdBufferBytes(boStride, height);
        if (!rhizo::MemfdBufferFits(allocSize)) {
          return allocationError(kErrUnsupported, "memfd buffer is empty or past INT32_MAX bytes");
        }
        boFd = rhizo::CreateBufferMemfd("rhizo-buffer", allocSize);
        if (boFd < 0) return allocationError(kErrNoResources, "memfd_create failed");
        boModifier = 0;
      } else {
        uint64_t modifier = 0;
        bo = gbm_bo_create_with_modifiers2(gbm_, width, height, gbmFormat, &modifier, 1, flags);
        if (!bo) {
          bo = gbm_bo_create(gbm_, width, height, gbmFormat, flags);
        }
        if (!bo) {
          char buf[128];
          snprintf(buf, sizeof(buf), "gbm_bo_create failed (%dx%d fmt=0x%x flags=0x%x)", width,
                   height, gbmFormat, flags);
          klog(buf);
          return allocationError(kErrNoResources, "GBM allocation failed");
        }
        boFd = gbm_bo_get_fd(bo);
        if (boFd < 0) {
          gbm_bo_destroy(bo);
          return allocationError(kErrNoResources, "gbm_bo_get_fd failed");
        }
        boStride = static_cast<int32_t>(gbm_bo_get_stride(bo));
        boModifier = gbm_bo_get_modifier(bo);
        allocSize = isYuv420 ? static_cast<uint64_t>(yv12TotalSize)
                             : static_cast<uint64_t>(boStride) * (height > 0 ? height : 1);
      }
      if (AllocRingEnabled()) {
        struct stat allocRingSt {};
        if (fstat(boFd, &allocRingSt) == 0) allocRingIno = allocRingSt.st_ino;
      }

      if (!memfd_) {
        void* zaddr = mmap(nullptr, allocSize, PROT_READ | PROT_WRITE, MAP_SHARED, boFd, 0);
        if (zaddr != MAP_FAILED) {
          memset(zaddr, 0, allocSize);
          munmap(zaddr, allocSize);
          if (!rhizo::VirtgpuTransferToHostHandle(fd_, gbm_bo_get_handle(bo).u32, width, height)) {
            char buf[160];
            snprintf(buf, sizeof(buf),
                     "zero-fill TransferToHost FAILED bufferId=%llu w=%d h=%d stride=%d",
                     (unsigned long long)bufferId, width, height, boStride);
            klog(buf);
          }
        } else {
          char buf[128];
          snprintf(buf, sizeof(buf), "zero-fill mmap failed errno=%d (%s) size=%llu", errno,
                   strerror(errno), (unsigned long long)allocSize);
          klog(buf);
        }
      }

      size_t nameLen = strnlen(reinterpret_cast<const char*>(descriptor.name.data()),
                                descriptor.name.size());

      native_handle_t* nh = rhizo::Encode(
          boFd, isYuv420 ? descriptor.width : (isPacked24 ? descriptor.width : width),
          isYuv420 ? descriptor.height : height,
          pixelFormat, drmFourcc, usage, isYuv420 ? yv12LumaStride : boStride, boModifier,
          descriptor.layerCount > 0 ? descriptor.layerCount : 1, allocSize, bufferId,
          isYuv420 ? yv12ChromaStride : 0, isYuv420 ? yv12CrOffset : 0,
          isYuv420 ? yv12CbOffset : 0, reinterpret_cast<const char*>(descriptor.name.data()),
          static_cast<int32_t>(nameLen));
      if (bo) gbm_bo_destroy(bo);
      if (!nh) {
        close(boFd);
        return allocationError(kErrNoResources, "native_handle_create failed");
      }
      if (AllocRingEnabled()) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "alloc ino=%llu id=%llu pid=%d size=%llu usage=0x%llx %dx%d fmt=0x%x name=%.*s",
                 (unsigned long long)allocRingIno, (unsigned long long)bufferId,
                 AIBinder_getCallingPid(), (unsigned long long)allocSize,
                 (unsigned long long)usage, descriptor.width, descriptor.height, pixelFormat,
                 static_cast<int>(nameLen), reinterpret_cast<const char*>(descriptor.name.data()));
        klog(buf);
      }

      NativeHandle aidlHandle;
      aidlHandle.fds.emplace_back(ScopedFileDescriptor(nh->data[0]));
      aidlHandle.ints.assign(nh->data + rhizo::kNumFds, nh->data + nh->numInts + rhizo::kNumFds);
      native_handle_delete(nh);
      buffers.push_back(std::move(aidlHandle));
      stride = isYuv420 ? yv12LumaStride : boStride / bytesPerPixel;
    }

    out->stride = stride;
    out->buffers = std::move(buffers);
    return ScopedAStatus::ok();
  }

  // answer whether a descriptor can be allocated
  ScopedAStatus isSupported(const BufferDescriptorInfo& descriptor, bool* out) override {
    int32_t pixelFormat = static_cast<int32_t>(descriptor.format);
    uint64_t usage = static_cast<uint64_t>(descriptor.usage);
    int32_t fourcc, bpp;
    bool ok = ready() && descriptor.width > 0 &&
              (pixelFormat == rhizo::kPixelFormatBLOB ||
               (descriptor.height > 0 && rhizo::PixelFormatToDrmFourcc(pixelFormat, &fourcc, &bpp))) &&
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

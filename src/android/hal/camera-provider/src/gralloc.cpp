#include "gralloc.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <algorithm>
#include <mutex>
#include <string>
#include <vector>

#include <android/hardware/graphics/mapper/IMapper.h>

#include "log.h"

namespace rhizo::camera {

namespace {

constexpr int64_t kMetadataWidth = 3;
constexpr int64_t kMetadataHeight = 4;
constexpr int64_t kMetadataAllocationSize = 10;
constexpr int64_t kMetadataPlaneLayouts = 15;
constexpr uint64_t kCpuWriteOften = 0x3ULL << 4;
constexpr char kStandardMetadataTypeName[] = "android.hardware.graphics.common.StandardMetadataType";

using LoadMapperFn = AIMapper_Error (*)(AIMapper**);

// load the AIMapper of the allocator's mapper library
AIMapper* LoadMapper() {
  std::vector<std::string> candidates;
  if (const char* env = getenv("RHIZO_CAMERA_MAPPER"); env != nullptr && *env != '\0') candidates.push_back(env);
  candidates.push_back("/vendor/lib64/hw/mapper.rhizo.so");
  candidates.push_back("mapper.rhizo.so");
  for (const std::string& path : candidates) {
    void* lib = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr) {
      klogf("mapper: dlopen %s failed: %s", path.c_str(), dlerror());
      continue;
    }
    auto load = reinterpret_cast<LoadMapperFn>(dlsym(lib, "AIMapper_loadIMapper"));
    AIMapper* mapper = nullptr;
    if (load == nullptr || load(&mapper) != AIMAPPER_ERROR_NONE || mapper == nullptr) {
      klogf("mapper: %s has no usable AIMapper_loadIMapper", path.c_str());
      dlclose(lib);
      continue;
    }
    if (mapper->version < AIMAPPER_VERSION_5) {
      klogf("mapper: %s is AIMapper version %u, want 5", path.c_str(), static_cast<unsigned>(mapper->version));
      continue;
    }
    klogf("mapper: loaded %s", path.c_str());
    return mapper;
  }
  return nullptr;
}

}

// return the process's mapper, or null
Gralloc* Gralloc::Get() {
  static std::once_flag once;
  static Gralloc* instance = nullptr;
  std::call_once(once, [] {
    if (AIMapper* m = LoadMapper()) instance = new Gralloc(m);
  });
  return instance;
}

// import a buffer handle from binder, or return null
buffer_handle_t Gralloc::importBuffer(const native_handle_t* raw) {
  buffer_handle_t out = nullptr;
  AIMapper_Error err = mapper_->v5.importBuffer(raw, &out);
  if (err != AIMAPPER_ERROR_NONE) {
    klogf("mapper: importBuffer failed (%d)", static_cast<int>(err));
    return nullptr;
  }
  return out;
}

void Gralloc::freeBuffer(buffer_handle_t buffer) {
  if (buffer != nullptr) mapper_->v5.freeBuffer(buffer);
}

// read a standard metadata value encoded as a uint64
bool Gralloc::metadataU64(buffer_handle_t buffer, int64_t type, uint64_t* out) {
  uint8_t buf[128];
  int32_t n = mapper_->v5.getStandardMetadata(buffer, type, buf, sizeof(buf));
  size_t nameLen = strlen(kStandardMetadataTypeName);
  size_t want = 8 + nameLen + 8 + 8;
  if (n <= 0 || static_cast<size_t>(n) != want) return false;
  int64_t len;
  memcpy(&len, buf, 8);
  if (static_cast<size_t>(len) != nameLen || memcmp(buf + 8, kStandardMetadataTypeName, nameLen) != 0) {
    return false;
  }
  int64_t t;
  memcpy(&t, buf + 8 + nameLen, 8);
  if (t != type) return false;
  memcpy(out, buf + 8 + nameLen + 8, 8);
  return true;
}

// lock a buffer for CPU writes and describe its planes
bool Gralloc::lock(buffer_handle_t buffer, LockedBuffer* out) {
  uint64_t width = 0, height = 0, allocation = 0;
  if (!metadataU64(buffer, kMetadataWidth, &width) || !metadataU64(buffer, kMetadataHeight, &height) ||
      width == 0 || height == 0 || width > 0x7fffffff || height > 0x7fffffff) {
    klogf("mapper: buffer %p has no usable width/height", buffer);
    return false;
  }
  int32_t size = mapper_->v5.getStandardMetadata(buffer, kMetadataPlaneLayouts, nullptr, 0);
  if (size <= 0) {
    klogf("mapper: buffer %p has no plane layouts (%d)", buffer, size);
    return false;
  }
  std::vector<uint8_t> layout(static_cast<size_t>(size));
  if (mapper_->v5.getStandardMetadata(buffer, kMetadataPlaneLayouts, layout.data(), layout.size()) != size) {
    return false;
  }
  std::vector<PlaneLayoutInfo> planes;
  if (!DecodePlaneLayouts(layout.data(), layout.size(), &planes)) {
    klogf("mapper: buffer %p plane layouts do not decode", buffer);
    return false;
  }
  size_t mapped = 0;
  if (metadataU64(buffer, kMetadataAllocationSize, &allocation) && allocation > 0) {
    mapped = static_cast<size_t>(allocation);
  } else {
    for (const PlaneLayoutInfo& p : planes) {
      if (p.offsetBytes >= 0 && p.totalSizeBytes > 0) {
        mapped = std::max(mapped, static_cast<size_t>(p.offsetBytes + p.totalSizeBytes));
      }
    }
  }
  ARect region{0, 0, static_cast<int32_t>(width), static_cast<int32_t>(height)};
  void* data = nullptr;
  AIMapper_Error err = mapper_->v5.lock(buffer, kCpuWriteOften, region, -1, &data);
  if (err != AIMAPPER_ERROR_NONE || data == nullptr) {
    klogf("mapper: lock %p failed (%d)", buffer, static_cast<int>(err));
    return false;
  }
  if (!DescribePlanes(planes, static_cast<uint8_t*>(data), mapped, static_cast<int32_t>(width),
                      static_cast<int32_t>(height), out)) {
    klogf("mapper: buffer %p (%llux%llu) has no plane layout the provider can write", buffer,
          static_cast<unsigned long long>(width), static_cast<unsigned long long>(height));
    int fence = -1;
    unlock(buffer, &fence);
    if (fence >= 0) close(fence);
    return false;
  }
  return true;
}

// unlock a buffer, or return false
bool Gralloc::unlock(buffer_handle_t buffer, int* releaseFence) {
  *releaseFence = -1;
  AIMapper_Error err = mapper_->v5.unlock(buffer, releaseFence);
  if (err != AIMAPPER_ERROR_NONE) {
    klogf("mapper: unlock %p failed (%d)", buffer, static_cast<int>(err));
    return false;
  }
  return true;
}

}

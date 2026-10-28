#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>

namespace rhizo {

constexpr uint64_t kMaxMemfdBufferBytes = INT32_MAX;

constexpr uint64_t kUsageGuestMemory = 1ULL << 28;
constexpr uint64_t kUsageCpuMask = 0xffULL;

// return true when a usage selects a guest memfd
inline bool WantsGuestMemory(uint64_t usage) {
  return (usage & kUsageGuestMemory) != 0 && (usage & ~(kUsageCpuMask | kUsageGuestMemory)) == 0;
}

// return a linear row stride rounded up to 64 bytes
inline int32_t LinearStrideBytes(int32_t width, int32_t unitBytes) {
  if (width <= 0 || unitBytes <= 0) return -1;
  const int64_t bytes = (static_cast<int64_t>(width) * unitBytes + 63) & ~static_cast<int64_t>(63);
  return bytes <= INT32_MAX ? static_cast<int32_t>(bytes) : -1;
}

// tell whether a memfd buffer size is in range
inline bool MemfdBufferFits(uint64_t bytes) {
  return bytes > 0 && bytes <= kMaxMemfdBufferBytes;
}

// return the bytes a linear buffer needs
inline uint64_t MemfdBufferBytes(int32_t strideBytes, int32_t height) {
  return static_cast<uint64_t>(strideBytes) * ((static_cast<uint64_t>(height > 0 ? height : 1) + 3) & ~3ull);
}

// return the bytes a YUV 4:2:0 buffer needs
inline uint64_t MemfdYuv420Bytes(int32_t lumaStride, int32_t chromaStride, int32_t height) {
  uint64_t cbOffset = static_cast<uint64_t>(lumaStride) * height + static_cast<uint64_t>(chromaStride) * (height / 2);
  return cbOffset + MemfdBufferBytes(chromaStride, height / 2);
}

// make a memfd sealed at its size
inline int CreateBufferMemfd(const char* name, uint64_t size) {
  if (size == 0) { errno = EINVAL; return -1; }
  int fd = memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING);
  if (fd < 0) return -1;
  if (ftruncate(fd, static_cast<off_t>(size)) != 0 ||
      fcntl(fd, F_ADD_SEALS, F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) != 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  return fd;
}

// tell whether fd is a shmem file
inline bool IsShmemFile(int fd) { return fcntl(fd, F_GET_SEALS) >= 0; }

// tell whether a seal set carries F_SEAL_SHRINK
inline bool SealsHoldSize(int seals) { return seals >= 0 && (seals & F_SEAL_SHRINK) != 0; }

// tell whether fd is a shmem file sealed against shrinking
inline bool ShmemSealedAgainstShrink(int fd) { return SealsHoldSize(fcntl(fd, F_GET_SEALS)); }

// tell whether the mapper may import fd
inline bool ShmemImportAllowed(int fd, uint64_t allocSize) {
  if (!IsShmemFile(fd)) return true;
  struct stat st {};
  return allocSize > 0 && ShmemSealedAgainstShrink(fd) && fstat(fd, &st) == 0 &&
         static_cast<uint64_t>(st.st_size) >= allocSize;
}

}

#pragma once

#include <fcntl.h>

#include <cstdint>
#include <cstring>
#include <set>

#include "rhizo/memfd_buffer.h"

#ifndef F_SEAL_FUTURE_WRITE
#define F_SEAL_FUTURE_WRITE 0x0010
#endif

namespace rhizo {

// tell whether a seal set allows a zero-copy pool
inline bool ShmSealsAllowZeroCopy(int seals) {
  return SealsHoldSize(seals) && (seals & F_SEAL_SEAL) != 0 && (seals & (F_SEAL_WRITE | F_SEAL_FUTURE_WRITE)) == 0;
}

// return the bytes per pixel of a packed DRM format, or 0
inline int32_t ShmBytesPerPixel(uint32_t drmFormat) {
  switch (drmFormat) {
    case 0x34325241: case 0x34325258: case 0x34324241: case 0x34324258: return 4;
    case 0x34324742: case 0x34324752: return 3;
    case 0x36314752: return 2;
    default: return 0;
  }
}

// tell whether a wl_shm pool over the frame's fd fits it
inline bool ShmZeroCopyFits(uint32_t drmFormat, int32_t width, int32_t height, int32_t strideBytes, int64_t fileBytes) {
  const int64_t bpp = ShmBytesPerPixel(drmFormat);
  return bpp > 0 && width > 0 && height > 0 && strideBytes >= static_cast<int64_t>(width) * bpp &&
         static_cast<int64_t>(strideBytes) * height <= fileBytes;
}

// tell whether a frame of 4-byte pixels fits the copy path
inline bool ShmCopyFits(int32_t width, int32_t height, int32_t strideBytes, int64_t fileBytes) {
  return width > 0 && height > 0 && strideBytes >= static_cast<int64_t>(width) * 4 &&
         static_cast<int64_t>(strideBytes) * height <= fileBytes;
}

// return the wl_shm format code for a DRM fourcc
inline uint32_t ShmFormatOf(uint32_t drmFormat) {
  if (drmFormat == 0x34325241) return 0;
  if (drmFormat == 0x34325258) return 1;
  return drmFormat;
}

// return the wl_shm copy format for a frame, or 0xffffffff
inline uint32_t ShmCopyFormat(uint32_t drmFormat) {
  switch (drmFormat) {
    case 0x34325241: case 0x34324241: return 0;
    case 0x34325258: case 0x34324258: return 1;
    default: return 0xffffffffu;
  }
}

// tell whether wl_shm can present drmFormat
inline bool ShmPresentable(const std::set<uint32_t>& advertised, uint32_t drmFormat) {
  return advertised.count(ShmFormatOf(drmFormat)) != 0 || ShmCopyFormat(drmFormat) != 0xffffffffu;
}

// name the wayland globals a connection presents through
inline const char* PresentPathsName(bool dmabuf, bool shm) {
  if (dmabuf && shm) return "zwp_linux_dmabuf_v1 and wl_shm";
  if (dmabuf) return "zwp_linux_dmabuf_v1";
  if (shm) return "wl_shm";
  return "nothing";
}

// copy pixels from src to dst with red and blue swapped
inline void SwapRedBlue(const uint8_t* src, int32_t srcStride, uint8_t* dst, int32_t dstStride, int32_t width,
                        int32_t height) {
  for (int32_t y = 0; y < height; y++) {
    const uint8_t* s = src + static_cast<int64_t>(y) * srcStride;
    uint8_t* d = dst + static_cast<int64_t>(y) * dstStride;
    for (int32_t x = 0; x < width; x++, s += 4, d += 4) {
      d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3];
    }
  }
}

}

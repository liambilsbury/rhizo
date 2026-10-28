#ifndef RHIZO_C2VA_VPP_H
#define RHIZO_C2VA_VPP_H

#include <stdint.h>

#include <mutex>

#include <va/va.h>
#include <va/va_vpp.h>

#include "va/convert.h"
#include "va/runtime.h"

namespace rhizo::c2va {

// pack a DRM fourcc
constexpr uint32_t DrmFourcc(char a, char b, char c, char d) {
  return static_cast<uint32_t>(a) | (static_cast<uint32_t>(b) << 8) | (static_cast<uint32_t>(c) << 16) |
         (static_cast<uint32_t>(d) << 24);
}
constexpr uint32_t kDrmAbgr8888 = DrmFourcc('A', 'B', '2', '4');
constexpr uint32_t kDrmXbgr8888 = DrmFourcc('X', 'B', '2', '4');
constexpr uint32_t kDrmArgb8888 = DrmFourcc('A', 'R', '2', '4');
constexpr uint32_t kDrmXrgb8888 = DrmFourcc('X', 'R', '2', '4');
constexpr uint32_t kDrmNv12 = DrmFourcc('N', 'V', '1', '2');
constexpr uint32_t kDrmYvu420 = DrmFourcc('Y', 'V', '1', '2');
constexpr uint32_t kDrmYuv420 = DrmFourcc('Y', 'U', '1', '2');
constexpr uint32_t kDrmP010 = DrmFourcc('P', '0', '1', '0');
constexpr uint64_t kDrmModLinear = 0;
constexpr uint64_t kDrmModInvalid = 0x00ffffffffffffffULL;

bool IsRgbFourcc(uint32_t drm_fourcc);
// return the X8 twin of an RGB format with alpha
uint32_t OpaqueDrmFormat(uint32_t drm_fourcc);

// a DRM PRIME 2 surface import, destroyed with the holder
class ImportedSurface {
 public:
  ImportedSurface() = default;
  ~ImportedSurface();
  ImportedSurface(const ImportedSurface&) = delete;
  ImportedSurface& operator=(const ImportedSurface&) = delete;

  // import a dmabuf, as its X8 twin when opaque
  Status Import(VADisplay dpy, const DmabufImage& img, bool opaque = false);
  VASurfaceID id() const { return id_; }
  uint32_t va_fourcc() const { return va_fourcc_; }

 private:
  VADisplay dpy_ = nullptr;
  VASurfaceID id_ = VA_INVALID_SURFACE;
  uint32_t va_fourcc_ = 0;
};

// the matrix and range of a VPP conversion
struct VppColor {
  uint8_t matrix;
  bool src_full_range;
  bool dst_full_range;
  uint8_t primaries = 2;
  uint8_t transfer = 2;
};
// fill a pipeline buffer's colour fields from color
void FillVppColor(const VppColor& color, VAProcPipelineParameterBuffer* p);
uint8_t VppMatrixCode(Matrix m);

// check the driver's VPP YUV-to-RGB against the CPU
bool VppYuvToRgb(VADisplay dpy, Matrix m, bool full_range, bool ten_bit);
bool VppRgbToYuv(VADisplay dpy, Matrix m, bool full_range);
// return whether VPP draws BT.709 limited NV12 to RGBA
bool VppUsable(VADisplay dpy);

VAImageFormat RgbImageFormat(uint32_t va_fourcc);

// a VPP context created on first use
class Vpp {
 public:
  ~Vpp();
  // scale and convert src into dst
  Status Run(VADisplay dpy, VASurfaceID src, const VARectangle& src_rect, VASurfaceID dst,
             const VARectangle& dst_rect, const VppColor& color);

 private:
  Status Ensure(VADisplay dpy);
  std::mutex mutex_;
  VADisplay dpy_ = nullptr;
  VAConfigID config_ = VA_INVALID_ID;
  VAContextID context_ = VA_INVALID_ID;
};

}

#endif

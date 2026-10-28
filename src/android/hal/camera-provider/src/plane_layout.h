#ifndef RHIZO_CAMERA_PLANE_LAYOUT_H
#define RHIZO_CAMERA_PLANE_LAYOUT_H

// read the mapper's PLANE_LAYOUTS metadata into image_ops destinations

#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "image_ops.h"

namespace rhizo::camera {

// a locked output buffer described by the mapper's plane layouts
struct LockedBuffer {
  enum class Kind { kNone, kYuv, kRgba, kBlob };
  Kind kind = Kind::kNone;
  int32_t width = 0;
  int32_t height = 0;
  YuvDest yuv{};
  uint8_t* rgba = nullptr;
  int32_t rgbaStride = 0;
  uint8_t* blob = nullptr;
  size_t blobSize = 0;
};

// a plane of PLANE_LAYOUTS
struct PlaneLayoutInfo {
  std::vector<int64_t> componentTypes;
  std::vector<int64_t> componentOffsetBits;
  std::vector<int64_t> componentSizeBits;
  int64_t offsetBytes = 0;
  int64_t sampleIncrementBits = 0;
  int64_t strideBytes = 0;
  int64_t widthSamples = 0;
  int64_t heightSamples = 0;
  int64_t totalSizeBytes = 0;
};

bool DecodePlaneLayouts(const uint8_t* data, size_t size, std::vector<PlaneLayoutInfo>* out);
bool DescribePlanes(const std::vector<PlaneLayoutInfo>& planes, uint8_t* base, size_t mapped,
                    int32_t width, int32_t height, LockedBuffer* out);

}

#endif

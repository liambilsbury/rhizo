#ifndef RHIZO_C2VA_CONVERT_H
#define RHIZO_C2VA_CONVERT_H

// CPU conversions in and out of VA images

#include <stdint.h>

#include "va/runtime.h"

namespace rhizo::c2va {

// an NV12 or P010 image
struct SemiPlanar {
  uint8_t* y;
  int32_t y_pitch;
  uint8_t* uv;
  int32_t uv_pitch;
  int32_t width;
  int32_t height;
  int32_t bytes_per_sample;
};

enum class Matrix { kBt601, kBt709, kBt2020, kFcc, kSmpte240m };

// map a matrix code to a Matrix, else def
Matrix MatrixFor(uint32_t matrix_coefficients, Matrix def);
void KrKbOf(Matrix m, double* kr, double* kb);

void CopySemiPlanarToDest(const SemiPlanar& src, int32_t width, int32_t height, const YuvDest& dst);

// copy a 4:2:0 source into a semi-planar image
void CopySrcToSemiPlanar(const YuvSrc& src, const SemiPlanar& dst);

// convert RGBA to a semi-planar image
void RgbaToSemiPlanar(const uint8_t* rgba, int32_t row_stride, int32_t width, int32_t height, Matrix matrix,
                      bool full_range, const SemiPlanar& dst);

// convert a semi-planar image to scaled full-range RGBA
void SemiPlanarToRgba(const SemiPlanar& src, Matrix matrix, bool full_range, uint8_t* rgba, int32_t row_stride,
                      int32_t dst_width, int32_t dst_height);

}

#endif

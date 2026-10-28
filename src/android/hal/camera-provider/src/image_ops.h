#ifndef RHIZO_CAMERA_IMAGE_OPS_H
#define RHIZO_CAMERA_IMAGE_OPS_H

// scale, convert and encode host camera frames on the CPU

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

namespace rhizo::camera {

// a packed I420 image with no row padding
struct I420View {
  const uint8_t* data;
  int32_t width;
  int32_t height;
};

// a plane of a 4:2:0 destination buffer
struct Plane {
  uint8_t* data;
  int32_t row_stride;
  int32_t pixel_stride;
};

// a 4:2:0 destination in YV12, I420, NV12 or NV21 layout
struct YuvDest {
  Plane y;
  Plane cb;
  Plane cr;
  int32_t width;
  int32_t height;
};

// a rectangle in source pixels
struct Rect {
  int32_t left;
  int32_t top;
  int32_t width;
  int32_t height;
};

Rect CenterCropFor(int32_t src_width, int32_t src_height, int32_t dst_width, int32_t dst_height);

void ScaleI420(const I420View& src, const Rect& crop, const YuvDest& dst);

void ScaleI420ToPacked(const I420View& src, const Rect& crop, uint8_t* dst, int32_t dst_width,
                       int32_t dst_height);

void ScaleI420ToRgba(const I420View& src, const Rect& crop, uint8_t* dst, int32_t dst_row_stride_bytes,
                     int32_t dst_width, int32_t dst_height);

ssize_t EncodeJpeg(const I420View& src, int quality, uint8_t* out, size_t cap);

}

#endif

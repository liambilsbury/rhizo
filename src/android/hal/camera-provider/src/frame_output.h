#ifndef RHIZO_CAMERA_FRAME_OUTPUT_H
#define RHIZO_CAMERA_FRAME_OUTPUT_H

// write a host frame into an output buffer as YUV, RGBA or JPEG

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include <string>
#include <vector>

#include "image_ops.h"

namespace rhizo::camera {

constexpr size_t kCameraBlobSize = 8;
constexpr int32_t kCameraBlobIdJpeg = 0x00FF;
constexpr size_t kMaxThumbnailBytes = 60 * 1024;

// the Exif fields of a capture
struct ExifInfo {
  std::string make;
  std::string model;
  std::string dateTime;
  int32_t orientation = 0;
  int32_t width = 0;
  int32_t height = 0;
};

// the settings of a JPEG capture
struct JpegRequest {
  int32_t quality = 90;
  int32_t thumbnailQuality = 90;
  int32_t thumbnailWidth = 0;
  int32_t thumbnailHeight = 0;
  ExifInfo exif;
};

// scratch buffers a session reuses across frames
struct Scratch {
  std::vector<uint8_t> a;
  std::vector<uint8_t> b;
  std::vector<uint8_t> image;
  std::vector<uint8_t> thumbnail;
  std::vector<uint8_t> thumbnailJpeg;
};

uint16_t ExifOrientation(int32_t degrees);
std::vector<uint8_t> BuildExifApp1(const ExifInfo& info, const uint8_t* thumbnail, size_t thumbnailSize);
ssize_t WriteJpegBlob(const I420View& image, int quality, const std::vector<uint8_t>& app1, uint8_t* blob,
                      size_t blobSize);
I420View StepDown(const I420View& src, Rect* crop, int32_t dstWidth, int32_t dstHeight, Scratch& s);
void FillYuv(const I420View& frame, const YuvDest& dst, Scratch& s);
void FillRgba(const I420View& frame, uint8_t* rgba, int32_t rowStrideBytes, int32_t width, int32_t height,
              Scratch& s);
ssize_t FillJpeg(const I420View& frame, int32_t width, int32_t height, const JpegRequest& req, uint8_t* blob,
                 size_t blobSize, Scratch& s);

}

#endif

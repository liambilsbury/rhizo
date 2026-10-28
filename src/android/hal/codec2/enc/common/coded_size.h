#ifndef RHIZO_C2VA_ENC_CODED_SIZE_H
#define RHIZO_C2VA_ENC_CODED_SIZE_H

// the coded size, padded to the driver's minimum and aligned

#include <stdint.h>

namespace rhizo::c2va::enc {

struct CodedSize {
  uint32_t width;
  uint32_t height;
};

inline CodedSize CodedSizeFor(bool hevc, uint32_t width, uint32_t height, uint32_t min_width, uint32_t min_height) {
  const uint32_t aw = hevc ? 64 : 16, ah = 16;
  const uint32_t w = width > min_width ? width : min_width;
  const uint32_t h = height > min_height ? height : min_height;
  return {(w + aw - 1) / aw * aw, (h + ah - 1) / ah * ah};
}

}

#endif

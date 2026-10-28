#ifndef RHIZO_C2VA_ENC_LEVEL_POLICY_H
#define RHIZO_C2VA_ENC_LEVEL_POLICY_H

// the encoder level policy

#include <stdint.h>

#include <vector>

#include "../h264/h264_syntax.h"
#include "../hevc/hevc_syntax.h"
#include "coded_size.h"

namespace rhizo::c2va::enc {

// return the lowest level that holds the stream, or 0
inline uint32_t MinLevelIdc(bool hevc, uint32_t profile_idc, uint32_t width, uint32_t height, uint32_t min_width,
                            uint32_t min_height, double frame_rate, uint32_t bitrate) {
  const CodedSize c = CodedSizeFor(hevc, width, height, min_width, min_height);
  if (hevc) return hevcenc::ChooseLevel(30, c.width, c.height, frame_rate, bitrate);
  return h264enc::ChooseLevel(profile_idc, 10, c.width / 16, c.height / 16, frame_rate, bitrate);
}

// pick an offered level from the requested and needed levels
inline uint32_t PickLevelIdc(const std::vector<uint32_t>& offered, uint32_t asked, uint32_t needed) {
  if (offered.empty()) return asked;
  bool asked_offered = false;
  for (uint32_t l : offered) asked_offered = asked_offered || l == asked;
  if (asked_offered && needed != 0 && asked >= needed) return asked;
  if (asked > offered.back()) return offered.back();
  if (needed != 0)
    for (uint32_t l : offered)
      if (l >= needed) return l;
  return offered.back();
}

}

#endif

#ifndef RHIZO_C2VA_FUNCTIONAL_CLIPS_H
#define RHIZO_C2VA_FUNCTIONAL_CLIPS_H

// declare the functional clips of clips_data.cpp

#include <stddef.h>
#include <stdint.h>

#include <va/va.h>

#include "va/runtime.h"

namespace rhizo::c2va {

enum class ClipFraming { kAnnexB, kIvf };

struct FunctionalClip {
  const char* name;
  Codec codec;
  VAProfile profile;
  uint32_t bit_depth;
  uint32_t width;
  uint32_t height;
  ClipFraming framing;
  const uint8_t* data;
  size_t size;
  uint32_t frames;
  const char* const* md5;
};

extern const FunctionalClip kFunctionalClips[];
extern const size_t kFunctionalClipCount;

}

#endif

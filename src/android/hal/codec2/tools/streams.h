#ifndef RHIZO_C2VA_STREAMS_H
#define RHIZO_C2VA_STREAMS_H

// split Annex B and IVF input into decode units

#include <stddef.h>
#include <stdint.h>

#include <string>
#include <vector>

#include "va/runtime.h"

namespace rhizo::c2va {

struct Unit {
  std::vector<uint8_t> data;
  bool codec_config = false;
  int64_t pts = 0;
};

bool ReadFile(const std::string& path, std::vector<uint8_t>* out);

// split a stream into access units
std::vector<Unit> SplitAccessUnits(Codec codec, const std::vector<uint8_t>& stream, bool csd);

// read the frames, fourcc and size of an IVF file
bool ReadIvf(const std::vector<uint8_t>& file, std::vector<Unit>* frames, std::string* fourcc, uint32_t* width,
             uint32_t* height);

// parse a codec from its name
bool ParseCodec(const std::string& name, Codec* codec);

}

#endif

#ifndef RHIZO_C2VA_AV1_PARSER_H
#define RHIZO_C2VA_AV1_PARSER_H

// the AV1 frame-level parse

#include <stddef.h>
#include <stdint.h>

#include "dec/av1/av1_bits.h"
#include "dec/av1/av1_syntax.h"

namespace rhizo::c2va::av1 {

enum class ParseError { kNone, kBad, kUnsupported };

// read the OBUs of a low-overhead format stream
class ObuReader {
 public:
  ObuReader(const uint8_t* data, size_t size, Trace* trace = nullptr) : data_(data), size_(size), trace_(trace) {}
  bool Next(Obu* obu);
  bool error() const { return error_; }

 private:
  const uint8_t* data_;
  size_t size_;
  size_t pos_ = 0;
  bool error_ = false;
  Trace* trace_;
};

// parse a Main profile sequence header
ParseError ParseSequenceHeader(const uint8_t* data, size_t size, size_t base_bits, Trace* trace,
                               SequenceHeader* seq);

// return true when the OBU is in the operating point
bool InOperatingPoint(const SequenceHeader& seq, const Obu& obu);

// parse the uncompressed header
ParseError ParseFrameHeader(const SequenceHeader& seq, const RefSlot refs[kNumRefFrames], const Obu& obu,
                            const uint8_t* data, size_t size, size_t base_bits, Trace* trace, FrameHeader* fh);

// parse a tile group into a span per tile
ParseError ParseTileGroup(const FrameHeader& fh, const uint8_t* data, size_t size, size_t data_offset,
                          size_t base_bits, Trace* trace, uint32_t* next_tile, TileSpan* tiles, uint32_t max_tiles,
                          bool* last);

// build a reference slot from a decoded frame
RefSlot MakeRefSlot(const SequenceHeader& seq, const FrameHeader& fh);

// return the setup shear's warpValid
bool WarpValid(const int32_t gm_params[6]);

}

#endif

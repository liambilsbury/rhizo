#ifndef RHIZO_C2VA_CORE_H
#define RHIZO_C2VA_CORE_H

// the interface between a codec core and the VA runtime

#include <stddef.h>
#include <stdint.h>

#include <memory>

#include <va/va.h>

namespace rhizo::c2va {

enum class Status {
  kOk,
  kBadStream,
  kUnsupported,
  kNoMemory,
  kVaError,
};

// a rectangle in luma samples
struct Rect {
  uint32_t left;
  uint32_t top;
  uint32_t width;
  uint32_t height;
};

// colour code points
struct ColorInfo {
  uint32_t primaries = 2;
  uint32_t transfer = 2;
  uint32_t matrix = 2;
  bool full_range = false;
};

struct StreamInfo {
  VAProfile profile;
  uint32_t rt_format;
  uint32_t coded_width;
  uint32_t coded_height;
  Rect visible;
  uint32_t bit_depth;
  uint32_t min_surfaces;
  uint32_t reorder_depth;
  ColorInfo color;
};

// the runtime side of a decoder core
class DecoderHost {
 public:
  virtual ~DecoderHost() = default;

  virtual VADisplay display() = 0;

  // configure the context for a new sequence
  virtual Status Configure(const StreamInfo& info, VAContextID* context) = 0;

  // read the size of the allocated surfaces
  virtual void SurfaceSize(uint32_t* width, uint32_t* height) = 0;

  // acquire a free surface for the core
  virtual Status AcquireSurface(VASurfaceID* surface) = 0;
  virtual void ReleaseSurface(VASurfaceID surface) = 0;

  // output a surface in display order
  virtual void Output(VASurfaceID surface, uint64_t tag, const Rect& crop, const ColorInfo& color) = 0;
  // mark a tag as producing no picture
  virtual void Skip(uint64_t tag) = 0;
};

// a codec decoder that outputs or skips each tag once
class DecoderCore {
 public:
  virtual ~DecoderCore() = default;

  // decode an access unit in the codec's framing
  virtual Status Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) = 0;

  virtual Status Drain() = 0;

  // reset to the stored parameter sets and sequence headers
  virtual void Reset() = 0;
};

std::unique_ptr<DecoderCore> CreateH264Decoder(DecoderHost* host);
std::unique_ptr<DecoderCore> CreateHevcDecoder(DecoderHost* host);
std::unique_ptr<DecoderCore> CreateVp9Decoder(DecoderHost* host);
std::unique_ptr<DecoderCore> CreateAv1Decoder(DecoderHost* host);

struct EncoderConfig {
  VAProfile profile;
  uint32_t level;
  uint32_t width;
  uint32_t height;
  uint32_t framerate_num;
  uint32_t framerate_den;
  uint32_t bitrate;
  enum class RateControl { kCbr, kVbr, kCq } rate_control;
  uint32_t quality;
  uint32_t keyframe_interval;
  ColorInfo color;
  uint32_t min_coded_width = 0;
  uint32_t min_coded_height = 0;
};

class EncoderHost {
 public:
  virtual ~EncoderHost() = default;

  virtual VADisplay display() = 0;

  // configure surfaces aligned to align_width and align_height
  virtual Status Configure(const EncoderConfig& config, VAConfigAttrib* attribs, int num_attribs,
                           uint32_t align_width, uint32_t align_height, VAContextID* context) = 0;
  // acquire a reconstruction surface for the core
  virtual Status AcquireReconSurface(VASurfaceID* surface) = 0;
  virtual void ReleaseReconSurface(VASurfaceID surface) = 0;

  // output parameter sets or an access unit for a tag
  virtual void Output(const uint8_t* data, size_t size, uint64_t tag, int64_t pts, bool keyframe,
                      bool codec_config) = 0;
};

class EncoderCore {
 public:
  virtual ~EncoderCore() = default;

  // encode an input surface held until its Output or Drain
  virtual Status Encode(VASurfaceID input, uint64_t tag, int64_t pts, bool force_keyframe) = 0;
  virtual Status Drain() = 0;
  // set the bitrate from the next picture
  virtual Status SetBitrate(uint32_t bitrate) = 0;
};

std::unique_ptr<EncoderCore> CreateH264Encoder(EncoderHost* host, const EncoderConfig& config, Status* status);
std::unique_ptr<EncoderCore> CreateHevcEncoder(EncoderHost* host, const EncoderConfig& config, Status* status);

}

#endif

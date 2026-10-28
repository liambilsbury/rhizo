#ifndef RHIZO_C2VA_ENC_VA_ENCODER_H
#define RHIZO_C2VA_ENC_VA_ENCODER_H

// the codec-independent half of the VA encoder cores

#include <stddef.h>
#include <stdint.h>

#include <deque>
#include <vector>

#include <va/va.h>

#include "../../va/core.h"
#include "coded_size.h"
#include "rate_control.h"

namespace rhizo::c2va::enc {

enum class NalClass { kParameterSet, kSlice, kOther };

// a planned picture
struct EncPicture {
  bool idr = false;
  uint32_t frames_since_idr = 0;
  uint32_t idr_count = 0;
  VASurfaceID input = VA_INVALID_SURFACE;
  VASurfaceID recon = VA_INVALID_SURFACE;
  VASurfaceID ref = VA_INVALID_SURFACE;
  int qp = 26;
  uint64_t tag = 0;
  int64_t pts = 0;
};

struct DriverInfo {
  bool virgl = false;
  bool virgl_host_radeonsi = false;
  uint32_t rt_formats = 0;
  uint32_t rate_controls = 0;
  uint32_t packed_headers = 0;
};

class VaEncoderBase : public EncoderCore {
 public:
  ~VaEncoderBase() override;

  Status Encode(VASurfaceID input, uint64_t tag, int64_t pts, bool force_keyframe) override;
  Status Drain() override;
  Status SetBitrate(uint32_t bitrate) override;

 protected:
  VaEncoderBase(EncoderHost* host, const EncoderConfig& config);

  Status Probe();
  Status ChooseRateControl();
  // start the session at the coded size
  Status Start(uint32_t rt_format, CodedSize coded, uint32_t align_width, uint32_t align_height,
               size_t coded_buffer_size);
  static size_t CodedBufferSize(uint32_t aligned_width, uint32_t aligned_height, bool ten_bit);

  // add the sequence parameters of an IDR picture
  virtual Status AddSequenceParams(const EncPicture& pic, std::vector<VABufferID>* bufs) = 0;
  virtual Status AddPictureParams(const EncPicture& pic, VABufferID coded, std::vector<VABufferID>* bufs) = 0;
  // add the packed parameter sets of an IDR picture
  virtual Status AddPackedParameterSets(const EncPicture& pic, std::vector<VABufferID>* bufs) = 0;
  // add the slice parameters and any packed slice header
  virtual Status AddSliceParams(const EncPicture& pic, std::vector<VABufferID>* bufs) = 0;
  // classify an escaped NAL unit without its start code
  virtual NalClass Classify(const uint8_t* nal, size_t size) const = 0;
  // write the core's parameter sets in Annex B
  virtual void OwnParameterSets(std::vector<uint8_t>* out) const = 0;
  // rewrite a slice to the core's parameters
  virtual Status FixSlice(const EncPicture& pic, const uint8_t* nal, size_t size, std::vector<uint8_t>* out,
                          int* slice_qp) = 0;

  Status AddBuffer(VABufferType type, const void* data, size_t size, std::vector<VABufferID>* bufs);
  // add an escaped packed NAL unit with its start code
  Status AddPacked(uint32_t packed_type, const std::vector<uint8_t>& data, size_t bit_length,
                   std::vector<VABufferID>* bufs);
  uint32_t packed_headers() const { return packed_used_; }
  bool packed(uint32_t type_bit) const { return (packed_used_ & type_bit) != 0; }

  double frame_rate() const { return fps_; }
  uint32_t bitrate() const { return bitrate_; }
  uint32_t va_rate_control() const { return va_rc_; }

  uint32_t packed_wanted_ = 0;
  uint32_t max_bitrate_ = 0;
  bool hevc_ = false;

  EncoderHost* host_;
  EncoderConfig config_;
  VADisplay dpy_ = nullptr;
  VAContextID ctx_ = VA_INVALID_ID;
  DriverInfo driver_;

 private:
  struct InFlight {
    EncPicture pic;
    int slot;
  };
  static constexpr int kPipelineDepth = 2;

  Status AddRateControl(const EncPicture& pic, std::vector<VABufferID>* bufs);
  // return the VBR peak for a bit rate
  uint32_t PeakFor(uint32_t bitrate) const;
  // check that pic names this encoder's surfaces and buffers
  bool Valid(const EncPicture& pic, int slot) const;
  Status Retire();
  Status SubmitAndRetire(EncPicture pic);
  Status RetireAll();
  // wait for and drop all of the queued pictures
  void Quiesce();
  Status Emit(const EncPicture& pic, const std::vector<uint8_t>& coded);
  void DestroyBuffers(std::vector<VABufferID>* bufs);

  double fps_ = 30.0;
  uint32_t bitrate_ = 0;
  uint32_t va_rc_ = VA_RC_CBR;
  uint32_t packed_used_ = 0;
  bool rc_dirty_ = true;
  bool frame_rc_ = false;
  FrameRateController rc_;
  bool rc_lock_logged_ = false;
  bool rc_trace_ = false;
  int qp_ = 26;

  VABufferID coded_[kPipelineDepth] = {VA_INVALID_ID, VA_INVALID_ID};
  size_t coded_size_ = 0;
  VASurfaceID recon_[2] = {VA_INVALID_SURFACE, VA_INVALID_SURFACE};
  int next_recon_ = 0;
  VASurfaceID last_recon_ = VA_INVALID_SURFACE;
  std::deque<InFlight> inflight_;
  uint64_t submitted_ = 0;
  uint32_t frames_since_idr_ = 0;
  uint32_t idr_count_ = 0;
  bool failed_ = false;
  bool retire_empty_ = false;
  bool force_idr_ = false;
  int lost_in_row_ = 0;

  bool decided_ = false;
  bool driver_param_sets_ = false;
  std::vector<uint8_t> last_config_;
  uint32_t rewritten_ = 0;
};

}

#endif

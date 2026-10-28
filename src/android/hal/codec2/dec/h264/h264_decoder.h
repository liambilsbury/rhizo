#ifndef RHIZO_C2VA_H264_DECODER_H
#define RHIZO_C2VA_H264_DECODER_H

// the H.264 decoder core on VA

#include <stddef.h>
#include <stdint.h>

#include <array>
#include <map>
#include <memory>
#include <vector>

#include "../../va/core.h"
#include "h264_dpb.h"
#include "h264_syntax.h"

namespace rhizo::c2va::h264 {

// derive the VA and DPB stream info from an SPS
Status DeriveStreamInfo(const Sps& sps, StreamInfo* info, uint32_t* dpb_size, uint32_t* reorder_depth);

// receive each finished picture
class PictureObserver {
 public:
  virtual ~PictureObserver() = default;
  // report a finished picture and its list completeness
  virtual void PictureDone(const SliceHeader& first, const CurrentPicture& cur, const Dpb& dpb, bool decoded,
                           bool lists_complete) = 0;
};

class H264Decoder : public DecoderCore, private DpbSink {
 public:
  explicit H264Decoder(DecoderHost* host);
  ~H264Decoder() override;

  Status Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) override;
  Status Drain() override;
  void Reset() override;

  void set_trace(SyntaxTrace* trace) { trace_ = trace; }
  void set_observer(PictureObserver* observer) { observer_ = observer; }

 private:
  // count the DPB frames holding an input's tag
  struct TagRef {
    int holders = 0;
    bool done = false;
  };
  enum class Access { kNeedIdr, kRecovering, kNormal };

  struct Slice {
    SliceHeader sh;
    const uint8_t* nal;
    size_t size;
  };
  // hold the slice fields that mark a new picture
  struct PicKey {
    uint32_t frame_num, pps_id, poc_lsb, idr_pic_id;
    int32_t delta_bottom, delta[2];
    bool field, bottom, idr;
    uint8_t nal_ref_idc, poc_type;
  };
  struct Picture {
    bool open = false;
    bool dropping = false;
    bool saw_first_mb0 = false;
    bool output_allowed = true;
    Pps pps;
    std::vector<Slice> slices;
    CurrentPicture cur;
    VASurfaceID surface = VA_INVALID_SURFACE;
  };

  void OutputStore(const FrameStore& fs) override;
  void RemoveStore(const FrameStore& fs) override;

  void Note(Status s);
  void HandleNal(const uint8_t* nal, size_t size);
  void StoreSps(const uint8_t* nal, size_t size);
  void StorePps(const uint8_t* nal, size_t size);
  const Pps* GetPps(uint32_t pps_id);
  void HandleSlice(const uint8_t* nal, size_t size);
  bool IsNewPicture(const PicKey& a, const PicKey& b) const;
  void StartPicture(const SliceHeader& sh, const Sps& sps, const Pps& pps);
  Status Activate(const Sps& sps);
  void FinishPicture();
  bool Submit(const std::vector<std::vector<RefEntry>>& lists);
  void FillPicture(VAPictureH264* pic, int store, uint8_t structure, bool long_term) const;

  DecoderHost* host_;
  Dpb dpb_;
  SyntaxTrace* trace_ = nullptr;
  PictureObserver* observer_ = nullptr;

  std::array<std::vector<uint8_t>, kMaxSps> sps_raw_;
  std::array<std::unique_ptr<Sps>, kMaxSps> sps_;
  std::array<uint32_t, kMaxSps> sps_gen_ = {};
  std::array<std::vector<uint8_t>, kMaxPps> pps_raw_;
  std::array<std::unique_ptr<Pps>, kMaxPps> pps_;
  std::array<uint32_t, kMaxPps> pps_sps_gen_ = {};

  bool has_active_ = false;
  Sps active_sps_;
  uint32_t active_gen_ = 0;
  Rect crop_ = {};
  ColorInfo color_;

  bool configured_ = false;
  StreamInfo info_ = {};
  VAContextID context_ = VA_INVALID_ID;

  Access access_ = Access::kNeedIdr;
  uint32_t recovery_frame_num_ = 0;
  bool floor_active_ = false;
  int32_t floor_poc_ = 0;
  RecoveryPoint pending_recovery_;

  Picture pic_;
  bool has_last_key_ = false;
  PicKey last_key_ = {};

  bool in_decode_ = false;
  uint64_t cur_tag_ = 0;
  bool cur_tag_done_ = false;
  std::map<uint64_t, TagRef> tags_;
  Status status_ = Status::kOk;
  bool destroying_ = false;
};

}

#endif

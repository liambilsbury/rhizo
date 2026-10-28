// the H.264 encoder core on VA

#include <string.h>

#include <memory>

#include <va/va.h>
#include <va/va_enc_h264.h>

#include "../../va/core.h"
#include "../common/bit_writer.h"
#include "../common/log.h"
#include "../common/va_encoder.h"
#include "h264_syntax.h"

namespace rhizo::c2va::enc {

namespace {

class H264Encoder : public VaEncoderBase {
 public:
  H264Encoder(EncoderHost* host, const EncoderConfig& config) : VaEncoderBase(host, config) {}
  Status Init();

 protected:
  Status AddSequenceParams(const EncPicture& pic, std::vector<VABufferID>* bufs) override;
  Status AddPictureParams(const EncPicture& pic, VABufferID coded, std::vector<VABufferID>* bufs) override;
  Status AddPackedParameterSets(const EncPicture& pic, std::vector<VABufferID>* bufs) override;
  Status AddSliceParams(const EncPicture& pic, std::vector<VABufferID>* bufs) override;
  NalClass Classify(const uint8_t* nal, size_t size) const override;
  void OwnParameterSets(std::vector<uint8_t>* out) const override;
  Status FixSlice(const EncPicture& pic, const uint8_t* nal, size_t size, std::vector<uint8_t>* out,
                  int* slice_qp) override;

 private:
  uint32_t FrameNum(const EncPicture& pic) const { return pic.frames_since_idr % max_frame_num_; }
  // return the POC of a picture
  int32_t Poc(uint32_t frames_since_idr) const { return static_cast<int32_t>(2 * frames_since_idr); }
  h264enc::SliceHeader SliceHeaderFor(const EncPicture& pic) const;

  h264enc::Sps sps_;
  h264enc::Pps pps_;
  h264enc::SliceSyntax syntax_;
  h264enc::SliceSyntax driver_syntax_;
  std::vector<uint8_t> sps_nal_;
  std::vector<uint8_t> pps_nal_;
  uint32_t max_frame_num_ = 16;
};

Status H264Encoder::Init() {
  uint32_t profile_idc = 0, constraints = 0;
  switch (config_.profile) {
    case VAProfileH264ConstrainedBaseline:
      profile_idc = 66;
      constraints = 0x30;
      break;
    case VAProfileH264Main:
      profile_idc = 77;
      break;
    case VAProfileH264High:
      profile_idc = 100;
      break;
    default:
      return Status::kUnsupported;
  }
  if (config_.width < 16 || config_.height < 16 || (config_.width & 1) || (config_.height & 1) ||
      config_.width > 8192 || config_.height > 8192 || config_.framerate_num == 0 || config_.framerate_den == 0)
    return Status::kUnsupported;

  Status s = Probe();
  if (s != Status::kOk) return s;
  if (driver_.virgl && !driver_.virgl_host_radeonsi) {
    EncLog("h264 encoder: virgl host is not radeonsi, refused");
    return Status::kUnsupported;
  }
  s = ChooseRateControl();
  if (s != Status::kOk) return s;

  const CodedSize coded =
      CodedSizeFor(false, config_.width, config_.height, config_.min_coded_width, config_.min_coded_height);
  const uint32_t wmbs = coded.width / 16;
  const uint32_t hmbs = coded.height / 16;
  if (wmbs > (config_.width + 15) / 16 || hmbs > (config_.height + 15) / 16)
    EncLog("h264 encoder: %ux%u coded as %ux%u, the driver's smallest picture being %ux%u", config_.width,
           config_.height, coded.width, coded.height, config_.min_coded_width, config_.min_coded_height);
  const double fps = static_cast<double>(config_.framerate_num) / config_.framerate_den;
  const uint32_t rc_bitrate = config_.rate_control == EncoderConfig::RateControl::kCq ? 0 : config_.bitrate;
  const uint32_t level = h264enc::ChooseLevel(profile_idc, config_.level, wmbs, hmbs, fps, rc_bitrate);
  if (level == 0) {
    EncLog("h264 encoder: %ux%u at %.2f fps and %u bit/s fits no level", config_.width, config_.height, fps,
           config_.bitrate);
    return Status::kUnsupported;
  }
  if (level != config_.level) EncLog("h264 encoder: level %u asked, %u signalled", config_.level, level);
  const h264enc::LevelLimits* lim = h264enc::FindLevel(level);
  max_bitrate_ = static_cast<uint32_t>((profile_idc == 100 ? 1500ull : 1200ull) * lim->max_br);

  sps_.profile_idc = profile_idc;
  sps_.constraint_flags = constraints;
  sps_.level_idc = level;
  sps_.log2_max_frame_num_minus4 = 0;
  max_frame_num_ = 16;
  sps_.pic_order_cnt_type = 2;
  sps_.max_num_ref_frames = 1;
  sps_.width_in_mbs = wmbs;
  sps_.height_in_mbs = hmbs;
  sps_.direct_8x8_inference = true;
  const uint32_t crop_r = (wmbs * 16 - config_.width) / 2;
  const uint32_t crop_b = (hmbs * 16 - config_.height) / 2;
  sps_.frame_cropping = crop_r || crop_b;
  sps_.crop_right = crop_r;
  sps_.crop_bottom = crop_b;
  sps_.vui_present = true;
  h264enc::Vui& vui = sps_.vui;
  vui.colour_description_present =
      config_.color.primaries != 2 || config_.color.transfer != 2 || config_.color.matrix != 2;
  vui.video_signal_type_present = vui.colour_description_present || config_.color.full_range;
  vui.full_range = config_.color.full_range;
  vui.colour_primaries = config_.color.primaries & 0xff;
  vui.transfer_characteristics = config_.color.transfer & 0xff;
  vui.matrix_coefficients = config_.color.matrix & 0xff;
  if (config_.framerate_num <= 0x7fffffff) {
    vui.timing_info_present = true;
    vui.num_units_in_tick = config_.framerate_den;
    vui.time_scale = 2 * config_.framerate_num;
  }
  vui.bitstream_restriction = true;
  vui.max_num_reorder_frames = 0;
  vui.max_dec_frame_buffering = 1;

  pps_.entropy_coding_mode = profile_idc != 66;
  pps_.pic_init_qp_minus26 = 0;
  pps_.deblocking_filter_control_present = false;
  pps_.transform_8x8_mode = profile_idc == 100 && !driver_.virgl;
  pps_.high_extension = pps_.transform_8x8_mode;
  syntax_ = h264enc::SyntaxOf(sps_, pps_);
  driver_syntax_ = syntax_;
  sps_nal_.clear();
  pps_nal_.clear();
  h264enc::AppendSps(sps_, &sps_nal_);
  h264enc::AppendPps(pps_, &pps_nal_);

  packed_wanted_ = VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE | VA_ENC_PACKED_HEADER_SLICE;
  hevc_ = false;
  return Start(VA_RT_FORMAT_YUV420, coded, 16, 16, CodedBufferSize(wmbs * 16, hmbs * 16, false));
}

Status H264Encoder::AddSequenceParams(const EncPicture& pic, std::vector<VABufferID>* bufs) {
  (void)pic;
  VAEncSequenceParameterBufferH264 seq;
  memset(&seq, 0, sizeof(seq));
  seq.seq_parameter_set_id = 0;
  seq.level_idc = static_cast<uint8_t>(sps_.level_idc);
  seq.intra_period = config_.keyframe_interval;
  seq.intra_idr_period = config_.keyframe_interval;
  seq.ip_period = 1;
  seq.bits_per_second = va_rate_control() == VA_RC_CQP ? 0 : bitrate();
  seq.max_num_ref_frames = sps_.max_num_ref_frames;
  seq.picture_width_in_mbs = static_cast<uint16_t>(sps_.width_in_mbs);
  seq.picture_height_in_mbs = static_cast<uint16_t>(sps_.height_in_mbs);
  seq.seq_fields.bits.chroma_format_idc = 1;
  seq.seq_fields.bits.frame_mbs_only_flag = 1;
  seq.seq_fields.bits.direct_8x8_inference_flag = sps_.direct_8x8_inference;
  seq.seq_fields.bits.log2_max_frame_num_minus4 = sps_.log2_max_frame_num_minus4;
  seq.seq_fields.bits.pic_order_cnt_type = sps_.pic_order_cnt_type;
  seq.seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4 = sps_.log2_max_pic_order_cnt_lsb_minus4;
  seq.frame_cropping_flag = sps_.frame_cropping;
  seq.frame_crop_left_offset = sps_.crop_left;
  seq.frame_crop_right_offset = sps_.crop_right;
  seq.frame_crop_top_offset = sps_.crop_top;
  seq.frame_crop_bottom_offset = sps_.crop_bottom;
  seq.vui_parameters_present_flag = sps_.vui_present;
  seq.vui_fields.bits.timing_info_present_flag = sps_.vui.timing_info_present;
  seq.vui_fields.bits.bitstream_restriction_flag = sps_.vui.bitstream_restriction;
  seq.vui_fields.bits.log2_max_mv_length_horizontal = 15;
  seq.vui_fields.bits.log2_max_mv_length_vertical = 15;
  seq.vui_fields.bits.motion_vectors_over_pic_boundaries_flag = 1;
  seq.num_units_in_tick = sps_.vui.num_units_in_tick;
  seq.time_scale = sps_.vui.time_scale;
  return AddBuffer(VAEncSequenceParameterBufferType, &seq, sizeof(seq), bufs);
}

Status H264Encoder::AddPictureParams(const EncPicture& pic, VABufferID coded, std::vector<VABufferID>* bufs) {
  VAEncPictureParameterBufferH264 pp;
  memset(&pp, 0, sizeof(pp));
  const uint32_t frame_num = FrameNum(pic);
  pp.CurrPic.picture_id = pic.recon;
  pp.CurrPic.frame_idx = frame_num;
  pp.CurrPic.flags = 0;
  pp.CurrPic.TopFieldOrderCnt = Poc(pic.frames_since_idr);
  pp.CurrPic.BottomFieldOrderCnt = Poc(pic.frames_since_idr);
  for (VAPictureH264& r : pp.ReferenceFrames) {
    r.picture_id = VA_INVALID_SURFACE;
    r.flags = VA_PICTURE_H264_INVALID;
  }
  if (!pic.idr) {
    VAPictureH264& r = pp.ReferenceFrames[0];
    r.picture_id = pic.ref;
    r.frame_idx = (pic.frames_since_idr - 1) % max_frame_num_;
    r.flags = VA_PICTURE_H264_SHORT_TERM_REFERENCE;
    r.TopFieldOrderCnt = Poc(pic.frames_since_idr - 1);
    r.BottomFieldOrderCnt = r.TopFieldOrderCnt;
  }
  pp.coded_buf = coded;
  pp.pic_parameter_set_id = 0;
  pp.seq_parameter_set_id = 0;
  pp.frame_num = static_cast<uint16_t>(frame_num);
  pp.pic_init_qp = static_cast<uint8_t>(26 + pps_.pic_init_qp_minus26);
  pp.num_ref_idx_l0_active_minus1 = 0;
  pp.pic_fields.bits.idr_pic_flag = pic.idr;
  pp.pic_fields.bits.reference_pic_flag = 1;
  pp.pic_fields.bits.entropy_coding_mode_flag = pps_.entropy_coding_mode;
  pp.pic_fields.bits.transform_8x8_mode_flag = pps_.transform_8x8_mode;
  pp.pic_fields.bits.deblocking_filter_control_present_flag = pps_.deblocking_filter_control_present;
  return AddBuffer(VAEncPictureParameterBufferType, &pp, sizeof(pp), bufs);
}

Status H264Encoder::AddPackedParameterSets(const EncPicture& pic, std::vector<VABufferID>* bufs) {
  (void)pic;
  Status s = AddPacked(VAEncPackedHeaderSequence, sps_nal_, sps_nal_.size() * 8, bufs);
  if (s != Status::kOk) return s;
  return AddPacked(VAEncPackedHeaderPicture, pps_nal_, pps_nal_.size() * 8, bufs);
}

h264enc::SliceHeader H264Encoder::SliceHeaderFor(const EncPicture& pic) const {
  h264enc::SliceHeader sh;
  sh.nal_ref_idc = pic.idr ? 3 : 2;
  sh.nal_unit_type = pic.idr ? h264enc::kNalIdrSlice : h264enc::kNalSlice;
  sh.first_mb_in_slice = 0;
  sh.slice_type = pic.idr ? 7 : 5;
  sh.frame_num = FrameNum(pic);
  sh.idr_pic_id = pic.idr ? (pic.idr_count & 1) : 0;
  sh.slice_qp_delta = pic.qp - (26 + pps_.pic_init_qp_minus26);
  return sh;
}

Status H264Encoder::AddSliceParams(const EncPicture& pic, std::vector<VABufferID>* bufs) {
  VAEncSliceParameterBufferH264 sp;
  memset(&sp, 0, sizeof(sp));
  const h264enc::SliceHeader sh = SliceHeaderFor(pic);
  sp.macroblock_address = 0;
  sp.num_macroblocks = sps_.width_in_mbs * sps_.height_in_mbs;
  sp.macroblock_info = VA_INVALID_ID;
  sp.slice_type = static_cast<uint8_t>(sh.slice_type % 5);
  sp.pic_parameter_set_id = 0;
  sp.idr_pic_id = static_cast<uint16_t>(sh.idr_pic_id);
  for (int i = 0; i < 32; i++) {
    sp.RefPicList0[i].picture_id = VA_INVALID_SURFACE;
    sp.RefPicList0[i].flags = VA_PICTURE_H264_INVALID;
    sp.RefPicList1[i].picture_id = VA_INVALID_SURFACE;
    sp.RefPicList1[i].flags = VA_PICTURE_H264_INVALID;
  }
  if (!pic.idr) {
    sp.RefPicList0[0].picture_id = pic.ref;
    sp.RefPicList0[0].frame_idx = (pic.frames_since_idr - 1) % max_frame_num_;
    sp.RefPicList0[0].flags = VA_PICTURE_H264_SHORT_TERM_REFERENCE;
    sp.RefPicList0[0].TopFieldOrderCnt = Poc(pic.frames_since_idr - 1);
    sp.RefPicList0[0].BottomFieldOrderCnt = sp.RefPicList0[0].TopFieldOrderCnt;
  }
  sp.num_ref_idx_active_override_flag = 0;
  sp.cabac_init_idc = 0;
  sp.slice_qp_delta = static_cast<int8_t>(sh.slice_qp_delta);
  sp.disable_deblocking_filter_idc = 0;
  Status s = AddBuffer(VAEncSliceParameterBufferType, &sp, sizeof(sp), bufs);
  if (s != Status::kOk || !packed(VA_ENC_PACKED_HEADER_SLICE)) return s;

  BitWriter bw;
  if (!h264enc::WriteSliceHeader(syntax_, sh, &bw)) return Status::kUnsupported;
  const size_t bits = bw.BitPos();
  std::vector<uint8_t> rbsp = bw.Bytes();
  std::vector<uint8_t> data = {0, 0, 0, 1, static_cast<uint8_t>((sh.nal_ref_idc << 5) | sh.nal_unit_type)};
  const size_t before = data.size();
  AppendEscaped(rbsp.data(), rbsp.size(), &data, false);
  const size_t added = (data.size() - before) - rbsp.size();
  return AddPacked(VAEncPackedHeaderSlice, data, before * 8 + added * 8 + bits, bufs);
}

NalClass H264Encoder::Classify(const uint8_t* nal, size_t size) const {
  if (size < 1) return NalClass::kOther;
  const uint32_t type = nal[0] & 31;
  if (type == h264enc::kNalSps || type == h264enc::kNalPps) return NalClass::kParameterSet;
  // radeonsi behind virgl writes nal_unit_type 0 in its slices
  if (type == h264enc::kNalSlice || type == h264enc::kNalIdrSlice || type == 0) return NalClass::kSlice;
  return NalClass::kOther;
}

void H264Encoder::OwnParameterSets(std::vector<uint8_t>* out) const {
  out->clear();
  out->insert(out->end(), sps_nal_.begin(), sps_nal_.end());
  out->insert(out->end(), pps_nal_.begin(), pps_nal_.end());
}

Status H264Encoder::FixSlice(const EncPicture& pic, const uint8_t* nal, size_t size, std::vector<uint8_t>* out,
                             int* slice_qp) {
  *slice_qp = -1;
  const h264enc::SliceHeader want = SliceHeaderFor(pic);
  h264enc::SliceIntent intent;
  intent.nal_ref_idc = want.nal_ref_idc;
  intent.nal_unit_type = want.nal_unit_type;
  intent.slice_type_mod5 = want.slice_type % 5;
  intent.frame_num = want.frame_num;
  intent.idr_pic_id = want.idr_pic_id;
  intent.pic_order_cnt_lsb = 0;
  if (pic.idr && intent.idr_pic_id == 0) {
    uint32_t bits = 0;
    if (!h264enc::LearnFrameNumBits(nal, size, driver_syntax_, intent, &bits)) {
      EncLog("h264 encoder: the driver's IDR slice header fits no frame_num width");
      return Status::kVaError;
    }
    if (bits != driver_syntax_.log2_max_frame_num)
      EncLog("h264 encoder: the driver writes frame_num in %u bits", bits);
    driver_syntax_.log2_max_frame_num = bits;
  }
  h264enc::FixResult r = h264enc::FixSlice(nal, size, driver_syntax_, syntax_, intent, out);
  if (r == h264enc::FixResult::kFailed) return Status::kVaError;
  if (out->size() > 1) {
    std::vector<uint8_t> rbsp = Unescape(out->data() + 1, out->size() - 1);
    BitReader br(rbsp.data(), rbsp.size());
    h264enc::SliceHeader sh;
    if (h264enc::ParseSliceHeader(syntax_, intent.nal_ref_idc, intent.nal_unit_type, &br, &sh))
      *slice_qp = 26 + syntax_.pic_init_qp_minus26 + sh.slice_qp_delta;
  }
  return Status::kOk;
}

}

}

namespace rhizo::c2va {

std::unique_ptr<EncoderCore> CreateH264Encoder(EncoderHost* host, const EncoderConfig& config, Status* status) {
  auto enc = std::make_unique<enc::H264Encoder>(host, config);
  Status s = enc->Init();
  if (status) *status = s;
  if (s != Status::kOk) return nullptr;
  return enc;
}

}

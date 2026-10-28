// the HEVC encoder core on VA

#include <string.h>

#include <memory>

#include <va/va.h>
#include <va/va_enc_hevc.h>

#include "../../va/core.h"
#include "../common/bit_writer.h"
#include "../common/log.h"
#include "../common/va_encoder.h"
#include "hevc_syntax.h"

namespace rhizo::c2va::enc {

namespace {

class HevcEncoder : public VaEncoderBase {
 public:
  HevcEncoder(EncoderHost* host, const EncoderConfig& config) : VaEncoderBase(host, config) {}
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
  // return the POC of a picture
  int32_t Poc(const EncPicture& pic) const { return static_cast<int32_t>(pic.frames_since_idr); }
  hevcenc::SliceHeader SliceHeaderFor(const EncPicture& pic) const;
  static hevcenc::StRps PreviousPicture();

  hevcenc::Vps vps_;
  hevcenc::Sps sps_;
  hevcenc::Pps pps_;
  hevcenc::SliceSyntax syntax_;
  std::vector<hevcenc::SliceSyntax> driver_syntaxes_;
  std::vector<uint8_t> vps_nal_;
  std::vector<uint8_t> sps_nal_;
  std::vector<uint8_t> pps_nal_;
  uint32_t ctus_ = 0;
  uint32_t max_poc_lsb_ = 256;
};

hevcenc::StRps HevcEncoder::PreviousPicture() {
  hevcenc::StRps r;
  r.num_negative = 1;
  r.delta_poc_s0[0] = -1;
  r.used_s0[0] = true;
  return r;
}

Status HevcEncoder::Init() {
  uint32_t profile_idc = 0, bit_depth_minus8 = 0, rt_format = VA_RT_FORMAT_YUV420;
  switch (config_.profile) {
    case VAProfileHEVCMain:
      profile_idc = 1;
      break;
    case VAProfileHEVCMain10:
      profile_idc = 2;
      bit_depth_minus8 = 2;
      rt_format = VA_RT_FORMAT_YUV420_10;
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
    EncLog("hevc encoder: virgl host is not radeonsi, refused");
    return Status::kUnsupported;
  }
  if (driver_.virgl && bit_depth_minus8) {
    EncLog("hevc encoder: 10-bit behind virgl refused (the host's reference surfaces are 8-bit)");
    return Status::kUnsupported;
  }
  s = ChooseRateControl();
  if (s != Status::kOk) return s;

  bool amp = false, sao = false;
  if (!driver_.virgl) {
    VAConfigAttrib f = {VAConfigAttribEncHEVCFeatures, 0};
    if (vaGetConfigAttributes(dpy_, config_.profile, VAEntrypointEncSlice, &f, 1) == VA_STATUS_SUCCESS &&
        f.value != VA_ATTRIB_NOT_SUPPORTED) {
      VAConfigAttribValEncHEVCFeatures v;
      v.value = f.value;
      amp = v.bits.amp != 0;
      sao = v.bits.sao != 0;
    }
  }

  const CodedSize coded =
      CodedSizeFor(true, config_.width, config_.height, config_.min_coded_width, config_.min_coded_height);
  const uint32_t cw = coded.width;
  const uint32_t ch = coded.height;
  if (cw > ((config_.width + 63) & ~63u) || ch > ((config_.height + 15) & ~15u))
    EncLog("hevc encoder: %ux%u coded as %ux%u, the driver's smallest picture being %ux%u", config_.width,
           config_.height, cw, ch, config_.min_coded_width, config_.min_coded_height);
  ctus_ = ((cw + 63) / 64) * ((ch + 63) / 64);
  const double fps = static_cast<double>(config_.framerate_num) / config_.framerate_den;
  const uint32_t rc_bitrate = config_.rate_control == EncoderConfig::RateControl::kCq ? 0 : config_.bitrate;
  const uint32_t level = hevcenc::ChooseLevel(config_.level, cw, ch, fps, rc_bitrate);
  if (level == 0) {
    EncLog("hevc encoder: %ux%u at %.2f fps and %u bit/s fits no Main tier level", config_.width, config_.height,
           fps, config_.bitrate);
    return Status::kUnsupported;
  }
  if (level != config_.level) EncLog("hevc encoder: level %u asked, %u signalled", config_.level, level);
  max_bitrate_ = static_cast<uint32_t>(1100ull * hevcenc::FindLevel(level)->max_br);

  hevcenc::ProfileTierLevel ptl;
  ptl.profile_idc = profile_idc;
  ptl.compatibility = profile_idc == 1 ? ((1u << (31 - 1)) | (1u << (31 - 2))) : (1u << (31 - 2));
  ptl.level_idc = level;
  vps_.ptl = ptl;
  vps_.max_dec_pic_buffering_minus1 = 1;
  sps_.ptl = ptl;
  sps_.width = cw;
  sps_.height = ch;
  sps_.conformance_window = cw != config_.width || ch != config_.height;
  sps_.conf_right = (cw - config_.width) / 2;
  sps_.conf_bottom = (ch - config_.height) / 2;
  sps_.bit_depth_luma_minus8 = bit_depth_minus8;
  sps_.bit_depth_chroma_minus8 = bit_depth_minus8;
  sps_.log2_max_pic_order_cnt_lsb_minus4 = 4;
  max_poc_lsb_ = 1u << (sps_.log2_max_pic_order_cnt_lsb_minus4 + 4);
  sps_.max_dec_pic_buffering_minus1 = 1;
  sps_.log2_min_luma_coding_block_size_minus3 = 0;
  sps_.log2_diff_max_min_luma_coding_block_size = 3;
  sps_.log2_min_luma_transform_block_size_minus2 = 0;
  sps_.log2_diff_max_min_luma_transform_block_size = 3;
  sps_.max_transform_hierarchy_depth_inter = 4;
  sps_.max_transform_hierarchy_depth_intra = 4;
  sps_.amp = amp;
  sps_.sao = sao;
  // Mesa parses packed slice headers as if TMVP is absent
  sps_.temporal_mvp = false;
  sps_.strong_intra_smoothing = false;
  sps_.vui_present = true;
  hevcenc::Vui& vui = sps_.vui;
  vui.colour_description_present =
      config_.color.primaries != 2 || config_.color.transfer != 2 || config_.color.matrix != 2;
  vui.video_signal_type_present = vui.colour_description_present || config_.color.full_range;
  vui.full_range = config_.color.full_range;
  vui.colour_primaries = config_.color.primaries & 0xff;
  vui.transfer_characteristics = config_.color.transfer & 0xff;
  vui.matrix_coefficients = config_.color.matrix & 0xff;
  vui.timing_info_present = true;
  vui.num_units_in_tick = config_.framerate_den;
  vui.time_scale = config_.framerate_num;

  pps_.cabac_init_present = true;
  pps_.init_qp_minus26 = 0;
  pps_.cu_qp_delta_enabled = !driver_.virgl && va_rate_control() != VA_RC_CQP;
  syntax_ = hevcenc::SyntaxOf(sps_, pps_);
  hevcenc::SliceSyntax host = syntax_;
  host.log2_max_pic_order_cnt_lsb = 4;
  host.cabac_init_present = false;
  driver_syntaxes_.clear();
  if (driver_.virgl) {
    driver_syntaxes_.push_back(host);
    host.cabac_init_present = true;
    driver_syntaxes_.push_back(host);
  } else {
    driver_syntaxes_.push_back(syntax_);
  }
  vps_nal_.clear();
  sps_nal_.clear();
  pps_nal_.clear();
  hevcenc::AppendVps(vps_, &vps_nal_);
  hevcenc::AppendSps(sps_, &sps_nal_);
  hevcenc::AppendPps(pps_, &pps_nal_);

  packed_wanted_ = VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE | VA_ENC_PACKED_HEADER_SLICE;
  hevc_ = true;
  return Start(rt_format, coded, 64, 16, CodedBufferSize(cw, ch, bit_depth_minus8 != 0));
}

Status HevcEncoder::AddSequenceParams(const EncPicture& pic, std::vector<VABufferID>* bufs) {
  (void)pic;
  VAEncSequenceParameterBufferHEVC seq;
  memset(&seq, 0, sizeof(seq));
  seq.general_profile_idc = static_cast<uint8_t>(sps_.ptl.profile_idc);
  seq.general_level_idc = static_cast<uint8_t>(sps_.ptl.level_idc);
  seq.general_tier_flag = 0;
  seq.intra_period = config_.keyframe_interval;
  seq.intra_idr_period = config_.keyframe_interval;
  seq.ip_period = 1;
  seq.bits_per_second = va_rate_control() == VA_RC_CQP ? 0 : bitrate();
  seq.pic_width_in_luma_samples = static_cast<uint16_t>(sps_.width);
  seq.pic_height_in_luma_samples = static_cast<uint16_t>(sps_.height);
  seq.seq_fields.bits.chroma_format_idc = 1;
  seq.seq_fields.bits.bit_depth_luma_minus8 = sps_.bit_depth_luma_minus8;
  seq.seq_fields.bits.bit_depth_chroma_minus8 = sps_.bit_depth_chroma_minus8;
  seq.seq_fields.bits.strong_intra_smoothing_enabled_flag = sps_.strong_intra_smoothing;
  seq.seq_fields.bits.amp_enabled_flag = sps_.amp;
  seq.seq_fields.bits.sample_adaptive_offset_enabled_flag = sps_.sao;
  seq.seq_fields.bits.sps_temporal_mvp_enabled_flag = sps_.temporal_mvp;
  seq.seq_fields.bits.low_delay_seq = 1;
  seq.log2_min_luma_coding_block_size_minus3 = static_cast<uint8_t>(sps_.log2_min_luma_coding_block_size_minus3);
  seq.log2_diff_max_min_luma_coding_block_size = static_cast<uint8_t>(sps_.log2_diff_max_min_luma_coding_block_size);
  seq.log2_min_transform_block_size_minus2 = static_cast<uint8_t>(sps_.log2_min_luma_transform_block_size_minus2);
  seq.log2_diff_max_min_transform_block_size =
      static_cast<uint8_t>(sps_.log2_diff_max_min_luma_transform_block_size);
  seq.max_transform_hierarchy_depth_inter = static_cast<uint8_t>(sps_.max_transform_hierarchy_depth_inter);
  seq.max_transform_hierarchy_depth_intra = static_cast<uint8_t>(sps_.max_transform_hierarchy_depth_intra);
  seq.vui_parameters_present_flag = sps_.vui_present;
  seq.vui_fields.bits.vui_timing_info_present_flag = sps_.vui.timing_info_present;
  seq.vui_num_units_in_tick = sps_.vui.num_units_in_tick;
  seq.vui_time_scale = sps_.vui.time_scale;
  return AddBuffer(VAEncSequenceParameterBufferType, &seq, sizeof(seq), bufs);
}

Status HevcEncoder::AddPictureParams(const EncPicture& pic, VABufferID coded, std::vector<VABufferID>* bufs) {
  VAEncPictureParameterBufferHEVC pp;
  memset(&pp, 0, sizeof(pp));
  pp.decoded_curr_pic.picture_id = pic.recon;
  pp.decoded_curr_pic.pic_order_cnt = Poc(pic);
  pp.decoded_curr_pic.flags = 0;
  for (VAPictureHEVC& r : pp.reference_frames) {
    r.picture_id = VA_INVALID_SURFACE;
    r.flags = VA_PICTURE_HEVC_INVALID;
  }
  if (!pic.idr) {
    pp.reference_frames[0].picture_id = pic.ref;
    pp.reference_frames[0].pic_order_cnt = Poc(pic) - 1;
    pp.reference_frames[0].flags = VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE;
  }
  pp.coded_buf = coded;
  pp.collocated_ref_pic_index = 0xff;
  pp.pic_init_qp = static_cast<uint8_t>(26 + pps_.init_qp_minus26);
  pp.diff_cu_qp_delta_depth = static_cast<uint8_t>(pps_.diff_cu_qp_delta_depth);
  pp.log2_parallel_merge_level_minus2 = static_cast<uint8_t>(pps_.log2_parallel_merge_level_minus2);
  pp.num_ref_idx_l0_default_active_minus1 = static_cast<uint8_t>(pps_.num_ref_idx_l0_default_active_minus1);
  pp.num_ref_idx_l1_default_active_minus1 = static_cast<uint8_t>(pps_.num_ref_idx_l1_default_active_minus1);
  pp.slice_pic_parameter_set_id = 0;
  pp.nal_unit_type = static_cast<uint8_t>(pic.idr ? hevcenc::kNalIdrWRadl : hevcenc::kNalTrailR);
  pp.pic_fields.bits.idr_pic_flag = pic.idr;
  pp.pic_fields.bits.coding_type = pic.idr ? 1 : 2;
  pp.pic_fields.bits.reference_pic_flag = 1;
  pp.pic_fields.bits.transform_skip_enabled_flag = pps_.transform_skip;
  pp.pic_fields.bits.cu_qp_delta_enabled_flag = pps_.cu_qp_delta_enabled;
  pp.pic_fields.bits.pps_loop_filter_across_slices_enabled_flag = pps_.loop_filter_across_slices;
  return AddBuffer(VAEncPictureParameterBufferType, &pp, sizeof(pp), bufs);
}

Status HevcEncoder::AddPackedParameterSets(const EncPicture& pic, std::vector<VABufferID>* bufs) {
  (void)pic;
  Status s = AddPacked(VAEncPackedHeaderSequence, vps_nal_, vps_nal_.size() * 8, bufs);
  if (s == Status::kOk) s = AddPacked(VAEncPackedHeaderSequence, sps_nal_, sps_nal_.size() * 8, bufs);
  if (s == Status::kOk) s = AddPacked(VAEncPackedHeaderPicture, pps_nal_, pps_nal_.size() * 8, bufs);
  return s;
}

hevcenc::SliceHeader HevcEncoder::SliceHeaderFor(const EncPicture& pic) const {
  hevcenc::SliceHeader sh;
  sh.nal_unit_type = pic.idr ? hevcenc::kNalIdrWRadl : hevcenc::kNalTrailR;
  sh.slice_type = pic.idr ? hevcenc::kSliceI : hevcenc::kSliceP;
  sh.pic_order_cnt_lsb = static_cast<uint32_t>(Poc(pic)) % max_poc_lsb_;
  sh.st_rps_sps = false;
  if (!pic.idr) sh.rps = PreviousPicture();
  sh.sao_luma = sps_.sao;
  sh.sao_chroma = sps_.sao;
  sh.five_minus_max_num_merge_cand = 0;
  sh.slice_qp_delta = pic.qp - (26 + pps_.init_qp_minus26);
  return sh;
}

Status HevcEncoder::AddSliceParams(const EncPicture& pic, std::vector<VABufferID>* bufs) {
  VAEncSliceParameterBufferHEVC sp;
  memset(&sp, 0, sizeof(sp));
  const hevcenc::SliceHeader sh = SliceHeaderFor(pic);
  sp.slice_segment_address = 0;
  sp.num_ctu_in_slice = ctus_;
  sp.slice_type = static_cast<uint8_t>(sh.slice_type);
  sp.slice_pic_parameter_set_id = 0;
  sp.num_ref_idx_l0_active_minus1 = 0;
  for (int i = 0; i < 15; i++) {
    sp.ref_pic_list0[i].picture_id = VA_INVALID_SURFACE;
    sp.ref_pic_list0[i].flags = VA_PICTURE_HEVC_INVALID;
    sp.ref_pic_list1[i].picture_id = VA_INVALID_SURFACE;
    sp.ref_pic_list1[i].flags = VA_PICTURE_HEVC_INVALID;
  }
  if (!pic.idr) {
    sp.ref_pic_list0[0].picture_id = pic.ref;
    sp.ref_pic_list0[0].pic_order_cnt = Poc(pic) - 1;
    sp.ref_pic_list0[0].flags = VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE;
  }
  sp.max_num_merge_cand = static_cast<uint8_t>(5 - sh.five_minus_max_num_merge_cand);
  sp.slice_qp_delta = static_cast<int8_t>(sh.slice_qp_delta);
  sp.slice_fields.bits.last_slice_of_pic_flag = 1;
  sp.slice_fields.bits.slice_sao_luma_flag = sh.sao_luma;
  sp.slice_fields.bits.slice_sao_chroma_flag = sh.sao_chroma;
  sp.slice_fields.bits.collocated_from_l0_flag = 1;
  Status s = AddBuffer(VAEncSliceParameterBufferType, &sp, sizeof(sp), bufs);
  if (s != Status::kOk || !packed(VA_ENC_PACKED_HEADER_SLICE)) return s;

  BitWriter bw;
  if (!hevcenc::WriteSliceHeader(syntax_, sh, &bw)) return Status::kUnsupported;
  const size_t bits = bw.BitPos();
  std::vector<uint8_t> rbsp = bw.Bytes();
  uint8_t header[2] = {static_cast<uint8_t>(sh.nal_unit_type << 1), 1};
  std::vector<uint8_t> data = {0, 0, 0, 1, header[0], header[1]};
  const size_t before = data.size();
  AppendEscaped(rbsp.data(), rbsp.size(), &data, false);
  const size_t added = (data.size() - before) - rbsp.size();
  return AddPacked(VAEncPackedHeaderSlice, data, before * 8 + added * 8 + bits, bufs);
}

NalClass HevcEncoder::Classify(const uint8_t* nal, size_t size) const {
  if (size < 2) return NalClass::kOther;
  const uint32_t type = (nal[0] >> 1) & 0x3f;
  if (type == hevcenc::kNalVps || type == hevcenc::kNalSps || type == hevcenc::kNalPps) return NalClass::kParameterSet;
  if (type <= 9 || (type >= hevcenc::kNalBlaWLp && type <= hevcenc::kNalCra)) return NalClass::kSlice;
  return NalClass::kOther;
}

void HevcEncoder::OwnParameterSets(std::vector<uint8_t>* out) const {
  out->clear();
  out->insert(out->end(), vps_nal_.begin(), vps_nal_.end());
  out->insert(out->end(), sps_nal_.begin(), sps_nal_.end());
  out->insert(out->end(), pps_nal_.begin(), pps_nal_.end());
}

Status HevcEncoder::FixSlice(const EncPicture& pic, const uint8_t* nal, size_t size, std::vector<uint8_t>* out,
                             int* slice_qp) {
  *slice_qp = -1;
  const hevcenc::SliceHeader want = SliceHeaderFor(pic);
  hevcenc::SliceIntent intent;
  intent.nal_unit_type = want.nal_unit_type;
  intent.slice_type = want.slice_type;
  intent.pic_order_cnt_lsb = want.pic_order_cnt_lsb;
  intent.rps = want.rps;
  hevcenc::FixResult r = hevcenc::FixSlice(nal, size, driver_syntaxes_, syntax_, intent, out);
  if (r == hevcenc::FixResult::kFailed) return Status::kVaError;
  if (out->size() > 2) {
    std::vector<uint8_t> rbsp = Unescape(out->data() + 2, out->size() - 2);
    BitReader br(rbsp.data(), rbsp.size());
    hevcenc::SliceHeader sh;
    if (hevcenc::ParseSliceHeader(syntax_, intent.nal_unit_type, &br, &sh))
      *slice_qp = 26 + syntax_.init_qp_minus26 + sh.slice_qp_delta;
  }
  return Status::kOk;
}

}

}

namespace rhizo::c2va {

std::unique_ptr<EncoderCore> CreateHevcEncoder(EncoderHost* host, const EncoderConfig& config, Status* status) {
  auto enc = std::make_unique<enc::HevcEncoder>(host, config);
  Status s = enc->Init();
  if (status) *status = s;
  if (s != Status::kOk) return nullptr;
  return enc;
}

}

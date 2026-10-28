#include "h264_decoder.h"

#include <string.h>

#include <algorithm>
#include <utility>

#include "../../common/bit_reader.h"

namespace rhizo::c2va {

std::unique_ptr<DecoderCore> CreateH264Decoder(DecoderHost* host) {
  return std::make_unique<h264::H264Decoder>(host);
}

namespace h264 {

namespace {

constexpr size_t kSliceHeaderBytes = 8192;
constexpr size_t kMaxSlicesPerPicture = 8192;

// return MaxDpbMbs for the SPS level
uint32_t MaxDpbMbs(const Sps& sps) {
  switch (sps.level_idc) {
    case 9:
    case 10:
      return 396;
    case 11:
      if (sps.constraint_set_flags[3] && (sps.profile_idc == 66 || sps.profile_idc == 77 || sps.profile_idc == 88))
        return 396;
      return 900;
    case 12:
    case 13:
    case 20:
      return 2376;
    case 21:
      return 4752;
    case 22:
    case 30:
      return 8100;
    case 31:
      return 18000;
    case 32:
      return 20480;
    case 40:
    case 41:
      return 32768;
    case 42:
      return 34816;
    case 50:
      return 110400;
    case 51:
    case 52:
      return 184320;
    default:
      return 696320;
  }
}

}

Status DeriveStreamInfo(const Sps& sps, StreamInfo* info, uint32_t* dpb_size, uint32_t* reorder_depth) {
  if (sps.chroma_format_idc != 1 || sps.separate_colour_plane_flag) return Status::kUnsupported;
  if (sps.bit_depth_luma_minus8 != 0 || sps.bit_depth_chroma_minus8 != 0) return Status::kUnsupported;
  if (sps.qpprime_y_zero_transform_bypass_flag) return Status::kUnsupported;
  VAProfile profile;
  switch (sps.profile_idc) {
    case 66:
      profile = VAProfileH264ConstrainedBaseline;
      break;
    case 77:
      profile = VAProfileH264Main;
      break;
    case 88:
      if (sps.constraint_set_flags[1])
        profile = VAProfileH264Main;
      else if (sps.constraint_set_flags[0])
        profile = VAProfileH264ConstrainedBaseline;
      else
        return Status::kUnsupported;
      break;
    case 100:
    case 110:
    case 122:
    case 244:
      profile = VAProfileH264High;
      break;
    default:
      return Status::kUnsupported;
  }
  const uint32_t w_mbs = sps.PicWidthInMbs(), h_mbs = sps.FrameHeightInMbs();
  if (w_mbs * h_mbs > 65536) return Status::kUnsupported;
  info->profile = profile;
  info->rt_format = VA_RT_FORMAT_YUV420;
  info->coded_width = w_mbs * 16;
  info->coded_height = h_mbs * 16;
  info->bit_depth = 8;
  const uint32_t cx = 2, cy = 2 * (2 - sps.frame_mbs_only_flag);
  info->visible.left = cx * sps.frame_crop_left_offset;
  info->visible.top = cy * sps.frame_crop_top_offset;
  info->visible.width = info->coded_width - cx * (sps.frame_crop_left_offset + sps.frame_crop_right_offset);
  info->visible.height = info->coded_height - cy * (sps.frame_crop_top_offset + sps.frame_crop_bottom_offset);
  ColorInfo color;
  const Vui& vui = sps.vui;
  if (vui.present && vui.video_signal_type_present_flag) {
    color.full_range = vui.video_full_range_flag;
    if (vui.colour_description_present_flag) {
      color.primaries = vui.colour_primaries;
      color.transfer = vui.transfer_characteristics;
      color.matrix = vui.matrix_coefficients;
    }
  }
  info->color = color;
  uint32_t dpb;
  if (vui.present && vui.bitstream_restriction_flag)
    dpb = vui.max_dec_frame_buffering;
  else
    dpb = std::min<uint32_t>(MaxDpbMbs(sps) / (w_mbs * h_mbs), kMaxDpbFrames);
  dpb = std::min<uint32_t>(std::max<uint32_t>({dpb, sps.max_num_ref_frames, 1}), kMaxDpbFrames);
  uint32_t reorder;
  const bool intra_profile = sps.constraint_set_flags[3] &&
                             (sps.profile_idc == 44 || sps.profile_idc == 86 || sps.profile_idc == 100 ||
                              sps.profile_idc == 110 || sps.profile_idc == 122 || sps.profile_idc == 244);
  if (vui.present && vui.bitstream_restriction_flag)
    reorder = vui.max_num_reorder_frames;
  else if (sps.pic_order_cnt_type == 2 || intra_profile)
    reorder = 0;
  else
    reorder = dpb;
  reorder = std::min(reorder, dpb);
  info->reorder_depth = reorder;
  info->min_surfaces = dpb + 1;
  *dpb_size = dpb;
  *reorder_depth = reorder;
  return Status::kOk;
}

H264Decoder::H264Decoder(DecoderHost* host) : host_(host), dpb_(this) {}

H264Decoder::~H264Decoder() {
  destroying_ = true;
  dpb_.Clear();
}

void H264Decoder::Note(Status s) {
  if (status_ == Status::kOk) status_ = s;
}

// output a store's tag once and drop its holder
void H264Decoder::OutputStore(const FrameStore& fs) {
  auto it = tags_.find(fs.tag);
  if (it == tags_.end()) return;
  if (!it->second.done) {
    it->second.done = true;
    if (!destroying_) host_->Output(fs.surface, fs.tag, fs.crop, fs.color);
    if (in_decode_ && fs.tag == cur_tag_) cur_tag_done_ = true;
  }
  if (--it->second.holders == 0) tags_.erase(it);
}

void H264Decoder::RemoveStore(const FrameStore& fs) {
  if (fs.has_tag) {
    auto it = tags_.find(fs.tag);
    if (it != tags_.end() && --it->second.holders == 0) {
      if (!it->second.done) {
        if (!destroying_) host_->Skip(fs.tag);
        if (in_decode_ && fs.tag == cur_tag_) cur_tag_done_ = true;
      }
      tags_.erase(it);
    }
  }
  if (!fs.non_existing && fs.surface != VA_INVALID_SURFACE) host_->ReleaseSurface(fs.surface);
}

Status H264Decoder::Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) {
  (void)codec_config;
  in_decode_ = true;
  cur_tag_ = tag;
  cur_tag_done_ = false;
  status_ = Status::kOk;
  pending_recovery_ = RecoveryPoint();
  if (data != nullptr && size > 0) {
    for (const NalSpan& nal : SplitAnnexB(data, size)) HandleNal(nal.data, nal.size);
  }
  FinishPicture();
  if (!cur_tag_done_ && tags_.find(tag) == tags_.end()) host_->Skip(tag);
  in_decode_ = false;
  return status_;
}

Status H264Decoder::Drain() {
  FinishPicture();
  dpb_.OutputAll();
  return Status::kOk;
}

void H264Decoder::Reset() {
  pic_ = Picture();
  dpb_.Clear();
  dpb_.ResetHistory();
  access_ = Access::kNeedIdr;
  floor_active_ = false;
  has_last_key_ = false;
  pending_recovery_ = RecoveryPoint();
}

void H264Decoder::HandleNal(const uint8_t* nal, size_t size) {
  NalHeader h;
  if (size < 1 || !ParseNalHeader(nal[0], &h)) {
    Note(Status::kBadStream);
    return;
  }
  switch (h.nal_unit_type) {
    case kNalSlice:
    case kNalIdr:
      HandleSlice(nal, size);
      return;
    case kNalSliceDpa:
    case kNalSliceDpb:
    case kNalSliceDpc:
      FinishPicture();
      Note(Status::kUnsupported);
      return;
    case kNalSps:
      FinishPicture();
      StoreSps(nal, size);
      return;
    case kNalPps:
      FinishPicture();
      StorePps(nal, size);
      return;
    case kNalSei: {
      FinishPicture();
      std::vector<uint8_t> rbsp = Unescape(nal, size);
      RecoveryPoint rp;
      if (ParseSeiRecoveryPoint(rbsp.data(), rbsp.size(), &rp)) pending_recovery_ = rp;
      return;
    }
    case kNalAud:
    case kNalEndOfSeq:
    case kNalEndOfStream:
      FinishPicture();
      return;
    default:
      return;
  }
}

void H264Decoder::StoreSps(const uint8_t* nal, size_t size) {
  std::vector<uint8_t> rbsp = Unescape(nal, size);
  auto sps = std::make_unique<Sps>();
  if (!ParseSps(rbsp.data(), rbsp.size(), sps.get(), trace_)) {
    Note(Status::kBadStream);
    return;
  }
  const uint32_t id = sps->seq_parameter_set_id;
  if (sps_[id] && sps_raw_[id] == rbsp) return;
  sps_raw_[id] = std::move(rbsp);
  sps_[id] = std::move(sps);
  sps_gen_[id]++;
}

void H264Decoder::StorePps(const uint8_t* nal, size_t size) {
  std::vector<uint8_t> rbsp = Unescape(nal, size);
  uint32_t pps_id, sps_id;
  if (!PeekPpsIds(rbsp.data(), rbsp.size(), &pps_id, &sps_id)) {
    Note(Status::kBadStream);
    return;
  }
  pps_[pps_id].reset();
  pps_raw_[pps_id] = std::move(rbsp);
  if (sps_[sps_id]) {
    auto pps = std::make_unique<Pps>();
    if (!ParsePps(pps_raw_[pps_id].data(), pps_raw_[pps_id].size(), *sps_[sps_id], pps.get(), trace_)) {
      Note(Status::kBadStream);
      pps_raw_[pps_id].clear();
      return;
    }
    pps_[pps_id] = std::move(pps);
    pps_sps_gen_[pps_id] = sps_gen_[sps_id];
  }
}

const Pps* H264Decoder::GetPps(uint32_t pps_id) {
  const std::vector<uint8_t>& raw = pps_raw_[pps_id];
  if (raw.empty()) return nullptr;
  uint32_t id, sps_id;
  if (!PeekPpsIds(raw.data(), raw.size(), &id, &sps_id) || !sps_[sps_id]) return nullptr;
  if (pps_[pps_id] && pps_sps_gen_[pps_id] == sps_gen_[sps_id]) return pps_[pps_id].get();
  auto pps = std::make_unique<Pps>();
  if (!ParsePps(raw.data(), raw.size(), *sps_[sps_id], pps.get(), nullptr)) return nullptr;
  pps_[pps_id] = std::move(pps);
  pps_sps_gen_[pps_id] = sps_gen_[sps_id];
  return pps_[pps_id].get();
}

// return true when a slice starts a new primary coded picture
bool H264Decoder::IsNewPicture(const PicKey& a, const PicKey& b) const {
  if (a.frame_num != b.frame_num || a.pps_id != b.pps_id || a.field != b.field) return true;
  if (a.field && a.bottom != b.bottom) return true;
  if ((a.nal_ref_idc == 0) != (b.nal_ref_idc == 0)) return true;
  if (a.poc_type == 0 && b.poc_type == 0 && (a.poc_lsb != b.poc_lsb || a.delta_bottom != b.delta_bottom)) return true;
  if (a.poc_type == 1 && b.poc_type == 1 && (a.delta[0] != b.delta[0] || a.delta[1] != b.delta[1])) return true;
  if (a.idr != b.idr) return true;
  if (a.idr && b.idr && a.idr_pic_id != b.idr_pic_id) return true;
  return false;
}

void H264Decoder::HandleSlice(const uint8_t* nal, size_t size) {
  std::vector<uint8_t> rbsp = Unescape(nal, std::min(size, kSliceHeaderBytes));
  uint32_t pps_id;
  if (!PeekSlicePpsId(rbsp.data(), rbsp.size(), &pps_id)) {
    Note(Status::kBadStream);
    return;
  }
  const Pps* pps = GetPps(pps_id);
  if (pps == nullptr) {
    Note(Status::kBadStream);
    return;
  }
  const Sps& sps = *sps_[pps->seq_parameter_set_id];
  Slice slice;
  if (!ParseSliceHeader(rbsp.data(), rbsp.size(), sps, *pps, &slice.sh, trace_)) {
    Note(Status::kBadStream);
    return;
  }
  const SliceHeader& sh = slice.sh;
  if (sh.redundant_pic_cnt > 0) return;
  PicKey key;
  key.frame_num = sh.frame_num;
  key.pps_id = sh.pic_parameter_set_id;
  key.poc_lsb = sh.pic_order_cnt_lsb;
  key.idr_pic_id = sh.idr_pic_id;
  key.delta_bottom = sh.delta_pic_order_cnt_bottom;
  key.delta[0] = sh.delta_pic_order_cnt[0];
  key.delta[1] = sh.delta_pic_order_cnt[1];
  key.field = sh.field_pic_flag;
  key.bottom = sh.bottom_field_flag;
  key.idr = sh.idr_pic_flag;
  key.nal_ref_idc = sh.nal.nal_ref_idc;
  key.poc_type = static_cast<uint8_t>(sps.pic_order_cnt_type);
  const bool in_picture = pic_.open || pic_.dropping;
  if (!in_picture || !has_last_key_ || IsNewPicture(last_key_, key) ||
      (sh.first_mb_in_slice == 0 && pic_.saw_first_mb0)) {
    FinishPicture();
    StartPicture(sh, sps, *pps);
  }
  last_key_ = key;
  has_last_key_ = true;
  if (sh.first_mb_in_slice == 0) pic_.saw_first_mb0 = true;
  if (pic_.dropping) return;
  if (sh.slice_type == kSliceSP || sh.slice_type == kSliceSI) {
    Note(Status::kUnsupported);
    return;
  }
  if (pic_.slices.size() >= kMaxSlicesPerPicture || sh.header_bits > 0xffff) {
    Note(Status::kBadStream);
    return;
  }
  slice.nal = nal;
  slice.size = size;
  pic_.slices.push_back(std::move(slice));
}

Status H264Decoder::Activate(const Sps& sps) {
  StreamInfo info;
  uint32_t dpb_size, reorder;
  Status st = DeriveStreamInfo(sps, &info, &dpb_size, &reorder);
  if (st != Status::kOk) return st;
  const bool same = configured_ && info.profile == info_.profile && info.rt_format == info_.rt_format &&
                    info.coded_width == info_.coded_width && info.coded_height == info_.coded_height &&
                    info.min_surfaces == info_.min_surfaces;
  if (!same) {
    dpb_.Flush(true);
    configured_ = false;
    VAContextID context = VA_INVALID_ID;
    st = host_->Configure(info, &context);
    if (st != Status::kOk) return st;
    context_ = context;
    configured_ = true;
  }
  info_ = info;
  active_sps_ = sps;
  active_gen_ = sps_gen_[sps.seq_parameter_set_id];
  has_active_ = true;
  crop_ = info.visible;
  color_ = info.color;
  dpb_.SetSequence(sps, dpb_size, reorder);
  return Status::kOk;
}

void H264Decoder::StartPicture(const SliceHeader& sh, const Sps& sps, const Pps& pps) {
  pic_ = Picture();
  pic_.pps = pps;
  const RecoveryPoint recovery = pending_recovery_;
  pending_recovery_ = RecoveryPoint();
  if (pps.num_slice_groups_minus1 > 0 || sh.slice_type == kSliceSP || sh.slice_type == kSliceSI) {
    Note(Status::kUnsupported);
    pic_.dropping = true;
    return;
  }
  const bool start = access_ == Access::kNeedIdr;
  if (start && !sh.idr_pic_flag && sh.slice_type != kSliceI && !recovery.present) {
    pic_.dropping = true;
    return;
  }
  if (sh.idr_pic_flag) dpb_.Flush(!sh.no_output_of_prior_pics_flag);
  if (sh.idr_pic_flag || start) {
    Status st = Activate(sps);
    if (st != Status::kOk) {
      Note(st);
      pic_.dropping = true;
      return;
    }
  } else if (!has_active_ || pps.seq_parameter_set_id != active_sps_.seq_parameter_set_id) {
    Note(Status::kBadStream);
    pic_.dropping = true;
    return;
  } else if (sps_gen_[sps.seq_parameter_set_id] != active_gen_) {
    StreamInfo info;
    uint32_t dpb_size, reorder;
    if (DeriveStreamInfo(sps, &info, &dpb_size, &reorder) != Status::kOk || info.profile != info_.profile ||
        info.coded_width != info_.coded_width || info.coded_height != info_.coded_height ||
        info.min_surfaces != info_.min_surfaces || sps.MaxFrameNum() != active_sps_.MaxFrameNum() ||
        sps.pic_order_cnt_type != active_sps_.pic_order_cnt_type) {
      Note(Status::kBadStream);
      pic_.dropping = true;
      return;
    }
    active_sps_ = sps;
    active_gen_ = sps_gen_[sps.seq_parameter_set_id];
  }
  if (!sh.idr_pic_flag && sh.HasMmco5()) dpb_.OutputAll();

  CurrentPicture& cur = pic_.cur;
  if (!dpb_.StartPicture(sh, start, &cur)) {
    Note(Status::kBadStream);
    pic_.dropping = true;
    return;
  }
  dpb_.PredictMarking(sh, &cur);
  if (start) {
    access_ = sh.idr_pic_flag ? Access::kNormal : Access::kRecovering;
    recovery_frame_num_ = (sh.frame_num + (recovery.present ? recovery.recovery_frame_cnt : 0)) %
                          active_sps_.MaxFrameNum();
    floor_active_ = false;
  }

  bool allowed = true;
  if (!cur.second_field) {
    if (access_ == Access::kRecovering) {
      if (sh.frame_num == recovery_frame_num_ && (cur.reference || start)) {
        access_ = Access::kNormal;
        floor_active_ = true;
        floor_poc_ = cur.Poc();
      } else {
        allowed = false;
      }
    } else if (floor_active_) {
      if (sh.idr_pic_flag || cur.mmco5)
        floor_active_ = false;
      else if (cur.Poc() < floor_poc_)
        allowed = false;
    }
  }

  if (cur.second_field) {
    pic_.surface = dpb_.store(cur.store).surface;
  } else {
    VASurfaceID surface = VA_INVALID_SURFACE;
    Status st = host_->AcquireSurface(&surface);
    if (st != Status::kOk) {
      Note(st);
      pic_.dropping = true;
      return;
    }
    pic_.surface = surface;
  }
  pic_.output_allowed = allowed;
  pic_.open = true;
}

void H264Decoder::FillPicture(VAPictureH264* pic, int store, uint8_t structure, bool long_term) const {
  const FrameStore& fs = dpb_.store(store);
  pic->picture_id = fs.surface;
  pic->frame_idx = long_term ? fs.long_term_frame_idx : fs.frame_num;
  uint32_t flags = long_term ? VA_PICTURE_H264_LONG_TERM_REFERENCE : VA_PICTURE_H264_SHORT_TERM_REFERENCE;
  uint8_t fields = structure;
  if (fields == 0) {
    const Mark want = long_term ? Mark::kLong : Mark::kShort;
    if ((fs.fields & kTopField) && fs.mark[0] == want) fields |= kTopField;
    if ((fs.fields & kBottomField) && fs.mark[1] == want) fields |= kBottomField;
  }
  if (fields == kTopField) flags |= VA_PICTURE_H264_TOP_FIELD;
  if (fields == kBottomField) flags |= VA_PICTURE_H264_BOTTOM_FIELD;
  pic->flags = flags;
  pic->TopFieldOrderCnt = (fs.fields & kTopField) ? fs.poc[0] : 0;
  pic->BottomFieldOrderCnt = (fs.fields & kBottomField) ? fs.poc[1] : 0;
}

static void InvalidPicture(VAPictureH264* pic) {
  memset(pic, 0, sizeof(*pic));
  pic->picture_id = VA_INVALID_SURFACE;
  pic->flags = VA_PICTURE_H264_INVALID;
}

bool H264Decoder::Submit(const std::vector<std::vector<RefEntry>>& lists) {
  const Picture& p = pic_;
  const CurrentPicture& cur = p.cur;
  const Sps& sps = active_sps_;
  const Pps& pps = p.pps;
  const SliceHeader& first = p.slices[0].sh;

  VAPictureParameterBufferH264 pp;
  memset(&pp, 0, sizeof(pp));
  pp.CurrPic.picture_id = p.surface;
  pp.CurrPic.frame_idx = first.frame_num;
  uint32_t flags = 0;
  if (cur.structure == kTopField) flags |= VA_PICTURE_H264_TOP_FIELD;
  if (cur.structure == kBottomField) flags |= VA_PICTURE_H264_BOTTOM_FIELD;
  if (cur.reference)
    flags |= cur.long_term ? VA_PICTURE_H264_LONG_TERM_REFERENCE : VA_PICTURE_H264_SHORT_TERM_REFERENCE;
  pp.CurrPic.flags = flags;
  const FrameStore* first_field = cur.second_field ? &dpb_.store(cur.store) : nullptr;
  int32_t first_poc[2] = {0, 0};
  if (first_field && (first_field->fields & kTopField)) first_poc[0] = first_field->poc[0];
  if (first_field && (first_field->fields & kBottomField)) first_poc[1] = first_field->poc[1];
  pp.CurrPic.TopFieldOrderCnt = (cur.structure & kTopField) ? cur.poc[0] : first_poc[0];
  pp.CurrPic.BottomFieldOrderCnt = (cur.structure & kBottomField) ? cur.poc[1] : first_poc[1];
  int n = 0;
  for (int i = 0; i < dpb_.slots() && n < 16; i++) {
    const FrameStore& fs = dpb_.store(i);
    if (!fs.used || !fs.IsRef()) continue;
    // VCN mis-decodes gap streams that reference the inferred frames
    if (fs.non_existing) continue;
    FillPicture(&pp.ReferenceFrames[n++], i, 0, fs.HasMark(Mark::kLong));
  }
  for (; n < 16; n++) InvalidPicture(&pp.ReferenceFrames[n]);
  pp.picture_width_in_mbs_minus1 = static_cast<uint16_t>(sps.pic_width_in_mbs_minus1);
  pp.picture_height_in_mbs_minus1 = static_cast<uint16_t>(sps.FrameHeightInMbs() - 1);
  pp.bit_depth_luma_minus8 = static_cast<uint8_t>(sps.bit_depth_luma_minus8);
  pp.bit_depth_chroma_minus8 = static_cast<uint8_t>(sps.bit_depth_chroma_minus8);
  pp.num_ref_frames = static_cast<uint8_t>(sps.max_num_ref_frames);
  pp.seq_fields.bits.chroma_format_idc = sps.chroma_format_idc;
  pp.seq_fields.bits.residual_colour_transform_flag = sps.separate_colour_plane_flag;
  pp.seq_fields.bits.gaps_in_frame_num_value_allowed_flag = sps.gaps_in_frame_num_value_allowed_flag;
  pp.seq_fields.bits.frame_mbs_only_flag = sps.frame_mbs_only_flag;
  pp.seq_fields.bits.mb_adaptive_frame_field_flag = sps.mb_adaptive_frame_field_flag;
  pp.seq_fields.bits.direct_8x8_inference_flag = sps.direct_8x8_inference_flag;
  pp.seq_fields.bits.MinLumaBiPredSize8x8 = sps.level_idc >= 31;
  pp.seq_fields.bits.log2_max_frame_num_minus4 = sps.log2_max_frame_num_minus4;
  pp.seq_fields.bits.pic_order_cnt_type = sps.pic_order_cnt_type;
  pp.seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4 = sps.log2_max_pic_order_cnt_lsb_minus4;
  pp.seq_fields.bits.delta_pic_order_always_zero_flag = sps.delta_pic_order_always_zero_flag;
  pp.pic_init_qp_minus26 = static_cast<int8_t>(pps.pic_init_qp_minus26);
  pp.pic_init_qs_minus26 = static_cast<int8_t>(pps.pic_init_qs_minus26);
  pp.chroma_qp_index_offset = static_cast<int8_t>(pps.chroma_qp_index_offset);
  pp.second_chroma_qp_index_offset = static_cast<int8_t>(pps.second_chroma_qp_index_offset);
  pp.pic_fields.bits.entropy_coding_mode_flag = pps.entropy_coding_mode_flag;
  pp.pic_fields.bits.weighted_pred_flag = pps.weighted_pred_flag;
  pp.pic_fields.bits.weighted_bipred_idc = pps.weighted_bipred_idc;
  pp.pic_fields.bits.transform_8x8_mode_flag = pps.transform_8x8_mode_flag;
  pp.pic_fields.bits.field_pic_flag = first.field_pic_flag;
  pp.pic_fields.bits.constrained_intra_pred_flag = pps.constrained_intra_pred_flag;
  pp.pic_fields.bits.pic_order_present_flag = pps.bottom_field_pic_order_in_frame_present_flag;
  pp.pic_fields.bits.deblocking_filter_control_present_flag = pps.deblocking_filter_control_present_flag;
  pp.pic_fields.bits.redundant_pic_cnt_present_flag = pps.redundant_pic_cnt_present_flag;
  pp.pic_fields.bits.reference_pic_flag = cur.reference;
  pp.frame_num = static_cast<uint16_t>(first.frame_num);

  VAIQMatrixBufferH264 iq;
  memset(&iq, 0, sizeof(iq));
  for (int i = 0; i < 6; i++)
    for (int k = 0; k < 16; k++) iq.ScalingList4x4[i][kZigzag4x4[k]] = pps.scaling.list4x4[i][k];
  for (int i = 0; i < 2; i++)
    for (int k = 0; k < 64; k++) iq.ScalingList8x8[i][kZigzag8x8[k]] = pps.scaling.list8x8[i][k];

  VADisplay dpy = host_->display();
  std::vector<VABufferID> ids;
  ids.reserve(2 + 2 * p.slices.size());
  bool ok = true;
  auto create = [&](VABufferType type, size_t size, const void* data) {
    if (!ok) return;
    VABufferID id = VA_INVALID_ID;
    if (vaCreateBuffer(dpy, context_, type, static_cast<unsigned>(size), 1, const_cast<void*>(data), &id) !=
        VA_STATUS_SUCCESS) {
      ok = false;
      return;
    }
    ids.push_back(id);
  };
  create(VAPictureParameterBufferType, sizeof(pp), &pp);
  create(VAIQMatrixBufferType, sizeof(iq), &iq);

  VASliceParameterBufferH264 sp;
  for (size_t s = 0; s < p.slices.size() && ok; s++) {
    const SliceHeader& sh = p.slices[s].sh;
    const std::vector<RefEntry>& l0 = lists[2 * s];
    const std::vector<RefEntry>& l1 = lists[2 * s + 1];
    memset(&sp, 0, sizeof(sp));
    sp.slice_data_size = static_cast<uint32_t>(p.slices[s].size);
    sp.slice_data_offset = 0;
    sp.slice_data_flag = VA_SLICE_DATA_FLAG_ALL;
    sp.slice_data_bit_offset = static_cast<uint16_t>(sh.header_bits);
    sp.first_mb_in_slice = static_cast<uint16_t>(sh.first_mb_in_slice);
    sp.slice_type = sh.slice_type;
    sp.direct_spatial_mv_pred_flag = sh.direct_spatial_mv_pred_flag;
    sp.num_ref_idx_l0_active_minus1 = static_cast<uint8_t>(sh.num_ref_idx_l0_active_minus1);
    sp.num_ref_idx_l1_active_minus1 = static_cast<uint8_t>(sh.num_ref_idx_l1_active_minus1);
    sp.cabac_init_idc = static_cast<uint8_t>(sh.cabac_init_idc);
    sp.slice_qp_delta = static_cast<int8_t>(sh.slice_qp_delta);
    sp.disable_deblocking_filter_idc = static_cast<uint8_t>(sh.disable_deblocking_filter_idc);
    sp.slice_alpha_c0_offset_div2 = static_cast<int8_t>(sh.slice_alpha_c0_offset_div2);
    sp.slice_beta_offset_div2 = static_cast<int8_t>(sh.slice_beta_offset_div2);
    for (int k = 0; k < 32; k++) {
      if (k < static_cast<int>(l0.size()) && l0[k].store >= 0 && !dpb_.store(l0[k].store).non_existing)
        FillPicture(&sp.RefPicList0[k], l0[k].store, l0[k].structure, l0[k].long_term);
      else
        InvalidPicture(&sp.RefPicList0[k]);
      if (k < static_cast<int>(l1.size()) && l1[k].store >= 0 && !dpb_.store(l1[k].store).non_existing)
        FillPicture(&sp.RefPicList1[k], l1[k].store, l1[k].structure, l1[k].long_term);
      else
        InvalidPicture(&sp.RefPicList1[k]);
    }
    if (sh.has_pred_weight_table) {
      const PredWeightTable& w = sh.pwt;
      sp.luma_log2_weight_denom = static_cast<uint8_t>(w.luma_log2_weight_denom);
      sp.chroma_log2_weight_denom = static_cast<uint8_t>(w.chroma_log2_weight_denom);
      const uint32_t n0 = sh.num_ref_idx_l0_active_minus1 + 1;
      const uint32_t n1 = sh.slice_type == kSliceB ? sh.num_ref_idx_l1_active_minus1 + 1 : 0;
      for (uint32_t i = 0; i < n0; i++) {
        sp.luma_weight_l0_flag |= w.luma_weight_flag[0][i];
        sp.chroma_weight_l0_flag |= w.chroma_weight_flag[0][i];
        sp.luma_weight_l0[i] = w.luma_weight[0][i];
        sp.luma_offset_l0[i] = w.luma_offset[0][i];
        for (int j = 0; j < 2; j++) {
          sp.chroma_weight_l0[i][j] = w.chroma_weight[0][i][j];
          sp.chroma_offset_l0[i][j] = w.chroma_offset[0][i][j];
        }
      }
      for (uint32_t i = 0; i < n1; i++) {
        sp.luma_weight_l1_flag |= w.luma_weight_flag[1][i];
        sp.chroma_weight_l1_flag |= w.chroma_weight_flag[1][i];
        sp.luma_weight_l1[i] = w.luma_weight[1][i];
        sp.luma_offset_l1[i] = w.luma_offset[1][i];
        for (int j = 0; j < 2; j++) {
          sp.chroma_weight_l1[i][j] = w.chroma_weight[1][i][j];
          sp.chroma_offset_l1[i][j] = w.chroma_offset[1][i][j];
        }
      }
    }
    create(VASliceParameterBufferType, sizeof(sp), &sp);
    create(VASliceDataBufferType, p.slices[s].size, p.slices[s].nal);
  }

  if (ok) {
    if (vaBeginPicture(dpy, context_, p.surface) != VA_STATUS_SUCCESS) {
      ok = false;
    } else {
      if (vaRenderPicture(dpy, context_, ids.data(), static_cast<int>(ids.size())) != VA_STATUS_SUCCESS) ok = false;
      if (vaEndPicture(dpy, context_) != VA_STATUS_SUCCESS) ok = false;
    }
  }
  for (VABufferID id : ids) vaDestroyBuffer(dpy, id);
  return ok;
}

void H264Decoder::FinishPicture() {
  if (pic_.dropping) {
    pic_ = Picture();
    return;
  }
  if (!pic_.open) return;
  Picture& p = pic_;
  if (p.slices.empty()) {
    if (!p.cur.second_field) host_->ReleaseSurface(p.surface);
    pic_ = Picture();
    return;
  }
  std::vector<std::vector<RefEntry>> lists(2 * p.slices.size());
  bool lists_complete = true;
  for (size_t s = 0; s < p.slices.size(); s++)
    lists_complete &= dpb_.BuildRefLists(p.slices[s].sh, p.cur, &lists[2 * s], &lists[2 * s + 1]);
  const bool decoded = Submit(lists);
  if (!decoded) Note(Status::kVaError);

  bool output = p.output_allowed && decoded && !p.cur.second_field && !cur_tag_done_;
  if (output) tags_[cur_tag_].holders++;
  const SliceHeader& first = p.slices[0].sh;
  dpb_.FinishPicture(first, &p.cur, p.surface, output, cur_tag_, crop_, color_);
  if (observer_) observer_->PictureDone(first, p.cur, dpb_, decoded, lists_complete);
  pic_ = Picture();
}

}
}

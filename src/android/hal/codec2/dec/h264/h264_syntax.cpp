#include "h264_syntax.h"

#include <string.h>

#include <utility>

#include "../../common/bit_reader.h"

namespace rhizo::c2va::h264 {

const uint8_t kDefault4x4Intra[16] = {6, 13, 13, 20, 20, 20, 28, 28, 28, 28, 32, 32, 32, 37, 37, 42};
const uint8_t kDefault4x4Inter[16] = {10, 14, 14, 20, 20, 20, 24, 24, 24, 24, 27, 27, 27, 30, 30, 34};
const uint8_t kDefault8x8Intra[64] = {6,  10, 10, 13, 11, 13, 16, 16, 16, 16, 18, 18, 18, 18, 18, 23,
                                      23, 23, 23, 23, 23, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27,
                                      27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31,
                                      31, 33, 33, 33, 33, 33, 36, 36, 36, 36, 38, 38, 38, 40, 40, 42};
const uint8_t kDefault8x8Inter[64] = {9,  13, 13, 15, 13, 15, 17, 17, 17, 17, 19, 19, 19, 19, 19, 21,
                                      21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 24, 24, 24, 24,
                                      24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27,
                                      27, 28, 28, 28, 28, 28, 30, 30, 30, 30, 32, 32, 32, 33, 33, 35};
const uint8_t kZigzag4x4[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
const uint8_t kZigzag8x8[64] = {0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
                                12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
                                35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
                                58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

namespace {

// range-checked syntax reader with a sticky failure
class Reader {
 public:
  Reader(const uint8_t* data, size_t size, SyntaxTrace* trace) : br_(data, size), trace_(trace) {}

  uint32_t U(int n, const char* name, int i0 = -1, int i1 = -1) {
    size_t pos = br_.BitPos();
    uint32_t v = br_.U(n);
    Note(pos, name, i0, i1, v);
    return v;
  }
  bool Flag(const char* name, int i0 = -1, int i1 = -1) { return U(1, name, i0, i1) != 0; }
  uint32_t Ue(const char* name, uint32_t lo, uint32_t hi, int i0 = -1, int i1 = -1) {
    size_t pos = br_.BitPos();
    uint32_t v = br_.Ue();
    Note(pos, name, i0, i1, v);
    if (v < lo || v > hi) {
      failed_ = true;
      return lo;
    }
    return v;
  }
  int32_t Se(const char* name, int32_t lo, int32_t hi, int i0 = -1, int i1 = -1) {
    size_t pos = br_.BitPos();
    int32_t v = br_.Se();
    Note(pos, name, i0, i1, v);
    if (v < lo || v > hi) {
      failed_ = true;
      return lo;
    }
    return v;
  }
  void Fail() { failed_ = true; }
  bool ok() const { return !failed_ && !br_.overrun(); }
  size_t BitPos() const { return br_.BitPos(); }
  void Skip(size_t bits) { br_.Skip(bits); }
  bool MoreRbspData() const { return br_.MoreRbspData(); }
  void Structure(const char* name) {
    if (trace_) trace_->Structure(name);
  }

 private:
  void Note(size_t pos, const char* name, int i0, int i1, int64_t v) {
    if (trace_ && !br_.overrun()) trace_->Element(pos, name, i0, i1, v);
  }

  BitReader br_;
  SyntaxTrace* trace_;
  bool failed_ = false;
};

void ReadNalHeader(Reader& r) {
  r.U(1, "forbidden_zero_bit");
  r.U(2, "nal_ref_idc");
  r.U(5, "nal_unit_type");
}

// read a scaling_list() in zig-zag order
void ReadScalingList(Reader& r, uint8_t* list, int size, bool* use_default) {
  int last = 8, next = 8;
  *use_default = false;
  for (int j = 0; j < size; j++) {
    if (next != 0) {
      int32_t delta = r.Se("delta_scale", -128, 127, j);
      next = (last + delta + 256) % 256;
      *use_default = (j == 0 && next == 0);
    }
    list[j] = static_cast<uint8_t>(next == 0 ? last : next);
    last = list[j];
  }
}

void FillFlat(ScalingLists* s) {
  memset(s->list4x4, 16, sizeof(s->list4x4));
  memset(s->list8x8, 16, sizeof(s->list8x8));
}

// read the scaling matrix with table 7-2's fall-back rules
void ReadScalingMatrix(Reader& r, int num_lists, bool pps, const ScalingLists* seq_lists, ScalingLists* out) {
  for (int i = 0; i < 12; i++) {
    bool present = false;
    if (i < num_lists)
      present = r.Flag(pps ? "pic_scaling_list_present_flag" : "seq_scaling_list_present_flag", i);
    uint8_t* dst = i < 6 ? out->list4x4[i] : out->list8x8[i - 6];
    int size = i < 6 ? 16 : 64;
    if (present) {
      bool use_default = false;
      ReadScalingList(r, dst, size, &use_default);
      if (use_default) {
        const uint8_t* def = i < 6 ? (i < 3 ? kDefault4x4Intra : kDefault4x4Inter)
                                   : (((i - 6) % 2 == 0) ? kDefault8x8Intra : kDefault8x8Inter);
        memcpy(dst, def, size);
      }
      continue;
    }
    switch (i) {
      case 0:
      case 3:
        if (seq_lists)
          memcpy(dst, seq_lists->list4x4[i], 16);
        else
          memcpy(dst, i == 0 ? kDefault4x4Intra : kDefault4x4Inter, 16);
        break;
      case 6:
      case 7:
        if (seq_lists)
          memcpy(dst, seq_lists->list8x8[i - 6], 64);
        else
          memcpy(dst, i == 6 ? kDefault8x8Intra : kDefault8x8Inter, 64);
        break;
      case 1:
      case 2:
      case 4:
      case 5:
        memcpy(dst, out->list4x4[i - 1], 16);
        break;
      default:
        memcpy(dst, out->list8x8[i - 8], 64);
        break;
    }
  }
}

bool HasChromaInfo(uint32_t profile_idc) {
  switch (profile_idc) {
    case 100: case 110: case 122: case 244: case 44: case 83: case 86:
    case 118: case 128: case 138: case 139: case 134: case 135:
      return true;
    default:
      return false;
  }
}

// read hrd_parameters()
void ReadHrd(Reader& r) {
  uint32_t cnt = r.Ue("cpb_cnt_minus1", 0, 31);
  r.U(4, "bit_rate_scale");
  r.U(4, "cpb_size_scale");
  for (uint32_t i = 0; i <= cnt && r.ok(); i++) {
    r.Ue("bit_rate_value_minus1", 0, 0xfffffffe, i);
    r.Ue("cpb_size_value_minus1", 0, 0xfffffffe, i);
    r.Flag("cbr_flag", i);
  }
  r.U(5, "initial_cpb_removal_delay_length_minus1");
  r.U(5, "cpb_removal_delay_length_minus1");
  r.U(5, "dpb_output_delay_length_minus1");
  r.U(5, "time_offset_length");
}

// read vui_parameters()
void ReadVui(Reader& r, Vui* v) {
  v->present = true;
  v->aspect_ratio_info_present_flag = r.Flag("aspect_ratio_info_present_flag");
  if (v->aspect_ratio_info_present_flag) {
    v->aspect_ratio_idc = r.U(8, "aspect_ratio_idc");
    if (v->aspect_ratio_idc == 255) {
      v->sar_width = r.U(16, "sar_width");
      v->sar_height = r.U(16, "sar_height");
    }
  }
  if (r.Flag("overscan_info_present_flag")) r.Flag("overscan_appropriate_flag");
  if (!r.ok()) return;
  Vui saved = *v;
  v->video_signal_type_present_flag = r.Flag("video_signal_type_present_flag");
  if (v->video_signal_type_present_flag) {
    v->video_format = r.U(3, "video_format");
    v->video_full_range_flag = r.Flag("video_full_range_flag");
    v->colour_description_present_flag = r.Flag("colour_description_present_flag");
    if (v->colour_description_present_flag) {
      v->colour_primaries = r.U(8, "colour_primaries");
      v->transfer_characteristics = r.U(8, "transfer_characteristics");
      v->matrix_coefficients = r.U(8, "matrix_coefficients");
    }
  }
  if (!r.ok()) {
    *v = saved;
    return;
  }
  if (r.Flag("chroma_loc_info_present_flag")) {
    r.Ue("chroma_sample_loc_type_top_field", 0, 5);
    r.Ue("chroma_sample_loc_type_bottom_field", 0, 5);
  }
  v->timing_info_present_flag = r.Flag("timing_info_present_flag");
  if (v->timing_info_present_flag) {
    v->num_units_in_tick = r.U(32, "num_units_in_tick");
    v->time_scale = r.U(32, "time_scale");
    r.Flag("fixed_frame_rate_flag");
  }
  v->nal_hrd_parameters_present_flag = r.Flag("nal_hrd_parameters_present_flag");
  if (v->nal_hrd_parameters_present_flag) ReadHrd(r);
  v->vcl_hrd_parameters_present_flag = r.Flag("vcl_hrd_parameters_present_flag");
  if (v->vcl_hrd_parameters_present_flag) ReadHrd(r);
  if (v->nal_hrd_parameters_present_flag || v->vcl_hrd_parameters_present_flag) r.Flag("low_delay_hrd_flag");
  v->pic_struct_present_flag = r.Flag("pic_struct_present_flag");
  if (!r.ok()) {
    v->timing_info_present_flag = false;
    return;
  }
  v->bitstream_restriction_flag = r.Flag("bitstream_restriction_flag");
  if (v->bitstream_restriction_flag) {
    r.Flag("motion_vectors_over_pic_boundaries_flag");
    r.Ue("max_bytes_per_pic_denom", 0, 16);
    r.Ue("max_bits_per_mb_denom", 0, 16);
    r.Ue("log2_max_mv_length_horizontal", 0, 15);
    r.Ue("log2_max_mv_length_vertical", 0, 15);
    v->max_num_reorder_frames = r.Ue("max_num_reorder_frames", 0, 16);
    v->max_dec_frame_buffering = r.Ue("max_dec_frame_buffering", 0, 16);
    if (v->max_num_reorder_frames > v->max_dec_frame_buffering) r.Fail();
  }
  if (!r.ok()) v->bitstream_restriction_flag = false;
}

}

bool ParseNalHeader(uint8_t byte, NalHeader* out) {
  if (byte & 0x80) return false;
  out->nal_ref_idc = (byte >> 5) & 3;
  out->nal_unit_type = byte & 0x1f;
  return true;
}

bool ParseSps(const uint8_t* rbsp, size_t size, Sps* out, SyntaxTrace* trace) {
  Reader r(rbsp, size, trace);
  Sps s;
  r.Structure("Sequence Parameter Set");
  ReadNalHeader(r);
  s.profile_idc = r.U(8, "profile_idc");
  static const char* const kCs[6] = {"constraint_set0_flag", "constraint_set1_flag", "constraint_set2_flag",
                                     "constraint_set3_flag", "constraint_set4_flag", "constraint_set5_flag"};
  for (int i = 0; i < 6; i++) s.constraint_set_flags[i] = r.Flag(kCs[i]);
  r.U(2, "reserved_zero_2bits");
  s.level_idc = r.U(8, "level_idc");
  s.seq_parameter_set_id = r.Ue("seq_parameter_set_id", 0, kMaxSps - 1);
  FillFlat(&s.scaling);
  if (HasChromaInfo(s.profile_idc)) {
    s.chroma_format_idc = r.Ue("chroma_format_idc", 0, 3);
    if (s.chroma_format_idc == 3) s.separate_colour_plane_flag = r.Flag("separate_colour_plane_flag");
    s.bit_depth_luma_minus8 = r.Ue("bit_depth_luma_minus8", 0, 6);
    s.bit_depth_chroma_minus8 = r.Ue("bit_depth_chroma_minus8", 0, 6);
    s.qpprime_y_zero_transform_bypass_flag = r.Flag("qpprime_y_zero_transform_bypass_flag");
    s.seq_scaling_matrix_present_flag = r.Flag("seq_scaling_matrix_present_flag");
    if (s.seq_scaling_matrix_present_flag)
      ReadScalingMatrix(r, s.chroma_format_idc != 3 ? 8 : 12, false, nullptr, &s.scaling);
  }
  s.log2_max_frame_num_minus4 = r.Ue("log2_max_frame_num_minus4", 0, 12);
  s.pic_order_cnt_type = r.Ue("pic_order_cnt_type", 0, 2);
  if (s.pic_order_cnt_type == 0) {
    s.log2_max_pic_order_cnt_lsb_minus4 = r.Ue("log2_max_pic_order_cnt_lsb_minus4", 0, 12);
  } else if (s.pic_order_cnt_type == 1) {
    const int32_t kMax = 0x7fffffff;
    s.delta_pic_order_always_zero_flag = r.Flag("delta_pic_order_always_zero_flag");
    s.offset_for_non_ref_pic = r.Se("offset_for_non_ref_pic", -kMax, kMax);
    s.offset_for_top_to_bottom_field = r.Se("offset_for_top_to_bottom_field", -kMax, kMax);
    s.num_ref_frames_in_pic_order_cnt_cycle = r.Ue("num_ref_frames_in_pic_order_cnt_cycle", 0, 255);
    for (uint32_t i = 0; i < s.num_ref_frames_in_pic_order_cnt_cycle && r.ok(); i++)
      s.offset_for_ref_frame.push_back(r.Se("offset_for_ref_frame", -kMax, kMax, i));
  }
  s.max_num_ref_frames = r.Ue("max_num_ref_frames", 0, 16);
  s.gaps_in_frame_num_value_allowed_flag = r.Flag("gaps_in_frame_num_allowed_flag");
  s.pic_width_in_mbs_minus1 = r.Ue("pic_width_in_mbs_minus1", 0, 1023);
  s.pic_height_in_map_units_minus1 = r.Ue("pic_height_in_map_units_minus1", 0, 1023);
  s.frame_mbs_only_flag = r.Flag("frame_mbs_only_flag");
  if (!s.frame_mbs_only_flag) s.mb_adaptive_frame_field_flag = r.Flag("mb_adaptive_frame_field_flag");
  s.direct_8x8_inference_flag = r.Flag("direct_8x8_inference_flag");
  s.frame_cropping_flag = r.Flag("frame_cropping_flag");
  if (s.frame_cropping_flag) {
    s.frame_crop_left_offset = r.Ue("frame_crop_left_offset", 0, 0xffff);
    s.frame_crop_right_offset = r.Ue("frame_crop_right_offset", 0, 0xffff);
    s.frame_crop_top_offset = r.Ue("frame_crop_top_offset", 0, 0xffff);
    s.frame_crop_bottom_offset = r.Ue("frame_crop_bottom_offset", 0, 0xffff);
  }
  bool vui = r.Flag("vui_parameters_present_flag");
  if (!r.ok()) return false;
  {
    uint32_t crop_x = 1, crop_y = 2 - s.frame_mbs_only_flag;
    if (s.ChromaArrayType() != 0) {
      crop_x = s.chroma_format_idc == 3 ? 1 : 2;
      crop_y = (s.chroma_format_idc == 1 ? 2 : 1) * (2 - s.frame_mbs_only_flag);
    }
    if (crop_x * (s.frame_crop_left_offset + s.frame_crop_right_offset) >= s.PicWidthInMbs() * 16 ||
        crop_y * (s.frame_crop_top_offset + s.frame_crop_bottom_offset) >= s.FrameHeightInMbs() * 16)
      return false;
  }
  if (vui) ReadVui(r, &s.vui);
  *out = std::move(s);
  return true;
}

bool PeekPpsIds(const uint8_t* rbsp, size_t size, uint32_t* pps_id, uint32_t* sps_id) {
  Reader r(rbsp, size, nullptr);
  r.Skip(8);
  *pps_id = r.Ue("pic_parameter_set_id", 0, kMaxPps - 1);
  *sps_id = r.Ue("seq_parameter_set_id", 0, kMaxSps - 1);
  return r.ok();
}

bool ParsePps(const uint8_t* rbsp, size_t size, const Sps& sps, Pps* out, SyntaxTrace* trace) {
  Reader r(rbsp, size, trace);
  Pps p;
  r.Structure("Picture Parameter Set");
  ReadNalHeader(r);
  p.pic_parameter_set_id = r.Ue("pic_parameter_set_id", 0, kMaxPps - 1);
  p.seq_parameter_set_id = r.Ue("seq_parameter_set_id", 0, kMaxSps - 1);
  if (r.ok() && p.seq_parameter_set_id != sps.seq_parameter_set_id) return false;
  p.entropy_coding_mode_flag = r.Flag("entropy_coding_mode_flag");
  p.bottom_field_pic_order_in_frame_present_flag = r.Flag("bottom_field_pic_order_in_frame_present_flag");
  p.num_slice_groups_minus1 = r.Ue("num_slice_groups_minus1", 0, 7);
  const uint32_t map_units = sps.PicWidthInMbs() * (sps.pic_height_in_map_units_minus1 + 1);
  if (p.num_slice_groups_minus1 > 0) {
    p.slice_group_map_type = r.Ue("slice_group_map_type", 0, 6);
    if (p.slice_group_map_type == 0) {
      for (uint32_t g = 0; g <= p.num_slice_groups_minus1 && r.ok(); g++)
        r.Ue("run_length_minus1", 0, map_units - 1, g);
    } else if (p.slice_group_map_type == 2) {
      for (uint32_t g = 0; g < p.num_slice_groups_minus1 && r.ok(); g++) {
        r.Ue("top_left", 0, map_units - 1, g);
        r.Ue("bottom_right", 0, map_units - 1, g);
      }
    } else if (p.slice_group_map_type >= 3 && p.slice_group_map_type <= 5) {
      r.Flag("slice_group_change_direction_flag");
      p.slice_group_change_rate_minus1 = r.Ue("slice_group_change_rate_minus1", 0, map_units - 1);
    } else if (p.slice_group_map_type == 6) {
      uint32_t n = r.Ue("pic_size_in_map_units_minus1", 0, map_units - 1);
      if (n != map_units - 1) r.Fail();
      int bits = 0;
      while ((1u << bits) < p.num_slice_groups_minus1 + 1) bits++;
      for (uint32_t i = 0; i <= n && r.ok(); i++) r.U(bits, "slice_group_id", i);
    }
  }
  p.num_ref_idx_l0_default_active_minus1 = r.Ue("num_ref_idx_l0_default_active_minus1", 0, 31);
  p.num_ref_idx_l1_default_active_minus1 = r.Ue("num_ref_idx_l1_default_active_minus1", 0, 31);
  p.weighted_pred_flag = r.Flag("weighted_pred_flag");
  p.weighted_bipred_idc = r.U(2, "weighted_bipred_idc");
  if (p.weighted_bipred_idc > 2) r.Fail();
  const int32_t qp_bd_offset = 6 * static_cast<int32_t>(sps.bit_depth_luma_minus8);
  p.pic_init_qp_minus26 = r.Se("pic_init_qp_minus26", -(26 + qp_bd_offset), 25);
  p.pic_init_qs_minus26 = r.Se("pic_init_qs_minus26", -26, 25);
  p.chroma_qp_index_offset = r.Se("chroma_qp_index_offset", -12, 12);
  p.deblocking_filter_control_present_flag = r.Flag("deblocking_filter_control_present_flag");
  p.constrained_intra_pred_flag = r.Flag("constrained_intra_pred_flag");
  p.redundant_pic_cnt_present_flag = r.Flag("redundant_pic_cnt_present_flag");
  p.scaling = sps.scaling;
  p.second_chroma_qp_index_offset = p.chroma_qp_index_offset;
  if (r.ok() && r.MoreRbspData()) {
    p.transform_8x8_mode_flag = r.Flag("transform_8x8_mode_flag");
    p.pic_scaling_matrix_present_flag = r.Flag("pic_scaling_matrix_present_flag");
    if (p.pic_scaling_matrix_present_flag) {
      int n = 6 + ((sps.chroma_format_idc != 3) ? 2 : 6) * p.transform_8x8_mode_flag;
      ReadScalingMatrix(r, n, true, sps.seq_scaling_matrix_present_flag ? &sps.scaling : nullptr, &p.scaling);
    }
    p.second_chroma_qp_index_offset = r.Se("second_chroma_qp_index_offset", -12, 12);
  }
  if (!r.ok()) return false;
  *out = p;
  return true;
}

bool PeekSlicePpsId(const uint8_t* rbsp, size_t size, uint32_t* pps_id) {
  Reader r(rbsp, size, nullptr);
  r.Skip(8);
  r.Ue("first_mb_in_slice", 0, 0xfffffffe);
  r.Ue("slice_type", 0, 9);
  *pps_id = r.Ue("pic_parameter_set_id", 0, kMaxPps - 1);
  return r.ok();
}

namespace {

// read ref_pic_list_modification()
void ReadModifications(Reader& r, int list, uint32_t num_active, uint32_t max_pic_num, SliceHeader* sh) {
  sh->ref_pic_list_modification_flag[list] =
      r.Flag(list == 0 ? "ref_pic_list_modification_flag_l0" : "ref_pic_list_modification_flag_l1");
  if (!sh->ref_pic_list_modification_flag[list]) return;
  for (uint32_t n = 0;; n++) {
    uint32_t idc = r.Ue("modification_of_pic_nums_idc", 0, 3);
    if (!r.ok()) return;
    if (idc == 3) return;
    if (n >= num_active) {
      r.Fail();
      return;
    }
    RefListModification m{idc, 0};
    if (idc == 0 || idc == 1)
      m.value = r.Ue("abs_diff_pic_num_minus1", 0, max_pic_num - 1);
    else
      m.value = r.Ue("long_term_pic_num", 0, max_pic_num - 1);
    sh->modifications[list].push_back(m);
  }
}

// read pred_weight_table() with the inferred weights
void ReadPredWeightTable(Reader& r, const Sps& sps, SliceHeader* sh) {
  PredWeightTable& w = sh->pwt;
  w.luma_log2_weight_denom = r.Ue("luma_log2_weight_denom", 0, 7);
  bool chroma = sps.ChromaArrayType() != 0;
  if (chroma) w.chroma_log2_weight_denom = r.Ue("chroma_log2_weight_denom", 0, 7);
  int lists = sh->slice_type == kSliceB ? 2 : 1;
  static const char* const kNames[2][6] = {
      {"luma_weight_l0_flag", "luma_weight_l0", "luma_offset_l0", "chroma_weight_l0_flag", "chroma_weight_l0",
       "chroma_offset_l0"},
      {"luma_weight_l1_flag", "luma_weight_l1", "luma_offset_l1", "chroma_weight_l1_flag", "chroma_weight_l1",
       "chroma_offset_l1"}};
  for (int l = 0; l < lists; l++) {
    uint32_t n = (l == 0 ? sh->num_ref_idx_l0_active_minus1 : sh->num_ref_idx_l1_active_minus1) + 1;
    for (uint32_t i = 0; i < n && r.ok(); i++) {
      w.luma_weight[l][i] = static_cast<int16_t>(1 << w.luma_log2_weight_denom);
      w.luma_offset[l][i] = 0;
      w.luma_weight_flag[l][i] = r.Flag(kNames[l][0], i);
      if (w.luma_weight_flag[l][i]) {
        w.luma_weight[l][i] = static_cast<int16_t>(r.Se(kNames[l][1], -128, 127, i));
        w.luma_offset[l][i] = static_cast<int16_t>(r.Se(kNames[l][2], -128, 127, i));
      }
      for (int j = 0; j < 2; j++) {
        w.chroma_weight[l][i][j] = static_cast<int16_t>(1 << w.chroma_log2_weight_denom);
        w.chroma_offset[l][i][j] = 0;
      }
      if (chroma) {
        w.chroma_weight_flag[l][i] = r.Flag(kNames[l][3], i);
        if (w.chroma_weight_flag[l][i]) {
          for (int j = 0; j < 2; j++) {
            w.chroma_weight[l][i][j] = static_cast<int16_t>(r.Se(kNames[l][4], -128, 127, i, j));
            w.chroma_offset[l][i][j] = static_cast<int16_t>(r.Se(kNames[l][5], -128, 127, i, j));
          }
        }
      }
    }
  }
}

// read dec_ref_pic_marking()
void ReadDecRefPicMarking(Reader& r, const Sps& sps, uint32_t max_pic_num, SliceHeader* sh) {
  if (sh->idr_pic_flag) {
    sh->no_output_of_prior_pics_flag = r.Flag("no_output_of_prior_pics_flag");
    sh->long_term_reference_flag = r.Flag("long_term_reference_flag");
    return;
  }
  sh->adaptive_ref_pic_marking_mode_flag = r.Flag("adaptive_ref_pic_marking_mode_flag");
  if (!sh->adaptive_ref_pic_marking_mode_flag) return;
  for (int n = 0; n < 66; n++) {
    Mmco m;
    m.op = r.Ue("memory_management_control_operation", 0, 6);
    if (!r.ok() || m.op == 0) return;
    if (m.op == 1 || m.op == 3)
      m.difference_of_pic_nums_minus1 = r.Ue("difference_of_pic_nums_minus1", 0, max_pic_num - 1);
    if (m.op == 2) m.long_term_pic_num = r.Ue("long_term_pic_num", 0, max_pic_num - 1);
    if (m.op == 3 || m.op == 6) m.long_term_frame_idx = r.Ue("long_term_frame_idx", 0, 15);
    if (m.op == 4)
      m.max_long_term_frame_idx_plus1 = r.Ue("max_long_term_frame_idx_plus1", 0, sps.max_num_ref_frames);
    sh->mmcos.push_back(m);
  }
  r.Fail();
}

}

bool ParseSliceHeader(const uint8_t* rbsp, size_t size, const Sps& sps, const Pps& pps, SliceHeader* out,
                      SyntaxTrace* trace) {
  SliceHeader sh;
  if (size < 1 || !ParseNalHeader(rbsp[0], &sh.nal)) return false;
  Reader r(rbsp, size, trace);
  r.Structure("Slice Header");
  ReadNalHeader(r);
  sh.idr_pic_flag = sh.nal.nal_unit_type == kNalIdr;
  sh.first_mb_in_slice = r.Ue("first_mb_in_slice", 0, 0xfffffffe);
  sh.slice_type_raw = r.Ue("slice_type", 0, 9);
  sh.slice_type = static_cast<uint8_t>(sh.slice_type_raw % 5);
  sh.pic_parameter_set_id = r.Ue("pic_parameter_set_id", 0, kMaxPps - 1);
  if (!r.ok() || sh.pic_parameter_set_id != pps.pic_parameter_set_id) return false;
  if (sh.idr_pic_flag && sh.slice_type != kSliceI && sh.slice_type != kSliceSI) return false;
  if (sps.separate_colour_plane_flag) {
    if (r.U(2, "colour_plane_id") > 2) return false;
  }
  sh.frame_num = r.U(sps.log2_max_frame_num_minus4 + 4, "frame_num");
  if (!sps.frame_mbs_only_flag) {
    sh.field_pic_flag = r.Flag("field_pic_flag");
    if (sh.field_pic_flag) sh.bottom_field_flag = r.Flag("bottom_field_flag");
  }
  const uint32_t pic_size_in_mbs = sps.PicWidthInMbs() * (sps.FrameHeightInMbs() / (1 + sh.field_pic_flag));
  const bool mbaff = sps.mb_adaptive_frame_field_flag && !sh.field_pic_flag;
  if (static_cast<uint64_t>(sh.first_mb_in_slice) * (1 + mbaff) >= pic_size_in_mbs) return false;
  if (sh.idr_pic_flag) sh.idr_pic_id = r.Ue("idr_pic_id", 0, 65535);
  const bool bottom_present = pps.bottom_field_pic_order_in_frame_present_flag && !sh.field_pic_flag;
  const int32_t kMax = 0x7fffffff;
  if (sps.pic_order_cnt_type == 0) {
    sh.pic_order_cnt_lsb = r.U(sps.log2_max_pic_order_cnt_lsb_minus4 + 4, "pic_order_cnt_lsb");
    if (bottom_present) sh.delta_pic_order_cnt_bottom = r.Se("delta_pic_order_cnt_bottom", -kMax, kMax);
  }
  if (sps.pic_order_cnt_type == 1 && !sps.delta_pic_order_always_zero_flag) {
    sh.delta_pic_order_cnt[0] = r.Se("delta_pic_order_cnt", -kMax, kMax, 0);
    if (bottom_present) sh.delta_pic_order_cnt[1] = r.Se("delta_pic_order_cnt", -kMax, kMax, 1);
  }
  if (pps.redundant_pic_cnt_present_flag) sh.redundant_pic_cnt = r.Ue("redundant_pic_cnt", 0, 127);
  if (sh.slice_type == kSliceB) sh.direct_spatial_mv_pred_flag = r.Flag("direct_spatial_mv_pred_flag");
  sh.num_ref_idx_l0_active_minus1 = pps.num_ref_idx_l0_default_active_minus1;
  sh.num_ref_idx_l1_active_minus1 = pps.num_ref_idx_l1_default_active_minus1;
  const uint32_t max_active = sh.field_pic_flag ? 31 : 15;
  if (sh.slice_type == kSliceP || sh.slice_type == kSliceSP || sh.slice_type == kSliceB) {
    sh.num_ref_idx_active_override_flag = r.Flag("num_ref_idx_active_override_flag");
    if (sh.num_ref_idx_active_override_flag) {
      sh.num_ref_idx_l0_active_minus1 = r.Ue("num_ref_idx_l0_active_minus1", 0, max_active);
      if (sh.slice_type == kSliceB)
        sh.num_ref_idx_l1_active_minus1 = r.Ue("num_ref_idx_l1_active_minus1", 0, max_active);
    }
    if (sh.num_ref_idx_l0_active_minus1 > max_active) return false;
    if (sh.slice_type == kSliceB && sh.num_ref_idx_l1_active_minus1 > max_active) return false;
  }
  if (sh.slice_type != kSliceB) sh.num_ref_idx_l1_active_minus1 = 0;
  if (sh.slice_type == kSliceI || sh.slice_type == kSliceSI) sh.num_ref_idx_l0_active_minus1 = 0;
  const uint32_t max_frame_num = sps.MaxFrameNum();
  const uint32_t max_pic_num = sh.field_pic_flag ? 2 * max_frame_num : max_frame_num;
  if (sh.slice_type != kSliceI && sh.slice_type != kSliceSI) {
    ReadModifications(r, 0, sh.num_ref_idx_l0_active_minus1 + 1, max_pic_num, &sh);
    if (sh.slice_type == kSliceB) ReadModifications(r, 1, sh.num_ref_idx_l1_active_minus1 + 1, max_pic_num, &sh);
  }
  if ((pps.weighted_pred_flag && (sh.slice_type == kSliceP || sh.slice_type == kSliceSP)) ||
      (pps.weighted_bipred_idc == 1 && sh.slice_type == kSliceB)) {
    sh.has_pred_weight_table = true;
    ReadPredWeightTable(r, sps, &sh);
  }
  if (sh.nal.nal_ref_idc != 0) ReadDecRefPicMarking(r, sps, max_pic_num, &sh);
  if (pps.entropy_coding_mode_flag && sh.slice_type != kSliceI && sh.slice_type != kSliceSI)
    sh.cabac_init_idc = r.Ue("cabac_init_idc", 0, 2);
  const int32_t qp_bd_offset = 6 * static_cast<int32_t>(sps.bit_depth_luma_minus8);
  sh.slice_qp_delta =
      r.Se("slice_qp_delta", -qp_bd_offset - 26 - pps.pic_init_qp_minus26, 25 - pps.pic_init_qp_minus26);
  if (sh.slice_type == kSliceSP || sh.slice_type == kSliceSI) {
    if (sh.slice_type == kSliceSP) sh.sp_for_switch_flag = r.Flag("sp_for_switch_flag");
    sh.slice_qs_delta = r.Se("slice_qs_delta", -26 - pps.pic_init_qs_minus26, 25 - pps.pic_init_qs_minus26);
  }
  if (pps.deblocking_filter_control_present_flag) {
    sh.disable_deblocking_filter_idc = r.Ue("disable_deblocking_filter_idc", 0, 2);
    if (sh.disable_deblocking_filter_idc != 1) {
      sh.slice_alpha_c0_offset_div2 = r.Se("slice_alpha_c0_offset_div2", -6, 6);
      sh.slice_beta_offset_div2 = r.Se("slice_beta_offset_div2", -6, 6);
    }
  }
  if (pps.num_slice_groups_minus1 > 0 && pps.slice_group_map_type >= 3 && pps.slice_group_map_type <= 5) {
    uint32_t map_units = sps.PicWidthInMbs() * (sps.pic_height_in_map_units_minus1 + 1);
    uint32_t rate = pps.slice_group_change_rate_minus1 + 1;
    uint32_t n = map_units / rate + 1;
    int bits = 0;
    while ((1u << bits) < n) bits++;
    sh.slice_group_change_cycle = r.U(bits, "slice_group_change_cycle");
  }
  if (!r.ok()) return false;
  sh.header_bits = r.BitPos();
  *out = std::move(sh);
  return true;
}

bool ParseSeiRecoveryPoint(const uint8_t* rbsp, size_t size, RecoveryPoint* out) {
  size_t pos = 1;
  while (pos < size) {
    if (size - pos == 1 && rbsp[pos] == 0x80) break;
    uint32_t type = 0, len = 0;
    while (pos < size && rbsp[pos] == 0xff) {
      type += 255;
      pos++;
    }
    if (pos >= size) return false;
    type += rbsp[pos++];
    while (pos < size && rbsp[pos] == 0xff) {
      len += 255;
      pos++;
    }
    if (pos >= size) return false;
    len += rbsp[pos++];
    if (len > size - pos) return false;
    if (type == 6) {
      Reader r(rbsp + pos, len, nullptr);
      RecoveryPoint rp;
      rp.recovery_frame_cnt = r.Ue("recovery_frame_cnt", 0, 65535);
      rp.exact_match_flag = r.Flag("exact_match_flag");
      rp.broken_link_flag = r.Flag("broken_link_flag");
      r.U(2, "changing_slice_group_idc");
      if (!r.ok()) return false;
      rp.present = true;
      *out = rp;
      return true;
    }
    pos += len;
  }
  return false;
}

}

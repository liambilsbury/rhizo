#include "hevc_syntax.h"

#include <string.h>

// the HEVC parameter set and slice header parsers

namespace rhizo::c2va::hevc {
namespace {

constexpr uint8_t kDefaultIntra[64] = {
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 16, 17, 16, 17, 18, 17, 18, 18, 17, 18, 21,
    19, 20, 21, 20, 19, 21, 24, 22, 22, 24, 24, 22, 22, 24, 25, 25, 27, 30, 27, 25, 25, 29,
    31, 35, 35, 31, 29, 36, 41, 44, 41, 36, 47, 54, 54, 47, 65, 70, 65, 88, 88, 115};
constexpr uint8_t kDefaultInter[64] = {
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 20,
    20, 20, 20, 20, 20, 20, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 28,
    28, 28, 28, 28, 28, 33, 33, 33, 33, 33, 41, 41, 41, 41, 54, 54, 54, 71, 71, 91};

// fill a default scaling list (Tables 7-5, 7-6)
void DefaultList(int size_id, int matrix_id, uint8_t* list) {
  if (size_id == 0) {
    memset(list, 16, 16);
    return;
  }
  memcpy(list, matrix_id < 3 ? kDefaultIntra : kDefaultInter, 64);
}

// read nal_unit_header()
void ReadNalHeader(SyntaxReader& r) {
  r.U(1, "forbidden_zero_bit");
  r.U(6, "nal_unit_type");
  r.U(6, "nuh_layer_id");
  r.U(3, "nuh_temporal_id_plus1");
}

// read profile_tier_level()
Parse ReadProfileTierLevel(SyntaxReader& r, bool profile_present, int max_sub_layers_minus1, Sps* sps) {
  if (profile_present) {
    r.U(2, "general_profile_space");
    bool tier = r.Flag("general_tier_flag");
    uint32_t profile = r.U(5, "general_profile_idc");
    for (int j = 0; j < 32; j++) r.Flag("general_profile_compatibility_flag", j);
    r.Flag("general_progressive_source_flag");
    r.Flag("general_interlaced_source_flag");
    r.Flag("general_non_packed_constraint_flag");
    r.Flag("general_frame_only_constraint_flag");
    r.Skip(43 + 1);
    if (sps) {
      sps->general_tier_flag = tier;
      sps->general_profile_idc = static_cast<uint8_t>(profile);
    }
  }
  uint32_t level = r.U(8, "general_level_idc");
  if (sps) sps->general_level_idc = static_cast<uint8_t>(level);
  bool sub_profile[8] = {};
  bool sub_level[8] = {};
  for (int i = 0; i < max_sub_layers_minus1; i++) {
    sub_profile[i] = r.Flag("sub_layer_profile_present_flag", i);
    sub_level[i] = r.Flag("sub_layer_level_present_flag", i);
  }
  if (max_sub_layers_minus1 > 0)
    for (int i = max_sub_layers_minus1; i < 8; i++) r.U(2, "reserved_zero_2bits", i);
  for (int i = 0; i < max_sub_layers_minus1; i++) {
    if (sub_profile[i]) r.Skip(88);
    if (sub_level[i]) r.U(8, "sub_layer_level_idc", i);
  }
  return Parse::kOk;
}

// read scaling_list_data() with references and defaults resolved
Parse ReadScalingListData(SyntaxReader& r, ScalingLists* sl) {
  for (int size_id = 0; size_id < 4; size_id++) {
    int coef_num = size_id == 0 ? 16 : 64;
    for (int matrix_id = 0; matrix_id < 6; matrix_id += (size_id == 3) ? 3 : 1) {
      bool pred_mode = r.Flag("scaling_list_pred_mode_flag", size_id, matrix_id);
      uint8_t* list = sl->list[size_id][matrix_id];
      if (!pred_mode) {
        uint32_t delta = r.Ue("scaling_list_pred_matrix_id_delta", size_id, matrix_id);
        uint32_t limit = size_id == 3 ? matrix_id / 3 : matrix_id;
        if (delta > limit) return Parse::kBad;
        if (delta == 0) {
          DefaultList(size_id, matrix_id, list);
          if (size_id > 1) sl->dc[size_id - 2][matrix_id] = 16;
        } else {
          int ref = matrix_id - static_cast<int>(delta) * (size_id == 3 ? 3 : 1);
          memcpy(list, sl->list[size_id][ref], coef_num);
          if (size_id > 1) sl->dc[size_id - 2][matrix_id] = sl->dc[size_id - 2][ref];
        }
      } else {
        int next = 8;
        if (size_id > 1) {
          int32_t dc = r.Se("scaling_list_dc_coef_minus8", size_id - 2, matrix_id);
          if (dc < -7 || dc > 247) return Parse::kBad;
          next = dc + 8;
          sl->dc[size_id - 2][matrix_id] = static_cast<uint8_t>(next);
        }
        for (int i = 0; i < coef_num; i++) {
          int32_t d = r.Se("scaling_list_delta_coef");
          if (d < -128 || d > 127) return Parse::kBad;
          next = (next + d + 256) % 256;
          if (next == 0) return Parse::kBad;
          list[i] = static_cast<uint8_t>(next);
        }
      }
    }
  }
  return r.overrun() ? Parse::kBad : Parse::kOk;
}

// read st_ref_pic_set()
Parse ReadStRps(SyntaxReader& r, int idx, int num_sets, const StRps* sets, uint32_t max_dec_pic_buffering_minus1,
                StRps* out) {
  bool inter = idx != 0 ? r.Flag("inter_ref_pic_set_prediction_flag") : false;
  if (inter) {
    uint32_t delta_idx_minus1 = 0;
    if (idx == num_sets) delta_idx_minus1 = r.Ue("delta_idx_minus1");
    if (delta_idx_minus1 + 1 > static_cast<uint32_t>(idx)) return Parse::kBad;
    const StRps& ref = sets[idx - static_cast<int>(delta_idx_minus1 + 1)];
    bool sign = r.Flag("delta_rps_sign");
    uint32_t abs_minus1 = r.Ue("abs_delta_rps_minus1");
    if (abs_minus1 > 32767) return Parse::kBad;
    int32_t delta_rps = (1 - 2 * static_cast<int32_t>(sign)) * static_cast<int32_t>(abs_minus1 + 1);
    int n = ref.NumDeltaPocs();
    bool used[kMaxStRpsEntries + 1];
    bool use_delta[kMaxStRpsEntries + 1];
    for (int j = 0; j <= n; j++) {
      used[j] = r.Flag("used_by_curr_pic_flag", j);
      use_delta[j] = used[j] ? true : r.Flag("use_delta_flag", j);
    }
    int i = 0;
    for (int j = ref.num_positive - 1; j >= 0; j--) {
      int32_t d = ref.delta_poc_s1[j] + delta_rps;
      if (d < 0 && use_delta[ref.num_negative + j]) {
        if (i >= kMaxStRpsEntries) return Parse::kBad;
        out->delta_poc_s0[i] = d;
        out->used_s0[i++] = used[ref.num_negative + j];
      }
    }
    if (delta_rps < 0 && use_delta[n]) {
      if (i >= kMaxStRpsEntries) return Parse::kBad;
      out->delta_poc_s0[i] = delta_rps;
      out->used_s0[i++] = used[n];
    }
    for (int j = 0; j < ref.num_negative; j++) {
      int32_t d = ref.delta_poc_s0[j] + delta_rps;
      if (d < 0 && use_delta[j]) {
        if (i >= kMaxStRpsEntries) return Parse::kBad;
        out->delta_poc_s0[i] = d;
        out->used_s0[i++] = used[j];
      }
    }
    out->num_negative = static_cast<uint8_t>(i);
    i = 0;
    for (int j = ref.num_negative - 1; j >= 0; j--) {
      int32_t d = ref.delta_poc_s0[j] + delta_rps;
      if (d > 0 && use_delta[j]) {
        if (i >= kMaxStRpsEntries) return Parse::kBad;
        out->delta_poc_s1[i] = d;
        out->used_s1[i++] = used[j];
      }
    }
    if (delta_rps > 0 && use_delta[n]) {
      if (i >= kMaxStRpsEntries) return Parse::kBad;
      out->delta_poc_s1[i] = delta_rps;
      out->used_s1[i++] = used[n];
    }
    for (int j = 0; j < ref.num_positive; j++) {
      int32_t d = ref.delta_poc_s1[j] + delta_rps;
      if (d > 0 && use_delta[ref.num_negative + j]) {
        if (i >= kMaxStRpsEntries) return Parse::kBad;
        out->delta_poc_s1[i] = d;
        out->used_s1[i++] = used[ref.num_negative + j];
      }
    }
    out->num_positive = static_cast<uint8_t>(i);
    if (out->NumDeltaPocs() > kMaxStRpsEntries) return Parse::kBad;
  } else {
    uint32_t neg = r.Ue("num_negative_pics");
    if (neg > max_dec_pic_buffering_minus1) return Parse::kBad;
    uint32_t pos = r.Ue("num_positive_pics");
    if (pos > max_dec_pic_buffering_minus1 - neg) return Parse::kBad;
    out->num_negative = static_cast<uint8_t>(neg);
    out->num_positive = static_cast<uint8_t>(pos);
    int32_t poc = 0;
    for (uint32_t i = 0; i < neg; i++) {
      uint32_t d = r.Ue("delta_poc_s0_minus1", static_cast<int>(i));
      if (d > 32767) return Parse::kBad;
      poc -= static_cast<int32_t>(d) + 1;
      out->delta_poc_s0[i] = poc;
      out->used_s0[i] = r.Flag("used_by_curr_pic_s0_flag", static_cast<int>(i));
    }
    poc = 0;
    for (uint32_t i = 0; i < pos; i++) {
      uint32_t d = r.Ue("delta_poc_s1_minus1", static_cast<int>(i));
      if (d > 32767) return Parse::kBad;
      poc += static_cast<int32_t>(d) + 1;
      out->delta_poc_s1[i] = poc;
      out->used_s1[i] = r.Flag("used_by_curr_pic_s1_flag", static_cast<int>(i));
    }
  }
  return r.overrun() ? Parse::kBad : Parse::kOk;
}

// read sub_layer_hrd_parameters()
void ReadSubLayerHrd(SyntaxReader& r, uint32_t cpb_cnt, bool sub_pic) {
  for (uint32_t i = 0; i < cpb_cnt; i++) {
    r.Ue("bit_rate_value_minus1", static_cast<int>(i));
    r.Ue("cpb_size_value_minus1", static_cast<int>(i));
    if (sub_pic) {
      r.Ue("cpb_size_du_value_minus1", static_cast<int>(i));
      r.Ue("bit_rate_du_value_minus1", static_cast<int>(i));
    }
    r.Flag("cbr_flag", static_cast<int>(i));
  }
}

// read past hrd_parameters()
Parse ReadHrd(SyntaxReader& r, bool common, int max_sub_layers_minus1) {
  bool nal = false, vcl = false, sub_pic = false;
  if (common) {
    nal = r.Flag("nal_hrd_parameters_present_flag");
    vcl = r.Flag("vcl_hrd_parameters_present_flag");
    if (nal || vcl) {
      sub_pic = r.Flag("sub_pic_hrd_params_present_flag");
      if (sub_pic) {
        r.U(8, "tick_divisor_minus2");
        r.U(5, "du_cpb_removal_delay_increment_length_minus1");
        r.Flag("sub_pic_cpb_params_in_pic_timing_sei_flag");
        r.U(5, "dpb_output_delay_du_length_minus1");
      }
      r.U(4, "bit_rate_scale");
      r.U(4, "cpb_size_scale");
      if (sub_pic) r.U(4, "cpb_size_du_scale");
      r.U(5, "initial_cpb_removal_delay_length_minus1");
      r.U(5, "au_cpb_removal_delay_length_minus1");
      r.U(5, "dpb_output_delay_length_minus1");
    }
  }
  for (int i = 0; i <= max_sub_layers_minus1; i++) {
    bool fixed_general = r.Flag("fixed_pic_rate_general_flag", i);
    bool fixed_within_cvs = true;
    if (!fixed_general) fixed_within_cvs = r.Flag("fixed_pic_rate_within_cvs_flag", i);
    bool low_delay = false;
    if (fixed_within_cvs)
      r.Ue("elemental_duration_in_tc_minus1", i);
    else
      low_delay = r.Flag("low_delay_hrd_flag", i);
    uint32_t cpb_cnt_minus1 = 0;
    if (!low_delay) cpb_cnt_minus1 = r.Ue("cpb_cnt_minus1", i);
    if (cpb_cnt_minus1 > 31) return Parse::kBad;
    if (nal) ReadSubLayerHrd(r, cpb_cnt_minus1 + 1, sub_pic);
    if (vcl) ReadSubLayerHrd(r, cpb_cnt_minus1 + 1, sub_pic);
    if (r.overrun()) return Parse::kBad;
  }
  return Parse::kOk;
}

// read vui_parameters()
Parse ReadVui(SyntaxReader& r, Sps* sps) {
  if (r.Flag("aspect_ratio_info_present_flag")) {
    if (r.U(8, "aspect_ratio_idc") == 255) {
      r.U(16, "sar_width");
      r.U(16, "sar_height");
    }
  }
  if (r.Flag("overscan_info_present_flag")) r.Flag("overscan_appropriate_flag");
  if (r.Flag("video_signal_type_present_flag")) {
    r.U(3, "video_format");
    sps->color.full_range = r.Flag("video_full_range_flag");
    if (r.Flag("colour_description_present_flag")) {
      sps->color.primaries = r.U(8, "colour_primaries");
      sps->color.transfer = r.U(8, "transfer_characteristics");
      sps->color.matrix = r.U(8, "matrix_coeffs");
    }
  }
  if (r.Flag("chroma_loc_info_present_flag")) {
    r.Ue("chroma_sample_loc_type_top_field");
    r.Ue("chroma_sample_loc_type_bottom_field");
  }
  r.Flag("neutral_chroma_indication_flag");
  r.Flag("field_seq_flag");
  r.Flag("frame_field_info_present_flag");
  if (r.Flag("default_display_window_flag")) {
    r.Ue("def_disp_win_left_offset");
    r.Ue("def_disp_win_right_offset");
    r.Ue("def_disp_win_top_offset");
    r.Ue("def_disp_win_bottom_offset");
  }
  if (r.Flag("vui_timing_info_present_flag")) {
    r.U(32, "vui_num_units_in_tick");
    r.U(32, "vui_time_scale");
    if (r.Flag("vui_poc_proportional_to_timing_flag")) r.Ue("vui_num_ticks_poc_diff_one_minus1");
    if (r.Flag("vui_hrd_parameters_present_flag")) {
      if (ReadHrd(r, true, sps->max_sub_layers_minus1) != Parse::kOk) return Parse::kBad;
    }
  }
  if (r.Flag("bitstream_restriction_flag")) {
    r.Flag("tiles_fixed_structure_flag");
    r.Flag("motion_vectors_over_pic_boundaries_flag");
    r.Flag("restricted_ref_pic_lists_flag");
    r.Ue("min_spatial_segmentation_idc");
    r.Ue("max_bytes_per_pic_denom");
    r.Ue("max_bits_per_min_cu_denom");
    r.Ue("log2_max_mv_length_horizontal");
    r.Ue("log2_max_mv_length_vertical");
  }
  return r.overrun() ? Parse::kBad : Parse::kOk;
}

// read the SPS extensions, rejecting range and SCC tools
Parse ReadSpsExtensions(SyntaxReader& r) {
  if (!r.Flag("sps_extension_present_flag")) return Parse::kOk;
  bool range = r.Flag("sps_range_extension_flag");
  bool multilayer = r.Flag("sps_multilayer_extension_flag");
  bool ext3d = r.Flag("sps_3d_extension_flag");
  bool scc = r.Flag("sps_scc_extension_flag");
  r.U(4, "sps_extension_4bits");
  if (range) {
    static const char* const kNames[] = {
        "transform_skip_rotation_enabled_flag", "transform_skip_context_enabled_flag",
        "implicit_rdpcm_enabled_flag",          "explicit_rdpcm_enabled_flag",
        "extended_precision_processing_flag",   "intra_smoothing_disabled_flag",
        "high_precision_offsets_enabled_flag",  "persistent_rice_adaptation_enabled_flag",
        "cabac_bypass_alignment_enabled_flag"};
    bool any = false;
    for (const char* n : kNames) any |= r.Flag(n);
    if (any) return Parse::kUnsupported;
  }
  if (multilayer) r.Flag("inter_view_mv_vert_constraint_flag");
  if (ext3d) {
    return scc ? Parse::kUnsupported : Parse::kOk;
  }
  if (scc) {
    bool any = r.Flag("sps_curr_pic_ref_enabled_flag");
    any |= r.Flag("palette_mode_enabled_flag");
    if (any) return Parse::kUnsupported;
    any |= r.U(2, "motion_vector_resolution_control_idc") != 0;
    any |= r.Flag("intra_boundary_filtering_disabled_flag");
    if (any) return Parse::kUnsupported;
  }
  return Parse::kOk;
}

}

bool ParseNalHeader(const uint8_t* data, size_t size, NalHeader* out) {
  if (size < 2) return false;
  if (data[0] & 0x80) return false;
  out->type = (data[0] >> 1) & 0x3f;
  out->layer_id = static_cast<uint8_t>(((data[0] & 1) << 5) | (data[1] >> 3));
  uint8_t tid_plus1 = data[1] & 7;
  if (tid_plus1 == 0) return false;
  out->temporal_id = tid_plus1 - 1;
  return true;
}

void UnescapeNal(const uint8_t* data, size_t size, Rbsp* out, size_t max_bytes) {
  out->bytes.clear();
  out->ep_before.clear();
  out->truncated = false;
  out->bytes.reserve(size < max_bytes ? size : max_bytes);
  for (size_t i = 0; i < size; i++) {
    if (out->bytes.size() >= max_bytes) {
      out->truncated = true;
      return;
    }
    if (i >= 2 && i + 2 < size && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 3) {
      out->bytes.push_back(0);
      out->bytes.push_back(0);
      out->ep_before.push_back(static_cast<uint32_t>(out->bytes.size()));
      i += 2;
      continue;
    }
    out->bytes.push_back(data[i]);
  }
}

void DefaultScalingLists(ScalingLists* out) {
  for (int size_id = 0; size_id < 4; size_id++)
    for (int m = 0; m < 6; m++) DefaultList(size_id, m, out->list[size_id][m]);
  memset(out->dc, 16, sizeof(out->dc));
}

Parse ParseVps(const Rbsp& rbsp, TraceSink* trace, Vps* out) {
  SyntaxReader r(rbsp.bytes.data(), rbsp.bytes.size(), trace);
  if (trace) trace->NalBegin(kVps);
  ReadNalHeader(r);
  out->id = static_cast<uint8_t>(r.U(4, "vps_video_parameter_set_id"));
  r.Flag("vps_base_layer_internal_flag");
  r.Flag("vps_base_layer_available_flag");
  r.U(6, "vps_max_layers_minus1");
  uint32_t max_sub_layers_minus1 = r.U(3, "vps_max_sub_layers_minus1");
  if (max_sub_layers_minus1 > 6) return Parse::kBad;
  out->max_sub_layers_minus1 = static_cast<uint8_t>(max_sub_layers_minus1);
  r.Flag("vps_temporal_id_nesting_flag");
  r.U(16, "vps_reserved_0xffff_16bits");
  ReadProfileTierLevel(r, true, static_cast<int>(max_sub_layers_minus1), nullptr);
  bool ordering = r.Flag("vps_sub_layer_ordering_info_present_flag");
  for (uint32_t i = ordering ? 0 : max_sub_layers_minus1; i <= max_sub_layers_minus1; i++) {
    r.Ue("vps_max_dec_pic_buffering_minus1", static_cast<int>(i));
    r.Ue("vps_max_num_reorder_pics", static_cast<int>(i));
    r.Ue("vps_max_latency_increase_plus1", static_cast<int>(i));
  }
  return r.overrun() ? Parse::kBad : Parse::kOk;
}

Parse ParseSps(const Rbsp& rbsp, TraceSink* trace, Sps* out) {
  SyntaxReader r(rbsp.bytes.data(), rbsp.bytes.size(), trace);
  if (trace) trace->NalBegin(kSps);
  ReadNalHeader(r);
  out->rbsp = rbsp.bytes;
  out->color = ColorInfo();
  out->vps_id = static_cast<uint8_t>(r.U(4, "sps_video_parameter_set_id"));
  uint32_t max_sub_layers_minus1 = r.U(3, "sps_max_sub_layers_minus1");
  if (max_sub_layers_minus1 > 6) return Parse::kBad;
  out->max_sub_layers_minus1 = static_cast<uint8_t>(max_sub_layers_minus1);
  out->highest_tid = out->max_sub_layers_minus1;
  r.Flag("sps_temporal_id_nesting_flag");
  ReadProfileTierLevel(r, true, static_cast<int>(max_sub_layers_minus1), out);
  uint32_t id = r.Ue("sps_seq_parameter_set_id");
  if (id > 15) return Parse::kBad;
  out->id = static_cast<uint8_t>(id);
  uint32_t chroma = r.Ue("chroma_format_idc");
  if (chroma > 3) return Parse::kBad;
  out->chroma_format_idc = static_cast<uint8_t>(chroma);
  out->separate_colour_plane_flag = chroma == 3 ? r.Flag("separate_colour_plane_flag") : false;
  if (chroma != 1) return r.overrun() ? Parse::kBad : Parse::kUnsupported;
  out->pic_width = r.Ue("pic_width_in_luma_samples");
  out->pic_height = r.Ue("pic_height_in_luma_samples");
  if (out->pic_width == 0 || out->pic_height == 0) return Parse::kBad;
  out->conf_win_left = out->conf_win_right = out->conf_win_top = out->conf_win_bottom = 0;
  if (r.Flag("conformance_window_flag")) {
    out->conf_win_left = r.Ue("conf_win_left_offset");
    out->conf_win_right = r.Ue("conf_win_right_offset");
    out->conf_win_top = r.Ue("conf_win_top_offset");
    out->conf_win_bottom = r.Ue("conf_win_bottom_offset");
  }
  uint32_t bd_luma = r.Ue("bit_depth_luma_minus8");
  uint32_t bd_chroma = r.Ue("bit_depth_chroma_minus8");
  if (bd_luma > 8 || bd_chroma > 8) return Parse::kBad;
  out->bit_depth_luma_minus8 = static_cast<uint8_t>(bd_luma);
  out->bit_depth_chroma_minus8 = static_cast<uint8_t>(bd_chroma);
  uint32_t poc_bits = r.Ue("log2_max_pic_order_cnt_lsb_minus4");
  if (poc_bits > 12) return Parse::kBad;
  out->log2_max_poc_lsb_minus4 = static_cast<uint8_t>(poc_bits);
  out->max_poc_lsb = 1u << (poc_bits + 4);
  bool ordering = r.Flag("sps_sub_layer_ordering_info_present_flag");
  for (uint32_t i = ordering ? 0 : max_sub_layers_minus1; i <= max_sub_layers_minus1; i++) {
    out->max_dec_pic_buffering_minus1[i] = r.Ue("sps_max_dec_pic_buffering_minus1", static_cast<int>(i));
    out->max_num_reorder_pics[i] = r.Ue("sps_max_num_reorder_pics", static_cast<int>(i));
    out->max_latency_increase_plus1[i] = r.Ue("sps_max_latency_increase_plus1", static_cast<int>(i));
    if (out->max_dec_pic_buffering_minus1[i] > kMaxDpbSize - 1) return Parse::kBad;
    if (out->max_num_reorder_pics[i] > out->max_dec_pic_buffering_minus1[i]) return Parse::kBad;
  }
  if (!ordering) {
    for (uint32_t i = 0; i < max_sub_layers_minus1; i++) {
      out->max_dec_pic_buffering_minus1[i] = out->max_dec_pic_buffering_minus1[max_sub_layers_minus1];
      out->max_num_reorder_pics[i] = out->max_num_reorder_pics[max_sub_layers_minus1];
      out->max_latency_increase_plus1[i] = out->max_latency_increase_plus1[max_sub_layers_minus1];
    }
  }
  uint32_t min_cb = r.Ue("log2_min_luma_coding_block_size_minus3");
  uint32_t diff_cb = r.Ue("log2_diff_max_min_luma_coding_block_size");
  uint32_t min_tb = r.Ue("log2_min_luma_transform_block_size_minus2");
  uint32_t diff_tb = r.Ue("log2_diff_max_min_luma_transform_block_size");
  if (min_cb > 3 || diff_cb > 3 || min_tb > 3 || diff_tb > 3) return Parse::kBad;
  out->log2_min_cb_minus3 = static_cast<uint8_t>(min_cb);
  out->log2_diff_max_min_cb = static_cast<uint8_t>(diff_cb);
  out->log2_min_tb_minus2 = static_cast<uint8_t>(min_tb);
  out->log2_diff_max_min_tb = static_cast<uint8_t>(diff_tb);
  out->min_cb_log2 = min_cb + 3;
  out->ctb_log2 = out->min_cb_log2 + diff_cb;
  if (out->ctb_log2 > 6) return Parse::kBad;
  uint32_t min_tb_log2 = min_tb + 2, max_tb_log2 = min_tb_log2 + diff_tb;
  if (min_tb_log2 >= out->min_cb_log2) return Parse::kBad;
  if (max_tb_log2 > (out->ctb_log2 < 5 ? out->ctb_log2 : 5)) return Parse::kBad;
  uint32_t th_inter = r.Ue("max_transform_hierarchy_depth_inter");
  uint32_t th_intra = r.Ue("max_transform_hierarchy_depth_intra");
  if (th_inter > out->ctb_log2 - min_tb_log2 || th_intra > out->ctb_log2 - min_tb_log2) return Parse::kBad;
  out->max_transform_hierarchy_depth_inter = static_cast<uint8_t>(th_inter);
  out->max_transform_hierarchy_depth_intra = static_cast<uint8_t>(th_intra);
  uint32_t min_cb_size = 1u << out->min_cb_log2;
  if (out->pic_width % min_cb_size || out->pic_height % min_cb_size) return Parse::kBad;
  if (static_cast<uint64_t>(out->conf_win_left) + out->conf_win_right >= out->pic_width / 2 ||
      static_cast<uint64_t>(out->conf_win_top) + out->conf_win_bottom >= out->pic_height / 2)
    return Parse::kBad;

  out->scaling_list_enabled = r.Flag("scaling_list_enabled_flag");
  out->scaling_list_data_present = false;
  DefaultScalingLists(&out->scaling);
  if (out->scaling_list_enabled) {
    out->scaling_list_data_present = r.Flag("sps_scaling_list_data_present_flag");
    if (out->scaling_list_data_present && ReadScalingListData(r, &out->scaling) != Parse::kOk) return Parse::kBad;
  }
  out->amp_enabled = r.Flag("amp_enabled_flag");
  out->sao_enabled = r.Flag("sample_adaptive_offset_enabled_flag");
  out->pcm_enabled = r.Flag("pcm_enabled_flag");
  out->pcm_bit_depth_luma_minus1 = out->pcm_bit_depth_chroma_minus1 = 0;
  out->log2_min_pcm_cb_minus3 = out->log2_diff_max_min_pcm_cb = 0;
  out->pcm_loop_filter_disabled = false;
  if (out->pcm_enabled) {
    out->pcm_bit_depth_luma_minus1 = static_cast<uint8_t>(r.U(4, "pcm_sample_bit_depth_luma_minus1"));
    out->pcm_bit_depth_chroma_minus1 = static_cast<uint8_t>(r.U(4, "pcm_sample_bit_depth_chroma_minus1"));
    uint32_t min_pcm = r.Ue("log2_min_pcm_luma_coding_block_size_minus3");
    uint32_t diff_pcm = r.Ue("log2_diff_max_min_pcm_luma_coding_block_size");
    out->pcm_loop_filter_disabled = r.Flag("pcm_loop_filter_disabled_flag");
    if (out->pcm_bit_depth_luma_minus1 + 1u > bd_luma + 8 || out->pcm_bit_depth_chroma_minus1 + 1u > bd_chroma + 8)
      return Parse::kBad;
    uint32_t lo = out->min_cb_log2 < 5 ? out->min_cb_log2 : 5;
    uint32_t hi = out->ctb_log2 < 5 ? out->ctb_log2 : 5;
    if (min_pcm + 3 < lo || min_pcm + 3 > hi || diff_pcm > hi - (min_pcm + 3)) return Parse::kBad;
    out->log2_min_pcm_cb_minus3 = static_cast<uint8_t>(min_pcm);
    out->log2_diff_max_min_pcm_cb = static_cast<uint8_t>(diff_pcm);
  }
  uint32_t num_st = r.Ue("num_short_term_ref_pic_sets");
  if (num_st > kMaxStRpsSets) return Parse::kBad;
  out->num_short_term_ref_pic_sets = static_cast<uint8_t>(num_st);
  for (uint32_t i = 0; i < num_st; i++) {
    if (ReadStRps(r, static_cast<int>(i), static_cast<int>(num_st), out->st_rps,
                  out->max_dec_pic_buffering_minus1[max_sub_layers_minus1], &out->st_rps[i]) != Parse::kOk)
      return Parse::kBad;
  }
  out->long_term_ref_pics_present = r.Flag("long_term_ref_pics_present_flag");
  out->num_long_term_ref_pics_sps = 0;
  if (out->long_term_ref_pics_present) {
    uint32_t n = r.Ue("num_long_term_ref_pics_sps");
    if (n > kMaxLtSps) return Parse::kBad;
    out->num_long_term_ref_pics_sps = static_cast<uint8_t>(n);
    for (uint32_t i = 0; i < n; i++) {
      out->lt_ref_pic_poc_lsb_sps[i] = r.U(static_cast<int>(poc_bits + 4), "lt_ref_pic_poc_lsb_sps", static_cast<int>(i));
      out->used_by_curr_pic_lt_sps[i] = r.Flag("used_by_curr_pic_lt_sps_flag", static_cast<int>(i));
    }
  }
  out->temporal_mvp_enabled = r.Flag("sps_temporal_mvp_enabled_flag");
  out->strong_intra_smoothing_enabled = r.Flag("strong_intra_smoothing_enabled_flag");
  if (r.overrun()) return Parse::kBad;

  out->pic_width_in_ctbs = (out->pic_width + (1u << out->ctb_log2) - 1) >> out->ctb_log2;
  out->pic_height_in_ctbs = (out->pic_height + (1u << out->ctb_log2) - 1) >> out->ctb_log2;
  out->pic_size_in_ctbs = out->pic_width_in_ctbs * out->pic_height_in_ctbs;

  Parse ext = Parse::kOk;
  bool vui_ok = true;
  if (r.Flag("vui_parameters_present_flag")) {
    ColorInfo saved = out->color;
    if (ReadVui(r, out) != Parse::kOk) {
      out->color = saved;
      vui_ok = false;
    }
  }
  if (vui_ok) {
    ext = ReadSpsExtensions(r);
    if (r.overrun()) ext = Parse::kOk;
  }
  if (bd_luma > 2 || bd_chroma > 2) return Parse::kUnsupported;
  if (out->ctb_log2 < 4) return Parse::kUnsupported;
  if (out->pic_width > kMaxPicDim || out->pic_height > kMaxPicDim) return Parse::kUnsupported;
  return ext;
}

Parse ParsePps(const Rbsp& rbsp, TraceSink* trace, Pps* out) {
  SyntaxReader r(rbsp.bytes.data(), rbsp.bytes.size(), trace);
  if (trace) trace->NalBegin(kPps);
  ReadNalHeader(r);
  uint32_t id = r.Ue("pps_pic_parameter_set_id");
  uint32_t sps_id = r.Ue("pps_seq_parameter_set_id");
  if (id > 63 || sps_id > 15) return Parse::kBad;
  out->id = static_cast<uint8_t>(id);
  out->sps_id = static_cast<uint8_t>(sps_id);
  out->dependent_slice_segments_enabled = r.Flag("dependent_slice_segments_enabled_flag");
  out->output_flag_present = r.Flag("output_flag_present_flag");
  out->num_extra_slice_header_bits = static_cast<uint8_t>(r.U(3, "num_extra_slice_header_bits"));
  out->sign_data_hiding_enabled = r.Flag("sign_data_hiding_enabled_flag");
  out->cabac_init_present = r.Flag("cabac_init_present_flag");
  uint32_t l0 = r.Ue("num_ref_idx_l0_default_active_minus1");
  uint32_t l1 = r.Ue("num_ref_idx_l1_default_active_minus1");
  if (l0 > 14 || l1 > 14) return Parse::kBad;
  out->num_ref_idx_l0_default_active_minus1 = static_cast<uint8_t>(l0);
  out->num_ref_idx_l1_default_active_minus1 = static_cast<uint8_t>(l1);
  int32_t init_qp = r.Se("init_qp_minus26");
  if (init_qp < -(26 + 48) || init_qp > 25) return Parse::kBad;
  out->init_qp_minus26 = static_cast<int8_t>(init_qp);
  out->constrained_intra_pred = r.Flag("constrained_intra_pred_flag");
  out->transform_skip_enabled = r.Flag("transform_skip_enabled_flag");
  out->cu_qp_delta_enabled = r.Flag("cu_qp_delta_enabled_flag");
  out->diff_cu_qp_delta_depth = 0;
  if (out->cu_qp_delta_enabled) {
    uint32_t d = r.Ue("diff_cu_qp_delta_depth");
    if (d > 3) return Parse::kBad;
    out->diff_cu_qp_delta_depth = static_cast<uint8_t>(d);
  }
  int32_t cb = r.Se("pps_cb_qp_offset");
  int32_t cr = r.Se("pps_cr_qp_offset");
  if (cb < -12 || cb > 12 || cr < -12 || cr > 12) return Parse::kBad;
  out->cb_qp_offset = static_cast<int8_t>(cb);
  out->cr_qp_offset = static_cast<int8_t>(cr);
  out->slice_chroma_qp_offsets_present = r.Flag("pps_slice_chroma_qp_offsets_present_flag");
  out->weighted_pred = r.Flag("weighted_pred_flag");
  out->weighted_bipred = r.Flag("weighted_bipred_flag");
  out->transquant_bypass_enabled = r.Flag("transquant_bypass_enabled_flag");
  out->tiles_enabled = r.Flag("tiles_enabled_flag");
  out->entropy_coding_sync_enabled = r.Flag("entropy_coding_sync_enabled_flag");
  out->num_tile_columns_minus1 = out->num_tile_rows_minus1 = 0;
  out->uniform_spacing = true;
  out->loop_filter_across_tiles_enabled = true;
  if (out->tiles_enabled) {
    uint32_t cols = r.Ue("num_tile_columns_minus1");
    uint32_t rows = r.Ue("num_tile_rows_minus1");
    if (cols >= kMaxTileCols || rows >= kMaxTileRows) return Parse::kBad;
    if (cols == 0 && rows == 0) return Parse::kBad;
    out->num_tile_columns_minus1 = static_cast<uint8_t>(cols);
    out->num_tile_rows_minus1 = static_cast<uint8_t>(rows);
    out->uniform_spacing = r.Flag("uniform_spacing_flag");
    if (!out->uniform_spacing) {
      for (uint32_t i = 0; i < cols; i++) out->column_width_minus1[i] = r.Ue("column_width_minus1", static_cast<int>(i));
      for (uint32_t j = 0; j < rows; j++) out->row_height_minus1[j] = r.Ue("row_height_minus1", static_cast<int>(j));
    }
    out->loop_filter_across_tiles_enabled = r.Flag("loop_filter_across_tiles_enabled_flag");
  }
  out->loop_filter_across_slices_enabled = r.Flag("pps_loop_filter_across_slices_enabled_flag");
  out->deblocking_filter_control_present = r.Flag("deblocking_filter_control_present_flag");
  out->deblocking_filter_override_enabled = false;
  out->deblocking_filter_disabled = false;
  out->beta_offset_div2 = out->tc_offset_div2 = 0;
  if (out->deblocking_filter_control_present) {
    out->deblocking_filter_override_enabled = r.Flag("deblocking_filter_override_enabled_flag");
    out->deblocking_filter_disabled = r.Flag("pps_deblocking_filter_disabled_flag");
    if (!out->deblocking_filter_disabled) {
      int32_t beta = r.Se("pps_beta_offset_div2");
      int32_t tc = r.Se("pps_tc_offset_div2");
      if (beta < -6 || beta > 6 || tc < -6 || tc > 6) return Parse::kBad;
      out->beta_offset_div2 = static_cast<int8_t>(beta);
      out->tc_offset_div2 = static_cast<int8_t>(tc);
    }
  }
  out->scaling_list_data_present = r.Flag("pps_scaling_list_data_present_flag");
  DefaultScalingLists(&out->scaling);
  if (out->scaling_list_data_present && ReadScalingListData(r, &out->scaling) != Parse::kOk) return Parse::kBad;
  out->lists_modification_present = r.Flag("lists_modification_present_flag");
  uint32_t pml = r.Ue("log2_parallel_merge_level_minus2");
  if (pml > 4) return Parse::kBad;
  out->log2_parallel_merge_level_minus2 = static_cast<uint8_t>(pml);
  out->slice_segment_header_extension_present = r.Flag("slice_segment_header_extension_present_flag");
  if (r.overrun()) return Parse::kBad;
  if (r.Flag("pps_extension_present_flag")) {
    bool range = r.Flag("pps_range_extension_flag");
    bool multilayer = r.Flag("pps_multilayer_extension_flag");
    bool ext3d = r.Flag("pps_3d_extension_flag");
    bool scc = r.Flag("pps_scc_extension_flag");
    r.U(4, "pps_extension_4bits");
    if (range) {
      bool any = false;
      if (out->transform_skip_enabled) any |= r.Ue("log2_max_transform_skip_block_size_minus2") != 0;
      any |= r.Flag("cross_component_prediction_enabled_flag");
      if (r.Flag("chroma_qp_offset_list_enabled_flag")) return Parse::kUnsupported;
      any |= r.Ue("log2_sao_offset_scale_luma") != 0;
      any |= r.Ue("log2_sao_offset_scale_chroma") != 0;
      if (any) return Parse::kUnsupported;
    }
    if (multilayer || ext3d) {
      if (scc) return Parse::kUnsupported;
    } else if (scc) {
      bool any = r.Flag("pps_curr_pic_ref_enabled_flag");
      any |= r.Flag("residual_adaptive_colour_transform_enabled_flag");
      if (any) return Parse::kUnsupported;
      if (r.Flag("pps_palette_predictor_initializers_present_flag")) return Parse::kUnsupported;
    }
  }
  return Parse::kOk;
}

Parse ResolvePps(const Pps& pps, const Sps& sps, PpsLayout* out) {
  int32_t qp_bd_offset_y = 6 * sps.bit_depth_luma_minus8;
  if (pps.init_qp_minus26 < -(26 + qp_bd_offset_y)) return Parse::kBad;
  if (pps.diff_cu_qp_delta_depth > sps.log2_diff_max_min_cb) return Parse::kBad;
  if (pps.log2_parallel_merge_level_minus2 + 2u > sps.ctb_log2) return Parse::kBad;
  memset(out, 0, sizeof(*out));
  if (!pps.tiles_enabled) return Parse::kOk;
  uint32_t cols = pps.num_tile_columns_minus1 + 1u, rows = pps.num_tile_rows_minus1 + 1u;
  if (cols > sps.pic_width_in_ctbs || rows > sps.pic_height_in_ctbs) return Parse::kBad;
  uint64_t used = 0;
  for (uint32_t i = 0; i < cols; i++) {
    uint64_t w;
    if (pps.uniform_spacing) {
      w = ((i + 1) * static_cast<uint64_t>(sps.pic_width_in_ctbs)) / cols -
          (i * static_cast<uint64_t>(sps.pic_width_in_ctbs)) / cols;
    } else if (i + 1 < cols) {
      w = static_cast<uint64_t>(pps.column_width_minus1[i]) + 1;
    } else {
      if (used >= sps.pic_width_in_ctbs) return Parse::kBad;
      w = sps.pic_width_in_ctbs - used;
    }
    used += w;
    if (w == 0 || used > sps.pic_width_in_ctbs) return Parse::kBad;
    if (i < kMaxTileCols - 1) out->column_width_minus1[i] = static_cast<uint16_t>(w - 1);
  }
  used = 0;
  for (uint32_t j = 0; j < rows; j++) {
    uint64_t h;
    if (pps.uniform_spacing) {
      h = ((j + 1) * static_cast<uint64_t>(sps.pic_height_in_ctbs)) / rows -
          (j * static_cast<uint64_t>(sps.pic_height_in_ctbs)) / rows;
    } else if (j + 1 < rows) {
      h = static_cast<uint64_t>(pps.row_height_minus1[j]) + 1;
    } else {
      if (used >= sps.pic_height_in_ctbs) return Parse::kBad;
      h = sps.pic_height_in_ctbs - used;
    }
    used += h;
    if (h == 0 || used > sps.pic_height_in_ctbs) return Parse::kBad;
    if (j < kMaxTileRows - 1) out->row_height_minus1[j] = static_cast<uint16_t>(h - 1);
  }
  return Parse::kOk;
}

bool PeekSliceHeader(const Rbsp& rbsp, bool* first_slice_segment_in_pic, uint32_t* pps_id) {
  NalHeader nal;
  if (!ParseNalHeader(rbsp.bytes.data(), rbsp.bytes.size(), &nal)) return false;
  BitReader r(rbsp.bytes.data(), rbsp.bytes.size());
  r.Skip(16);
  *first_slice_segment_in_pic = r.U(1) != 0;
  if (IsIrap(nal.type)) r.U(1);
  *pps_id = r.Ue();
  return !r.overrun() && *pps_id <= 63;
}

namespace {

// read pred_weight_table()
Parse ReadPredWeights(SyntaxReader& r, const SliceHeader& sh, PredWeights* pw) {
  memset(pw, 0, sizeof(*pw));
  uint32_t luma_denom = r.Ue("luma_log2_weight_denom");
  if (luma_denom > 7) return Parse::kBad;
  pw->luma_log2_weight_denom = static_cast<uint8_t>(luma_denom);
  int32_t delta_chroma = r.Se("delta_chroma_log2_weight_denom");
  int32_t chroma_denom = static_cast<int32_t>(luma_denom) + delta_chroma;
  if (chroma_denom < 0 || chroma_denom > 7) return Parse::kBad;
  pw->delta_chroma_log2_weight_denom = static_cast<int8_t>(delta_chroma);
  const int lists = sh.slice_type == 0 ? 2 : 1;
  for (int l = 0; l < lists; l++) {
    const int n = (l == 0 ? sh.num_ref_idx_l0_active_minus1 : sh.num_ref_idx_l1_active_minus1) + 1;
    bool luma_flag[kMaxRefIdx], chroma_flag[kMaxRefIdx];
    for (int i = 0; i < n; i++) luma_flag[i] = r.Flag(l == 0 ? "luma_weight_l0_flag" : "luma_weight_l1_flag", i);
    for (int i = 0; i < n; i++)
      chroma_flag[i] = r.Flag(l == 0 ? "chroma_weight_l0_flag" : "chroma_weight_l1_flag", i);
    for (int i = 0; i < n; i++) {
      if (luma_flag[i]) {
        int32_t w = r.Se(l == 0 ? "delta_luma_weight_l0" : "delta_luma_weight_l1", i);
        int32_t o = r.Se(l == 0 ? "luma_offset_l0" : "luma_offset_l1", i);
        if (w < -128 || w > 127 || o < -128 || o > 127) return Parse::kBad;
        pw->delta_luma_weight[l][i] = static_cast<int8_t>(w);
        pw->luma_offset[l][i] = static_cast<int8_t>(o);
      }
      if (chroma_flag[i]) {
        for (int j = 0; j < 2; j++) {
          int32_t w = r.Se(l == 0 ? "delta_chroma_weight_l0" : "delta_chroma_weight_l1", i, j);
          int32_t o = r.Se(l == 0 ? "delta_chroma_offset_l0" : "delta_chroma_offset_l1", i, j);
          if (w < -128 || w > 127 || o < -4 * 128 || o > 4 * 128 - 1) return Parse::kBad;
          pw->delta_chroma_weight[l][i][j] = static_cast<int8_t>(w);
          int32_t weight = (1 << chroma_denom) + w;
          int32_t off = 128 + o - ((128 * weight) >> chroma_denom);
          if (off < -128) off = -128;
          if (off > 127) off = 127;
          pw->chroma_offset[l][i][j] = static_cast<int8_t>(off);
        }
      }
    }
  }
  return r.overrun() ? Parse::kBad : Parse::kOk;
}

}

Parse ParseSliceHeader(const Rbsp& rbsp, const NalHeader& nal, const Sps& sps, const Pps& pps,
                       const SliceHeader* prev, TraceSink* trace, SliceHeader* out) {
  SyntaxReader r(rbsp.bytes.data(), rbsp.bytes.size(), trace);
  if (trace) trace->NalBegin(nal.type);
  ReadNalHeader(r);
  bool first = r.Flag("first_slice_segment_in_pic_flag");
  bool no_output_of_prior_pics = false;
  if (IsIrap(nal.type)) no_output_of_prior_pics = r.Flag("no_output_of_prior_pics_flag");
  uint32_t pps_id = r.Ue("slice_pic_parameter_set_id");
  if (pps_id != pps.id) return Parse::kBad;
  bool dependent = false;
  uint32_t address = 0;
  if (!first) {
    if (pps.dependent_slice_segments_enabled) dependent = r.Flag("dependent_slice_segment_flag");
    address = r.U(CeilLog2(sps.pic_size_in_ctbs), "slice_segment_address");
    if (address == 0 || address >= sps.pic_size_in_ctbs) return Parse::kBad;
  }
  if (dependent) {
    if (!prev) return Parse::kBad;
    *out = *prev;
  } else {
    memset(out, 0, sizeof(*out));
  }
  out->nal = nal;
  out->first_slice_segment_in_pic = first;
  out->no_output_of_prior_pics = no_output_of_prior_pics;
  out->pps_id = static_cast<uint8_t>(pps_id);
  out->dependent_slice_segment = dependent;
  out->segment_address = address;

  if (!dependent) {
    for (int i = 0; i < pps.num_extra_slice_header_bits; i++) r.Flag("slice_reserved_flag", i);
    uint32_t slice_type = r.Ue("slice_type");
    if (slice_type > 2) return Parse::kBad;
    if (IsIrap(nal.type) && slice_type != 2) return Parse::kBad;
    out->slice_type = static_cast<uint8_t>(slice_type);
    out->pic_output_flag = pps.output_flag_present ? r.Flag("pic_output_flag") : true;
    const int poc_bits = sps.log2_max_poc_lsb_minus4 + 4;
    if (!IsIdr(nal.type)) {
      out->pic_order_cnt_lsb = r.U(poc_bits, "slice_pic_order_cnt_lsb");
      out->short_term_ref_pic_set_sps_flag = r.Flag("short_term_ref_pic_set_sps_flag");
      if (!out->short_term_ref_pic_set_sps_flag) {
        size_t begin = r.BitPos();
        if (ReadStRps(r, sps.num_short_term_ref_pic_sets, sps.num_short_term_ref_pic_sets, sps.st_rps,
                      sps.max_dec_pic_buffering_minus1[sps.highest_tid], &out->st_rps) != Parse::kOk)
          return Parse::kBad;
        out->st_rps_bits = static_cast<uint32_t>(r.BitPos() - begin);
      } else {
        if (sps.num_short_term_ref_pic_sets == 0) return Parse::kBad;
        uint32_t idx = 0;
        if (sps.num_short_term_ref_pic_sets > 1)
          idx = r.U(CeilLog2(sps.num_short_term_ref_pic_sets), "short_term_ref_pic_set_idx");
        if (idx >= sps.num_short_term_ref_pic_sets) return Parse::kBad;
        out->short_term_ref_pic_set_idx = static_cast<uint8_t>(idx);
        out->st_rps = sps.st_rps[idx];
      }
      if (sps.long_term_ref_pics_present) {
        uint32_t num_sps = 0;
        if (sps.num_long_term_ref_pics_sps > 0) num_sps = r.Ue("num_long_term_sps");
        if (num_sps > sps.num_long_term_ref_pics_sps) return Parse::kBad;
        uint32_t num_pics = r.Ue("num_long_term_pics");
        if (num_pics > kMaxLtSlice || num_sps + num_pics > kMaxLtSlice) return Parse::kBad;
        out->num_long_term_sps = static_cast<uint8_t>(num_sps);
        out->num_long_term_pics = static_cast<uint8_t>(num_pics);
        uint64_t cycle = 0;
        for (uint32_t i = 0; i < num_sps + num_pics; i++) {
          const int ii = static_cast<int>(i);
          if (i < num_sps) {
            uint32_t lt_idx = 0;
            if (sps.num_long_term_ref_pics_sps > 1)
              lt_idx = r.U(CeilLog2(sps.num_long_term_ref_pics_sps), "lt_idx_sps", ii);
            if (lt_idx >= sps.num_long_term_ref_pics_sps) return Parse::kBad;
            out->poc_lsb_lt[i] = sps.lt_ref_pic_poc_lsb_sps[lt_idx];
            out->used_by_curr_pic_lt[i] = sps.used_by_curr_pic_lt_sps[lt_idx];
          } else {
            out->poc_lsb_lt[i] = r.U(poc_bits, "poc_lsb_lt", ii);
            out->used_by_curr_pic_lt[i] = r.Flag("used_by_curr_pic_lt_flag", ii);
          }
          out->delta_poc_msb_present[i] = r.Flag("delta_poc_msb_present_flag", ii);
          uint32_t d = 0;
          if (out->delta_poc_msb_present[i]) d = r.Ue("delta_poc_msb_cycle_lt", ii);
          cycle = (i == 0 || i == num_sps) ? d : cycle + d;
          if (cycle > (1ull << (32 - poc_bits))) return Parse::kBad;
          out->delta_poc_msb_cycle_lt[i] = static_cast<uint32_t>(cycle);
        }
      }
      if (sps.temporal_mvp_enabled) out->temporal_mvp_enabled = r.Flag("slice_temporal_mvp_enabled_flag");
    }
    if (sps.sao_enabled) {
      out->sao_luma = r.Flag("slice_sao_luma_flag");
      out->sao_chroma = r.Flag("slice_sao_chroma_flag");
    }
    uint32_t before = 0, after = 0, lt = 0;
    for (int i = 0; i < out->st_rps.num_negative; i++) before += out->st_rps.used_s0[i];
    for (int i = 0; i < out->st_rps.num_positive; i++) after += out->st_rps.used_s1[i];
    for (int i = 0; i < out->num_long_term_sps + out->num_long_term_pics; i++) lt += out->used_by_curr_pic_lt[i];
    const uint32_t total = before + after + lt;
    out->num_pic_total_curr = total;
    out->collocated_from_l0 = true;
    if (out->slice_type != 2) {
      // Mesa VA caps each RPS list at 8 and VA's ReferenceFrames at 15
      if (total == 0 || total > kMaxRefIdx || before > 8 || after > 8 || lt > 8) return Parse::kBad;
      out->num_ref_idx_l0_active_minus1 = pps.num_ref_idx_l0_default_active_minus1;
      out->num_ref_idx_l1_active_minus1 = out->slice_type == 0 ? pps.num_ref_idx_l1_default_active_minus1 : 0;
      if (r.Flag("num_ref_idx_active_override_flag")) {
        uint32_t l0 = r.Ue("num_ref_idx_l0_active_minus1");
        if (l0 > 14) return Parse::kBad;
        out->num_ref_idx_l0_active_minus1 = static_cast<uint8_t>(l0);
        if (out->slice_type == 0) {
          uint32_t l1 = r.Ue("num_ref_idx_l1_active_minus1");
          if (l1 > 14) return Parse::kBad;
          out->num_ref_idx_l1_active_minus1 = static_cast<uint8_t>(l1);
        }
      }
      if (pps.lists_modification_present && total > 1) {
        const int bits = CeilLog2(total);
        out->rplm_flag_l0 = r.Flag("ref_pic_list_modification_flag_l0");
        if (out->rplm_flag_l0) {
          for (int i = 0; i <= out->num_ref_idx_l0_active_minus1; i++) {
            uint32_t e = r.U(bits, "list_entry_l0", i);
            if (e >= total) return Parse::kBad;
            out->list_entry_l0[i] = static_cast<uint8_t>(e);
          }
        }
        if (out->slice_type == 0) {
          out->rplm_flag_l1 = r.Flag("ref_pic_list_modification_flag_l1");
          if (out->rplm_flag_l1) {
            for (int i = 0; i <= out->num_ref_idx_l1_active_minus1; i++) {
              uint32_t e = r.U(bits, "list_entry_l1", i);
              if (e >= total) return Parse::kBad;
              out->list_entry_l1[i] = static_cast<uint8_t>(e);
            }
          }
        }
      }
      if (out->slice_type == 0) out->mvd_l1_zero = r.Flag("mvd_l1_zero_flag");
      if (pps.cabac_init_present) out->cabac_init = r.Flag("cabac_init_flag");
      if (out->temporal_mvp_enabled) {
        if (out->slice_type == 0) out->collocated_from_l0 = r.Flag("collocated_from_l0_flag");
        uint32_t limit = out->collocated_from_l0 ? out->num_ref_idx_l0_active_minus1 : out->num_ref_idx_l1_active_minus1;
        if (limit > 0) {
          uint32_t c = r.Ue("collocated_ref_idx");
          if (c > limit) return Parse::kBad;
          out->collocated_ref_idx = static_cast<uint8_t>(c);
        }
      }
      if ((pps.weighted_pred && out->slice_type == 1) || (pps.weighted_bipred && out->slice_type == 0)) {
        out->has_pred_weights = true;
        if (ReadPredWeights(r, *out, &out->pw) != Parse::kOk) return Parse::kBad;
      }
      uint32_t merge = r.Ue("five_minus_max_num_merge_cand");
      if (merge > 4) return Parse::kBad;
      out->five_minus_max_num_merge_cand = static_cast<uint8_t>(merge);
    }
    int32_t qp_delta = r.Se("slice_qp_delta");
    int32_t slice_qp = 26 + pps.init_qp_minus26 + qp_delta;
    if (slice_qp < -6 * sps.bit_depth_luma_minus8 || slice_qp > 51) return Parse::kBad;
    out->slice_qp_delta = static_cast<int8_t>(qp_delta);
    if (pps.slice_chroma_qp_offsets_present) {
      int32_t cb = r.Se("slice_cb_qp_offset");
      int32_t cr = r.Se("slice_cr_qp_offset");
      if (cb < -12 || cb > 12 || cr < -12 || cr > 12) return Parse::kBad;
      if (pps.cb_qp_offset + cb < -12 || pps.cb_qp_offset + cb > 12) return Parse::kBad;
      if (pps.cr_qp_offset + cr < -12 || pps.cr_qp_offset + cr > 12) return Parse::kBad;
      out->cb_qp_offset = static_cast<int8_t>(cb);
      out->cr_qp_offset = static_cast<int8_t>(cr);
    }
    bool override = false;
    if (pps.deblocking_filter_override_enabled) override = r.Flag("deblocking_filter_override_flag");
    out->deblocking_filter_disabled = pps.deblocking_filter_disabled;
    out->beta_offset_div2 = pps.beta_offset_div2;
    out->tc_offset_div2 = pps.tc_offset_div2;
    if (override) {
      out->deblocking_filter_disabled = r.Flag("slice_deblocking_filter_disabled_flag");
      if (!out->deblocking_filter_disabled) {
        int32_t beta = r.Se("slice_beta_offset_div2");
        int32_t tc = r.Se("slice_tc_offset_div2");
        if (beta < -6 || beta > 6 || tc < -6 || tc > 6) return Parse::kBad;
        out->beta_offset_div2 = static_cast<int8_t>(beta);
        out->tc_offset_div2 = static_cast<int8_t>(tc);
      }
    }
    out->loop_filter_across_slices_enabled = pps.loop_filter_across_slices_enabled;
    if (pps.loop_filter_across_slices_enabled && (out->sao_luma || out->sao_chroma || !out->deblocking_filter_disabled))
      out->loop_filter_across_slices_enabled = r.Flag("slice_loop_filter_across_slices_enabled_flag");
  }

  out->num_entry_point_offsets = 0;
  if (pps.tiles_enabled || pps.entropy_coding_sync_enabled) {
    uint32_t n = r.Ue("num_entry_point_offsets");
    uint64_t limit;
    const uint64_t tiles = (pps.num_tile_columns_minus1 + 1ull) * (pps.num_tile_rows_minus1 + 1ull);
    if (!pps.tiles_enabled)
      limit = sps.pic_height_in_ctbs - 1ull;
    else if (!pps.entropy_coding_sync_enabled)
      limit = tiles - 1;
    else
      limit = (pps.num_tile_columns_minus1 + 1ull) * sps.pic_height_in_ctbs - 1;
    if (n > limit) return Parse::kBad;
    out->num_entry_point_offsets = n;
    if (n > 0) {
      uint32_t len = r.Ue("offset_len_minus1");
      if (len > 31) return Parse::kBad;
      for (uint32_t i = 0; i < n; i++) r.U(static_cast<int>(len + 1), "entry_point_offset_minus1", static_cast<int>(i));
    }
  }
  if (pps.slice_segment_header_extension_present) {
    uint32_t len = r.Ue("slice_segment_header_extension_length");
    if (len > 256) return Parse::kBad;
    for (uint32_t i = 0; i < len; i++) r.U(8, "slice_segment_header_extension_data_byte", static_cast<int>(i));
  }
  if (!r.Flag("alignment_bit_equal_to_one")) return Parse::kBad;
  while (!r.ByteAligned()) r.U(1, "alignment_bit_equal_to_zero");
  if (r.overrun()) return Parse::kBad;
  out->header_bytes = static_cast<uint32_t>(r.BitPos() / 8);
  if (out->header_bytes >= rbsp.bytes.size()) return Parse::kBad;
  return Parse::kOk;
}

}

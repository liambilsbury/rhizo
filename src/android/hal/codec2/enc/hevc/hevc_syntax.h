#ifndef RHIZO_C2VA_ENC_HEVC_SYNTAX_H
#define RHIZO_C2VA_ENC_HEVC_SYNTAX_H

// HEVC parameter sets, slice headers and level limits

#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "../../common/bit_reader.h"
#include "../common/bit_writer.h"

namespace rhizo::c2va::hevcenc {

constexpr uint32_t kNalTrailN = 0;
constexpr uint32_t kNalTrailR = 1;
constexpr uint32_t kNalBlaWLp = 16;
constexpr uint32_t kNalIdrWRadl = 19;
constexpr uint32_t kNalIdrNLp = 20;
constexpr uint32_t kNalCra = 21;
constexpr uint32_t kNalRsvIrap23 = 23;
constexpr uint32_t kNalVps = 32;
constexpr uint32_t kNalSps = 33;
constexpr uint32_t kNalPps = 34;
constexpr uint32_t kNalAud = 35;

constexpr uint32_t kSliceB = 0;
constexpr uint32_t kSliceP = 1;
constexpr uint32_t kSliceI = 2;

// the general fields of profile_tier_level(1, 0)
struct ProfileTierLevel {
  uint32_t profile_idc = 1;
  bool tier = false;
  uint32_t compatibility = 0;
  bool progressive_source = true;
  bool interlaced_source = false;
  bool non_packed_constraint = false;
  bool frame_only_constraint = true;
  uint32_t level_idc = 93;
};

// the vui_parameters() fields an encoder sets
struct Vui {
  bool video_signal_type_present = false;
  uint32_t video_format = 5;
  bool full_range = false;
  bool colour_description_present = false;
  uint32_t colour_primaries = 2;
  uint32_t transfer_characteristics = 2;
  uint32_t matrix_coefficients = 2;
  bool timing_info_present = false;
  uint32_t num_units_in_tick = 0;
  uint32_t time_scale = 0;
};

// a derived short-term RPS
struct StRps {
  uint32_t num_negative = 0;
  uint32_t num_positive = 0;
  int32_t delta_poc_s0[16] = {};
  bool used_s0[16] = {};
  int32_t delta_poc_s1[16] = {};
  bool used_s1[16] = {};

  uint32_t NumDeltaPocs() const { return num_negative + num_positive; }
  uint32_t NumUsed() const;
  bool operator==(const StRps& o) const;
  bool operator!=(const StRps& o) const { return !(*this == o); }
};

struct Vps {
  ProfileTierLevel ptl;
  uint32_t max_dec_pic_buffering_minus1 = 1;
  uint32_t max_num_reorder_pics = 0;
  uint32_t max_latency_increase_plus1 = 0;
};

// a 4:2:0 single-sub-layer seq_parameter_set_rbsp()
struct Sps {
  ProfileTierLevel ptl;
  uint32_t width = 0;
  uint32_t height = 0;
  bool conformance_window = false;
  uint32_t conf_left = 0;
  uint32_t conf_right = 0;
  uint32_t conf_top = 0;
  uint32_t conf_bottom = 0;
  uint32_t bit_depth_luma_minus8 = 0;
  uint32_t bit_depth_chroma_minus8 = 0;
  uint32_t log2_max_pic_order_cnt_lsb_minus4 = 4;
  uint32_t max_dec_pic_buffering_minus1 = 1;
  uint32_t max_num_reorder_pics = 0;
  uint32_t max_latency_increase_plus1 = 0;
  uint32_t log2_min_luma_coding_block_size_minus3 = 0;
  uint32_t log2_diff_max_min_luma_coding_block_size = 3;
  uint32_t log2_min_luma_transform_block_size_minus2 = 0;
  uint32_t log2_diff_max_min_luma_transform_block_size = 3;
  uint32_t max_transform_hierarchy_depth_inter = 4;
  uint32_t max_transform_hierarchy_depth_intra = 4;
  bool amp = false;
  bool sao = false;
  std::vector<StRps> st_rps;
  bool temporal_mvp = false;
  bool strong_intra_smoothing = false;
  bool vui_present = false;
  Vui vui;
};

// a pic_parameter_set_rbsp() without tiles or extensions
struct Pps {
  bool dependent_slice_segments_enabled = false;
  bool output_flag_present = false;
  uint32_t num_extra_slice_header_bits = 0;
  bool sign_data_hiding = false;
  bool cabac_init_present = true;
  uint32_t num_ref_idx_l0_default_active_minus1 = 0;
  uint32_t num_ref_idx_l1_default_active_minus1 = 0;
  int32_t init_qp_minus26 = 0;
  bool constrained_intra_pred = false;
  bool transform_skip = false;
  bool cu_qp_delta_enabled = false;
  uint32_t diff_cu_qp_delta_depth = 0;
  int32_t cb_qp_offset = 0;
  int32_t cr_qp_offset = 0;
  bool slice_chroma_qp_offsets_present = false;
  bool weighted_pred = false;
  bool weighted_bipred = false;
  bool transquant_bypass = false;
  bool loop_filter_across_slices = false;
  bool deblocking_filter_control_present = false;
  bool deblocking_filter_override_enabled = false;
  bool pps_deblocking_filter_disabled = false;
  int32_t beta_offset_div2 = 0;
  int32_t tc_offset_div2 = 0;
  bool lists_modification_present = false;
  uint32_t log2_parallel_merge_level_minus2 = 0;
};

// the SPS and PPS fields of the slice segment header layout
struct SliceSyntax {
  bool dependent_slice_segments_enabled = false;
  bool output_flag_present = false;
  uint32_t num_extra_slice_header_bits = 0;
  uint32_t log2_max_pic_order_cnt_lsb = 8;
  std::vector<StRps> sps_rps;
  bool long_term_ref_pics_present = false;
  bool temporal_mvp = false;
  bool sao = false;
  bool lists_modification_present = false;
  bool cabac_init_present = true;
  bool weighted_pred = false;
  bool weighted_bipred = false;
  bool slice_chroma_qp_offsets_present = false;
  bool deblocking_filter_override_enabled = false;
  bool pps_deblocking_filter_disabled = false;
  int32_t pps_beta_offset_div2 = 0;
  int32_t pps_tc_offset_div2 = 0;
  bool loop_filter_across_slices = false;
  bool tiles_or_wavefronts = false;
  bool slice_segment_header_extension_present = false;
  uint32_t num_ref_idx_l0_default_active_minus1 = 0;
  uint32_t num_ref_idx_l1_default_active_minus1 = 0;
  int32_t init_qp_minus26 = 0;

  bool operator==(const SliceSyntax& o) const;
  bool operator!=(const SliceSyntax& o) const { return !(*this == o); }
};
SliceSyntax SyntaxOf(const Sps& sps, const Pps& pps);

// the slice_segment_header() of a single-segment P or I picture
struct SliceHeader {
  uint32_t nal_unit_type = kNalIdrWRadl;
  bool no_output_of_prior_pics = false;
  uint32_t pps_id = 0;
  uint32_t slice_type = kSliceI;
  bool pic_output = true;
  uint32_t pic_order_cnt_lsb = 0;
  bool st_rps_sps = false;
  uint32_t st_rps_idx = 0;
  StRps rps;
  bool slice_temporal_mvp = false;
  bool sao_luma = false;
  bool sao_chroma = false;
  bool num_ref_idx_active_override = false;
  uint32_t num_ref_idx_l0_active_minus1 = 0;
  bool ref_pic_list_modification_l0 = false;
  std::vector<uint32_t> list_entry_l0;
  bool cabac_init = false;
  uint32_t collocated_ref_idx = 0;
  uint32_t five_minus_max_num_merge_cand = 0;
  int32_t slice_qp_delta = 0;
  int32_t slice_cb_qp_offset = 0;
  int32_t slice_cr_qp_offset = 0;
  bool deblocking_filter_override = false;
  bool slice_deblocking_filter_disabled = false;
  int32_t slice_beta_offset_div2 = 0;
  int32_t slice_tc_offset_div2 = 0;
  bool slice_loop_filter_across_slices = false;
};

// parse an st_ref_pic_set()
bool ParseStRps(uint32_t idx, const std::vector<StRps>& sets, BitReader* br, StRps* out);

// append the VPS as an Annex B NAL unit
void AppendVps(const Vps& vps, std::vector<uint8_t>* out);
void AppendSps(const Sps& sps, std::vector<uint8_t>* out);
void AppendPps(const Pps& pps, std::vector<uint8_t>* out);

// write a slice segment header through byte_alignment()
bool WriteSliceHeader(const SliceSyntax& syn, const SliceHeader& sh, BitWriter* bw);
// parse a slice segment header through byte_alignment()
bool ParseSliceHeader(const SliceSyntax& syn, uint32_t nal_unit_type, BitReader* br, SliceHeader* sh);

// the slice fields the encoder sets
struct SliceIntent {
  uint32_t nal_unit_type;
  uint32_t slice_type;
  uint32_t pic_order_cnt_lsb;
  StRps rps;
};

enum class FixResult { kUnchanged, kRewritten, kFailed };

// rewrite a driver's slice to the intent and output syntax
FixResult FixSlice(const uint8_t* nal, size_t size, const std::vector<SliceSyntax>& driver_syntaxes,
                   const SliceSyntax& out_syntax, const SliceIntent& intent, std::vector<uint8_t>* out_nal);

// the Main tier limits of a level
struct LevelLimits {
  uint32_t level_idc;
  uint64_t max_luma_ps;
  uint64_t max_luma_sr;
  uint32_t max_br;
};
const LevelLimits* FindLevel(uint32_t level_idc);

// raise the requested level to the lowest that fits
uint32_t ChooseLevel(uint32_t requested, uint32_t width, uint32_t height, double frame_rate, uint32_t bitrate);

}

#endif

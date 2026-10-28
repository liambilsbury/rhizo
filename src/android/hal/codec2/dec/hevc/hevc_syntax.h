#ifndef RHIZO_C2VA_HEVC_SYNTAX_H
#define RHIZO_C2VA_HEVC_SYNTAX_H

// the HEVC high-level syntax from RBSPs

#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "../../va/core.h"
#include "syntax_reader.h"

namespace rhizo::c2va::hevc {

enum NalType : uint8_t {
  kTrailN = 0,
  kTrailR = 1,
  kTsaN = 2,
  kTsaR = 3,
  kStsaN = 4,
  kStsaR = 5,
  kRadlN = 6,
  kRadlR = 7,
  kRaslN = 8,
  kRaslR = 9,
  kBlaWLp = 16,
  kBlaWRadl = 17,
  kBlaNLp = 18,
  kIdrWRadl = 19,
  kIdrNLp = 20,
  kCraNut = 21,
  kVps = 32,
  kSps = 33,
  kPps = 34,
  kAud = 35,
  kEos = 36,
  kEob = 37,
  kFd = 38,
  kSeiPrefix = 39,
  kSeiSuffix = 40,
};

constexpr int kMaxSubLayers = 7;
constexpr int kMaxDpbSize = 16;
constexpr int kMaxStRpsSets = 64;
constexpr int kMaxStRpsEntries = 16;
constexpr int kMaxLtSps = 32;
constexpr int kMaxLtSlice = 16;
constexpr int kMaxRefIdx = 15;
constexpr int kMaxTileCols = 20;
constexpr int kMaxTileRows = 22;
constexpr uint32_t kMaxPicDim = 16888;

enum class Parse {
  kOk,
  kBad,
  kUnsupported,
};

struct NalHeader {
  uint8_t type;
  uint8_t layer_id;
  uint8_t temporal_id;
};

// parse nal_unit_header()
bool ParseNalHeader(const uint8_t* data, size_t size, NalHeader* out);

inline bool IsIrap(uint8_t t) { return t >= kBlaWLp && t <= 23; }
inline bool IsIdr(uint8_t t) { return t == kIdrWRadl || t == kIdrNLp; }
inline bool IsBla(uint8_t t) { return t >= kBlaWLp && t <= kBlaNLp; }
inline bool IsRasl(uint8_t t) { return t == kRaslN || t == kRaslR; }
inline bool IsRadl(uint8_t t) { return t == kRadlN || t == kRadlR; }
// return true for a sub-layer non-reference picture
inline bool IsSlnr(uint8_t t) { return t <= 14 && (t % 2) == 0; }
// return true for a non-reserved VCL type
inline bool IsHandledVcl(uint8_t t) { return t <= kRaslR || (t >= kBlaWLp && t <= kCraNut); }

// NAL unit RBSP and its emulation prevention byte positions
struct Rbsp {
  std::vector<uint8_t> bytes;
  std::vector<uint32_t> ep_before;
  bool truncated = false;
};
// unescape the first max_bytes of a NAL unit into an RBSP
void UnescapeNal(const uint8_t* data, size_t size, Rbsp* out, size_t max_bytes = SIZE_MAX);

// a candidate short-term RPS
struct StRps {
  uint8_t num_negative = 0;
  uint8_t num_positive = 0;
  int32_t delta_poc_s0[kMaxStRpsEntries];
  int32_t delta_poc_s1[kMaxStRpsEntries];
  bool used_s0[kMaxStRpsEntries];
  bool used_s1[kMaxStRpsEntries];
  int NumDeltaPocs() const { return num_negative + num_positive; }
};

// scaling lists in coefficient scan order
struct ScalingLists {
  uint8_t list[4][6][64];
  uint8_t dc[2][6];
};
// fill the default scaling lists (Tables 7-5, 7-6)
void DefaultScalingLists(ScalingLists* out);

struct Vps {
  uint8_t id;
  uint8_t max_sub_layers_minus1;
};

struct Sps {
  uint8_t vps_id;
  uint8_t max_sub_layers_minus1;
  uint8_t id;
  uint8_t general_profile_idc;
  uint8_t general_level_idc;
  bool general_tier_flag;
  uint8_t chroma_format_idc;
  bool separate_colour_plane_flag;
  uint32_t pic_width;
  uint32_t pic_height;
  uint32_t conf_win_left, conf_win_right, conf_win_top, conf_win_bottom;
  uint8_t bit_depth_luma_minus8;
  uint8_t bit_depth_chroma_minus8;
  uint8_t log2_max_poc_lsb_minus4;
  uint32_t max_dec_pic_buffering_minus1[kMaxSubLayers];
  uint32_t max_num_reorder_pics[kMaxSubLayers];
  uint32_t max_latency_increase_plus1[kMaxSubLayers];
  uint8_t log2_min_cb_minus3;
  uint8_t log2_diff_max_min_cb;
  uint8_t log2_min_tb_minus2;
  uint8_t log2_diff_max_min_tb;
  uint8_t max_transform_hierarchy_depth_inter;
  uint8_t max_transform_hierarchy_depth_intra;
  bool scaling_list_enabled;
  bool scaling_list_data_present;
  ScalingLists scaling;
  bool amp_enabled;
  bool sao_enabled;
  bool pcm_enabled;
  uint8_t pcm_bit_depth_luma_minus1;
  uint8_t pcm_bit_depth_chroma_minus1;
  uint8_t log2_min_pcm_cb_minus3;
  uint8_t log2_diff_max_min_pcm_cb;
  bool pcm_loop_filter_disabled;
  uint8_t num_short_term_ref_pic_sets;
  StRps st_rps[kMaxStRpsSets];
  bool long_term_ref_pics_present;
  uint8_t num_long_term_ref_pics_sps;
  uint32_t lt_ref_pic_poc_lsb_sps[kMaxLtSps];
  bool used_by_curr_pic_lt_sps[kMaxLtSps];
  bool temporal_mvp_enabled;
  bool strong_intra_smoothing_enabled;
  ColorInfo color;

  uint32_t min_cb_log2;
  uint32_t ctb_log2;
  uint32_t pic_width_in_ctbs;
  uint32_t pic_height_in_ctbs;
  uint32_t pic_size_in_ctbs;
  uint32_t max_poc_lsb;
  uint8_t highest_tid;

  std::vector<uint8_t> rbsp;
};

struct Pps {
  uint8_t id;
  uint8_t sps_id;
  bool dependent_slice_segments_enabled;
  bool output_flag_present;
  uint8_t num_extra_slice_header_bits;
  bool sign_data_hiding_enabled;
  bool cabac_init_present;
  uint8_t num_ref_idx_l0_default_active_minus1;
  uint8_t num_ref_idx_l1_default_active_minus1;
  int8_t init_qp_minus26;
  bool constrained_intra_pred;
  bool transform_skip_enabled;
  bool cu_qp_delta_enabled;
  uint8_t diff_cu_qp_delta_depth;
  int8_t cb_qp_offset;
  int8_t cr_qp_offset;
  bool slice_chroma_qp_offsets_present;
  bool weighted_pred;
  bool weighted_bipred;
  bool transquant_bypass_enabled;
  bool tiles_enabled;
  bool entropy_coding_sync_enabled;
  uint8_t num_tile_columns_minus1;
  uint8_t num_tile_rows_minus1;
  bool uniform_spacing;
  uint32_t column_width_minus1[kMaxTileCols];
  uint32_t row_height_minus1[kMaxTileRows];
  bool loop_filter_across_tiles_enabled;
  bool loop_filter_across_slices_enabled;
  bool deblocking_filter_control_present;
  bool deblocking_filter_override_enabled;
  bool deblocking_filter_disabled;
  int8_t beta_offset_div2;
  int8_t tc_offset_div2;
  bool scaling_list_data_present;
  ScalingLists scaling;
  bool lists_modification_present;
  uint8_t log2_parallel_merge_level_minus2;
  bool slice_segment_header_extension_present;
};

// tile layout of a PPS resolved against its SPS
struct PpsLayout {
  uint16_t column_width_minus1[kMaxTileCols];
  uint16_t row_height_minus1[kMaxTileRows];
};
Parse ResolvePps(const Pps& pps, const Sps& sps, PpsLayout* out);

// pred_weight_table() with ChromaOffsetLX derived
struct PredWeights {
  uint8_t luma_log2_weight_denom;
  int8_t delta_chroma_log2_weight_denom;
  int8_t delta_luma_weight[2][kMaxRefIdx];
  int8_t luma_offset[2][kMaxRefIdx];
  int8_t delta_chroma_weight[2][kMaxRefIdx][2];
  int8_t chroma_offset[2][kMaxRefIdx][2];
};

struct SliceHeader {
  NalHeader nal;
  bool first_slice_segment_in_pic;
  bool no_output_of_prior_pics;
  uint8_t pps_id;
  bool dependent_slice_segment;
  uint32_t segment_address;

  uint8_t slice_type;
  bool pic_output_flag;
  uint8_t colour_plane_id;
  uint32_t pic_order_cnt_lsb;
  bool short_term_ref_pic_set_sps_flag;
  uint8_t short_term_ref_pic_set_idx;
  StRps st_rps;
  uint32_t st_rps_bits;
  uint8_t num_long_term_sps;
  uint8_t num_long_term_pics;
  uint32_t poc_lsb_lt[kMaxLtSlice];
  bool used_by_curr_pic_lt[kMaxLtSlice];
  bool delta_poc_msb_present[kMaxLtSlice];
  uint32_t delta_poc_msb_cycle_lt[kMaxLtSlice];
  bool temporal_mvp_enabled;
  bool sao_luma;
  bool sao_chroma;
  uint8_t num_ref_idx_l0_active_minus1;
  uint8_t num_ref_idx_l1_active_minus1;
  bool rplm_flag_l0;
  bool rplm_flag_l1;
  uint8_t list_entry_l0[kMaxRefIdx];
  uint8_t list_entry_l1[kMaxRefIdx];
  bool mvd_l1_zero;
  bool cabac_init;
  bool collocated_from_l0;
  uint8_t collocated_ref_idx;
  bool has_pred_weights;
  PredWeights pw;
  uint8_t five_minus_max_num_merge_cand;
  int8_t slice_qp_delta;
  int8_t cb_qp_offset;
  int8_t cr_qp_offset;
  bool deblocking_filter_disabled;
  int8_t beta_offset_div2;
  int8_t tc_offset_div2;
  bool loop_filter_across_slices_enabled;
  uint32_t num_pic_total_curr;

  uint32_t num_entry_point_offsets;
  uint32_t header_bytes;
};

// read the first-segment flag and PPS id of a slice header
bool PeekSliceHeader(const Rbsp& rbsp, bool* first_slice_segment_in_pic, uint32_t* pps_id);

Parse ParseVps(const Rbsp& rbsp, TraceSink* trace, Vps* out);
Parse ParseSps(const Rbsp& rbsp, TraceSink* trace, Sps* out);
Parse ParsePps(const Rbsp& rbsp, TraceSink* trace, Pps* out);
// parse a slice segment header
Parse ParseSliceHeader(const Rbsp& rbsp, const NalHeader& nal, const Sps& sps, const Pps& pps,
                       const SliceHeader* prev, TraceSink* trace, SliceHeader* out);

inline int CeilLog2(uint32_t n) {
  int b = 0;
  while ((1ull << b) < n) b++;
  return b;
}

}

#endif

#ifndef RHIZO_C2VA_H264_SYNTAX_H
#define RHIZO_C2VA_H264_SYNTAX_H

// the H.264 high-level syntax from RBSPs

#include <stddef.h>
#include <stdint.h>

#include <vector>

namespace rhizo::c2va::h264 {

enum NalType : uint8_t {
  kNalSlice = 1,
  kNalSliceDpa = 2,
  kNalSliceDpb = 3,
  kNalSliceDpc = 4,
  kNalIdr = 5,
  kNalSei = 6,
  kNalSps = 7,
  kNalPps = 8,
  kNalAud = 9,
  kNalEndOfSeq = 10,
  kNalEndOfStream = 11,
  kNalFiller = 12,
};

enum SliceType : uint8_t { kSliceP = 0, kSliceB = 1, kSliceI = 2, kSliceSP = 3, kSliceSI = 4 };

constexpr int kMaxSps = 32;
constexpr int kMaxPps = 256;
constexpr int kMaxRefs = 32;

// trace the parsed syntax elements
class SyntaxTrace {
 public:
  virtual ~SyntaxTrace() = default;
  virtual void Structure(const char* name) = 0;
  virtual void Element(size_t bit_pos, const char* name, int idx0, int idx1, int64_t value) = 0;
};

struct NalHeader {
  uint8_t nal_ref_idc = 0;
  uint8_t nal_unit_type = 0;
};

struct HrdParameters {
  uint32_t cpb_cnt_minus1 = 0;
};

struct Vui {
  bool present = false;
  bool aspect_ratio_info_present_flag = false;
  uint32_t aspect_ratio_idc = 0;
  uint32_t sar_width = 0;
  uint32_t sar_height = 0;
  bool video_signal_type_present_flag = false;
  uint32_t video_format = 5;
  bool video_full_range_flag = false;
  bool colour_description_present_flag = false;
  uint32_t colour_primaries = 2;
  uint32_t transfer_characteristics = 2;
  uint32_t matrix_coefficients = 2;
  bool timing_info_present_flag = false;
  uint32_t num_units_in_tick = 0;
  uint32_t time_scale = 0;
  bool nal_hrd_parameters_present_flag = false;
  bool vcl_hrd_parameters_present_flag = false;
  bool pic_struct_present_flag = false;
  bool bitstream_restriction_flag = false;
  uint32_t max_num_reorder_frames = 0;
  uint32_t max_dec_frame_buffering = 0;
};

// scaling lists in zig-zag order
struct ScalingLists {
  uint8_t list4x4[6][16];
  uint8_t list8x8[6][64];
};

struct Sps {
  uint32_t profile_idc = 0;
  bool constraint_set_flags[6] = {};
  uint32_t level_idc = 0;
  uint32_t seq_parameter_set_id = 0;
  uint32_t chroma_format_idc = 1;
  bool separate_colour_plane_flag = false;
  uint32_t bit_depth_luma_minus8 = 0;
  uint32_t bit_depth_chroma_minus8 = 0;
  bool qpprime_y_zero_transform_bypass_flag = false;
  bool seq_scaling_matrix_present_flag = false;
  ScalingLists scaling;
  uint32_t log2_max_frame_num_minus4 = 0;
  uint32_t pic_order_cnt_type = 0;
  uint32_t log2_max_pic_order_cnt_lsb_minus4 = 0;
  bool delta_pic_order_always_zero_flag = false;
  int32_t offset_for_non_ref_pic = 0;
  int32_t offset_for_top_to_bottom_field = 0;
  uint32_t num_ref_frames_in_pic_order_cnt_cycle = 0;
  std::vector<int32_t> offset_for_ref_frame;
  uint32_t max_num_ref_frames = 0;
  bool gaps_in_frame_num_value_allowed_flag = false;
  uint32_t pic_width_in_mbs_minus1 = 0;
  uint32_t pic_height_in_map_units_minus1 = 0;
  bool frame_mbs_only_flag = true;
  bool mb_adaptive_frame_field_flag = false;
  bool direct_8x8_inference_flag = false;
  bool frame_cropping_flag = false;
  uint32_t frame_crop_left_offset = 0;
  uint32_t frame_crop_right_offset = 0;
  uint32_t frame_crop_top_offset = 0;
  uint32_t frame_crop_bottom_offset = 0;
  Vui vui;

  uint32_t MaxFrameNum() const { return 1u << (log2_max_frame_num_minus4 + 4); }
  uint32_t MaxPicOrderCntLsb() const { return 1u << (log2_max_pic_order_cnt_lsb_minus4 + 4); }
  uint32_t PicWidthInMbs() const { return pic_width_in_mbs_minus1 + 1; }
  uint32_t FrameHeightInMbs() const { return (2 - frame_mbs_only_flag) * (pic_height_in_map_units_minus1 + 1); }
  uint32_t ChromaArrayType() const { return separate_colour_plane_flag ? 0 : chroma_format_idc; }
};

struct Pps {
  uint32_t pic_parameter_set_id = 0;
  uint32_t seq_parameter_set_id = 0;
  bool entropy_coding_mode_flag = false;
  bool bottom_field_pic_order_in_frame_present_flag = false;
  uint32_t num_slice_groups_minus1 = 0;
  uint32_t slice_group_map_type = 0;
  uint32_t slice_group_change_rate_minus1 = 0;
  uint32_t num_ref_idx_l0_default_active_minus1 = 0;
  uint32_t num_ref_idx_l1_default_active_minus1 = 0;
  bool weighted_pred_flag = false;
  uint32_t weighted_bipred_idc = 0;
  int32_t pic_init_qp_minus26 = 0;
  int32_t pic_init_qs_minus26 = 0;
  int32_t chroma_qp_index_offset = 0;
  bool deblocking_filter_control_present_flag = false;
  bool constrained_intra_pred_flag = false;
  bool redundant_pic_cnt_present_flag = false;
  bool transform_8x8_mode_flag = false;
  bool pic_scaling_matrix_present_flag = false;
  int32_t second_chroma_qp_index_offset = 0;
  ScalingLists scaling;
};

// a ref_pic_list_modification() operation
struct RefListModification {
  uint32_t modification_of_pic_nums_idc;
  uint32_t value;
};

// a memory_management_control_operation
struct Mmco {
  uint32_t op;
  uint32_t difference_of_pic_nums_minus1 = 0;
  uint32_t long_term_pic_num = 0;
  uint32_t long_term_frame_idx = 0;
  uint32_t max_long_term_frame_idx_plus1 = 0;
};

struct PredWeightTable {
  uint32_t luma_log2_weight_denom = 0;
  uint32_t chroma_log2_weight_denom = 0;
  bool luma_weight_flag[2][kMaxRefs] = {};
  int16_t luma_weight[2][kMaxRefs] = {};
  int16_t luma_offset[2][kMaxRefs] = {};
  bool chroma_weight_flag[2][kMaxRefs] = {};
  int16_t chroma_weight[2][kMaxRefs][2] = {};
  int16_t chroma_offset[2][kMaxRefs][2] = {};
};

struct SliceHeader {
  NalHeader nal;
  bool idr_pic_flag = false;
  uint32_t first_mb_in_slice = 0;
  uint32_t slice_type_raw = 0;
  uint8_t slice_type = kSliceI;
  uint32_t pic_parameter_set_id = 0;
  uint32_t frame_num = 0;
  bool field_pic_flag = false;
  bool bottom_field_flag = false;
  uint32_t idr_pic_id = 0;
  uint32_t pic_order_cnt_lsb = 0;
  int32_t delta_pic_order_cnt_bottom = 0;
  int32_t delta_pic_order_cnt[2] = {0, 0};
  uint32_t redundant_pic_cnt = 0;
  bool direct_spatial_mv_pred_flag = false;
  bool num_ref_idx_active_override_flag = false;
  uint32_t num_ref_idx_l0_active_minus1 = 0;
  uint32_t num_ref_idx_l1_active_minus1 = 0;
  bool ref_pic_list_modification_flag[2] = {false, false};
  std::vector<RefListModification> modifications[2];
  bool has_pred_weight_table = false;
  PredWeightTable pwt;
  bool no_output_of_prior_pics_flag = false;
  bool long_term_reference_flag = false;
  bool adaptive_ref_pic_marking_mode_flag = false;
  std::vector<Mmco> mmcos;
  uint32_t cabac_init_idc = 0;
  int32_t slice_qp_delta = 0;
  bool sp_for_switch_flag = false;
  int32_t slice_qs_delta = 0;
  uint32_t disable_deblocking_filter_idc = 0;
  int32_t slice_alpha_c0_offset_div2 = 0;
  int32_t slice_beta_offset_div2 = 0;
  uint32_t slice_group_change_cycle = 0;
  size_t header_bits = 0;

  bool HasMmco5() const {
    for (const Mmco& m : mmcos)
      if (m.op == 5) return true;
    return false;
  }
};

struct RecoveryPoint {
  bool present = false;
  uint32_t recovery_frame_cnt = 0;
  bool exact_match_flag = false;
  bool broken_link_flag = false;
};

// parse nal_unit_header() from a NAL unit's first byte
bool ParseNalHeader(uint8_t byte, NalHeader* out);

// parse seq_parameter_set_rbsp()
bool ParseSps(const uint8_t* rbsp, size_t size, Sps* out, SyntaxTrace* trace = nullptr);

// read the ids of a PPS, or parse it against its SPS
bool PeekPpsIds(const uint8_t* rbsp, size_t size, uint32_t* pps_id, uint32_t* sps_id);
bool ParsePps(const uint8_t* rbsp, size_t size, const Sps& sps, Pps* out, SyntaxTrace* trace = nullptr);

bool PeekSlicePpsId(const uint8_t* rbsp, size_t size, uint32_t* pps_id);

// parse a slice_header()
bool ParseSliceHeader(const uint8_t* rbsp, size_t size, const Sps& sps, const Pps& pps, SliceHeader* out,
                      SyntaxTrace* trace = nullptr);

// parse a recovery point SEI message
bool ParseSeiRecoveryPoint(const uint8_t* rbsp, size_t size, RecoveryPoint* out);

extern const uint8_t kDefault4x4Intra[16];
extern const uint8_t kDefault4x4Inter[16];
extern const uint8_t kDefault8x8Intra[64];
extern const uint8_t kDefault8x8Inter[64];
extern const uint8_t kZigzag4x4[16];
extern const uint8_t kZigzag8x8[64];

}

#endif

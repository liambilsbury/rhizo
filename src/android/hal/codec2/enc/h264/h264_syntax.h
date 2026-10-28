#ifndef RHIZO_C2VA_ENC_H264_SYNTAX_H
#define RHIZO_C2VA_ENC_H264_SYNTAX_H

// H.264 parameter sets, slice headers and level limits

#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "../../common/bit_reader.h"
#include "../common/bit_writer.h"

namespace rhizo::c2va::h264enc {

constexpr uint32_t kNalSlice = 1;
constexpr uint32_t kNalIdrSlice = 5;
constexpr uint32_t kNalSei = 6;
constexpr uint32_t kNalSps = 7;
constexpr uint32_t kNalPps = 8;
constexpr uint32_t kNalAud = 9;

constexpr uint32_t kSliceP = 0;
constexpr uint32_t kSliceB = 1;
constexpr uint32_t kSliceI = 2;
constexpr uint32_t kSliceSp = 3;
constexpr uint32_t kSliceSi = 4;

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
  bool fixed_frame_rate = false;
  bool bitstream_restriction = false;
  uint32_t max_num_reorder_frames = 0;
  uint32_t max_dec_frame_buffering = 1;
};

// a 4:2:0 progressive seq_parameter_set_data()
struct Sps {
  uint32_t profile_idc = 77;
  uint32_t constraint_flags = 0;
  uint32_t level_idc = 40;
  uint32_t sps_id = 0;
  uint32_t bit_depth_luma_minus8 = 0;
  uint32_t bit_depth_chroma_minus8 = 0;
  uint32_t log2_max_frame_num_minus4 = 0;
  uint32_t pic_order_cnt_type = 2;
  uint32_t log2_max_pic_order_cnt_lsb_minus4 = 0;
  uint32_t max_num_ref_frames = 1;
  bool gaps_in_frame_num_allowed = false;
  uint32_t width_in_mbs = 0;
  uint32_t height_in_mbs = 0;
  bool direct_8x8_inference = true;
  bool frame_cropping = false;
  uint32_t crop_left = 0;
  uint32_t crop_right = 0;
  uint32_t crop_top = 0;
  uint32_t crop_bottom = 0;
  bool vui_present = false;
  Vui vui;
};

// a single-slice-group pic_parameter_set_rbsp()
struct Pps {
  uint32_t pps_id = 0;
  uint32_t sps_id = 0;
  bool entropy_coding_mode = false;
  bool bottom_field_pic_order_in_frame_present = false;
  uint32_t num_ref_idx_l0_default_active_minus1 = 0;
  uint32_t num_ref_idx_l1_default_active_minus1 = 0;
  bool weighted_pred = false;
  uint32_t weighted_bipred_idc = 0;
  int32_t pic_init_qp_minus26 = 0;
  int32_t pic_init_qs_minus26 = 0;
  int32_t chroma_qp_index_offset = 0;
  bool deblocking_filter_control_present = false;
  bool constrained_intra_pred = false;
  bool redundant_pic_cnt_present = false;
  bool high_extension = false;
  bool transform_8x8_mode = false;
  int32_t second_chroma_qp_index_offset = 0;
};

// the SPS and PPS fields of the slice header layout
struct SliceSyntax {
  uint32_t log2_max_frame_num = 4;
  uint32_t pic_order_cnt_type = 2;
  uint32_t log2_max_pic_order_cnt_lsb = 4;
  bool delta_pic_order_always_zero = false;
  bool bottom_field_pic_order_in_frame_present = false;
  bool redundant_pic_cnt_present = false;
  bool entropy_coding_mode = false;
  bool weighted_pred = false;
  uint32_t weighted_bipred_idc = 0;
  bool deblocking_filter_control_present = false;
  uint32_t num_ref_idx_l0_default_active_minus1 = 0;
  uint32_t num_ref_idx_l1_default_active_minus1 = 0;
  int32_t pic_init_qp_minus26 = 0;

  bool operator==(const SliceSyntax& o) const;
  bool operator!=(const SliceSyntax& o) const { return !(*this == o); }
};
SliceSyntax SyntaxOf(const Sps& sps, const Pps& pps);

// a modification_of_pic_nums_idc entry
struct RefListMod {
  uint32_t idc = 3;
  uint32_t value = 0;
};

// a memory_management_control_operation
struct Mmco {
  uint32_t op = 0;
  uint32_t difference_of_pic_nums_minus1 = 0;
  uint32_t long_term_pic_num = 0;
  uint32_t long_term_frame_idx = 0;
  uint32_t max_long_term_frame_idx_plus1 = 0;
};

// the slice_header() of a P or I frame slice
struct SliceHeader {
  uint32_t nal_ref_idc = 3;
  uint32_t nal_unit_type = kNalIdrSlice;
  uint32_t first_mb_in_slice = 0;
  uint32_t slice_type = 7;
  uint32_t pps_id = 0;
  uint32_t frame_num = 0;
  uint32_t idr_pic_id = 0;
  uint32_t pic_order_cnt_lsb = 0;
  int32_t delta_pic_order_cnt_bottom = 0;
  int32_t delta_pic_order_cnt[2] = {0, 0};
  uint32_t redundant_pic_cnt = 0;
  bool num_ref_idx_active_override = false;
  uint32_t num_ref_idx_l0_active_minus1 = 0;
  bool ref_pic_list_modification_l0 = false;
  std::vector<RefListMod> mods_l0;
  bool no_output_of_prior_pics = false;
  bool long_term_reference = false;
  bool adaptive_ref_pic_marking = false;
  std::vector<Mmco> mmcos;
  uint32_t cabac_init_idc = 0;
  int32_t slice_qp_delta = 0;
  uint32_t disable_deblocking_filter_idc = 0;
  int32_t slice_alpha_c0_offset_div2 = 0;
  int32_t slice_beta_offset_div2 = 0;
};

// append the SPS as an Annex B NAL unit
void AppendSps(const Sps& sps, std::vector<uint8_t>* out);
void AppendPps(const Pps& pps, std::vector<uint8_t>* out);

// write the slice header of a P or I slice
bool WriteSliceHeader(const SliceSyntax& syn, const SliceHeader& sh, BitWriter* bw);
// parse a slice header with the caller's NAL header fields
bool ParseSliceHeader(const SliceSyntax& syn, uint32_t nal_ref_idc, uint32_t nal_unit_type, BitReader* br,
                      SliceHeader* sh);

// the slice fields the encoder sets
struct SliceIntent {
  uint32_t nal_ref_idc;
  uint32_t nal_unit_type;
  uint32_t slice_type_mod5;
  uint32_t frame_num;
  uint32_t idr_pic_id;
  uint32_t pic_order_cnt_lsb;
};

enum class FixResult { kUnchanged, kRewritten, kFailed };

// find the log2_max_frame_num of a driver's IDR slice
bool LearnFrameNumBits(const uint8_t* nal, size_t size, const SliceSyntax& syn, const SliceIntent& intent,
                       uint32_t* bits);

// rewrite a driver's slice to the intent and output syntax
FixResult FixSlice(const uint8_t* nal, size_t size, const SliceSyntax& driver_syntax, const SliceSyntax& out_syntax,
                   const SliceIntent& intent, std::vector<uint8_t>* out_nal);

// the Table A-1 limits of a level
struct LevelLimits {
  uint32_t level_idc;
  uint32_t max_mbps;
  uint32_t max_fs;
  uint32_t max_dpb_mbs;
  uint32_t max_br;
};
const LevelLimits* FindLevel(uint32_t level_idc);

// raise the requested level to the lowest that fits
uint32_t ChooseLevel(uint32_t profile_idc, uint32_t requested, uint32_t width_in_mbs, uint32_t height_in_mbs,
                     double frame_rate, uint32_t bitrate);

}

#endif

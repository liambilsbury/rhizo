#ifndef RHIZO_C2VA_AV1_SYNTAX_H
#define RHIZO_C2VA_AV1_SYNTAX_H

// the AV1 frame-level syntax of spec 1.0.0 with Errata 1

#include <stddef.h>
#include <stdint.h>

namespace rhizo::c2va::av1 {

constexpr int kNumRefFrames = 8;
constexpr int kRefsPerFrame = 7;
constexpr int kTotalRefsPerFrame = 8;
constexpr int kPrimaryRefNone = 7;
constexpr int kMaxSegments = 8;
constexpr int kSegLvlMax = 8;
constexpr int kSegLvlAltQ = 0;
constexpr int kSegLvlRefFrame = 5;
constexpr int kMaxLoopFilter = 63;
constexpr int kMaxTileCols = 64;
constexpr int kMaxTileRows = 64;
constexpr int kMaxTileWidth = 4096;
constexpr int kMaxTileArea = 4096 * 2304;
constexpr int kMaxOperatingPoints = 32;
constexpr int kWarpedModelPrecBits = 16;
constexpr int kSuperresNum = 8;
constexpr int kSuperresDenomMin = 9;
constexpr int kSuperresDenomBits = 3;
constexpr int kSelectScreenContentTools = 2;
constexpr int kSelectIntegerMv = 2;
constexpr int kMaxGrainYPoints = 14;
constexpr int kMaxGrainCbCrPoints = 10;
constexpr int kMaxGrainLumaCoeffs = 24;
constexpr int kMaxGrainChromaCoeffs = 25;

constexpr int kMaxFrameTiles = 256;

enum ObuType : uint32_t {
  kObuSequenceHeader = 1,
  kObuTemporalDelimiter = 2,
  kObuFrameHeader = 3,
  kObuTileGroup = 4,
  kObuMetadata = 5,
  kObuFrame = 6,
  kObuRedundantFrameHeader = 7,
  kObuTileList = 8,
  kObuPadding = 15,
};

enum FrameType : uint32_t {
  kKeyFrame = 0,
  kInterFrame = 1,
  kIntraOnlyFrame = 2,
  kSwitchFrame = 3,
};

enum WarpType : uint32_t {
  kIdentity = 0,
  kTranslation = 1,
  kRotZoom = 2,
  kAffine = 3,
};

enum RestorationType : uint32_t {
  kRestoreNone = 0,
  kRestoreWiener = 1,
  kRestoreSgrproj = 2,
  kRestoreSwitchable = 3,
};

// an OBU inside a buffer
struct Obu {
  uint32_t type;
  bool has_extension;
  uint32_t temporal_id;
  uint32_t spatial_id;
  const uint8_t* payload;
  size_t payload_size;
  size_t offset;
  size_t header_bytes;
};

// the sequence header OBU and its derived variables
struct SequenceHeader {
  uint32_t seq_profile = 0;
  bool still_picture = false;
  bool reduced_still_picture_header = false;
  bool timing_info_present_flag = false;
  bool decoder_model_info_present_flag = false;
  bool equal_picture_interval = false;
  uint32_t buffer_removal_time_length_minus_1 = 0;
  uint32_t frame_presentation_time_length_minus_1 = 0;
  bool initial_display_delay_present_flag = false;
  uint32_t operating_points_cnt_minus_1 = 0;
  uint32_t operating_point_idc[kMaxOperatingPoints] = {};
  uint32_t seq_level_idx[kMaxOperatingPoints] = {};
  uint32_t seq_tier[kMaxOperatingPoints] = {};
  bool decoder_model_present_for_this_op[kMaxOperatingPoints] = {};
  uint32_t operating_point = 0;
  uint32_t operating_point_idc_sel = 0;
  uint32_t frame_width_bits_minus_1 = 0;
  uint32_t frame_height_bits_minus_1 = 0;
  uint32_t max_frame_width_minus_1 = 0;
  uint32_t max_frame_height_minus_1 = 0;
  bool frame_id_numbers_present_flag = false;
  uint32_t delta_frame_id_length_minus_2 = 0;
  uint32_t additional_frame_id_length_minus_1 = 0;
  bool use_128x128_superblock = false;
  bool enable_filter_intra = false;
  bool enable_intra_edge_filter = false;
  bool enable_interintra_compound = false;
  bool enable_masked_compound = false;
  bool enable_warped_motion = false;
  bool enable_dual_filter = false;
  bool enable_order_hint = false;
  bool enable_jnt_comp = false;
  bool enable_ref_frame_mvs = false;
  uint32_t seq_force_screen_content_tools = kSelectScreenContentTools;
  uint32_t seq_force_integer_mv = kSelectIntegerMv;
  uint32_t order_hint_bits = 0;
  bool enable_superres = false;
  bool enable_cdef = false;
  bool enable_restoration = false;
  uint32_t bit_depth = 8;
  bool mono_chrome = false;
  uint32_t color_primaries = 2;
  uint32_t transfer_characteristics = 2;
  uint32_t matrix_coefficients = 2;
  bool color_range = false;
  bool subsampling_x = true;
  bool subsampling_y = true;
  uint32_t chroma_sample_position = 0;
  bool separate_uv_delta_q = false;
  bool film_grain_params_present = false;
};

struct FilmGrainParams {
  bool apply_grain = false;
  uint32_t grain_seed = 0;
  bool update_grain = false;
  uint32_t num_y_points = 0;
  uint8_t point_y_value[kMaxGrainYPoints] = {};
  uint8_t point_y_scaling[kMaxGrainYPoints] = {};
  bool chroma_scaling_from_luma = false;
  uint32_t num_cb_points = 0;
  uint8_t point_cb_value[kMaxGrainCbCrPoints] = {};
  uint8_t point_cb_scaling[kMaxGrainCbCrPoints] = {};
  uint32_t num_cr_points = 0;
  uint8_t point_cr_value[kMaxGrainCbCrPoints] = {};
  uint8_t point_cr_scaling[kMaxGrainCbCrPoints] = {};
  uint32_t grain_scaling_minus_8 = 0;
  uint32_t ar_coeff_lag = 0;
  uint8_t ar_coeffs_y_plus_128[kMaxGrainLumaCoeffs] = {};
  uint8_t ar_coeffs_cb_plus_128[kMaxGrainChromaCoeffs] = {};
  uint8_t ar_coeffs_cr_plus_128[kMaxGrainChromaCoeffs] = {};
  uint32_t ar_coeff_shift_minus_6 = 0;
  uint32_t grain_scale_shift = 0;
  uint32_t cb_mult = 0;
  uint32_t cb_luma_mult = 0;
  uint32_t cb_offset = 0;
  uint32_t cr_mult = 0;
  uint32_t cr_luma_mult = 0;
  uint32_t cr_offset = 0;
  bool overlap_flag = false;
  bool clip_to_restricted_range = false;
};

// the parameters a frame carries to the next
struct CarriedParams {
  int32_t loop_filter_ref_deltas[kTotalRefsPerFrame] = {1, 0, 0, 0, -1, 0, -1, -1};
  int32_t loop_filter_mode_deltas[2] = {0, 0};
  bool feature_enabled[kMaxSegments][kSegLvlMax] = {};
  int32_t feature_data[kMaxSegments][kSegLvlMax] = {};
  int32_t gm_params[kTotalRefsPerFrame][6] = {};
};

// the slot contents the reference frame update stores
struct RefSlot {
  bool valid = false;
  uint32_t frame_id = 0;
  uint32_t upscaled_width = 0;
  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
  uint32_t render_width = 0;
  uint32_t render_height = 0;
  uint32_t mi_cols = 0;
  uint32_t mi_rows = 0;
  uint32_t frame_type = kKeyFrame;
  uint32_t bit_depth = 8;
  uint32_t order_hint = 0;
  bool showable = false;
  CarriedParams carried;
  FilmGrainParams grain;
};

// the tile layout tile_info() derives
struct TileInfo {
  bool uniform_tile_spacing_flag = true;
  uint32_t tile_cols_log2 = 0;
  uint32_t tile_rows_log2 = 0;
  uint32_t tile_cols = 1;
  uint32_t tile_rows = 1;
  uint32_t mi_col_starts[kMaxTileCols + 1] = {};
  uint32_t mi_row_starts[kMaxTileRows + 1] = {};
  uint32_t width_in_sbs[kMaxTileCols] = {};
  uint32_t height_in_sbs[kMaxTileRows] = {};
  uint32_t context_update_tile_id = 0;
  uint32_t tile_size_bytes = 4;
};

// the uncompressed header
struct FrameHeader {
  uint32_t temporal_id = 0;
  uint32_t spatial_id = 0;

  bool show_existing_frame = false;
  uint32_t frame_to_show_map_idx = 0;
  uint32_t frame_type = kKeyFrame;
  bool frame_is_intra = true;
  bool show_frame = true;
  bool showable_frame = false;
  bool error_resilient_mode = false;
  bool disable_cdf_update = false;
  bool allow_screen_content_tools = false;
  bool force_integer_mv = false;
  uint32_t current_frame_id = 0;
  bool frame_size_override_flag = false;
  uint32_t order_hint = 0;
  uint32_t primary_ref_frame = kPrimaryRefNone;
  uint32_t refresh_frame_flags = 0;
  bool frame_refs_short_signaling = false;
  uint32_t ref_frame_idx[kRefsPerFrame] = {};

  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
  uint32_t upscaled_width = 0;
  uint32_t render_width = 0;
  uint32_t render_height = 0;
  bool use_superres = false;
  uint32_t superres_denom = kSuperresNum;
  uint32_t mi_cols = 0;
  uint32_t mi_rows = 0;

  bool allow_intrabc = false;
  bool allow_high_precision_mv = false;
  bool is_filter_switchable = false;
  uint32_t interpolation_filter = 0;
  bool is_motion_mode_switchable = false;
  bool use_ref_frame_mvs = false;
  bool disable_frame_end_update_cdf = true;

  TileInfo tile;

  uint32_t base_q_idx = 0;
  int32_t delta_q_y_dc = 0;
  int32_t delta_q_u_dc = 0;
  int32_t delta_q_u_ac = 0;
  int32_t delta_q_v_dc = 0;
  int32_t delta_q_v_ac = 0;
  bool using_qmatrix = false;
  uint32_t qm_y = 0;
  uint32_t qm_u = 0;
  uint32_t qm_v = 0;

  bool segmentation_enabled = false;
  bool segmentation_update_map = false;
  bool segmentation_temporal_update = false;
  bool segmentation_update_data = false;

  bool delta_q_present = false;
  uint32_t delta_q_res = 0;
  bool delta_lf_present = false;
  uint32_t delta_lf_res = 0;
  bool delta_lf_multi = false;

  bool coded_lossless = false;
  bool all_lossless = false;

  uint32_t loop_filter_level[4] = {};
  uint32_t loop_filter_sharpness = 0;
  bool loop_filter_delta_enabled = false;
  bool loop_filter_delta_update = false;

  uint32_t cdef_damping_minus_3 = 0;
  uint32_t cdef_bits = 0;
  uint32_t cdef_y_pri_strength[8] = {};
  uint32_t cdef_y_sec_strength[8] = {};
  uint32_t cdef_uv_pri_strength[8] = {};
  uint32_t cdef_uv_sec_strength[8] = {};

  uint32_t frame_restoration_type[3] = {};
  bool uses_lr = false;
  uint32_t lr_unit_shift = 0;
  uint32_t lr_uv_shift = 0;

  uint32_t tx_mode = 0;
  bool reference_select = false;
  bool skip_mode_present = false;
  bool allow_warped_motion = false;
  bool reduced_tx_set = false;

  uint32_t gm_type[kTotalRefsPerFrame] = {};

  FilmGrainParams grain;
  CarriedParams carried;

  bool ref_valid[kNumRefFrames] = {};
  uint32_t ref_order_hint[kNumRefFrames] = {};

  size_t header_bits = 0;
};

// a tile's bytes in its tile group's buffer
struct TileSpan {
  size_t offset;
  uint32_t size;
  uint16_t row;
  uint16_t col;
  uint16_t tg_start;
  uint16_t tg_end;
};

}

#endif

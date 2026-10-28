#ifndef RHIZO_C2VA_VP9_SYNTAX_H
#define RHIZO_C2VA_VP9_SYNTAX_H

// the VP9 frame-level syntax of spec v0.7

#include <stddef.h>
#include <stdint.h>

namespace rhizo::c2va::vp9 {

constexpr int kNumRefFrames = 8;
constexpr int kMaxSegments = 8;
constexpr int kSegLvlMax = 4;
constexpr int kSegLvlAltQ = 0;
constexpr int kSegLvlAltL = 1;
constexpr int kSegLvlRefFrame = 2;
constexpr int kSegLvlSkip = 3;
constexpr int kMaxLoopFilter = 63;
constexpr int kMaxSuperframeFrames = 8;

constexpr uint32_t kKeyFrame = 0;
constexpr uint32_t kCsRgb = 7;

// a coded frame inside a chunk
struct FrameSpan {
  const uint8_t* data;
  size_t size;
};

// split a chunk into its superframe's frames
bool SplitSuperframe(const uint8_t* data, size_t size, FrameSpan frames[kMaxSuperframeFrames], int* count);

// the color configuration of a frame
struct ColorConfig {
  uint32_t bit_depth = 8;
  uint32_t color_space = 0;
  bool color_range = false;
  bool subsampling_x = true;
  bool subsampling_y = true;
};

// the slot contents the reference frame update stores
struct RefInfo {
  bool valid = false;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t profile = 0;
  ColorConfig color;
};

// the uncompressed header state carried across frames
struct ParseState {
  ColorConfig color;
  int32_t lf_ref_deltas[4] = {1, 0, -1, -1};
  int32_t lf_mode_deltas[2] = {0, 0};
  bool feature_enabled[kMaxSegments][kSegLvlMax] = {};
  int32_t feature_data[kMaxSegments][kSegLvlMax] = {};
  bool abs_or_delta_update = false;
  uint8_t tree_probs[7] = {255, 255, 255, 255, 255, 255, 255};
  uint8_t pred_probs[3] = {255, 255, 255};
  RefInfo refs[kNumRefFrames];
};

// a frame's uncompressed header and its derived variables
struct FrameHeader {
  uint32_t profile = 0;
  bool show_existing_frame = false;
  uint32_t frame_to_show_map_idx = 0;
  uint32_t frame_type = kKeyFrame;
  bool show_frame = false;
  bool error_resilient_mode = false;
  bool intra_only = false;
  uint32_t reset_frame_context = 0;
  uint32_t refresh_frame_flags = 0;
  uint32_t ref_frame_idx[3] = {};
  bool ref_frame_sign_bias[3] = {};
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t render_width = 0;
  uint32_t render_height = 0;
  bool allow_high_precision_mv = false;
  uint32_t interpolation_filter = 0;
  bool refresh_frame_context = false;
  bool frame_parallel_decoding_mode = false;
  uint32_t frame_context_idx = 0;
  ColorConfig color;
  uint32_t loop_filter_level = 0;
  uint32_t loop_filter_sharpness = 0;
  bool loop_filter_delta_enabled = false;
  bool loop_filter_delta_update = false;
  uint32_t base_q_idx = 0;
  int32_t delta_q_y_dc = 0;
  int32_t delta_q_uv_dc = 0;
  int32_t delta_q_uv_ac = 0;
  bool lossless = false;
  bool segmentation_enabled = false;
  bool segmentation_update_map = false;
  bool segmentation_temporal_update = false;
  bool segmentation_update_data = false;
  uint32_t tile_cols_log2 = 0;
  uint32_t tile_rows_log2 = 0;
  uint32_t header_size_in_bytes = 0;
  uint32_t uncompressed_header_size = 0;

  bool frame_is_intra() const { return frame_type == kKeyFrame || intra_only; }
};

enum class Parse {
  kOk,
  kBad,
};

// parse a frame's uncompressed header
Parse ParseFrame(const uint8_t* data, size_t size, ParseState* state, FrameHeader* hdr);

// apply the reference frame update process to the slots
void ApplyRefreshes(const FrameHeader& hdr, ParseState* state);

// return true when a segment's feature is active
bool FeatureActive(const FrameHeader& hdr, const ParseState& state, int segment, int feature);

// compute a segment's loop filter levels
void LoopFilterLevels(const FrameHeader& hdr, const ParseState& state, int segment, uint8_t out[4][2]);

// return a segment's qindex
int32_t SegmentQIndex(const FrameHeader& hdr, const ParseState& state, int segment);

// return the dc and ac dequantizers
int32_t DcQ(uint32_t bit_depth, int32_t b);
int32_t AcQ(uint32_t bit_depth, int32_t b);

}

#endif

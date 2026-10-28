#include "dec/av1/av1_parser.h"

#include <string.h>

// the AV1 frame-level parse

namespace rhizo::c2va::av1 {
namespace {

constexpr uint32_t kAllFrames = (1u << kNumRefFrames) - 1;

constexpr int kFeatureBits[kSegLvlMax] = {8, 6, 6, 6, 6, 3, 0, 0};
constexpr bool kFeatureSigned[kSegLvlMax] = {true, true, true, true, true, false, false, false};
constexpr int kFeatureMax[kSegLvlMax] = {255, kMaxLoopFilter, kMaxLoopFilter, kMaxLoopFilter, kMaxLoopFilter, 7, 0, 0};

constexpr uint32_t kRemapLrType[4] = {kRestoreNone, kRestoreSwitchable, kRestoreWiener, kRestoreSgrproj};

constexpr int kRefFrameList[kRefsPerFrame - 2] = {2, 3, 5, 6, 7};

constexpr int32_t kDivLut[257] = {
    16384, 16320, 16257, 16194, 16132, 16070, 16009, 15948, 15888, 15828, 15768, 15709, 15650, 15592, 15534, 15477,
    15420, 15364, 15308, 15252, 15197, 15142, 15087, 15033, 14980, 14926, 14873, 14821, 14769, 14717, 14665, 14614,
    14564, 14513, 14463, 14413, 14364, 14315, 14266, 14218, 14170, 14122, 14075, 14028, 13981, 13935, 13888, 13843,
    13797, 13752, 13707, 13662, 13618, 13574, 13530, 13487, 13443, 13400, 13358, 13315, 13273, 13231, 13190, 13148,
    13107, 13066, 13026, 12985, 12945, 12906, 12866, 12827, 12788, 12749, 12710, 12672, 12633, 12596, 12558, 12520,
    12483, 12446, 12409, 12373, 12336, 12300, 12264, 12228, 12193, 12157, 12122, 12087, 12053, 12018, 11984, 11950,
    11916, 11882, 11848, 11815, 11782, 11749, 11716, 11683, 11651, 11619, 11586, 11555, 11523, 11491, 11460, 11429,
    11398, 11367, 11336, 11305, 11275, 11245, 11215, 11185, 11155, 11125, 11096, 11067, 11038, 11009, 10980, 10951,
    10923, 10894, 10866, 10838, 10810, 10782, 10755, 10727, 10700, 10673, 10645, 10618, 10592, 10565, 10538, 10512,
    10486, 10460, 10434, 10408, 10382, 10356, 10331, 10305, 10280, 10255, 10230, 10205, 10180, 10156, 10131, 10107,
    10082, 10058, 10034, 10010, 9986,  9963,  9939,  9916,  9892,  9869,  9846,  9823,  9800,  9777,  9754,  9732,
    9709,  9687,  9664,  9642,  9620,  9598,  9576,  9554,  9533,  9511,  9489,  9468,  9447,  9425,  9404,  9383,
    9362,  9341,  9321,  9300,  9279,  9259,  9239,  9218,  9198,  9178,  9158,  9138,  9118,  9098,  9079,  9059,
    9039,  9020,  9001,  8981,  8962,  8943,  8924,  8905,  8886,  8867,  8849,  8830,  8812,  8793,  8775,  8756,
    8738,  8720,  8702,  8684,  8666,  8648,  8630,  8613,  8595,  8577,  8560,  8542,  8525,  8508,  8490,  8473,
    8456,  8439,  8422,  8405,  8389,  8372,  8355,  8339,  8322,  8306,  8289,  8273,  8257,  8240,  8224,  8208,
    8192};

int32_t Clip3(int32_t lo, int32_t hi, int32_t v) { return v < lo ? lo : (v > hi ? hi : v); }

// return tile_log2()
uint32_t TileLog2(uint32_t blk, uint32_t target) {
  uint32_t k = 0;
  while ((static_cast<uint64_t>(blk) << k) < target) k++;
  return k;
}

int64_t Round2Signed(int64_t x, int n) {
  if (n == 0) return x;
  int64_t half = int64_t{1} << (n - 1);
  return x >= 0 ? (x + half) >> n : -((-x + half) >> n);
}

// set the global motion params to identity
void DefaultGmParams(int32_t gm[kTotalRefsPerFrame][6]) {
  for (int ref = 0; ref < kTotalRefsPerFrame; ref++) {
    for (int i = 0; i < 6; i++) gm[ref][i] = (i % 3 == 2) ? (1 << kWarpedModelPrecBits) : 0;
  }
}

// parse the uncompressed header
class HeaderParser {
 public:
  HeaderParser(const SequenceHeader& seq, const RefSlot* refs, Bits& b, FrameHeader* h)
      : seq_(seq), refs_(refs), b_(b), h_(*h) {}

  ParseError Run(const Obu& obu, bool frame_obu);

 private:
  int32_t RelativeDist(uint32_t a, uint32_t b) const;
  void Fail(ParseError e) {
    if (err_ == ParseError::kNone) err_ = e;
  }
  bool FrameSize();
  void SuperresParams();
  void ComputeImageSize();
  void RenderSize();
  bool FrameSizeWithRefs();
  void SetFrameRefs(uint32_t last_frame_idx, uint32_t gold_frame_idx);
  void MarkRefFrames(uint32_t id_len);
  void TileInfo();
  void QuantizationParams();
  int32_t ReadDeltaQ(const char* coded_name, const char* name);
  void SegmentationParams();
  void DeltaQParams();
  void DeltaLfParams();
  uint32_t GetQIndexIgnoringDelta(int segment_id) const;
  void LoopFilterParams();
  void CdefParams();
  void LrParams();
  void ReadTxMode();
  void SkipModeParams();
  void GlobalMotionParams();
  void ReadGlobalParam(uint32_t type, int ref, int idx);
  uint32_t DecodeSubexp(uint32_t num_syms);
  void FilmGrainParams();
  bool CheckRefSizes();

  const SequenceHeader& seq_;
  const RefSlot* refs_;
  Bits& b_;
  FrameHeader& h_;
  int32_t prev_gm_[kTotalRefsPerFrame][6];
  int num_planes_ = 3;
  ParseError err_ = ParseError::kNone;
};

// return the order hint distance from b to a
int32_t HeaderParser::RelativeDist(uint32_t a, uint32_t b) const {
  if (!seq_.enable_order_hint) return 0;
  int32_t diff = static_cast<int32_t>(a) - static_cast<int32_t>(b);
  int32_t m = 1 << (seq_.order_hint_bits - 1);
  return (diff & (m - 1)) - (diff & m);
}

// parse the frame size
bool HeaderParser::FrameSize() {
  if (h_.frame_size_override_flag) {
    uint32_t w = b_.f(seq_.frame_width_bits_minus_1 + 1, "frame_width_minus_1");
    uint32_t hh = b_.f(seq_.frame_height_bits_minus_1 + 1, "frame_height_minus_1");
    if (w > seq_.max_frame_width_minus_1 || hh > seq_.max_frame_height_minus_1) {
      Fail(ParseError::kBad);
      return false;
    }
    h_.frame_width = w + 1;
    h_.frame_height = hh + 1;
  } else {
    h_.frame_width = seq_.max_frame_width_minus_1 + 1;
    h_.frame_height = seq_.max_frame_height_minus_1 + 1;
  }
  SuperresParams();
  ComputeImageSize();
  return true;
}

// parse the superres params
void HeaderParser::SuperresParams() {
  h_.use_superres = seq_.enable_superres ? b_.flag("use_superres") : false;
  if (h_.use_superres) {
    h_.superres_denom = b_.f(kSuperresDenomBits, "coded_denom") + kSuperresDenomMin;
  } else {
    h_.superres_denom = kSuperresNum;
  }
  h_.upscaled_width = h_.frame_width;
  h_.frame_width = (h_.upscaled_width * kSuperresNum + h_.superres_denom / 2) / h_.superres_denom;
}

// compute the frame size in mode info units
void HeaderParser::ComputeImageSize() {
  h_.mi_cols = 2 * ((h_.frame_width + 7) >> 3);
  h_.mi_rows = 2 * ((h_.frame_height + 7) >> 3);
}

// parse the render size
void HeaderParser::RenderSize() {
  if (b_.flag("render_and_frame_size_different")) {
    h_.render_width = b_.f(16, "render_width_minus_1") + 1;
    h_.render_height = b_.f(16, "render_height_minus_1") + 1;
  } else {
    h_.render_width = h_.upscaled_width;
    h_.render_height = h_.frame_height;
  }
}

// parse the frame size from a reference or the bitstream
bool HeaderParser::FrameSizeWithRefs() {
  bool found = false;
  for (int i = 0; i < kRefsPerFrame; i++) {
    if (b_.flag("found_ref", i)) {
      const RefSlot& r = refs_[h_.ref_frame_idx[i]];
      h_.upscaled_width = r.upscaled_width;
      h_.frame_width = h_.upscaled_width;
      h_.frame_height = r.frame_height;
      h_.render_width = r.render_width;
      h_.render_height = r.render_height;
      found = true;
      break;
    }
  }
  if (!found) {
    if (!FrameSize()) return false;
    RenderSize();
    return true;
  }
  if (h_.frame_width == 0 || h_.frame_height == 0 || h_.frame_width > seq_.max_frame_width_minus_1 + 1 ||
      h_.frame_height > seq_.max_frame_height_minus_1 + 1) {
    Fail(ParseError::kBad);
    return false;
  }
  SuperresParams();
  ComputeImageSize();
  return true;
}

// return true when the references fit the scaling bounds
bool HeaderParser::CheckRefSizes() {
  for (int i = 0; i < kRefsPerFrame; i++) {
    uint32_t idx = h_.ref_frame_idx[i];
    if (!h_.ref_valid[idx]) continue;
    const RefSlot& r = refs_[idx];
    if (2 * h_.frame_width < r.upscaled_width || 2 * h_.frame_height < r.frame_height ||
        h_.frame_width > 16 * r.upscaled_width || h_.frame_height > 16 * r.frame_height) {
      return false;
    }
  }
  return true;
}

// derive the frame refs from the last and golden refs
void HeaderParser::SetFrameRefs(uint32_t last_frame_idx, uint32_t gold_frame_idx) {
  int ref_frame_idx[kRefsPerFrame];
  for (int i = 0; i < kRefsPerFrame; i++) ref_frame_idx[i] = -1;
  ref_frame_idx[0] = static_cast<int>(last_frame_idx);
  ref_frame_idx[3] = static_cast<int>(gold_frame_idx);
  bool used[kNumRefFrames] = {};
  used[last_frame_idx] = true;
  used[gold_frame_idx] = true;
  int32_t cur_frame_hint = 1 << (seq_.order_hint_bits - 1);
  int32_t shifted[kNumRefFrames];
  for (int i = 0; i < kNumRefFrames; i++) {
    shifted[i] = cur_frame_hint + RelativeDist(h_.ref_order_hint[i], h_.order_hint);
  }
  if (shifted[last_frame_idx] >= cur_frame_hint || shifted[gold_frame_idx] >= cur_frame_hint) {
    Fail(ParseError::kBad);
  }
  {
    int ref = -1;
    int32_t latest = 0;
    for (int i = 0; i < kNumRefFrames; i++) {
      int32_t hint = shifted[i];
      if (!used[i] && hint >= cur_frame_hint && (ref < 0 || hint >= latest)) {
        ref = i;
        latest = hint;
      }
    }
    if (ref >= 0) {
      ref_frame_idx[6] = ref;
      used[ref] = true;
    }
  }
  for (int slot : {4, 5}) {
    int ref = -1;
    int32_t earliest = 0;
    for (int i = 0; i < kNumRefFrames; i++) {
      int32_t hint = shifted[i];
      if (!used[i] && hint >= cur_frame_hint && (ref < 0 || hint < earliest)) {
        ref = i;
        earliest = hint;
      }
    }
    if (ref >= 0) {
      ref_frame_idx[slot] = ref;
      used[ref] = true;
    }
  }
  for (int k = 0; k < kRefsPerFrame - 2; k++) {
    int slot = kRefFrameList[k] - 1;
    if (ref_frame_idx[slot] >= 0) continue;
    int ref = -1;
    int32_t latest = 0;
    for (int i = 0; i < kNumRefFrames; i++) {
      int32_t hint = shifted[i];
      if (!used[i] && hint < cur_frame_hint && (ref < 0 || hint >= latest)) {
        ref = i;
        latest = hint;
      }
    }
    if (ref >= 0) {
      ref_frame_idx[slot] = ref;
      used[ref] = true;
    }
  }
  int ref = -1;
  int32_t earliest = 0;
  for (int i = 0; i < kNumRefFrames; i++) {
    int32_t hint = shifted[i];
    if (ref < 0 || hint < earliest) {
      ref = i;
      earliest = hint;
    }
  }
  for (int i = 0; i < kRefsPerFrame; i++) {
    if (ref_frame_idx[i] < 0) ref_frame_idx[i] = ref;
    h_.ref_frame_idx[i] = static_cast<uint32_t>(ref_frame_idx[i]);
  }
}

// invalidate the reference frames with out-of-range ids
void HeaderParser::MarkRefFrames(uint32_t id_len) {
  int64_t diff_len = seq_.delta_frame_id_length_minus_2 + 2;
  int64_t cur = h_.current_frame_id;
  int64_t span = int64_t{1} << diff_len;
  for (int i = 0; i < kNumRefFrames; i++) {
    int64_t id = refs_[i].frame_id;
    if (cur > span) {
      if (id > cur || id < cur - span) h_.ref_valid[i] = false;
    } else {
      if (id > cur && id < (int64_t{1} << id_len) + cur - span) h_.ref_valid[i] = false;
    }
  }
}

// parse the tile info
void HeaderParser::TileInfo() {
  struct TileInfo& t = h_.tile;
  uint32_t sb_cols = seq_.use_128x128_superblock ? ((h_.mi_cols + 31) >> 5) : ((h_.mi_cols + 15) >> 4);
  uint32_t sb_rows = seq_.use_128x128_superblock ? ((h_.mi_rows + 31) >> 5) : ((h_.mi_rows + 15) >> 4);
  uint32_t sb_shift = seq_.use_128x128_superblock ? 5 : 4;
  uint32_t sb_size = sb_shift + 2;
  uint32_t max_tile_width_sb = kMaxTileWidth >> sb_size;
  uint32_t max_tile_area_sb = kMaxTileArea >> (2 * sb_size);
  uint32_t min_log2_tile_cols = TileLog2(max_tile_width_sb, sb_cols);
  uint32_t max_log2_tile_cols = TileLog2(1, sb_cols < kMaxTileCols ? sb_cols : kMaxTileCols);
  uint32_t max_log2_tile_rows = TileLog2(1, sb_rows < kMaxTileRows ? sb_rows : kMaxTileRows);
  uint32_t area_log2 = TileLog2(max_tile_area_sb, sb_rows * sb_cols);
  uint32_t min_log2_tiles = min_log2_tile_cols > area_log2 ? min_log2_tile_cols : area_log2;
  uint32_t col_start_sb[kMaxTileCols + 1] = {};
  uint32_t row_start_sb[kMaxTileRows + 1] = {};

  t.uniform_tile_spacing_flag = b_.flag("uniform_tile_spacing_flag");
  uint32_t i = 0;
  if (t.uniform_tile_spacing_flag) {
    t.tile_cols_log2 = min_log2_tile_cols;
    while (t.tile_cols_log2 < max_log2_tile_cols) {
      if (!b_.flag("increment_tile_cols_log2")) break;
      t.tile_cols_log2++;
    }
    uint32_t tile_width_sb = (sb_cols + (1u << t.tile_cols_log2) - 1) >> t.tile_cols_log2;
    for (uint32_t start = 0; start < sb_cols; start += tile_width_sb) {
      if (i >= kMaxTileCols) return Fail(ParseError::kBad);
      col_start_sb[i++] = start;
    }
    t.tile_cols = i;

    uint32_t min_log2_tile_rows = min_log2_tiles > t.tile_cols_log2 ? min_log2_tiles - t.tile_cols_log2 : 0;
    t.tile_rows_log2 = min_log2_tile_rows;
    while (t.tile_rows_log2 < max_log2_tile_rows) {
      if (!b_.flag("increment_tile_rows_log2")) break;
      t.tile_rows_log2++;
    }
    if (t.tile_rows_log2 > 31) return Fail(ParseError::kBad);
    uint32_t tile_height_sb = (sb_rows + (1u << t.tile_rows_log2) - 1) >> t.tile_rows_log2;
    i = 0;
    for (uint32_t start = 0; start < sb_rows; start += tile_height_sb) {
      if (i >= kMaxTileRows) return Fail(ParseError::kBad);
      row_start_sb[i++] = start;
    }
    t.tile_rows = i;
  } else {
    uint32_t widest_tile_sb = 0;
    uint32_t start = 0;
    for (i = 0; start < sb_cols; i++) {
      if (i >= kMaxTileCols) return Fail(ParseError::kBad);
      col_start_sb[i] = start;
      uint32_t max_width = sb_cols - start < max_tile_width_sb ? sb_cols - start : max_tile_width_sb;
      uint32_t size_sb = b_.ns(max_width, "width_in_sbs_minus_1", static_cast<int>(i)) + 1;
      if (size_sb > widest_tile_sb) widest_tile_sb = size_sb;
      start += size_sb;
      if (b_.overrun()) return Fail(ParseError::kBad);
    }
    t.tile_cols = i;
    t.tile_cols_log2 = TileLog2(1, t.tile_cols);

    uint32_t area = min_log2_tiles > 0 ? (sb_rows * sb_cols) >> (min_log2_tiles + 1) : sb_rows * sb_cols;
    uint32_t max_tile_height_sb = area / widest_tile_sb;
    if (max_tile_height_sb < 1) max_tile_height_sb = 1;
    start = 0;
    for (i = 0; start < sb_rows; i++) {
      if (i >= kMaxTileRows) return Fail(ParseError::kBad);
      row_start_sb[i] = start;
      uint32_t max_height = sb_rows - start < max_tile_height_sb ? sb_rows - start : max_tile_height_sb;
      start += b_.ns(max_height, "height_in_sbs_minus_1", static_cast<int>(i)) + 1;
      if (b_.overrun()) return Fail(ParseError::kBad);
    }
    t.tile_rows = i;
    t.tile_rows_log2 = TileLog2(1, t.tile_rows);
  }
  col_start_sb[t.tile_cols] = sb_cols;
  row_start_sb[t.tile_rows] = sb_rows;
  for (i = 0; i < t.tile_cols; i++) {
    t.mi_col_starts[i] = col_start_sb[i] << sb_shift;
    t.width_in_sbs[i] = col_start_sb[i + 1] - col_start_sb[i];
  }
  t.mi_col_starts[t.tile_cols] = h_.mi_cols;
  for (i = 0; i < t.tile_rows; i++) {
    t.mi_row_starts[i] = row_start_sb[i] << sb_shift;
    t.height_in_sbs[i] = row_start_sb[i + 1] - row_start_sb[i];
  }
  t.mi_row_starts[t.tile_rows] = h_.mi_rows;

  if (t.tile_cols_log2 > 0 || t.tile_rows_log2 > 0) {
    t.context_update_tile_id = b_.f(static_cast<int>(t.tile_rows_log2 + t.tile_cols_log2), "context_update_tile_id");
    t.tile_size_bytes = b_.f(2, "tile_size_bytes_minus_1") + 1;
    if (t.context_update_tile_id >= t.tile_cols * t.tile_rows) Fail(ParseError::kBad);
  } else {
    t.context_update_tile_id = 0;
  }
}

// read a delta q
int32_t HeaderParser::ReadDeltaQ(const char* coded_name, const char* name) {
  if (b_.flag(coded_name)) return b_.su(7, name);
  return 0;
}

// parse the quantization params
void HeaderParser::QuantizationParams() {
  h_.base_q_idx = b_.f(8, "base_q_idx");
  h_.delta_q_y_dc = ReadDeltaQ("delta_coded", "delta_q_y_dc");
  if (num_planes_ > 1) {
    bool diff_uv_delta = seq_.separate_uv_delta_q ? b_.flag("diff_uv_delta") : false;
    h_.delta_q_u_dc = ReadDeltaQ("delta_coded", "delta_q_u_dc");
    h_.delta_q_u_ac = ReadDeltaQ("delta_coded", "delta_q_u_ac");
    if (diff_uv_delta) {
      h_.delta_q_v_dc = ReadDeltaQ("delta_coded", "delta_q_v_dc");
      h_.delta_q_v_ac = ReadDeltaQ("delta_coded", "delta_q_v_ac");
    } else {
      h_.delta_q_v_dc = h_.delta_q_u_dc;
      h_.delta_q_v_ac = h_.delta_q_u_ac;
    }
  } else {
    h_.delta_q_u_dc = h_.delta_q_u_ac = h_.delta_q_v_dc = h_.delta_q_v_ac = 0;
  }
  h_.using_qmatrix = b_.flag("using_qmatrix");
  if (h_.using_qmatrix) {
    h_.qm_y = b_.f(4, "qm_y");
    h_.qm_u = b_.f(4, "qm_u");
    h_.qm_v = seq_.separate_uv_delta_q ? b_.f(4, "qm_v") : h_.qm_u;
  }
}

// parse the segmentation params
void HeaderParser::SegmentationParams() {
  CarriedParams& c = h_.carried;
  h_.segmentation_enabled = b_.flag("segmentation_enabled");
  if (h_.segmentation_enabled) {
    if (h_.primary_ref_frame == kPrimaryRefNone) {
      h_.segmentation_update_map = true;
      h_.segmentation_temporal_update = false;
      h_.segmentation_update_data = true;
    } else {
      h_.segmentation_update_map = b_.flag("segmentation_update_map");
      h_.segmentation_temporal_update =
          h_.segmentation_update_map ? b_.flag("segmentation_temporal_update") : false;
      h_.segmentation_update_data = b_.flag("segmentation_update_data");
    }
    if (h_.segmentation_update_data) {
      for (int i = 0; i < kMaxSegments; i++) {
        for (int j = 0; j < kSegLvlMax; j++) {
          bool enabled = b_.flag("feature_enabled", i, j);
          int32_t clipped = 0;
          if (enabled) {
            int bits = kFeatureBits[j];
            int32_t limit = kFeatureMax[j];
            if (kFeatureSigned[j]) {
              clipped = Clip3(-limit, limit, b_.su(1 + bits, "feature_value", i, j));
            } else {
              clipped = Clip3(0, limit, static_cast<int32_t>(b_.f(bits, "feature_value", i, j)));
            }
          }
          c.feature_enabled[i][j] = enabled;
          c.feature_data[i][j] = clipped;
        }
      }
    }
  } else {
    h_.segmentation_update_map = h_.segmentation_temporal_update = h_.segmentation_update_data = false;
    for (int i = 0; i < kMaxSegments; i++) {
      for (int j = 0; j < kSegLvlMax; j++) {
        c.feature_enabled[i][j] = false;
        c.feature_data[i][j] = 0;
      }
    }
  }
}

// parse the delta q params
void HeaderParser::DeltaQParams() {
  h_.delta_q_res = 0;
  h_.delta_q_present = h_.base_q_idx > 0 ? b_.flag("delta_q_present") : false;
  if (h_.delta_q_present) h_.delta_q_res = b_.f(2, "delta_q_res");
}

// parse the delta loop filter params
void HeaderParser::DeltaLfParams() {
  h_.delta_lf_present = false;
  h_.delta_lf_res = 0;
  h_.delta_lf_multi = false;
  if (h_.delta_q_present) {
    if (!h_.allow_intrabc) h_.delta_lf_present = b_.flag("delta_lf_present");
    if (h_.delta_lf_present) {
      h_.delta_lf_res = b_.f(2, "delta_lf_res");
      h_.delta_lf_multi = b_.flag("delta_lf_multi");
    }
  }
}

// return a segment's qindex ignoring delta q
uint32_t HeaderParser::GetQIndexIgnoringDelta(int segment_id) const {
  const CarriedParams& c = h_.carried;
  if (h_.segmentation_enabled && c.feature_enabled[segment_id][kSegLvlAltQ]) {
    int32_t q = static_cast<int32_t>(h_.base_q_idx) + c.feature_data[segment_id][kSegLvlAltQ];
    return static_cast<uint32_t>(Clip3(0, 255, q));
  }
  return h_.base_q_idx;
}

// parse the loop filter params
void HeaderParser::LoopFilterParams() {
  CarriedParams& c = h_.carried;
  if (h_.coded_lossless || h_.allow_intrabc) {
    for (uint32_t& l : h_.loop_filter_level) l = 0;
    static constexpr int32_t kDefaults[kTotalRefsPerFrame] = {1, 0, 0, 0, -1, 0, -1, -1};
    memcpy(c.loop_filter_ref_deltas, kDefaults, sizeof(kDefaults));
    c.loop_filter_mode_deltas[0] = c.loop_filter_mode_deltas[1] = 0;
    return;
  }
  h_.loop_filter_level[0] = b_.f(6, "loop_filter_level", 0);
  h_.loop_filter_level[1] = b_.f(6, "loop_filter_level", 1);
  if (num_planes_ > 1 && (h_.loop_filter_level[0] || h_.loop_filter_level[1])) {
    h_.loop_filter_level[2] = b_.f(6, "loop_filter_level", 2);
    h_.loop_filter_level[3] = b_.f(6, "loop_filter_level", 3);
  }
  h_.loop_filter_sharpness = b_.f(3, "loop_filter_sharpness");
  h_.loop_filter_delta_enabled = b_.flag("loop_filter_delta_enabled");
  if (h_.loop_filter_delta_enabled) {
    h_.loop_filter_delta_update = b_.flag("loop_filter_delta_update");
    if (h_.loop_filter_delta_update) {
      for (int i = 0; i < kTotalRefsPerFrame; i++) {
        if (b_.flag("update_ref_delta", i)) c.loop_filter_ref_deltas[i] = b_.su(7, "loop_filter_ref_deltas", i);
      }
      for (int i = 0; i < 2; i++) {
        if (b_.flag("update_mode_delta", i)) c.loop_filter_mode_deltas[i] = b_.su(7, "loop_filter_mode_deltas", i);
      }
    }
  }
}

// parse the cdef params
void HeaderParser::CdefParams() {
  if (h_.coded_lossless || h_.allow_intrabc || !seq_.enable_cdef) {
    h_.cdef_bits = 0;
    h_.cdef_damping_minus_3 = 0;
    return;
  }
  h_.cdef_damping_minus_3 = b_.f(2, "cdef_damping_minus_3");
  h_.cdef_bits = b_.f(2, "cdef_bits");
  for (int i = 0; i < (1 << h_.cdef_bits); i++) {
    h_.cdef_y_pri_strength[i] = b_.f(4, "cdef_y_pri_strength", i);
    h_.cdef_y_sec_strength[i] = b_.f(2, "cdef_y_sec_strength", i);
    if (num_planes_ > 1) {
      h_.cdef_uv_pri_strength[i] = b_.f(4, "cdef_uv_pri_strength", i);
      h_.cdef_uv_sec_strength[i] = b_.f(2, "cdef_uv_sec_strength", i);
    }
  }
}

// parse the loop restoration params
void HeaderParser::LrParams() {
  h_.uses_lr = false;
  if (h_.all_lossless || h_.allow_intrabc || !seq_.enable_restoration) {
    h_.frame_restoration_type[0] = h_.frame_restoration_type[1] = h_.frame_restoration_type[2] = kRestoreNone;
    return;
  }
  bool uses_chroma_lr = false;
  for (int i = 0; i < num_planes_; i++) {
    h_.frame_restoration_type[i] = kRemapLrType[b_.f(2, "lr_type", i)];
    if (h_.frame_restoration_type[i] != kRestoreNone) {
      h_.uses_lr = true;
      if (i > 0) uses_chroma_lr = true;
    }
  }
  if (h_.uses_lr) {
    if (seq_.use_128x128_superblock) {
      h_.lr_unit_shift = b_.f(1, "lr_unit_shift") + 1;
    } else {
      h_.lr_unit_shift = b_.f(1, "lr_unit_shift");
      if (h_.lr_unit_shift) h_.lr_unit_shift += b_.f(1, "lr_unit_extra_shift");
    }
    h_.lr_uv_shift = (seq_.subsampling_x && seq_.subsampling_y && uses_chroma_lr) ? b_.f(1, "lr_uv_shift") : 0;
  }
}

// read the tx mode
void HeaderParser::ReadTxMode() {
  if (h_.coded_lossless) {
    h_.tx_mode = 0;
  } else {
    h_.tx_mode = b_.flag("tx_mode_select") ? 2 : 1;
  }
}

// parse the skip mode params
void HeaderParser::SkipModeParams() {
  bool allowed = false;
  if (!h_.frame_is_intra && h_.reference_select && seq_.enable_order_hint) {
    int forward_idx = -1, backward_idx = -1;
    uint32_t forward_hint = 0, backward_hint = 0;
    for (int i = 0; i < kRefsPerFrame; i++) {
      uint32_t ref_hint = h_.ref_order_hint[h_.ref_frame_idx[i]];
      if (RelativeDist(ref_hint, h_.order_hint) < 0) {
        if (forward_idx < 0 || RelativeDist(ref_hint, forward_hint) > 0) {
          forward_idx = i;
          forward_hint = ref_hint;
        }
      } else if (RelativeDist(ref_hint, h_.order_hint) > 0) {
        if (backward_idx < 0 || RelativeDist(ref_hint, backward_hint) < 0) {
          backward_idx = i;
          backward_hint = ref_hint;
        }
      }
    }
    if (forward_idx < 0) {
      allowed = false;
    } else if (backward_idx >= 0) {
      allowed = true;
    } else {
      int second_forward_idx = -1;
      uint32_t second_forward_hint = 0;
      for (int i = 0; i < kRefsPerFrame; i++) {
        uint32_t ref_hint = h_.ref_order_hint[h_.ref_frame_idx[i]];
        if (RelativeDist(ref_hint, forward_hint) < 0) {
          if (second_forward_idx < 0 || RelativeDist(ref_hint, second_forward_hint) > 0) {
            second_forward_idx = i;
            second_forward_hint = ref_hint;
          }
        }
      }
      allowed = second_forward_idx >= 0;
    }
  }
  h_.skip_mode_present = allowed ? b_.flag("skip_mode_present") : false;
}

// decode a subexponential value below num_syms
uint32_t HeaderParser::DecodeSubexp(uint32_t num_syms) {
  uint32_t i = 0, mk = 0, k = 3;
  while (true) {
    uint32_t b2 = i ? k + i - 1 : k;
    if (b2 > 30) {
      Fail(ParseError::kBad);
      return 0;
    }
    uint32_t a = 1u << b2;
    if (num_syms <= mk + 3 * a) return b_.ns(num_syms - mk, "subexp_final_bits") + mk;
    if (!b_.flag("subexp_more_bits")) return b_.f(static_cast<int>(b2), "subexp_bits") + mk;
    i++;
    mk += a;
    if (b_.overrun()) {
      Fail(ParseError::kBad);
      return 0;
    }
  }
}

// return inverse_recenter(r, v)
int32_t InverseRecenter(int32_t r, int32_t v) {
  if (v > 2 * r) return v;
  if (v & 1) return r - ((v + 1) >> 1);
  return r + (v >> 1);
}

// read a global motion param
void HeaderParser::ReadGlobalParam(uint32_t type, int ref, int idx) {
  int abs_bits = 12;
  int prec_bits = 15;
  if (idx < 2) {
    if (type == kTranslation) {
      abs_bits = 9 - !h_.allow_high_precision_mv;
      prec_bits = 3 - !h_.allow_high_precision_mv;
    } else {
      abs_bits = 12;
      prec_bits = 6;
    }
  }
  int prec_diff = kWarpedModelPrecBits - prec_bits;
  int32_t round = (idx % 3) == 2 ? (1 << kWarpedModelPrecBits) : 0;
  int32_t sub = (idx % 3) == 2 ? (1 << prec_bits) : 0;
  int32_t mx = 1 << abs_bits;
  int32_t r = (prev_gm_[ref][idx] >> prec_diff) - sub;
  int32_t low = -mx;
  int32_t range = 2 * mx + 1;
  int32_t ur = r - low;
  int32_t v = static_cast<int32_t>(DecodeSubexp(static_cast<uint32_t>(range)));
  int32_t x;
  if (ur >= 0 && ur < range) {
    x = (ur << 1) <= range ? InverseRecenter(ur, v) : range - 1 - InverseRecenter(range - 1 - ur, v);
  } else {
    x = v;
  }
  x = Clip3(0, range - 1, x);
  h_.carried.gm_params[ref][idx] = (x + low) * (1 << prec_diff) + round;
}

// parse the global motion params
void HeaderParser::GlobalMotionParams() {
  CarriedParams& c = h_.carried;
  for (int ref = 0; ref < kTotalRefsPerFrame; ref++) h_.gm_type[ref] = kIdentity;
  DefaultGmParams(c.gm_params);
  if (h_.frame_is_intra) return;
  for (int ref = 1; ref < kTotalRefsPerFrame; ref++) {
    uint32_t type = kIdentity;
    if (b_.flag("is_global", ref)) {
      if (b_.flag("is_rot_zoom", ref)) {
        type = kRotZoom;
      } else {
        type = b_.flag("is_translation", ref) ? kTranslation : kAffine;
      }
    }
    h_.gm_type[ref] = type;
    if (type >= kRotZoom) {
      ReadGlobalParam(type, ref, 2);
      ReadGlobalParam(type, ref, 3);
      if (type == kAffine) {
        ReadGlobalParam(type, ref, 4);
        ReadGlobalParam(type, ref, 5);
      } else {
        c.gm_params[ref][4] = -c.gm_params[ref][3];
        c.gm_params[ref][5] = c.gm_params[ref][2];
      }
    }
    if (type >= kTranslation) {
      ReadGlobalParam(type, ref, 0);
      ReadGlobalParam(type, ref, 1);
    }
  }
}

// parse the film grain params
void HeaderParser::FilmGrainParams() {
  struct FilmGrainParams& g = h_.grain;
  g = {};
  if (!seq_.film_grain_params_present || (!h_.show_frame && !h_.showable_frame)) return;
  g.apply_grain = b_.flag("apply_grain");
  if (!g.apply_grain) {
    g = {};
    return;
  }
  g.grain_seed = b_.f(16, "grain_seed");
  g.update_grain = h_.frame_type == kInterFrame ? b_.flag("update_grain") : true;
  if (!g.update_grain) {
    uint32_t idx = b_.f(3, "film_grain_params_ref_idx");
    bool is_ref = false;
    for (int i = 0; i < kRefsPerFrame; i++) is_ref = is_ref || h_.ref_frame_idx[i] == idx;
    if (!is_ref || !h_.ref_valid[idx]) return Fail(ParseError::kBad);
    uint32_t seed = g.grain_seed;
    g = refs_[idx].grain;
    g.grain_seed = seed;
    return;
  }
  g.num_y_points = b_.f(4, "num_y_points");
  if (g.num_y_points > kMaxGrainYPoints) return Fail(ParseError::kBad);
  for (uint32_t i = 0; i < g.num_y_points; i++) {
    g.point_y_value[i] = static_cast<uint8_t>(b_.f(8, "point_y_value", static_cast<int>(i)));
    g.point_y_scaling[i] = static_cast<uint8_t>(b_.f(8, "point_y_scaling", static_cast<int>(i)));
  }
  g.chroma_scaling_from_luma = seq_.mono_chrome ? false : b_.flag("chroma_scaling_from_luma");
  if (seq_.mono_chrome || g.chroma_scaling_from_luma ||
      (seq_.subsampling_x && seq_.subsampling_y && g.num_y_points == 0)) {
    g.num_cb_points = g.num_cr_points = 0;
  } else {
    g.num_cb_points = b_.f(4, "num_cb_points");
    if (g.num_cb_points > kMaxGrainCbCrPoints) return Fail(ParseError::kBad);
    for (uint32_t i = 0; i < g.num_cb_points; i++) {
      g.point_cb_value[i] = static_cast<uint8_t>(b_.f(8, "point_cb_value", static_cast<int>(i)));
      g.point_cb_scaling[i] = static_cast<uint8_t>(b_.f(8, "point_cb_scaling", static_cast<int>(i)));
    }
    g.num_cr_points = b_.f(4, "num_cr_points");
    if (g.num_cr_points > kMaxGrainCbCrPoints) return Fail(ParseError::kBad);
    for (uint32_t i = 0; i < g.num_cr_points; i++) {
      g.point_cr_value[i] = static_cast<uint8_t>(b_.f(8, "point_cr_value", static_cast<int>(i)));
      g.point_cr_scaling[i] = static_cast<uint8_t>(b_.f(8, "point_cr_scaling", static_cast<int>(i)));
    }
  }
  g.grain_scaling_minus_8 = b_.f(2, "grain_scaling_minus_8");
  g.ar_coeff_lag = b_.f(2, "ar_coeff_lag");
  uint32_t num_pos_luma = 2 * g.ar_coeff_lag * (g.ar_coeff_lag + 1);
  uint32_t num_pos_chroma = num_pos_luma;
  if (g.num_y_points) {
    num_pos_chroma = num_pos_luma + 1;
    for (uint32_t i = 0; i < num_pos_luma; i++) {
      g.ar_coeffs_y_plus_128[i] = static_cast<uint8_t>(b_.f(8, "ar_coeffs_y_plus_128", static_cast<int>(i)));
    }
  }
  if (g.chroma_scaling_from_luma || g.num_cb_points) {
    for (uint32_t i = 0; i < num_pos_chroma; i++) {
      g.ar_coeffs_cb_plus_128[i] = static_cast<uint8_t>(b_.f(8, "ar_coeffs_cb_plus_128", static_cast<int>(i)));
    }
  }
  if (g.chroma_scaling_from_luma || g.num_cr_points) {
    for (uint32_t i = 0; i < num_pos_chroma; i++) {
      g.ar_coeffs_cr_plus_128[i] = static_cast<uint8_t>(b_.f(8, "ar_coeffs_cr_plus_128", static_cast<int>(i)));
    }
  }
  g.ar_coeff_shift_minus_6 = b_.f(2, "ar_coeff_shift_minus_6");
  g.grain_scale_shift = b_.f(2, "grain_scale_shift");
  if (g.num_cb_points) {
    g.cb_mult = b_.f(8, "cb_mult");
    g.cb_luma_mult = b_.f(8, "cb_luma_mult");
    g.cb_offset = b_.f(9, "cb_offset");
  }
  if (g.num_cr_points) {
    g.cr_mult = b_.f(8, "cr_mult");
    g.cr_luma_mult = b_.f(8, "cr_luma_mult");
    g.cr_offset = b_.f(9, "cr_offset");
  }
  g.overlap_flag = b_.flag("overlap_flag");
  g.clip_to_restricted_range = b_.flag("clip_to_restricted_range");
}

// parse the uncompressed header
ParseError HeaderParser::Run(const Obu& obu, bool frame_obu) {
  num_planes_ = seq_.mono_chrome ? 1 : 3;
  h_.temporal_id = obu.temporal_id;
  h_.spatial_id = obu.spatial_id;
  for (int i = 0; i < kNumRefFrames; i++) {
    h_.ref_valid[i] = refs_[i].valid;
    h_.ref_order_hint[i] = refs_[i].order_hint;
  }
  uint32_t id_len = 0;
  if (seq_.frame_id_numbers_present_flag) {
    id_len = seq_.additional_frame_id_length_minus_1 + seq_.delta_frame_id_length_minus_2 + 3;
  }
  bool timing_points = seq_.decoder_model_info_present_flag && !seq_.equal_picture_interval;

  if (seq_.reduced_still_picture_header) {
    h_.show_existing_frame = false;
    h_.frame_type = kKeyFrame;
    h_.frame_is_intra = true;
    h_.show_frame = true;
    h_.showable_frame = false;
    h_.error_resilient_mode = true;
  } else {
    h_.show_existing_frame = b_.flag("show_existing_frame");
    if (h_.show_existing_frame) {
      h_.frame_to_show_map_idx = b_.f(3, "frame_to_show_map_idx");
      if (timing_points) b_.f(seq_.frame_presentation_time_length_minus_1 + 1, "frame_presentation_time");
      h_.refresh_frame_flags = 0;
      if (seq_.frame_id_numbers_present_flag) b_.f(static_cast<int>(id_len), "display_frame_id");
      const RefSlot& shown = refs_[h_.frame_to_show_map_idx];
      h_.frame_type = shown.frame_type;
      if (h_.frame_type == kKeyFrame) h_.refresh_frame_flags = kAllFrames;
      if (seq_.film_grain_params_present) h_.grain = shown.grain;
      h_.header_bits = b_.BitPos();
      if (b_.overrun()) return ParseError::kBad;
      return ParseError::kNone;
    }
    h_.frame_type = b_.f(2, "frame_type");
    h_.frame_is_intra = h_.frame_type == kIntraOnlyFrame || h_.frame_type == kKeyFrame;
    h_.show_frame = b_.flag("show_frame");
    if (h_.show_frame && timing_points) {
      b_.f(seq_.frame_presentation_time_length_minus_1 + 1, "frame_presentation_time");
    }
    h_.showable_frame = h_.show_frame ? h_.frame_type != kKeyFrame : b_.flag("showable_frame");
    if (h_.frame_type == kSwitchFrame || (h_.frame_type == kKeyFrame && h_.show_frame)) {
      h_.error_resilient_mode = true;
    } else {
      h_.error_resilient_mode = b_.flag("error_resilient_mode");
    }
  }
  if (h_.frame_type == kKeyFrame && h_.show_frame) {
    for (int i = 0; i < kNumRefFrames; i++) {
      h_.ref_valid[i] = false;
      h_.ref_order_hint[i] = 0;
    }
  }
  h_.disable_cdf_update = b_.flag("disable_cdf_update");
  if (seq_.seq_force_screen_content_tools == kSelectScreenContentTools) {
    h_.allow_screen_content_tools = b_.flag("allow_screen_content_tools");
  } else {
    h_.allow_screen_content_tools = seq_.seq_force_screen_content_tools != 0;
  }
  if (h_.allow_screen_content_tools) {
    if (seq_.seq_force_integer_mv == kSelectIntegerMv) {
      h_.force_integer_mv = b_.flag("force_integer_mv");
    } else {
      h_.force_integer_mv = seq_.seq_force_integer_mv != 0;
    }
  } else {
    h_.force_integer_mv = false;
  }
  if (h_.frame_is_intra) h_.force_integer_mv = true;
  if (seq_.frame_id_numbers_present_flag) {
    h_.current_frame_id = b_.f(static_cast<int>(id_len), "current_frame_id");
    MarkRefFrames(id_len);
  } else {
    h_.current_frame_id = 0;
  }
  if (h_.frame_type == kSwitchFrame) {
    h_.frame_size_override_flag = true;
  } else if (seq_.reduced_still_picture_header) {
    h_.frame_size_override_flag = false;
  } else {
    h_.frame_size_override_flag = b_.flag("frame_size_override_flag");
  }
  h_.order_hint = b_.f(static_cast<int>(seq_.order_hint_bits), "order_hint");
  if (h_.frame_is_intra || h_.error_resilient_mode) {
    h_.primary_ref_frame = kPrimaryRefNone;
  } else {
    h_.primary_ref_frame = b_.f(3, "primary_ref_frame");
  }
  if (seq_.decoder_model_info_present_flag) {
    if (b_.flag("buffer_removal_time_present_flag")) {
      for (uint32_t op = 0; op <= seq_.operating_points_cnt_minus_1; op++) {
        if (!seq_.decoder_model_present_for_this_op[op]) continue;
        uint32_t idc = seq_.operating_point_idc[op];
        bool in_temporal = (idc >> h_.temporal_id) & 1;
        bool in_spatial = (idc >> (h_.spatial_id + 8)) & 1;
        if (idc == 0 || (in_temporal && in_spatial)) {
          b_.f(seq_.buffer_removal_time_length_minus_1 + 1, "buffer_removal_time", static_cast<int>(op));
        }
      }
    }
  }
  h_.allow_high_precision_mv = false;
  h_.use_ref_frame_mvs = false;
  h_.allow_intrabc = false;
  if (h_.frame_type == kSwitchFrame || (h_.frame_type == kKeyFrame && h_.show_frame)) {
    h_.refresh_frame_flags = kAllFrames;
  } else {
    h_.refresh_frame_flags = b_.f(8, "refresh_frame_flags");
  }
  if (h_.frame_type == kIntraOnlyFrame && h_.refresh_frame_flags == kAllFrames) return ParseError::kBad;
  if (!h_.frame_is_intra || h_.refresh_frame_flags != kAllFrames) {
    if (h_.error_resilient_mode && seq_.enable_order_hint) {
      for (int i = 0; i < kNumRefFrames; i++) {
        uint32_t hint = b_.f(static_cast<int>(seq_.order_hint_bits), "ref_order_hint", i);
        if (hint != h_.ref_order_hint[i]) h_.ref_valid[i] = false;
      }
    }
  }
  if (h_.frame_is_intra) {
    if (!FrameSize()) return err_;
    RenderSize();
    if (h_.allow_screen_content_tools && h_.upscaled_width == h_.frame_width) {
      h_.allow_intrabc = b_.flag("allow_intrabc");
    }
  } else {
    h_.frame_refs_short_signaling = seq_.enable_order_hint ? b_.flag("frame_refs_short_signaling") : false;
    if (h_.frame_refs_short_signaling) {
      uint32_t last_frame_idx = b_.f(3, "last_frame_idx");
      uint32_t gold_frame_idx = b_.f(3, "gold_frame_idx");
      SetFrameRefs(last_frame_idx, gold_frame_idx);
    }
    for (int i = 0; i < kRefsPerFrame; i++) {
      if (!h_.frame_refs_short_signaling) h_.ref_frame_idx[i] = b_.f(3, "ref_frame_idx", i);
      if (seq_.frame_id_numbers_present_flag) {
        b_.f(static_cast<int>(seq_.delta_frame_id_length_minus_2 + 2), "delta_frame_id_minus_1", i);
      }
    }
    if (h_.frame_size_override_flag && !h_.error_resilient_mode) {
      if (!FrameSizeWithRefs()) return err_;
    } else {
      if (!FrameSize()) return err_;
      RenderSize();
    }
    if (!CheckRefSizes()) return ParseError::kBad;
    h_.allow_high_precision_mv = h_.force_integer_mv ? false : b_.flag("allow_high_precision_mv");
    h_.is_filter_switchable = b_.flag("is_filter_switchable");
    h_.interpolation_filter = h_.is_filter_switchable ? 4 : b_.f(2, "interpolation_filter");
    h_.is_motion_mode_switchable = b_.flag("is_motion_mode_switchable");
    if (h_.error_resilient_mode || !seq_.enable_ref_frame_mvs) {
      h_.use_ref_frame_mvs = false;
    } else {
      h_.use_ref_frame_mvs = b_.flag("use_ref_frame_mvs");
    }
  }
  if (seq_.reduced_still_picture_header || h_.disable_cdf_update) {
    h_.disable_frame_end_update_cdf = true;
  } else {
    h_.disable_frame_end_update_cdf = b_.flag("disable_frame_end_update_cdf");
  }
  if (h_.primary_ref_frame == kPrimaryRefNone) {
    h_.carried = CarriedParams{};
    DefaultGmParams(prev_gm_);
    h_.loop_filter_delta_enabled = true;
  } else {
    const RefSlot& prev = refs_[h_.ref_frame_idx[h_.primary_ref_frame]];
    memcpy(prev_gm_, prev.carried.gm_params, sizeof(prev_gm_));
    h_.carried = prev.carried;
  }
  TileInfo();
  if (err_ != ParseError::kNone) return err_;
  QuantizationParams();
  SegmentationParams();
  DeltaQParams();
  DeltaLfParams();
  h_.coded_lossless = true;
  for (int seg = 0; seg < kMaxSegments; seg++) {
    bool lossless = GetQIndexIgnoringDelta(seg) == 0 && h_.delta_q_y_dc == 0 && h_.delta_q_u_ac == 0 &&
                    h_.delta_q_u_dc == 0 && h_.delta_q_v_ac == 0 && h_.delta_q_v_dc == 0;
    if (!lossless) h_.coded_lossless = false;
  }
  h_.all_lossless = h_.coded_lossless && h_.frame_width == h_.upscaled_width;
  LoopFilterParams();
  CdefParams();
  LrParams();
  ReadTxMode();
  h_.reference_select = h_.frame_is_intra ? false : b_.flag("reference_select");
  SkipModeParams();
  if (h_.frame_is_intra || h_.error_resilient_mode || !seq_.enable_warped_motion) {
    h_.allow_warped_motion = false;
  } else {
    h_.allow_warped_motion = b_.flag("allow_warped_motion");
  }
  h_.reduced_tx_set = b_.flag("reduced_tx_set");
  GlobalMotionParams();
  FilmGrainParams();
  if (err_ != ParseError::kNone) return err_;
  if (frame_obu) b_.ByteAlign();
  h_.header_bits = b_.BitPos();
  if (b_.overrun()) return ParseError::kBad;
  return ParseError::kNone;
}

// parse the color config
void ParseColorConfig(Bits& b, SequenceHeader& s) {
  bool high_bitdepth = b.flag("high_bitdepth");
  if (s.seq_profile == 2 && high_bitdepth) {
    s.bit_depth = b.flag("twelve_bit") ? 12 : 10;
  } else {
    s.bit_depth = high_bitdepth ? 10 : 8;
  }
  s.mono_chrome = s.seq_profile == 1 ? false : b.flag("mono_chrome");
  if (b.flag("color_description_present_flag")) {
    s.color_primaries = b.f(8, "color_primaries");
    s.transfer_characteristics = b.f(8, "transfer_characteristics");
    s.matrix_coefficients = b.f(8, "matrix_coefficients");
  } else {
    s.color_primaries = 2;
    s.transfer_characteristics = 2;
    s.matrix_coefficients = 2;
  }
  s.chroma_sample_position = 0;
  if (s.mono_chrome) {
    s.color_range = b.flag("color_range");
    s.subsampling_x = s.subsampling_y = true;
    s.separate_uv_delta_q = false;
    return;
  }
  if (s.color_primaries == 1 && s.transfer_characteristics == 13 && s.matrix_coefficients == 0) {
    s.color_range = true;
    s.subsampling_x = s.subsampling_y = false;
  } else {
    s.color_range = b.flag("color_range");
    if (s.seq_profile == 0) {
      s.subsampling_x = s.subsampling_y = true;
    } else if (s.seq_profile == 1) {
      s.subsampling_x = s.subsampling_y = false;
    } else if (s.bit_depth == 12) {
      s.subsampling_x = b.flag("subsampling_x");
      s.subsampling_y = s.subsampling_x ? b.flag("subsampling_y") : false;
    } else {
      s.subsampling_x = true;
      s.subsampling_y = false;
    }
    if (s.subsampling_x && s.subsampling_y) s.chroma_sample_position = b.f(2, "chroma_sample_position");
  }
  s.separate_uv_delta_q = b.flag("separate_uv_delta_q");
}

}

bool ObuReader::Next(Obu* obu) {
  if (error_ || pos_ >= size_) return false;
  size_t start = pos_;
  uint8_t h = data_[pos_++];
  obu->offset = start;
  obu->type = (h >> 3) & 15;
  obu->has_extension = (h >> 2) & 1;
  bool has_size = (h >> 1) & 1;
  if (trace_) {
    trace_->Section("obu_header");
    trace_->Element(0, 1, "obu_forbidden_bit", -1, -1, h >> 7);
    trace_->Element(1, 4, "obu_type", -1, -1, obu->type);
    trace_->Element(5, 1, "obu_extension_flag", -1, -1, obu->has_extension);
    trace_->Element(6, 1, "obu_has_size_field", -1, -1, has_size);
    trace_->Element(7, 1, "obu_reserved_1bit", -1, -1, h & 1);
  }
  if (h & 0x80) {
    error_ = true;
    return false;
  }
  obu->temporal_id = 0;
  obu->spatial_id = 0;
  if (obu->has_extension) {
    if (pos_ >= size_) {
      error_ = true;
      return false;
    }
    uint8_t e = data_[pos_++];
    obu->temporal_id = e >> 5;
    obu->spatial_id = (e >> 3) & 3;
    if (trace_) {
      trace_->Element(8, 3, "temporal_id", -1, -1, obu->temporal_id);
      trace_->Element(11, 2, "spatial_id", -1, -1, obu->spatial_id);
      trace_->Element(13, 3, "extension_header_reserved_3bits", -1, -1, e & 7);
    }
  }
  uint64_t obu_size;
  if (has_size) {
    size_t size_pos = pos_;
    obu_size = 0;
    bool done = false;
    for (int i = 0; i < 8 && pos_ < size_; i++) {
      uint8_t byte = data_[pos_++];
      obu_size |= static_cast<uint64_t>(byte & 0x7f) << (i * 7);
      if (!(byte & 0x80)) {
        done = true;
        break;
      }
    }
    if (!done || obu_size > size_ - pos_) {
      error_ = true;
      return false;
    }
    if (trace_) {
      trace_->Element((size_pos - start) * 8, static_cast<int>((pos_ - size_pos) * 8), "obu_size", -1, -1,
                      static_cast<int64_t>(obu_size));
    }
  } else {
    obu_size = size_ - pos_;
  }
  obu->header_bytes = pos_ - start;
  obu->payload = data_ + pos_;
  obu->payload_size = static_cast<size_t>(obu_size);
  pos_ += static_cast<size_t>(obu_size);
  return true;
}

ParseError ParseSequenceHeader(const uint8_t* data, size_t size, size_t base_bits, Trace* trace,
                               SequenceHeader* seq) {
  Bits b(data, size, base_bits, trace);
  if (trace) trace->Section("sequence_header");
  SequenceHeader s;
  s.seq_profile = b.f(3, "seq_profile");
  s.still_picture = b.flag("still_picture");
  s.reduced_still_picture_header = b.flag("reduced_still_picture_header");
  uint32_t buffer_delay_length_minus_1 = 0;
  if (s.reduced_still_picture_header) {
    s.operating_points_cnt_minus_1 = 0;
    s.operating_point_idc[0] = 0;
    s.seq_level_idx[0] = b.f(5, "seq_level_idx", 0);
  } else {
    s.timing_info_present_flag = b.flag("timing_info_present_flag");
    if (s.timing_info_present_flag) {
      b.f(32, "num_units_in_display_tick");
      b.f(32, "time_scale");
      s.equal_picture_interval = b.flag("equal_picture_interval");
      if (s.equal_picture_interval) b.uvlc("num_ticks_per_picture_minus_1");
      s.decoder_model_info_present_flag = b.flag("decoder_model_info_present_flag");
      if (s.decoder_model_info_present_flag) {
        buffer_delay_length_minus_1 = b.f(5, "buffer_delay_length_minus_1");
        b.f(32, "num_units_in_decoding_tick");
        s.buffer_removal_time_length_minus_1 = b.f(5, "buffer_removal_time_length_minus_1");
        s.frame_presentation_time_length_minus_1 = b.f(5, "frame_presentation_time_length_minus_1");
      }
    }
    s.initial_display_delay_present_flag = b.flag("initial_display_delay_present_flag");
    s.operating_points_cnt_minus_1 = b.f(5, "operating_points_cnt_minus_1");
    for (uint32_t i = 0; i <= s.operating_points_cnt_minus_1; i++) {
      int ii = static_cast<int>(i);
      s.operating_point_idc[i] = b.f(12, "operating_point_idc", ii);
      s.seq_level_idx[i] = b.f(5, "seq_level_idx", ii);
      s.seq_tier[i] = s.seq_level_idx[i] > 7 ? b.f(1, "seq_tier", ii) : 0;
      if (s.decoder_model_info_present_flag) {
        s.decoder_model_present_for_this_op[i] = b.flag("decoder_model_present_for_this_op", ii);
        if (s.decoder_model_present_for_this_op[i]) {
          int n = static_cast<int>(buffer_delay_length_minus_1 + 1);
          b.f(n, "decoder_buffer_delay", ii);
          b.f(n, "encoder_buffer_delay", ii);
          b.f(1, "low_delay_mode_flag", ii);
        }
      }
      if (s.initial_display_delay_present_flag) {
        if (b.flag("initial_display_delay_present_for_this_op", ii)) b.f(4, "initial_display_delay_minus_1", ii);
      }
    }
  }
  s.operating_point = 0;
  s.operating_point_idc_sel = s.operating_point_idc[0];
  s.frame_width_bits_minus_1 = b.f(4, "frame_width_bits_minus_1");
  s.frame_height_bits_minus_1 = b.f(4, "frame_height_bits_minus_1");
  s.max_frame_width_minus_1 = b.f(static_cast<int>(s.frame_width_bits_minus_1 + 1), "max_frame_width_minus_1");
  s.max_frame_height_minus_1 = b.f(static_cast<int>(s.frame_height_bits_minus_1 + 1), "max_frame_height_minus_1");
  s.frame_id_numbers_present_flag = s.reduced_still_picture_header ? false : b.flag("frame_id_numbers_present_flag");
  if (s.frame_id_numbers_present_flag) {
    s.delta_frame_id_length_minus_2 = b.f(4, "delta_frame_id_length_minus_2");
    s.additional_frame_id_length_minus_1 = b.f(3, "additional_frame_id_length_minus_1");
  }
  s.use_128x128_superblock = b.flag("use_128x128_superblock");
  s.enable_filter_intra = b.flag("enable_filter_intra");
  s.enable_intra_edge_filter = b.flag("enable_intra_edge_filter");
  if (s.reduced_still_picture_header) {
    s.seq_force_screen_content_tools = kSelectScreenContentTools;
    s.seq_force_integer_mv = kSelectIntegerMv;
    s.order_hint_bits = 0;
  } else {
    s.enable_interintra_compound = b.flag("enable_interintra_compound");
    s.enable_masked_compound = b.flag("enable_masked_compound");
    s.enable_warped_motion = b.flag("enable_warped_motion");
    s.enable_dual_filter = b.flag("enable_dual_filter");
    s.enable_order_hint = b.flag("enable_order_hint");
    if (s.enable_order_hint) {
      s.enable_jnt_comp = b.flag("enable_jnt_comp");
      s.enable_ref_frame_mvs = b.flag("enable_ref_frame_mvs");
    }
    if (b.flag("seq_choose_screen_content_tools")) {
      s.seq_force_screen_content_tools = kSelectScreenContentTools;
    } else {
      s.seq_force_screen_content_tools = b.f(1, "seq_force_screen_content_tools");
    }
    if (s.seq_force_screen_content_tools > 0) {
      if (b.flag("seq_choose_integer_mv")) {
        s.seq_force_integer_mv = kSelectIntegerMv;
      } else {
        s.seq_force_integer_mv = b.f(1, "seq_force_integer_mv");
      }
    } else {
      s.seq_force_integer_mv = kSelectIntegerMv;
    }
    s.order_hint_bits = s.enable_order_hint ? b.f(3, "order_hint_bits_minus_1") + 1 : 0;
  }
  s.enable_superres = b.flag("enable_superres");
  s.enable_cdef = b.flag("enable_cdef");
  s.enable_restoration = b.flag("enable_restoration");
  ParseColorConfig(b, s);
  s.film_grain_params_present = b.flag("film_grain_params_present");
  if (b.overrun()) return ParseError::kBad;
  if (s.frame_id_numbers_present_flag &&
      s.additional_frame_id_length_minus_1 + s.delta_frame_id_length_minus_2 + 3 > 16) {
    return ParseError::kBad;
  }
  if (s.seq_profile > 2) return ParseError::kBad;
  if (s.seq_profile != 0 || s.bit_depth > 10 || !s.subsampling_x || !s.subsampling_y) {
    *seq = s;
    return ParseError::kUnsupported;
  }
  *seq = s;
  return ParseError::kNone;
}

bool InOperatingPoint(const SequenceHeader& seq, const Obu& obu) {
  if (obu.type == kObuSequenceHeader || obu.type == kObuTemporalDelimiter) return true;
  if (seq.operating_point_idc_sel == 0 || !obu.has_extension) return true;
  bool in_temporal = (seq.operating_point_idc_sel >> obu.temporal_id) & 1;
  bool in_spatial = (seq.operating_point_idc_sel >> (obu.spatial_id + 8)) & 1;
  return in_temporal && in_spatial;
}

ParseError ParseFrameHeader(const SequenceHeader& seq, const RefSlot refs[kNumRefFrames], const Obu& obu,
                            const uint8_t* data, size_t size, size_t base_bits, Trace* trace, FrameHeader* fh) {
  Bits b(data, size, base_bits, trace);
  if (trace) trace->Section("frame_header");
  FrameHeader h;
  HeaderParser p(seq, refs, b, &h);
  ParseError e = p.Run(obu, obu.type == kObuFrame);
  if (e != ParseError::kNone) return e;
  *fh = h;
  return ParseError::kNone;
}

ParseError ParseTileGroup(const FrameHeader& fh, const uint8_t* data, size_t size, size_t data_offset,
                          size_t base_bits, Trace* trace, uint32_t* next_tile, TileSpan* tiles, uint32_t max_tiles,
                          bool* last) {
  const TileInfo& t = fh.tile;
  uint32_t num_tiles = t.tile_cols * t.tile_rows;
  Bits b(data, size, base_bits, trace);
  if (trace) trace->Section("tile_group");
  bool start_and_end = num_tiles > 1 ? b.flag("tile_start_and_end_present_flag") : false;
  uint32_t tg_start = 0, tg_end = num_tiles - 1;
  if (num_tiles > 1 && start_and_end) {
    int tile_bits = static_cast<int>(t.tile_cols_log2 + t.tile_rows_log2);
    tg_start = b.f(tile_bits, "tg_start");
    tg_end = b.f(tile_bits, "tg_end");
  }
  b.ByteAlign();
  if (b.overrun()) return ParseError::kBad;
  if (tg_start != *next_tile || tg_end < tg_start || tg_end >= num_tiles) return ParseError::kBad;
  if (tg_end >= max_tiles) return ParseError::kUnsupported;
  size_t pos = b.BitPos() / 8;
  size_t sz = size - pos;
  for (uint32_t tile_num = tg_start; tile_num <= tg_end; tile_num++) {
    size_t tile_size;
    if (tile_num == tg_end) {
      tile_size = sz;
    } else {
      if (sz < t.tile_size_bytes) return ParseError::kBad;
      uint32_t minus_1 = 0;
      for (uint32_t k = 0; k < t.tile_size_bytes; k++) minus_1 |= static_cast<uint32_t>(data[pos + k]) << (8 * k);
      if (trace) {
        trace->Element(base_bits + pos * 8, static_cast<int>(8 * t.tile_size_bytes), "tile_size_minus_1",
                       static_cast<int>(tile_num), -1, minus_1);
      }
      pos += t.tile_size_bytes;
      sz -= t.tile_size_bytes;
      tile_size = static_cast<size_t>(minus_1) + 1;
      if (tile_size > sz) return ParseError::kBad;
    }
    if (tile_size == 0 || tile_size > UINT32_MAX) return ParseError::kBad;
    TileSpan& span = tiles[tile_num];
    span.offset = data_offset + pos;
    span.size = static_cast<uint32_t>(tile_size);
    span.row = static_cast<uint16_t>(tile_num / t.tile_cols);
    span.col = static_cast<uint16_t>(tile_num % t.tile_cols);
    span.tg_start = static_cast<uint16_t>(tg_start);
    span.tg_end = static_cast<uint16_t>(tg_end);
    pos += tile_size;
    sz -= tile_size;
  }
  *next_tile = tg_end + 1;
  *last = tg_end == num_tiles - 1;
  return ParseError::kNone;
}

RefSlot MakeRefSlot(const SequenceHeader& seq, const FrameHeader& fh) {
  RefSlot s;
  s.valid = true;
  s.frame_id = fh.current_frame_id;
  s.upscaled_width = fh.upscaled_width;
  s.frame_width = fh.frame_width;
  s.frame_height = fh.frame_height;
  s.render_width = fh.render_width;
  s.render_height = fh.render_height;
  s.mi_cols = fh.mi_cols;
  s.mi_rows = fh.mi_rows;
  s.frame_type = fh.frame_type;
  s.bit_depth = seq.bit_depth;
  s.order_hint = fh.order_hint;
  s.showable = fh.showable_frame;
  s.carried = fh.carried;
  if (seq.film_grain_params_present) s.grain = fh.grain;
  return s;
}

bool WarpValid(const int32_t p[6]) {
  constexpr int kReduceBits = 6;
  int64_t d = p[2];
  if (d <= 0) return false;
  int n = FloorLog2(static_cast<uint32_t>(d));
  int64_t e = d - (int64_t{1} << n);
  int64_t f = n > 8 ? Round2Signed(e, n - 8) : e << (8 - n);
  if (f < 0 || f > 256) return false;
  int div_shift = n + 14;
  int64_t div_factor = kDivLut[f];
  int64_t alpha0 = Clip3(-32768, 32767, static_cast<int32_t>(p[2] - (1 << kWarpedModelPrecBits)));
  int64_t beta0 = Clip3(-32768, 32767, p[3]);
  int64_t v = static_cast<int64_t>(p[4]) * (1 << kWarpedModelPrecBits);
  int64_t gamma0 = Round2Signed(v * div_factor, div_shift);
  gamma0 = gamma0 < -32768 ? -32768 : (gamma0 > 32767 ? 32767 : gamma0);
  int64_t w = static_cast<int64_t>(p[3]) * p[4];
  int64_t delta0 = p[5] - Round2Signed(w * div_factor, div_shift) - (1 << kWarpedModelPrecBits);
  delta0 = delta0 < -32768 ? -32768 : (delta0 > 32767 ? 32767 : delta0);
  auto reduce = [](int64_t x) { return Round2Signed(x, kReduceBits) * (1 << kReduceBits); };
  int64_t alpha = reduce(alpha0), beta = reduce(beta0), gamma = reduce(gamma0), delta = reduce(delta0);
  auto abs64 = [](int64_t x) { return x < 0 ? -x : x; };
  if (4 * abs64(alpha) + 7 * abs64(beta) >= (1 << kWarpedModelPrecBits)) return false;
  if (4 * abs64(gamma) + 4 * abs64(delta) >= (1 << kWarpedModelPrecBits)) return false;
  return true;
}

}

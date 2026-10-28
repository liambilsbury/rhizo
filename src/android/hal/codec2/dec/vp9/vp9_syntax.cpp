#include "vp9_syntax.h"

#include "../../common/bit_reader.h"
#include "vp9_quant_tables.h"

// the VP9 uncompressed header parse

namespace rhizo::c2va::vp9 {
namespace {

constexpr uint32_t kSyncCode = 0x498342;
constexpr uint32_t kCsBt601 = 1;
constexpr int kSegmentationFeatureBits[kSegLvlMax] = {8, 6, 2, 0};
constexpr bool kSegmentationFeatureSigned[kSegLvlMax] = {true, true, false, false};
constexpr uint32_t kLiteralToType[4] = {1, 0, 2, 3};
constexpr int kMinTileWidthB64 = 4;
constexpr int kMaxTileWidthB64 = 64;

int32_t Clip3(int32_t lo, int32_t hi, int32_t v) { return v < lo ? lo : v > hi ? hi : v; }

// read a signed s(n)
int32_t ReadSigned(BitReader& br, int n) {
  const int32_t v = static_cast<int32_t>(br.U(n));
  return br.Flag() ? -v : v;
}

// read a probability
uint8_t ReadProb(BitReader& br) { return br.Flag() ? static_cast<uint8_t>(br.U(8)) : 255; }

// parse the color config
bool ReadColorConfig(BitReader& br, uint32_t profile, ColorConfig* c) {
  if (profile >= 2) {
    c->bit_depth = br.Flag() ? 12 : 10;
  } else {
    c->bit_depth = 8;
  }
  c->color_space = br.U(3);
  if (c->color_space != kCsRgb) {
    c->color_range = br.Flag();
    if (profile == 1 || profile == 3) {
      c->subsampling_x = br.Flag();
      c->subsampling_y = br.Flag();
      if (br.Flag()) return false;
      if (c->subsampling_x && c->subsampling_y) return false;
    } else {
      c->subsampling_x = true;
      c->subsampling_y = true;
    }
  } else {
    c->color_range = true;
    if (profile == 1 || profile == 3) {
      c->subsampling_x = false;
      c->subsampling_y = false;
      if (br.Flag()) return false;
    } else {
      return false;
    }
  }
  return true;
}

// read the frame size
void ReadFrameSize(BitReader& br, FrameHeader* h) {
  h->width = br.U(16) + 1;
  h->height = br.U(16) + 1;
}

// read the render size
void ReadRenderSize(BitReader& br, FrameHeader* h) {
  if (br.Flag()) {
    h->render_width = br.U(16) + 1;
    h->render_height = br.U(16) + 1;
  } else {
    h->render_width = h->width;
    h->render_height = h->height;
  }
}

// reset the header state for past independence
void SetupPastIndependence(ParseState* s) {
  for (int i = 0; i < kMaxSegments; i++) {
    for (int j = 0; j < kSegLvlMax; j++) {
      s->feature_enabled[i][j] = false;
      s->feature_data[i][j] = 0;
    }
  }
  s->abs_or_delta_update = false;
  s->lf_ref_deltas[0] = 1;
  s->lf_ref_deltas[1] = 0;
  s->lf_ref_deltas[2] = -1;
  s->lf_ref_deltas[3] = -1;
  s->lf_mode_deltas[0] = 0;
  s->lf_mode_deltas[1] = 0;
}

// parse the loop filter params
void ReadLoopFilterParams(BitReader& br, FrameHeader* h, ParseState* s) {
  h->loop_filter_level = br.U(6);
  h->loop_filter_sharpness = br.U(3);
  h->loop_filter_delta_enabled = br.Flag();
  h->loop_filter_delta_update = false;
  if (h->loop_filter_delta_enabled) {
    h->loop_filter_delta_update = br.Flag();
    if (h->loop_filter_delta_update) {
      for (int i = 0; i < 4; i++) {
        if (br.Flag()) s->lf_ref_deltas[i] = ReadSigned(br, 6);
      }
      for (int i = 0; i < 2; i++) {
        if (br.Flag()) s->lf_mode_deltas[i] = ReadSigned(br, 6);
      }
    }
  }
}

// read a delta q
int32_t ReadDeltaQ(BitReader& br) { return br.Flag() ? ReadSigned(br, 4) : 0; }

// parse the quantization params
void ReadQuantizationParams(BitReader& br, FrameHeader* h) {
  h->base_q_idx = br.U(8);
  h->delta_q_y_dc = ReadDeltaQ(br);
  h->delta_q_uv_dc = ReadDeltaQ(br);
  h->delta_q_uv_ac = ReadDeltaQ(br);
  h->lossless = h->base_q_idx == 0 && h->delta_q_y_dc == 0 && h->delta_q_uv_dc == 0 && h->delta_q_uv_ac == 0;
}

// parse the segmentation params
void ReadSegmentationParams(BitReader& br, FrameHeader* h, ParseState* s) {
  h->segmentation_enabled = br.Flag();
  h->segmentation_update_map = false;
  h->segmentation_temporal_update = false;
  h->segmentation_update_data = false;
  if (!h->segmentation_enabled) return;
  h->segmentation_update_map = br.Flag();
  if (h->segmentation_update_map) {
    for (int i = 0; i < 7; i++) s->tree_probs[i] = ReadProb(br);
    h->segmentation_temporal_update = br.Flag();
    for (int i = 0; i < 3; i++) s->pred_probs[i] = h->segmentation_temporal_update ? ReadProb(br) : 255;
  }
  h->segmentation_update_data = br.Flag();
  if (h->segmentation_update_data) {
    s->abs_or_delta_update = br.Flag();
    for (int i = 0; i < kMaxSegments; i++) {
      for (int j = 0; j < kSegLvlMax; j++) {
        int32_t value = 0;
        const bool enabled = br.Flag();
        s->feature_enabled[i][j] = enabled;
        if (enabled) {
          value = static_cast<int32_t>(br.U(kSegmentationFeatureBits[j]));
          if (kSegmentationFeatureSigned[j] && br.Flag()) value = -value;
        }
        s->feature_data[i][j] = value;
      }
    }
  }
}

// parse the tile info
bool ReadTileInfo(BitReader& br, FrameHeader* h) {
  const uint32_t mi_cols = (h->width + 7) >> 3;
  const uint32_t sb64_cols = (mi_cols + 7) >> 3;
  uint32_t min_log2 = 0;
  while ((static_cast<uint32_t>(kMaxTileWidthB64) << min_log2) < sb64_cols) min_log2++;
  uint32_t max_log2 = 1;
  while ((sb64_cols >> max_log2) >= static_cast<uint32_t>(kMinTileWidthB64)) max_log2++;
  max_log2--;
  h->tile_cols_log2 = min_log2;
  while (h->tile_cols_log2 < max_log2) {
    if (!br.Flag()) break;
    h->tile_cols_log2++;
  }
  h->tile_rows_log2 = br.U(1);
  if (h->tile_rows_log2) h->tile_rows_log2 += br.U(1);
  return h->tile_cols_log2 <= 6;
}

// return true when the tiles fit inside the frame
bool TilesFit(const uint8_t* data, size_t size, const FrameHeader& h) {
  size_t pos = static_cast<size_t>(h.uncompressed_header_size) + h.header_size_in_bytes;
  if (pos > size) return false;
  const uint32_t tiles = (1u << h.tile_cols_log2) * (1u << h.tile_rows_log2);
  for (uint32_t t = 0; t + 1 < tiles; t++) {
    if (size - pos < 4) return false;
    const uint32_t tile_size = (static_cast<uint32_t>(data[pos]) << 24) | (static_cast<uint32_t>(data[pos + 1]) << 16) |
                               (static_cast<uint32_t>(data[pos + 2]) << 8) | data[pos + 3];
    pos += 4;
    if (tile_size > size - pos) return false;
    pos += tile_size;
  }
  return size - pos >= 1;
}

// return true when a reference is within the scaling range
bool ScalingOk(const FrameHeader& h, const ParseState& s) {
  for (int i = 0; i < 3; i++) {
    const RefInfo& r = s.refs[h.ref_frame_idx[i]];
    const uint64_t w = h.width, ht = h.height, rw = r.width, rh = r.height;
    if (2 * w >= rw && 2 * ht >= rh && w <= 16 * rw && ht <= 16 * rh) return true;
  }
  return false;
}

}

bool SplitSuperframe(const uint8_t* data, size_t size, FrameSpan frames[kMaxSuperframeFrames], int* count) {
  *count = 0;
  if (size == 0) return true;
  const uint8_t last = data[size - 1];
  if ((last & 0xe0) == 0xc0) {
    const size_t sz_bytes = ((last >> 3) & 3) + 1;
    const size_t num_frames = (last & 7) + 1;
    const size_t index_size = 2 + num_frames * sz_bytes;
    if (size >= index_size && data[size - index_size] == last) {
      const uint8_t* p = data + size - index_size + 1;
      const size_t avail = size - index_size;
      size_t offset = 0;
      for (size_t i = 0; i < num_frames; i++) {
        size_t frame_size = 0;
        for (size_t b = 0; b < sz_bytes; b++) frame_size |= static_cast<size_t>(*p++) << (8 * b);
        if (frame_size > avail - offset) return false;
        if (frame_size > 0) frames[(*count)++] = {data + offset, frame_size};
        offset += frame_size;
      }
      return true;
    }
  }
  frames[(*count)++] = {data, size};
  return true;
}

Parse ParseFrame(const uint8_t* data, size_t size, ParseState* s, FrameHeader* h) {
  *h = FrameHeader();
  BitReader br(data, size);
  if (br.U(2) != 2) return Parse::kBad;
  const uint32_t profile_low_bit = br.U(1);
  const uint32_t profile_high_bit = br.U(1);
  h->profile = (profile_high_bit << 1) + profile_low_bit;
  if (h->profile == 3 && br.Flag()) return Parse::kBad;
  h->show_existing_frame = br.Flag();
  if (h->show_existing_frame) {
    h->frame_to_show_map_idx = br.U(3);
    br.ByteAlign();
    h->uncompressed_header_size = static_cast<uint32_t>(br.BitPos() / 8);
    if (br.overrun()) return Parse::kBad;
    if (!s->refs[h->frame_to_show_map_idx].valid) return Parse::kBad;
    h->color = s->refs[h->frame_to_show_map_idx].color;
    h->width = s->refs[h->frame_to_show_map_idx].width;
    h->height = s->refs[h->frame_to_show_map_idx].height;
    return Parse::kOk;
  }
  h->frame_type = br.U(1);
  h->show_frame = br.Flag();
  h->error_resilient_mode = br.Flag();
  if (h->frame_type == kKeyFrame) {
    if (br.U(24) != kSyncCode) return Parse::kBad;
    ColorConfig c;
    if (!ReadColorConfig(br, h->profile, &c)) return Parse::kBad;
    s->color = c;
    ReadFrameSize(br, h);
    ReadRenderSize(br, h);
    h->refresh_frame_flags = 0xff;
  } else {
    h->intra_only = h->show_frame ? false : br.Flag();
    h->reset_frame_context = h->error_resilient_mode ? 0 : br.U(2);
    if (h->intra_only) {
      if (br.U(24) != kSyncCode) return Parse::kBad;
      ColorConfig c = s->color;
      if (h->profile > 0) {
        if (!ReadColorConfig(br, h->profile, &c)) return Parse::kBad;
      } else {
        c.color_space = kCsBt601;
        c.subsampling_x = true;
        c.subsampling_y = true;
        c.bit_depth = 8;
      }
      s->color = c;
      h->refresh_frame_flags = br.U(8);
      ReadFrameSize(br, h);
      ReadRenderSize(br, h);
    } else {
      h->refresh_frame_flags = br.U(8);
      for (int i = 0; i < 3; i++) {
        h->ref_frame_idx[i] = br.U(3);
        h->ref_frame_sign_bias[i] = br.Flag();
      }
      if (br.overrun()) return Parse::kBad;
      for (int i = 0; i < 3; i++) {
        if (!s->refs[h->ref_frame_idx[i]].valid) return Parse::kBad;
      }
      bool found_ref = false;
      for (int i = 0; i < 3; i++) {
        found_ref = br.Flag();
        if (found_ref) {
          h->width = s->refs[h->ref_frame_idx[i]].width;
          h->height = s->refs[h->ref_frame_idx[i]].height;
          break;
        }
      }
      if (!found_ref) ReadFrameSize(br, h);
      ReadRenderSize(br, h);
      h->allow_high_precision_mv = br.Flag();
      h->interpolation_filter = br.Flag() ? 4 : kLiteralToType[br.U(2)];
      for (int i = 0; i < 3; i++) {
        const RefInfo& r = s->refs[h->ref_frame_idx[i]];
        if (r.profile != h->profile || r.color.bit_depth != s->color.bit_depth ||
            r.color.subsampling_x != s->color.subsampling_x || r.color.subsampling_y != s->color.subsampling_y) {
          return Parse::kBad;
        }
      }
      if (!ScalingOk(*h, *s)) return Parse::kBad;
    }
  }
  h->color = s->color;
  if (!h->error_resilient_mode) {
    h->refresh_frame_context = br.Flag();
    h->frame_parallel_decoding_mode = br.Flag();
  } else {
    h->refresh_frame_context = false;
    h->frame_parallel_decoding_mode = true;
  }
  h->frame_context_idx = br.U(2);
  if (h->frame_is_intra() || h->error_resilient_mode) SetupPastIndependence(s);
  ReadLoopFilterParams(br, h, s);
  ReadQuantizationParams(br, h);
  ReadSegmentationParams(br, h, s);
  if (!ReadTileInfo(br, h)) return Parse::kBad;
  h->header_size_in_bytes = br.U(16);
  br.ByteAlign();
  if (br.overrun()) return Parse::kBad;
  h->uncompressed_header_size = static_cast<uint32_t>(br.BitPos() / 8);
  if (h->header_size_in_bytes == 0) return Parse::kBad;
  if (!TilesFit(data, size, *h)) return Parse::kBad;
  return Parse::kOk;
}

void ApplyRefreshes(const FrameHeader& h, ParseState* s) {
  if (h.show_existing_frame) return;
  for (int i = 0; i < kNumRefFrames; i++) {
    if (!((h.refresh_frame_flags >> i) & 1)) continue;
    RefInfo& r = s->refs[i];
    r.valid = true;
    r.width = h.width;
    r.height = h.height;
    r.profile = h.profile;
    r.color = h.color;
  }
}

bool FeatureActive(const FrameHeader& h, const ParseState& s, int segment, int feature) {
  return h.segmentation_enabled && s.feature_enabled[segment][feature];
}

void LoopFilterLevels(const FrameHeader& h, const ParseState& s, int segment, uint8_t out[4][2]) {
  const int32_t level = static_cast<int32_t>(h.loop_filter_level);
  int32_t lvl_seg = level;
  if (FeatureActive(h, s, segment, kSegLvlAltL)) {
    lvl_seg = s.feature_data[segment][kSegLvlAltL];
    if (!s.abs_or_delta_update) lvl_seg += level;
    lvl_seg = Clip3(0, kMaxLoopFilter, lvl_seg);
  }
  // the spec's loop_filter_delta_update in 8.8.1 step 3 reads as loop_filter_delta_enabled
  if (!h.loop_filter_delta_enabled) {
    for (int ref = 0; ref < 4; ref++) out[ref][0] = out[ref][1] = static_cast<uint8_t>(lvl_seg);
    return;
  }
  const int32_t scale = 1 << (level >> 5);
  const int32_t intra = Clip3(0, kMaxLoopFilter, lvl_seg + s.lf_ref_deltas[0] * scale);
  out[0][0] = out[0][1] = static_cast<uint8_t>(intra);
  for (int ref = 1; ref < 4; ref++) {
    for (int mode = 0; mode < 2; mode++) {
      const int32_t inter = lvl_seg + s.lf_ref_deltas[ref] * scale + s.lf_mode_deltas[mode] * scale;
      out[ref][mode] = static_cast<uint8_t>(Clip3(0, kMaxLoopFilter, inter));
    }
  }
}

int32_t SegmentQIndex(const FrameHeader& h, const ParseState& s, int segment) {
  if (FeatureActive(h, s, segment, kSegLvlAltQ)) {
    int32_t data = s.feature_data[segment][kSegLvlAltQ];
    if (!s.abs_or_delta_update) data += static_cast<int32_t>(h.base_q_idx);
    return Clip3(0, 255, data);
  }
  return static_cast<int32_t>(h.base_q_idx);
}

int32_t DcQ(uint32_t bit_depth, int32_t b) {
  const uint32_t row = bit_depth >= 12 ? 2 : bit_depth >= 10 ? 1 : 0;
  return kDcQLookup[row][Clip3(0, 255, b)];
}

int32_t AcQ(uint32_t bit_depth, int32_t b) {
  const uint32_t row = bit_depth >= 12 ? 2 : bit_depth >= 10 ? 1 : 0;
  return kAcQLookup[row][Clip3(0, 255, b)];
}

}

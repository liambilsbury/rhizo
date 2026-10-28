// the VP9 decoder core on VA

#include <string.h>

#include <va/va.h>
#include <va/va_dec_vp9.h>

#include "../../va/core.h"
#include "vp9_syntax.h"

namespace rhizo::c2va {
namespace {

constexpr uint32_t kMinSurfaces = vp9::kNumRefFrames + 1;
constexpr uint32_t kAllSlots = (1u << vp9::kNumRefFrames) - 1;

uint32_t Align8(uint32_t v) { return (v + 7) & ~7u; }

// map a VP9 color space to colour code points
ColorInfo MapColor(const vp9::ColorConfig& c) {
  ColorInfo out;
  out.full_range = c.color_range;
  switch (c.color_space) {
    case 1:
      out.transfer = 6;
      out.matrix = 6;
      break;
    case 2:
      out.primaries = 1;
      out.transfer = 1;
      out.matrix = 1;
      break;
    case 3:
      out.primaries = 6;
      out.transfer = 6;
      out.matrix = 6;
      break;
    case 4:
      out.primaries = 7;
      out.transfer = 7;
      out.matrix = 7;
      break;
    case 5:
      out.primaries = 9;
      out.matrix = 9;
      break;
    case vp9::kCsRgb:
      out.matrix = 0;
      break;
    default:
      break;
  }
  return out;
}

class Vp9Decoder : public DecoderCore {
 public:
  explicit Vp9Decoder(DecoderHost* host) : host_(host) {
    for (VASurfaceID& s : slots_) s = VA_INVALID_SURFACE;
  }
  ~Vp9Decoder() override { ClearSlots(kAllSlots, nullptr); }

  Status Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) override;
  Status Drain() override { return Status::kOk; }
  void Reset() override;

 private:
  Status DecodeFrame(const vp9::FrameSpan& frame, const vp9::FrameHeader& h, vp9::ParseState* next, bool output,
                     uint64_t tag);
  Status DecodeNewFrame(const vp9::FrameSpan& frame, const vp9::FrameHeader& h, vp9::ParseState* next, bool output,
                        uint64_t tag);
  Status PrepareContext(const vp9::FrameHeader& h, vp9::ParseState* next);
  Status Submit(const vp9::FrameSpan& frame, const vp9::FrameHeader& h, const vp9::ParseState& next,
                VASurfaceID target);
  void SetSlots(uint32_t mask, VASurfaceID surface, VASurfaceID keep);
  void ClearSlots(uint32_t mask, vp9::ParseState* state);
  void ReleaseOrphans(const VASurfaceID (&before)[vp9::kNumRefFrames], VASurfaceID keep);
  bool InSlots(VASurfaceID s) const;

  DecoderHost* host_;
  vp9::ParseState state_;
  VASurfaceID slots_[vp9::kNumRefFrames];
  bool configured_ = false;
  StreamInfo info_{};
  uint32_t surface_width_ = 0;
  uint32_t surface_height_ = 0;
  VAContextID context_ = VA_INVALID_ID;
};

bool Vp9Decoder::InSlots(VASurfaceID s) const {
  for (VASurfaceID x : slots_) {
    if (x == s) return true;
  }
  return false;
}

// release the surfaces from before that no slot holds now
void Vp9Decoder::ReleaseOrphans(const VASurfaceID (&before)[vp9::kNumRefFrames], VASurfaceID keep) {
  for (int i = 0; i < vp9::kNumRefFrames; i++) {
    const VASurfaceID s = before[i];
    if (s == VA_INVALID_SURFACE || s == keep || InSlots(s)) continue;
    bool seen = false;
    for (int j = 0; j < i; j++) seen = seen || before[j] == s;
    if (!seen) host_->ReleaseSurface(s);
  }
}

// point the slots in mask at a surface
void Vp9Decoder::SetSlots(uint32_t mask, VASurfaceID surface, VASurfaceID keep) {
  VASurfaceID before[vp9::kNumRefFrames];
  memcpy(before, slots_, sizeof(before));
  for (int i = 0; i < vp9::kNumRefFrames; i++) {
    if ((mask >> i) & 1) slots_[i] = surface;
  }
  ReleaseOrphans(before, keep);
}

// empty the slots in mask and mark them invalid in state
void Vp9Decoder::ClearSlots(uint32_t mask, vp9::ParseState* state) {
  SetSlots(mask, VA_INVALID_SURFACE, VA_INVALID_SURFACE);
  if (!state) return;
  for (int i = 0; i < vp9::kNumRefFrames; i++) {
    if ((mask >> i) & 1) state->refs[i].valid = false;
  }
}

void Vp9Decoder::Reset() {
  ClearSlots(kAllSlots, nullptr);
  state_ = vp9::ParseState();
}

// configure the VA context when a frame needs new surfaces
Status Vp9Decoder::PrepareContext(const vp9::FrameHeader& h, vp9::ParseState* next) {
  StreamInfo want{};
  want.profile = h.profile == 2 ? VAProfileVP9Profile2 : VAProfileVP9Profile0;
  want.rt_format = h.color.bit_depth == 10 ? VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420;
  want.coded_width = Align8(h.width);
  want.coded_height = Align8(h.height);
  want.visible = {0, 0, h.width, h.height};
  want.bit_depth = h.color.bit_depth;
  want.min_surfaces = kMinSurfaces;
  want.reorder_depth = 0;
  want.color = MapColor(h.color);

  const bool replaces_all = h.frame_is_intra() && h.refresh_frame_flags == kAllSlots;
  if (!configured_ && !h.frame_is_intra()) return Status::kBadStream;
  if (configured_) {
    const bool same_format = want.profile == info_.profile && want.rt_format == info_.rt_format &&
                             want.min_surfaces == info_.min_surfaces;
    const bool fits = want.coded_width <= surface_width_ && want.coded_height <= surface_height_;
    if (same_format && fits) return Status::kOk;
    if (!replaces_all) return Status::kUnsupported;
  }
  ClearSlots(kAllSlots, next);
  configured_ = false;
  context_ = VA_INVALID_ID;
  const Status st = host_->Configure(want, &context_);
  if (st != Status::kOk) return st;
  host_->SurfaceSize(&surface_width_, &surface_height_);
  if (want.coded_width > surface_width_ || want.coded_height > surface_height_) return Status::kVaError;
  configured_ = true;
  info_ = want;
  return Status::kOk;
}

Status Vp9Decoder::Submit(const vp9::FrameSpan& frame, const vp9::FrameHeader& h, const vp9::ParseState& next,
                          VASurfaceID target) {
  VADecPictureParameterBufferVP9 pic;
  memset(&pic, 0, sizeof(pic));
  pic.frame_width = static_cast<uint16_t>(h.width);
  pic.frame_height = static_cast<uint16_t>(h.height);
  for (int i = 0; i < vp9::kNumRefFrames; i++) {
    pic.reference_frames[i] = h.frame_type == vp9::kKeyFrame ? VA_INVALID_SURFACE : slots_[i];
  }
  auto& b = pic.pic_fields.bits;
  b.subsampling_x = h.color.subsampling_x;
  b.subsampling_y = h.color.subsampling_y;
  b.frame_type = h.frame_type;
  b.show_frame = h.show_frame;
  b.error_resilient_mode = h.error_resilient_mode;
  b.intra_only = h.intra_only;
  b.allow_high_precision_mv = h.allow_high_precision_mv;
  b.mcomp_filter_type = h.frame_is_intra() ? 0 : h.interpolation_filter;
  b.frame_parallel_decoding_mode = h.frame_parallel_decoding_mode;
  b.reset_frame_context = h.reset_frame_context;
  b.refresh_frame_context = h.refresh_frame_context;
  // radeonsi, radv and anv reset frame_context_idx themselves
  b.frame_context_idx = h.frame_context_idx;
  b.segmentation_enabled = h.segmentation_enabled;
  b.segmentation_temporal_update = h.segmentation_temporal_update;
  b.segmentation_update_map = h.segmentation_update_map;
  if (!h.frame_is_intra()) {
    b.last_ref_frame = h.ref_frame_idx[0];
    b.last_ref_frame_sign_bias = h.ref_frame_sign_bias[0];
    b.golden_ref_frame = h.ref_frame_idx[1];
    b.golden_ref_frame_sign_bias = h.ref_frame_sign_bias[1];
    b.alt_ref_frame = h.ref_frame_idx[2];
    b.alt_ref_frame_sign_bias = h.ref_frame_sign_bias[2];
  }
  b.lossless_flag = h.lossless;
  pic.filter_level = static_cast<uint8_t>(h.loop_filter_level);
  pic.sharpness_level = static_cast<uint8_t>(h.loop_filter_sharpness);
  pic.log2_tile_rows = static_cast<uint8_t>(h.tile_rows_log2);
  pic.log2_tile_columns = static_cast<uint8_t>(h.tile_cols_log2);
  pic.frame_header_length_in_bytes = static_cast<uint8_t>(h.uncompressed_header_size);
  pic.first_partition_size = static_cast<uint16_t>(h.header_size_in_bytes);
  memcpy(pic.mb_segment_tree_probs, next.tree_probs, sizeof(pic.mb_segment_tree_probs));
  memcpy(pic.segment_pred_probs, next.pred_probs, sizeof(pic.segment_pred_probs));
  pic.profile = static_cast<uint8_t>(h.profile);
  pic.bit_depth = static_cast<uint8_t>(h.color.bit_depth);

  VASliceParameterBufferVP9 slice;
  memset(&slice, 0, sizeof(slice));
  slice.slice_data_size = static_cast<uint32_t>(frame.size);
  slice.slice_data_offset = 0;
  slice.slice_data_flag = VA_SLICE_DATA_FLAG_ALL;
  const int segments = h.segmentation_enabled ? vp9::kMaxSegments : 1;
  const uint32_t bd = h.color.bit_depth;
  for (int s = 0; s < segments; s++) {
    VASegmentParameterVP9& seg = slice.seg_param[s];
    seg.segment_flags.fields.segment_reference_enabled = vp9::FeatureActive(h, next, s, vp9::kSegLvlRefFrame);
    seg.segment_flags.fields.segment_reference = next.feature_data[s][vp9::kSegLvlRefFrame] & 3;
    seg.segment_flags.fields.segment_reference_skipped = vp9::FeatureActive(h, next, s, vp9::kSegLvlSkip);
    vp9::LoopFilterLevels(h, next, s, seg.filter_level);
    const int32_t q = vp9::SegmentQIndex(h, next, s);
    seg.luma_ac_quant_scale = static_cast<int16_t>(vp9::AcQ(bd, q));
    seg.luma_dc_quant_scale = static_cast<int16_t>(vp9::DcQ(bd, q + h.delta_q_y_dc));
    seg.chroma_ac_quant_scale = static_cast<int16_t>(vp9::AcQ(bd, q + h.delta_q_uv_ac));
    seg.chroma_dc_quant_scale = static_cast<int16_t>(vp9::DcQ(bd, q + h.delta_q_uv_dc));
  }

  VADisplay dpy = host_->display();
  VABufferID bufs[3] = {VA_INVALID_ID, VA_INVALID_ID, VA_INVALID_ID};
  VAStatus va = vaCreateBuffer(dpy, context_, VAPictureParameterBufferType, sizeof(pic), 1, &pic, &bufs[0]);
  if (va == VA_STATUS_SUCCESS) {
    va = vaCreateBuffer(dpy, context_, VASliceParameterBufferType, sizeof(slice), 1, &slice, &bufs[1]);
  }
  if (va == VA_STATUS_SUCCESS) {
    va = vaCreateBuffer(dpy, context_, VASliceDataBufferType, static_cast<unsigned int>(frame.size), 1,
                        const_cast<uint8_t*>(frame.data), &bufs[2]);
  }
  if (va == VA_STATUS_SUCCESS) {
    va = vaBeginPicture(dpy, context_, target);
    if (va == VA_STATUS_SUCCESS) {
      va = vaRenderPicture(dpy, context_, bufs, 3);
      const VAStatus end = vaEndPicture(dpy, context_);
      if (va == VA_STATUS_SUCCESS) va = end;
    }
  }
  for (VABufferID id : bufs) {
    if (id != VA_INVALID_ID) vaDestroyBuffer(dpy, id);
  }
  return va == VA_STATUS_SUCCESS ? Status::kOk : Status::kVaError;
}

// decode a parsed frame and output it when output is set
Status Vp9Decoder::DecodeFrame(const vp9::FrameSpan& frame, const vp9::FrameHeader& h, vp9::ParseState* next,
                               bool output, uint64_t tag) {
  if (h.show_existing_frame) {
    const VASurfaceID s = slots_[h.frame_to_show_map_idx];
    if (s == VA_INVALID_SURFACE) return Status::kBadStream;
    if (output) host_->Output(s, tag, Rect{0, 0, h.width, h.height}, MapColor(h.color));
    return Status::kOk;
  }
  const Status st = DecodeNewFrame(frame, h, next, output, tag);
  if (st != Status::kOk && st != Status::kNoMemory) ClearSlots(h.refresh_frame_flags, next);
  return st;
}

// decode a new frame into a new surface
Status Vp9Decoder::DecodeNewFrame(const vp9::FrameSpan& frame, const vp9::FrameHeader& h, vp9::ParseState* next,
                                  bool output, uint64_t tag) {
  if (h.profile != 0 && h.profile != 2) return Status::kUnsupported;
  if (h.color.bit_depth > 10 || !h.color.subsampling_x || !h.color.subsampling_y) return Status::kUnsupported;
  if (h.width > 0xffff || h.height > 0xffff) return Status::kUnsupported;
  if (h.uncompressed_header_size > 0xff) return Status::kBadStream;
  if (frame.size > 0xffffffffu) return Status::kUnsupported;
  Status st = PrepareContext(h, next);
  if (st != Status::kOk) return st;
  VASurfaceID target = VA_INVALID_SURFACE;
  st = host_->AcquireSurface(&target);
  if (st != Status::kOk) return st;
  st = Submit(frame, h, *next, target);
  if (st != Status::kOk) {
    host_->ReleaseSurface(target);
    return st;
  }
  if (output) host_->Output(target, tag, Rect{0, 0, h.width, h.height}, MapColor(h.color));
  vp9::ApplyRefreshes(h, next);
  SetSlots(h.refresh_frame_flags, target, VA_INVALID_SURFACE);
  if (!InSlots(target)) host_->ReleaseSurface(target);
  return Status::kOk;
}

Status Vp9Decoder::Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) {
  if (codec_config || size == 0) {
    host_->Skip(tag);
    return Status::kOk;
  }
  vp9::FrameSpan frames[vp9::kMaxSuperframeFrames];
  int count = 0;
  if (!vp9::SplitSuperframe(data, size, frames, &count)) {
    host_->Skip(tag);
    return Status::kBadStream;
  }
  int shown = -1;
  {
    vp9::ParseState scratch = state_;
    for (int k = 0; k < count; k++) {
      vp9::FrameHeader h;
      if (vp9::ParseFrame(frames[k].data, frames[k].size, &scratch, &h) != vp9::Parse::kOk) break;
      vp9::ApplyRefreshes(h, &scratch);
      if (h.show_existing_frame || h.show_frame) shown = k;
    }
  }
  Status status = Status::kOk;
  bool output = false;
  for (int k = 0; k < count; k++) {
    vp9::ParseState next = state_;
    vp9::FrameHeader h;
    if (vp9::ParseFrame(frames[k].data, frames[k].size, &next, &h) != vp9::Parse::kOk) {
      status = Status::kBadStream;
      break;
    }
    status = DecodeFrame(frames[k], h, &next, k == shown, tag);
    state_ = next;
    if (status != Status::kOk) break;
    if (k == shown) output = true;
  }
  if (!output) host_->Skip(tag);
  return status;
}

}

std::unique_ptr<DecoderCore> CreateVp9Decoder(DecoderHost* host) { return std::make_unique<Vp9Decoder>(host); }

}

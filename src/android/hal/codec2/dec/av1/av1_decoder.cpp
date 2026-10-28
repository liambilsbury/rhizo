#include "dec/av1/av1_decoder.h"

#include <string.h>

#include <vector>

#include "dec/av1/av1_parser.h"

// the AV1 decoder core on VA

namespace rhizo::c2va {
namespace av1 {

int SpatialLayers(const SequenceHeader& seq) {
  int n = 0;
  for (int i = 0; i < 4; i++) n += (seq.operating_point_idc_sel >> (8 + i)) & 1;
  return n;
}

bool DriverAppliesGrain(const char* vendor) { return !(vendor && strstr(vendor, " for virgl")); }

StreamInfo StreamInfoFor(const SequenceHeader& seq, bool grain_applies) {
  StreamInfo info{};
  uint32_t w = seq.max_frame_width_minus_1 + 1;
  uint32_t h = seq.max_frame_height_minus_1 + 1;
  info.profile = VAProfileAV1Profile0;
  info.rt_format = seq.bit_depth == 10 ? VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420;
  info.coded_width = (w + 15) & ~15u;
  info.coded_height = (h + 15) & ~15u;
  info.visible = {0, 0, w, h};
  info.bit_depth = seq.bit_depth;
  uint32_t pictures = kNumRefFrames + 1 + (SpatialLayers(seq) > 1 ? 1 : 0);
  info.min_surfaces = pictures * (seq.film_grain_params_present && grain_applies ? 2 : 1);
  info.reorder_depth = 0;
  info.color.primaries = seq.color_primaries;
  info.color.transfer = seq.transfer_characteristics;
  info.color.matrix = seq.matrix_coefficients;
  info.color.full_range = seq.color_range;
  return info;
}

void FillPictureParameters(const SequenceHeader& seq, const FrameHeader& h, const VASurfaceID refs[kNumRefFrames],
                           VASurfaceID current, VASurfaceID display, bool grain,
                           VADecPictureParameterBufferAV1* pp) {
  memset(pp, 0, sizeof(*pp));
  const CarriedParams& c = h.carried;
  pp->profile = static_cast<uint8_t>(seq.seq_profile);
  pp->order_hint_bits_minus_1 = static_cast<uint8_t>(seq.order_hint_bits ? seq.order_hint_bits - 1 : 0);
  pp->bit_depth_idx = static_cast<uint8_t>(seq.bit_depth == 12 ? 2 : (seq.bit_depth == 10 ? 1 : 0));
  pp->matrix_coefficients = static_cast<uint8_t>(seq.matrix_coefficients);

  auto& sf = pp->seq_info_fields.fields;
  sf.still_picture = seq.still_picture;
  sf.use_128x128_superblock = seq.use_128x128_superblock;
  sf.enable_filter_intra = seq.enable_filter_intra;
  sf.enable_intra_edge_filter = seq.enable_intra_edge_filter;
  sf.enable_interintra_compound = seq.enable_interintra_compound;
  sf.enable_masked_compound = seq.enable_masked_compound;
  sf.enable_dual_filter = seq.enable_dual_filter;
  sf.enable_order_hint = seq.enable_order_hint;
  sf.enable_jnt_comp = seq.enable_jnt_comp;
  sf.enable_cdef = seq.enable_cdef;
  sf.mono_chrome = seq.mono_chrome;
  sf.color_range = seq.color_range;
  sf.subsampling_x = seq.subsampling_x;
  sf.subsampling_y = seq.subsampling_y;
  sf.film_grain_params_present = seq.film_grain_params_present;

  pp->current_frame = current;
  pp->current_display_picture = display;
  pp->anchor_frames_num = 0;
  pp->anchor_frames_list = nullptr;
  // Mesa derives the coded width from the upscaled width and the superres denominator
  pp->frame_width_minus1 = static_cast<uint16_t>(h.upscaled_width - 1);
  pp->frame_height_minus1 = static_cast<uint16_t>(h.frame_height - 1);
  for (int i = 0; i < kNumRefFrames; i++) pp->ref_frame_map[i] = refs[i];
  for (int i = 0; i < kRefsPerFrame; i++) {
    pp->ref_frame_idx[i] = static_cast<uint8_t>(h.frame_is_intra ? 0 : h.ref_frame_idx[i]);
  }
  pp->primary_ref_frame = static_cast<uint8_t>(h.primary_ref_frame);
  pp->order_hint = static_cast<uint8_t>(h.order_hint);

  auto& seg = pp->seg_info;
  seg.segment_info_fields.bits.enabled = h.segmentation_enabled;
  seg.segment_info_fields.bits.update_map = h.segmentation_update_map;
  seg.segment_info_fields.bits.temporal_update = h.segmentation_temporal_update;
  seg.segment_info_fields.bits.update_data = h.segmentation_update_data;
  for (int i = 0; i < kMaxSegments; i++) {
    uint8_t mask = 0;
    for (int j = 0; j < kSegLvlMax; j++) {
      seg.feature_data[i][j] = static_cast<int16_t>(c.feature_data[i][j]);
      if (c.feature_enabled[i][j]) mask |= static_cast<uint8_t>(1u << j);
    }
    seg.feature_mask[i] = mask;
  }

  const FilmGrainParams& g = h.grain;
  if (grain && seq.film_grain_params_present && g.apply_grain) {
    auto& fg = pp->film_grain_info;
    auto& ff = fg.film_grain_info_fields.bits;
    ff.apply_grain = 1;
    ff.chroma_scaling_from_luma = g.chroma_scaling_from_luma;
    ff.grain_scaling_minus_8 = g.grain_scaling_minus_8;
    ff.ar_coeff_lag = g.ar_coeff_lag;
    ff.ar_coeff_shift_minus_6 = g.ar_coeff_shift_minus_6;
    ff.grain_scale_shift = g.grain_scale_shift;
    ff.overlap_flag = g.overlap_flag;
    ff.clip_to_restricted_range = g.clip_to_restricted_range;
    fg.grain_seed = static_cast<uint16_t>(g.grain_seed);
    fg.num_y_points = static_cast<uint8_t>(g.num_y_points);
    memcpy(fg.point_y_value, g.point_y_value, sizeof(fg.point_y_value));
    memcpy(fg.point_y_scaling, g.point_y_scaling, sizeof(fg.point_y_scaling));
    fg.num_cb_points = static_cast<uint8_t>(g.num_cb_points);
    memcpy(fg.point_cb_value, g.point_cb_value, sizeof(fg.point_cb_value));
    memcpy(fg.point_cb_scaling, g.point_cb_scaling, sizeof(fg.point_cb_scaling));
    fg.num_cr_points = static_cast<uint8_t>(g.num_cr_points);
    memcpy(fg.point_cr_value, g.point_cr_value, sizeof(fg.point_cr_value));
    memcpy(fg.point_cr_scaling, g.point_cr_scaling, sizeof(fg.point_cr_scaling));
    uint32_t num_pos_luma = 2 * g.ar_coeff_lag * (g.ar_coeff_lag + 1);
    uint32_t num_pos_chroma = num_pos_luma + (g.num_y_points ? 1 : 0);
    if (g.num_y_points) {
      for (uint32_t i = 0; i < num_pos_luma; i++) {
        fg.ar_coeffs_y[i] = static_cast<int8_t>(static_cast<int>(g.ar_coeffs_y_plus_128[i]) - 128);
      }
    }
    for (uint32_t i = 0; i < num_pos_chroma; i++) {
      if (g.chroma_scaling_from_luma || g.num_cb_points) {
        fg.ar_coeffs_cb[i] = static_cast<int8_t>(static_cast<int>(g.ar_coeffs_cb_plus_128[i]) - 128);
      }
      if (g.chroma_scaling_from_luma || g.num_cr_points) {
        fg.ar_coeffs_cr[i] = static_cast<int8_t>(static_cast<int>(g.ar_coeffs_cr_plus_128[i]) - 128);
      }
    }
    fg.cb_mult = static_cast<uint8_t>(g.cb_mult);
    fg.cb_luma_mult = static_cast<uint8_t>(g.cb_luma_mult);
    fg.cb_offset = static_cast<uint16_t>(g.cb_offset);
    fg.cr_mult = static_cast<uint8_t>(g.cr_mult);
    fg.cr_luma_mult = static_cast<uint8_t>(g.cr_luma_mult);
    fg.cr_offset = static_cast<uint16_t>(g.cr_offset);
  }

  const TileInfo& t = h.tile;
  pp->tile_cols = static_cast<uint8_t>(t.tile_cols);
  pp->tile_rows = static_cast<uint8_t>(t.tile_rows);
  for (uint32_t i = 0; i < t.tile_cols && i < 63; i++) {
    pp->width_in_sbs_minus_1[i] = static_cast<uint16_t>(t.width_in_sbs[i] - 1);
  }
  for (uint32_t i = 0; i < t.tile_rows && i < 63; i++) {
    pp->height_in_sbs_minus_1[i] = static_cast<uint16_t>(t.height_in_sbs[i] - 1);
  }
  pp->tile_count_minus_1 = 0;
  pp->context_update_tile_id = static_cast<uint16_t>(t.context_update_tile_id);

  auto& pf = pp->pic_info_fields.bits;
  pf.frame_type = h.frame_type;
  pf.show_frame = h.show_frame;
  pf.showable_frame = h.showable_frame;
  pf.error_resilient_mode = h.error_resilient_mode;
  pf.disable_cdf_update = h.disable_cdf_update;
  pf.allow_screen_content_tools = h.allow_screen_content_tools;
  pf.force_integer_mv = h.force_integer_mv;
  pf.allow_intrabc = h.allow_intrabc;
  pf.use_superres = h.use_superres;
  pf.allow_high_precision_mv = h.allow_high_precision_mv;
  pf.is_motion_mode_switchable = h.is_motion_mode_switchable;
  pf.use_ref_frame_mvs = h.use_ref_frame_mvs;
  pf.disable_frame_end_update_cdf = h.disable_frame_end_update_cdf;
  pf.uniform_tile_spacing_flag = t.uniform_tile_spacing_flag;
  pf.allow_warped_motion = h.allow_warped_motion;
  pf.large_scale_tile = 0;

  pp->superres_scale_denominator = static_cast<uint8_t>(h.superres_denom);
  pp->interp_filter = static_cast<uint8_t>(h.interpolation_filter);
  pp->filter_level[0] = static_cast<uint8_t>(h.loop_filter_level[0]);
  pp->filter_level[1] = static_cast<uint8_t>(h.loop_filter_level[1]);
  pp->filter_level_u = static_cast<uint8_t>(h.loop_filter_level[2]);
  pp->filter_level_v = static_cast<uint8_t>(h.loop_filter_level[3]);
  auto& lf = pp->loop_filter_info_fields.bits;
  lf.sharpness_level = static_cast<uint8_t>(h.loop_filter_sharpness);
  lf.mode_ref_delta_enabled = h.loop_filter_delta_enabled;
  lf.mode_ref_delta_update = h.loop_filter_delta_update;
  for (int i = 0; i < kTotalRefsPerFrame; i++) pp->ref_deltas[i] = static_cast<int8_t>(c.loop_filter_ref_deltas[i]);
  for (int i = 0; i < 2; i++) pp->mode_deltas[i] = static_cast<int8_t>(c.loop_filter_mode_deltas[i]);

  pp->base_qindex = static_cast<uint8_t>(h.base_q_idx);
  pp->y_dc_delta_q = static_cast<int8_t>(h.delta_q_y_dc);
  pp->u_dc_delta_q = static_cast<int8_t>(h.delta_q_u_dc);
  pp->u_ac_delta_q = static_cast<int8_t>(h.delta_q_u_ac);
  pp->v_dc_delta_q = static_cast<int8_t>(h.delta_q_v_dc);
  pp->v_ac_delta_q = static_cast<int8_t>(h.delta_q_v_ac);
  auto& qm = pp->qmatrix_fields.bits;
  qm.using_qmatrix = h.using_qmatrix;
  if (h.using_qmatrix) {
    qm.qm_y = static_cast<uint16_t>(h.qm_y);
    qm.qm_u = static_cast<uint16_t>(h.qm_u);
    qm.qm_v = static_cast<uint16_t>(h.qm_v);
  }

  auto& mc = pp->mode_control_fields.bits;
  mc.delta_q_present_flag = h.delta_q_present;
  mc.log2_delta_q_res = h.delta_q_res;
  mc.delta_lf_present_flag = h.delta_lf_present;
  mc.log2_delta_lf_res = h.delta_lf_res;
  mc.delta_lf_multi = h.delta_lf_multi;
  mc.tx_mode = h.tx_mode;
  mc.reference_select = h.reference_select;
  mc.reduced_tx_set_used = h.reduced_tx_set;
  mc.skip_mode_present = h.skip_mode_present;

  pp->cdef_damping_minus_3 = static_cast<uint8_t>(h.cdef_damping_minus_3);
  pp->cdef_bits = static_cast<uint8_t>(h.cdef_bits);
  for (int i = 0; i < 8; i++) {
    pp->cdef_y_strengths[i] = static_cast<uint8_t>((h.cdef_y_pri_strength[i] << 2) | (h.cdef_y_sec_strength[i] & 3));
    pp->cdef_uv_strengths[i] =
        static_cast<uint8_t>((h.cdef_uv_pri_strength[i] << 2) | (h.cdef_uv_sec_strength[i] & 3));
  }

  auto& lr = pp->loop_restoration_fields.bits;
  lr.yframe_restoration_type = static_cast<uint16_t>(h.frame_restoration_type[0]);
  lr.cbframe_restoration_type = static_cast<uint16_t>(h.frame_restoration_type[1]);
  lr.crframe_restoration_type = static_cast<uint16_t>(h.frame_restoration_type[2]);
  lr.lr_unit_shift = static_cast<uint16_t>(h.lr_unit_shift);
  lr.lr_uv_shift = static_cast<uint16_t>(h.lr_uv_shift);

  for (int i = 0; i < kRefsPerFrame; i++) {
    int ref = i + 1;
    VAWarpedMotionParamsAV1& wm = pp->wm[i];
    wm.wmtype = static_cast<VAAV1TransformationType>(h.gm_type[ref]);
    for (int j = 0; j < 6; j++) wm.wmmat[j] = c.gm_params[ref][j];
    wm.invalid = h.gm_type[ref] > kTranslation && !WarpValid(c.gm_params[ref]);
  }
}

}

namespace {

using av1::FrameHeader;
using av1::Obu;
using av1::ObuReader;
using av1::ParseError;
using av1::RefSlot;
using av1::SequenceHeader;
using av1::TileSpan;
using av1::kNumRefFrames;

// a decoded picture and its grained copy
struct Picture {
  explicit Picture(DecoderHost* h) : host(h) {}
  ~Picture() {
    Drop(&surface);
    Drop(&grain);
  }
  Picture(const Picture&) = delete;
  Picture& operator=(const Picture&) = delete;

  void Drop(VASurfaceID* s) {
    if (*s != VA_INVALID_SURFACE) host->ReleaseSurface(*s);
    *s = VA_INVALID_SURFACE;
  }

  DecoderHost* host;
  VASurfaceID surface = VA_INVALID_SURFACE;
  VASurfaceID grain = VA_INVALID_SURFACE;
  bool keep_grain = false;
};
using PicturePtr = std::shared_ptr<Picture>;

Status FromParse(ParseError e) {
  switch (e) {
    case ParseError::kNone:
      return Status::kOk;
    case ParseError::kUnsupported:
      return Status::kUnsupported;
    case ParseError::kBad:
      break;
  }
  return Status::kBadStream;
}

Status FromVa(VAStatus s) {
  if (s == VA_STATUS_SUCCESS) return Status::kOk;
  if (s == VA_STATUS_ERROR_ALLOCATION_FAILED) return Status::kNoMemory;
  return Status::kVaError;
}

bool SameConfig(const StreamInfo& a, const StreamInfo& b) {
  return a.profile == b.profile && a.rt_format == b.rt_format && a.coded_width == b.coded_width &&
         a.coded_height == b.coded_height && a.min_surfaces == b.min_surfaces;
}

// return true when two sequence headers match
bool SameSequence(const SequenceHeader& a, const SequenceHeader& b) {
  if (a.operating_points_cnt_minus_1 != b.operating_points_cnt_minus_1) return false;
  for (uint32_t i = 0; i <= a.operating_points_cnt_minus_1; i++) {
    if (a.operating_point_idc[i] != b.operating_point_idc[i] || a.seq_level_idx[i] != b.seq_level_idx[i] ||
        a.seq_tier[i] != b.seq_tier[i] ||
        a.decoder_model_present_for_this_op[i] != b.decoder_model_present_for_this_op[i]) {
      return false;
    }
  }
  return a.seq_profile == b.seq_profile && a.still_picture == b.still_picture &&
         a.reduced_still_picture_header == b.reduced_still_picture_header &&
         a.timing_info_present_flag == b.timing_info_present_flag &&
         a.decoder_model_info_present_flag == b.decoder_model_info_present_flag &&
         a.equal_picture_interval == b.equal_picture_interval &&
         a.buffer_removal_time_length_minus_1 == b.buffer_removal_time_length_minus_1 &&
         a.frame_presentation_time_length_minus_1 == b.frame_presentation_time_length_minus_1 &&
         a.initial_display_delay_present_flag == b.initial_display_delay_present_flag &&
         a.frame_width_bits_minus_1 == b.frame_width_bits_minus_1 &&
         a.frame_height_bits_minus_1 == b.frame_height_bits_minus_1 &&
         a.max_frame_width_minus_1 == b.max_frame_width_minus_1 &&
         a.max_frame_height_minus_1 == b.max_frame_height_minus_1 &&
         a.frame_id_numbers_present_flag == b.frame_id_numbers_present_flag &&
         a.delta_frame_id_length_minus_2 == b.delta_frame_id_length_minus_2 &&
         a.additional_frame_id_length_minus_1 == b.additional_frame_id_length_minus_1 &&
         a.use_128x128_superblock == b.use_128x128_superblock && a.enable_filter_intra == b.enable_filter_intra &&
         a.enable_intra_edge_filter == b.enable_intra_edge_filter &&
         a.enable_interintra_compound == b.enable_interintra_compound &&
         a.enable_masked_compound == b.enable_masked_compound && a.enable_warped_motion == b.enable_warped_motion &&
         a.enable_dual_filter == b.enable_dual_filter && a.enable_order_hint == b.enable_order_hint &&
         a.enable_jnt_comp == b.enable_jnt_comp && a.enable_ref_frame_mvs == b.enable_ref_frame_mvs &&
         a.seq_force_screen_content_tools == b.seq_force_screen_content_tools &&
         a.seq_force_integer_mv == b.seq_force_integer_mv && a.order_hint_bits == b.order_hint_bits &&
         a.enable_superres == b.enable_superres && a.enable_cdef == b.enable_cdef &&
         a.enable_restoration == b.enable_restoration && a.bit_depth == b.bit_depth &&
         a.mono_chrome == b.mono_chrome && a.color_primaries == b.color_primaries &&
         a.transfer_characteristics == b.transfer_characteristics &&
         a.matrix_coefficients == b.matrix_coefficients && a.color_range == b.color_range &&
         a.subsampling_x == b.subsampling_x && a.subsampling_y == b.subsampling_y &&
         a.chroma_sample_position == b.chroma_sample_position && a.separate_uv_delta_q == b.separate_uv_delta_q &&
         a.film_grain_params_present == b.film_grain_params_present;
}

class Av1Decoder final : public DecoderCore {
 public:
  Av1Decoder(DecoderHost* host, av1::Trace* trace) : host_(host), trace_(trace) {
    tiles_.resize(av1::kMaxFrameTiles);
    slices_.reset(new VASliceParameterBufferAV1[av1::kMaxFrameTiles]);
  }
  ~Av1Decoder() override { Forget(); }

  Status Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) override;
  Status Drain() override { return Status::kOk; }
  void Reset() override { Forget(); }

 private:
  Status OnSequenceHeader(const Obu& obu);
  Status OnFrameHeader(const Obu& obu, const uint8_t* buffer);
  Status OnTileGroup(const uint8_t* data, size_t size, size_t offset, size_t base_bits, const uint8_t* buffer);
  Status ShowExisting(const FrameHeader& h);
  Status SubmitFrame(const uint8_t* buffer);
  bool Referenced(const PicturePtr& pic) const;
  bool FitsSurfaces(const StreamInfo& info);
  bool GrainApplies();
  Status RunVa(const VADecPictureParameterBufferAV1& pp, const uint8_t* data, size_t size, VASurfaceID target);
  void Forget();
  ColorInfo Color() const;
  static void Note(Status* st, Status s) {
    if (*st == Status::kOk && s != Status::kOk) *st = s;
  }

  DecoderHost* host_;
  av1::Trace* trace_;

  bool have_seq_ = false;
  bool seq_supported_ = false;
  SequenceHeader seq_;
  bool configured_ = false;
  StreamInfo info_{};
  VAContextID context_ = VA_INVALID_ID;
  bool config_tried_ = false;
  StreamInfo tried_info_{};
  Status config_status_ = Status::kOk;
  int grain_applies_ = -1;

  RefSlot slots_[kNumRefFrames];
  PicturePtr pics_[kNumRefFrames];

  bool in_frame_ = false;
  FrameHeader cur_;
  uint32_t next_tile_ = 0;
  std::vector<TileSpan> tiles_;
  std::unique_ptr<VASliceParameterBufferAV1[]> slices_;
  uint32_t num_slices_ = 0;

  PicturePtr shown_;
  VASurfaceID shown_surface_ = VA_INVALID_SURFACE;
  Rect shown_crop_{};
};

// drop the reference pictures and slots
void Av1Decoder::Forget() {
  shown_.reset();
  in_frame_ = false;
  for (int i = 0; i < kNumRefFrames; i++) {
    pics_[i].reset();
    slots_[i] = RefSlot{};
  }
}

ColorInfo Av1Decoder::Color() const {
  ColorInfo c;
  c.primaries = seq_.color_primaries;
  c.transfer = seq_.transfer_characteristics;
  c.matrix = seq_.matrix_coefficients;
  c.full_range = seq_.color_range;
  return c;
}

Status Av1Decoder::Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) {
  Status st = Status::kOk;
  if (data == nullptr) size = 0;
  if (codec_config) {
    if (size >= 4 && (data[0] & 0x80)) {
      data += 4;
      size -= 4;
    }
    ObuReader rd(data, size, trace_);
    Obu obu;
    while (rd.Next(&obu)) {
      if (obu.type == av1::kObuSequenceHeader) Note(&st, OnSequenceHeader(obu));
    }
    if (rd.error()) Note(&st, Status::kBadStream);
    host_->Skip(tag);
    return st;
  }

  in_frame_ = false;
  shown_.reset();
  ObuReader rd(data, size, trace_);
  Obu obu;
  while (rd.Next(&obu)) {
    if (have_seq_ && !av1::InOperatingPoint(seq_, obu)) continue;
    switch (obu.type) {
      case av1::kObuSequenceHeader:
        Note(&st, OnSequenceHeader(obu));
        break;
      case av1::kObuTemporalDelimiter:
        if (in_frame_) Note(&st, Status::kBadStream);
        in_frame_ = false;
        break;
      case av1::kObuRedundantFrameHeader:
        break;
      case av1::kObuFrameHeader:
      case av1::kObuFrame:
        if (in_frame_) {
          if (obu.type == av1::kObuFrameHeader) break;
          Note(&st, Status::kBadStream);
          in_frame_ = false;
        }
        Note(&st, OnFrameHeader(obu, data));
        break;
      case av1::kObuTileGroup:
        if (!in_frame_) {
          Note(&st, Status::kBadStream);
          break;
        }
        Note(&st, OnTileGroup(obu.payload, obu.payload_size, static_cast<size_t>(obu.payload - data),
                              obu.header_bytes * 8, data));
        break;
      case av1::kObuTileList:
        Note(&st, Status::kUnsupported);
        break;
      default:
        break;
    }
  }
  if (rd.error()) Note(&st, Status::kBadStream);
  if (in_frame_) {
    Note(&st, Status::kBadStream);
    in_frame_ = false;
  }
  if (shown_) {
    host_->Output(shown_surface_, tag, shown_crop_, Color());
    if (!shown_->keep_grain) shown_->Drop(&shown_->grain);
    shown_.reset();
  } else {
    host_->Skip(tag);
  }
  return st;
}

Status Av1Decoder::OnSequenceHeader(const Obu& obu) {
  SequenceHeader s;
  ParseError e = av1::ParseSequenceHeader(obu.payload, obu.payload_size, obu.header_bytes * 8, trace_, &s);
  if (e == ParseError::kBad) return Status::kBadStream;
  if (have_seq_ && seq_supported_ == (e == ParseError::kNone) && SameSequence(s, seq_)) return Status::kOk;
  Forget();
  seq_ = s;
  have_seq_ = true;
  seq_supported_ = e == ParseError::kNone;
  if (!seq_supported_) return Status::kUnsupported;
  StreamInfo info = av1::StreamInfoFor(s, GrainApplies());
  if (configured_ && FitsSurfaces(info)) {
    info_ = info;
    return Status::kOk;
  }
  if (!configured_ && config_tried_ && SameConfig(info, tried_info_)) return config_status_;
  configured_ = false;
  config_tried_ = true;
  tried_info_ = info;
  VAContextID context = VA_INVALID_ID;
  config_status_ = host_->Configure(info, &context);
  if (config_status_ != Status::kOk) return config_status_;
  configured_ = true;
  info_ = info;
  context_ = context;
  return Status::kOk;
}

Status Av1Decoder::OnFrameHeader(const Obu& obu, const uint8_t* buffer) {
  if (!have_seq_) return Status::kBadStream;
  if (!seq_supported_) return Status::kUnsupported;
  if (!configured_) return config_status_ != Status::kOk ? config_status_ : Status::kVaError;
  FrameHeader h;
  ParseError e = av1::ParseFrameHeader(seq_, slots_, obu, obu.payload, obu.payload_size, obu.header_bytes * 8,
                                       trace_, &h);
  if (e != ParseError::kNone) return FromParse(e);
  if (h.show_existing_frame) return ShowExisting(h);
  if (h.tile.tile_cols * h.tile.tile_rows > av1::kMaxFrameTiles) return Status::kUnsupported;
  cur_ = h;
  next_tile_ = 0;
  in_frame_ = true;
  if (obu.type != av1::kObuFrame) return Status::kOk;
  size_t header_bytes = h.header_bits / 8;
  if (header_bytes > obu.payload_size) {
    in_frame_ = false;
    return Status::kBadStream;
  }
  return OnTileGroup(obu.payload + header_bytes, obu.payload_size - header_bytes,
                     static_cast<size_t>(obu.payload - buffer) + header_bytes, (obu.header_bytes + header_bytes) * 8,
                     buffer);
}

Status Av1Decoder::OnTileGroup(const uint8_t* data, size_t size, size_t offset, size_t base_bits,
                               const uint8_t* buffer) {
  bool last = false;
  ParseError e = av1::ParseTileGroup(cur_, data, size, offset, base_bits, trace_, &next_tile_, tiles_.data(),
                                     static_cast<uint32_t>(tiles_.size()), &last);
  if (e != ParseError::kNone) {
    in_frame_ = false;
    return FromParse(e);
  }
  if (!last) return Status::kOk;
  in_frame_ = false;
  return SubmitFrame(buffer);
}

// show an existing frame
Status Av1Decoder::ShowExisting(const FrameHeader& h) {
  uint32_t idx = h.frame_to_show_map_idx;
  PicturePtr pic = pics_[idx];
  if (!pic || !slots_[idx].valid) return Status::kBadStream;
  bool grain = seq_.film_grain_params_present && h.grain.apply_grain && pic->grain != VA_INVALID_SURFACE;
  shown_ = pic;
  shown_surface_ = grain ? pic->grain : pic->surface;
  shown_crop_ = {0, 0, slots_[idx].upscaled_width, slots_[idx].frame_height};
  if (h.frame_type == av1::kKeyFrame) {
    RefSlot s = slots_[idx];
    s.showable = false;
    pic->keep_grain = false;
    for (int i = 0; i < kNumRefFrames; i++) {
      slots_[i] = s;
      pics_[i] = pic;
    }
  }
  return Status::kOk;
}

Status Av1Decoder::SubmitFrame(const uint8_t* buffer) {
  const FrameHeader& h = cur_;
  if (!h.frame_is_intra) {
    for (int i = 0; i < av1::kRefsPerFrame; i++) {
      uint32_t idx = h.ref_frame_idx[i];
      if (!h.ref_valid[idx] || !pics_[idx]) return Status::kBadStream;
    }
  }
  Status note = Status::kOk;
  if (shown_ && !Referenced(shown_)) {
    if (h.show_frame) {
      shown_.reset();
    } else if (av1::SpatialLayers(seq_) <= 1) {
      shown_.reset();
      note = Status::kBadStream;
    }
  }
  PicturePtr pic = std::make_shared<Picture>(host_);
  Status st = host_->AcquireSurface(&pic->surface);
  if (st != Status::kOk) {
    pic->surface = VA_INVALID_SURFACE;
    return st;
  }
  bool grain = seq_.film_grain_params_present && h.grain.apply_grain && GrainApplies();
  if (grain) {
    st = host_->AcquireSurface(&pic->grain);
    if (st != Status::kOk) {
      pic->grain = VA_INVALID_SURFACE;
      return st;
    }
  }
  pic->keep_grain = grain && h.showable_frame;

  VASurfaceID refs[kNumRefFrames];
  for (int i = 0; i < kNumRefFrames; i++) refs[i] = pics_[i] ? pics_[i]->surface : VA_INVALID_SURFACE;
  VADecPictureParameterBufferAV1 pp;
  av1::FillPictureParameters(seq_, h, refs, pic->surface, grain ? pic->grain : pic->surface, grain, &pp);

  uint32_t num_tiles = h.tile.tile_cols * h.tile.tile_rows;
  size_t lo = tiles_[0].offset;
  size_t hi = lo;
  for (uint32_t i = 0; i < num_tiles; i++) {
    if (tiles_[i].offset < lo) lo = tiles_[i].offset;
    if (tiles_[i].offset + tiles_[i].size > hi) hi = tiles_[i].offset + tiles_[i].size;
  }
  memset(slices_.get(), 0, sizeof(VASliceParameterBufferAV1) * num_tiles);
  for (uint32_t i = 0; i < num_tiles; i++) {
    VASliceParameterBufferAV1& sp = slices_[i];
    sp.slice_data_size = tiles_[i].size;
    sp.slice_data_offset = static_cast<uint32_t>(tiles_[i].offset - lo);
    sp.slice_data_flag = VA_SLICE_DATA_FLAG_ALL;
    sp.tile_row = tiles_[i].row;
    sp.tile_column = tiles_[i].col;
  }
  num_slices_ = num_tiles;
  st = RunVa(pp, buffer + lo, hi - lo, pic->surface);
  if (st != Status::kOk) return st;

  for (int i = 0; i < kNumRefFrames; i++) {
    slots_[i].valid = h.ref_valid[i];
    slots_[i].order_hint = h.ref_order_hint[i];
  }
  RefSlot s = av1::MakeRefSlot(seq_, h);
  for (int i = 0; i < kNumRefFrames; i++) {
    if ((h.refresh_frame_flags >> i) & 1) {
      slots_[i] = s;
      pics_[i] = pic;
    }
  }
  if (h.show_frame) {
    shown_ = pic;
    shown_surface_ = grain ? pic->grain : pic->surface;
    shown_crop_ = {0, 0, h.upscaled_width, h.frame_height};
  }
  return note;
}

// return true when the current surfaces hold the stream
bool Av1Decoder::FitsSurfaces(const StreamInfo& info) {
  if (info.profile != info_.profile || info.rt_format != info_.rt_format || info.min_surfaces != info_.min_surfaces) {
    return false;
  }
  uint32_t w = 0, h = 0;
  host_->SurfaceSize(&w, &h);
  return info.coded_width <= w && info.coded_height <= h;
}

// return true when the driver applies film grain
bool Av1Decoder::GrainApplies() {
  if (grain_applies_ < 0) grain_applies_ = av1::DriverAppliesGrain(vaQueryVendorString(host_->display())) ? 1 : 0;
  return grain_applies_ == 1;
}

bool Av1Decoder::Referenced(const PicturePtr& pic) const {
  for (const PicturePtr& p : pics_) {
    if (p == pic) return true;
  }
  return false;
}

// render a frame with one vaRenderPicture call
Status Av1Decoder::RunVa(const VADecPictureParameterBufferAV1& pp, const uint8_t* data, size_t size,
                         VASurfaceID target) {
  VADisplay dpy = host_->display();
  VABufferID bufs[3] = {VA_INVALID_ID, VA_INVALID_ID, VA_INVALID_ID};
  VAStatus vs = vaCreateBuffer(dpy, context_, VAPictureParameterBufferType, sizeof(pp), 1,
                               const_cast<VADecPictureParameterBufferAV1*>(&pp), &bufs[0]);
  if (vs == VA_STATUS_SUCCESS) {
    vs = vaCreateBuffer(dpy, context_, VASliceParameterBufferType, sizeof(VASliceParameterBufferAV1),
                        num_slices_, slices_.get(), &bufs[1]);
  }
  if (vs == VA_STATUS_SUCCESS) {
    vs = vaCreateBuffer(dpy, context_, VASliceDataBufferType, static_cast<unsigned int>(size), 1,
                        const_cast<uint8_t*>(data), &bufs[2]);
  }
  Status st = FromVa(vs);
  if (st == Status::kOk) {
    st = FromVa(vaBeginPicture(dpy, context_, target));
    if (st == Status::kOk) {
      st = FromVa(vaRenderPicture(dpy, context_, bufs, 3));
      Status end = FromVa(vaEndPicture(dpy, context_));
      if (st == Status::kOk) st = end;
    }
  }
  for (VABufferID b : bufs) {
    if (b != VA_INVALID_ID) vaDestroyBuffer(dpy, b);
  }
  return st;
}

}

std::unique_ptr<DecoderCore> CreateAv1DecoderWithTrace(DecoderHost* host, av1::Trace* trace) {
  return std::make_unique<Av1Decoder>(host, trace);
}

std::unique_ptr<DecoderCore> CreateAv1Decoder(DecoderHost* host) { return CreateAv1DecoderWithTrace(host, nullptr); }

}

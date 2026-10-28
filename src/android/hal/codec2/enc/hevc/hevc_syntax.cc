#include "hevc_syntax.h"

#include <math.h>

namespace rhizo::c2va::hevcenc {

namespace {

// return Ceil(Log2(n))
int CeilLog2(uint32_t n) {
  int bits = 0;
  while ((1u << bits) < n) bits++;
  return bits;
}

// write the two-byte nal_unit_header()
void NalHeader(uint32_t type, uint8_t out[2]) {
  out[0] = static_cast<uint8_t>(type << 1);
  out[1] = 1;
}

// write the profile_tier_level(1, 0)
void WritePtl(const ProfileTierLevel& p, BitWriter* bw) {
  bw->U(2, 0);
  bw->Flag(p.tier);
  bw->U(5, p.profile_idc);
  bw->U(32, p.compatibility);
  bw->Flag(p.progressive_source);
  bw->Flag(p.interlaced_source);
  bw->Flag(p.non_packed_constraint);
  bw->Flag(p.frame_only_constraint);
  bw->U(32, 0);
  bw->U(11, 0);
  bw->U(1, 0);
  bw->U(8, p.level_idc);
}

// write an explicit st_ref_pic_set(stRpsIdx)
void WriteStRps(uint32_t idx, const StRps& r, BitWriter* bw) {
  if (idx != 0) bw->Flag(false);
  bw->Ue(r.num_negative);
  bw->Ue(r.num_positive);
  int32_t prev = 0;
  for (uint32_t i = 0; i < r.num_negative; i++) {
    bw->Ue(static_cast<uint32_t>(prev - r.delta_poc_s0[i] - 1));
    bw->Flag(r.used_s0[i]);
    prev = r.delta_poc_s0[i];
  }
  prev = 0;
  for (uint32_t i = 0; i < r.num_positive; i++) {
    bw->Ue(static_cast<uint32_t>(r.delta_poc_s1[i] - prev - 1));
    bw->Flag(r.used_s1[i]);
    prev = r.delta_poc_s1[i];
  }
}

// check that WriteStRps can write the set
bool ValidRps(const StRps& r) {
  if (r.num_negative > 16 || r.num_positive > 16 || r.NumDeltaPocs() > 16) return false;
  for (uint32_t i = 0; i < r.num_negative; i++)
    if (r.delta_poc_s0[i] >= (i ? r.delta_poc_s0[i - 1] : 0)) return false;
  for (uint32_t i = 0; i < r.num_positive; i++)
    if (r.delta_poc_s1[i] <= (i ? r.delta_poc_s1[i - 1] : 0)) return false;
  return true;
}

}

bool ParseStRps(uint32_t idx, const std::vector<StRps>& sets, BitReader* br, StRps* out) {
  *out = StRps();
  const uint32_t num_sets = static_cast<uint32_t>(sets.size());
  const bool inter = idx != 0 && br->Flag();
  if (inter) {
    uint32_t delta_idx_minus1 = (idx == num_sets) ? br->Ue() : 0;
    if (delta_idx_minus1 + 1 > idx || idx - (delta_idx_minus1 + 1) >= num_sets) return false;
    const StRps& ref = sets[idx - (delta_idx_minus1 + 1)];
    const bool sign = br->Flag();
    const uint32_t abs_minus1 = br->Ue();
    if (abs_minus1 > 32767) return false;
    const int32_t delta_rps = (sign ? -1 : 1) * static_cast<int32_t>(abs_minus1 + 1);
    const uint32_t n = ref.NumDeltaPocs();
    bool used[17] = {}, use_delta[17] = {};
    for (uint32_t j = 0; j <= n; j++) {
      used[j] = br->Flag();
      use_delta[j] = used[j] ? true : br->Flag();
    }
    uint32_t i = 0;
    for (int32_t j = static_cast<int32_t>(ref.num_positive) - 1; j >= 0; j--) {
      const int32_t d = ref.delta_poc_s1[j] + delta_rps;
      const uint32_t k = ref.num_negative + static_cast<uint32_t>(j);
      if (d < 0 && use_delta[k]) {
        if (i >= 16) return false;
        out->delta_poc_s0[i] = d;
        out->used_s0[i++] = used[k];
      }
    }
    if (delta_rps < 0 && use_delta[n]) {
      if (i >= 16) return false;
      out->delta_poc_s0[i] = delta_rps;
      out->used_s0[i++] = used[n];
    }
    for (uint32_t j = 0; j < ref.num_negative; j++) {
      const int32_t d = ref.delta_poc_s0[j] + delta_rps;
      if (d < 0 && use_delta[j]) {
        if (i >= 16) return false;
        out->delta_poc_s0[i] = d;
        out->used_s0[i++] = used[j];
      }
    }
    out->num_negative = i;
    i = 0;
    for (int32_t j = static_cast<int32_t>(ref.num_negative) - 1; j >= 0; j--) {
      const int32_t d = ref.delta_poc_s0[j] + delta_rps;
      if (d > 0 && use_delta[j]) {
        if (i >= 16) return false;
        out->delta_poc_s1[i] = d;
        out->used_s1[i++] = used[j];
      }
    }
    if (delta_rps > 0 && use_delta[n]) {
      if (i >= 16) return false;
      out->delta_poc_s1[i] = delta_rps;
      out->used_s1[i++] = used[n];
    }
    for (uint32_t j = 0; j < ref.num_positive; j++) {
      const int32_t d = ref.delta_poc_s1[j] + delta_rps;
      const uint32_t k = ref.num_negative + j;
      if (d > 0 && use_delta[k]) {
        if (i >= 16) return false;
        out->delta_poc_s1[i] = d;
        out->used_s1[i++] = used[k];
      }
    }
    out->num_positive = i;
  } else {
    out->num_negative = br->Ue();
    out->num_positive = br->Ue();
    if (out->num_negative > 16 || out->num_positive > 16 || out->NumDeltaPocs() > 16) return false;
    int32_t prev = 0;
    for (uint32_t i = 0; i < out->num_negative; i++) {
      const uint32_t d = br->Ue();
      if (d > 32767) return false;
      prev -= static_cast<int32_t>(d + 1);
      out->delta_poc_s0[i] = prev;
      out->used_s0[i] = br->Flag();
    }
    prev = 0;
    for (uint32_t i = 0; i < out->num_positive; i++) {
      const uint32_t d = br->Ue();
      if (d > 32767) return false;
      prev += static_cast<int32_t>(d + 1);
      out->delta_poc_s1[i] = prev;
      out->used_s1[i] = br->Flag();
    }
  }
  return out->NumDeltaPocs() <= 16 && !br->overrun();
}

namespace {

bool IsIdr(uint32_t type) { return type == kNalIdrWRadl || type == kNalIdrNLp; }
bool IsIrap(uint32_t type) { return type >= kNalBlaWLp && type <= kNalRsvIrap23; }

}

uint32_t StRps::NumUsed() const {
  uint32_t n = 0;
  for (uint32_t i = 0; i < num_negative && i < 16; i++) n += used_s0[i];
  for (uint32_t i = 0; i < num_positive && i < 16; i++) n += used_s1[i];
  return n;
}

bool StRps::operator==(const StRps& o) const {
  if (num_negative != o.num_negative || num_positive != o.num_positive) return false;
  for (uint32_t i = 0; i < num_negative && i < 16; i++)
    if (delta_poc_s0[i] != o.delta_poc_s0[i] || used_s0[i] != o.used_s0[i]) return false;
  for (uint32_t i = 0; i < num_positive && i < 16; i++)
    if (delta_poc_s1[i] != o.delta_poc_s1[i] || used_s1[i] != o.used_s1[i]) return false;
  return true;
}

bool SliceSyntax::operator==(const SliceSyntax& o) const {
  return dependent_slice_segments_enabled == o.dependent_slice_segments_enabled &&
         output_flag_present == o.output_flag_present &&
         num_extra_slice_header_bits == o.num_extra_slice_header_bits &&
         log2_max_pic_order_cnt_lsb == o.log2_max_pic_order_cnt_lsb && sps_rps == o.sps_rps &&
         long_term_ref_pics_present == o.long_term_ref_pics_present && temporal_mvp == o.temporal_mvp &&
         sao == o.sao && lists_modification_present == o.lists_modification_present &&
         cabac_init_present == o.cabac_init_present && weighted_pred == o.weighted_pred &&
         weighted_bipred == o.weighted_bipred && slice_chroma_qp_offsets_present == o.slice_chroma_qp_offsets_present &&
         deblocking_filter_override_enabled == o.deblocking_filter_override_enabled &&
         pps_deblocking_filter_disabled == o.pps_deblocking_filter_disabled &&
         pps_beta_offset_div2 == o.pps_beta_offset_div2 && pps_tc_offset_div2 == o.pps_tc_offset_div2 &&
         loop_filter_across_slices == o.loop_filter_across_slices && tiles_or_wavefronts == o.tiles_or_wavefronts &&
         slice_segment_header_extension_present == o.slice_segment_header_extension_present &&
         num_ref_idx_l0_default_active_minus1 == o.num_ref_idx_l0_default_active_minus1 &&
         num_ref_idx_l1_default_active_minus1 == o.num_ref_idx_l1_default_active_minus1 &&
         init_qp_minus26 == o.init_qp_minus26;
}

SliceSyntax SyntaxOf(const Sps& sps, const Pps& pps) {
  SliceSyntax s;
  s.dependent_slice_segments_enabled = pps.dependent_slice_segments_enabled;
  s.output_flag_present = pps.output_flag_present;
  s.num_extra_slice_header_bits = pps.num_extra_slice_header_bits;
  s.log2_max_pic_order_cnt_lsb = sps.log2_max_pic_order_cnt_lsb_minus4 + 4;
  s.sps_rps = sps.st_rps;
  s.temporal_mvp = sps.temporal_mvp;
  s.sao = sps.sao;
  s.lists_modification_present = pps.lists_modification_present;
  s.cabac_init_present = pps.cabac_init_present;
  s.weighted_pred = pps.weighted_pred;
  s.weighted_bipred = pps.weighted_bipred;
  s.slice_chroma_qp_offsets_present = pps.slice_chroma_qp_offsets_present;
  s.deblocking_filter_override_enabled = pps.deblocking_filter_control_present && pps.deblocking_filter_override_enabled;
  s.pps_deblocking_filter_disabled = pps.deblocking_filter_control_present && pps.pps_deblocking_filter_disabled;
  s.pps_beta_offset_div2 = pps.deblocking_filter_control_present ? pps.beta_offset_div2 : 0;
  s.pps_tc_offset_div2 = pps.deblocking_filter_control_present ? pps.tc_offset_div2 : 0;
  s.loop_filter_across_slices = pps.loop_filter_across_slices;
  s.num_ref_idx_l0_default_active_minus1 = pps.num_ref_idx_l0_default_active_minus1;
  s.num_ref_idx_l1_default_active_minus1 = pps.num_ref_idx_l1_default_active_minus1;
  s.init_qp_minus26 = pps.init_qp_minus26;
  return s;
}

void AppendVps(const Vps& vps, std::vector<uint8_t>* out) {
  BitWriter bw;
  bw.U(4, 0);
  bw.Flag(true);
  bw.Flag(true);
  bw.U(6, 0);
  bw.U(3, 0);
  bw.Flag(true);
  bw.U(16, 0xffff);
  WritePtl(vps.ptl, &bw);
  bw.Flag(true);
  bw.Ue(vps.max_dec_pic_buffering_minus1);
  bw.Ue(vps.max_num_reorder_pics);
  bw.Ue(vps.max_latency_increase_plus1);
  bw.U(6, 0);
  bw.Ue(0);
  bw.Flag(false);
  bw.Flag(false);
  bw.TrailingBits();
  uint8_t header[2];
  NalHeader(kNalVps, header);
  AppendNal(header, 2, bw.Bytes(), out);
}

void AppendSps(const Sps& sps, std::vector<uint8_t>* out) {
  BitWriter bw;
  bw.U(4, 0);
  bw.U(3, 0);
  bw.Flag(true);
  WritePtl(sps.ptl, &bw);
  bw.Ue(0);
  bw.Ue(1);
  bw.Ue(sps.width);
  bw.Ue(sps.height);
  bw.Flag(sps.conformance_window);
  if (sps.conformance_window) {
    bw.Ue(sps.conf_left);
    bw.Ue(sps.conf_right);
    bw.Ue(sps.conf_top);
    bw.Ue(sps.conf_bottom);
  }
  bw.Ue(sps.bit_depth_luma_minus8);
  bw.Ue(sps.bit_depth_chroma_minus8);
  bw.Ue(sps.log2_max_pic_order_cnt_lsb_minus4);
  bw.Flag(true);
  bw.Ue(sps.max_dec_pic_buffering_minus1);
  bw.Ue(sps.max_num_reorder_pics);
  bw.Ue(sps.max_latency_increase_plus1);
  bw.Ue(sps.log2_min_luma_coding_block_size_minus3);
  bw.Ue(sps.log2_diff_max_min_luma_coding_block_size);
  bw.Ue(sps.log2_min_luma_transform_block_size_minus2);
  bw.Ue(sps.log2_diff_max_min_luma_transform_block_size);
  bw.Ue(sps.max_transform_hierarchy_depth_inter);
  bw.Ue(sps.max_transform_hierarchy_depth_intra);
  bw.Flag(false);
  bw.Flag(sps.amp);
  bw.Flag(sps.sao);
  bw.Flag(false);
  bw.Ue(static_cast<uint32_t>(sps.st_rps.size()));
  for (size_t i = 0; i < sps.st_rps.size(); i++) WriteStRps(static_cast<uint32_t>(i), sps.st_rps[i], &bw);
  bw.Flag(false);
  bw.Flag(sps.temporal_mvp);
  bw.Flag(sps.strong_intra_smoothing);
  bw.Flag(sps.vui_present);
  if (sps.vui_present) {
    const Vui& v = sps.vui;
    bw.Flag(false);
    bw.Flag(false);
    bw.Flag(v.video_signal_type_present);
    if (v.video_signal_type_present) {
      bw.U(3, v.video_format);
      bw.Flag(v.full_range);
      bw.Flag(v.colour_description_present);
      if (v.colour_description_present) {
        bw.U(8, v.colour_primaries);
        bw.U(8, v.transfer_characteristics);
        bw.U(8, v.matrix_coefficients);
      }
    }
    bw.Flag(false);
    bw.Flag(false);
    bw.Flag(false);
    bw.Flag(false);
    bw.Flag(false);
    bw.Flag(v.timing_info_present);
    if (v.timing_info_present) {
      bw.U(32, v.num_units_in_tick);
      bw.U(32, v.time_scale);
      bw.Flag(false);
      bw.Flag(false);
    }
    bw.Flag(false);
  }
  bw.Flag(false);
  bw.TrailingBits();
  uint8_t header[2];
  NalHeader(kNalSps, header);
  AppendNal(header, 2, bw.Bytes(), out);
}

void AppendPps(const Pps& pps, std::vector<uint8_t>* out) {
  BitWriter bw;
  bw.Ue(0);
  bw.Ue(0);
  bw.Flag(pps.dependent_slice_segments_enabled);
  bw.Flag(pps.output_flag_present);
  bw.U(3, pps.num_extra_slice_header_bits);
  bw.Flag(pps.sign_data_hiding);
  bw.Flag(pps.cabac_init_present);
  bw.Ue(pps.num_ref_idx_l0_default_active_minus1);
  bw.Ue(pps.num_ref_idx_l1_default_active_minus1);
  bw.Se(pps.init_qp_minus26);
  bw.Flag(pps.constrained_intra_pred);
  bw.Flag(pps.transform_skip);
  bw.Flag(pps.cu_qp_delta_enabled);
  if (pps.cu_qp_delta_enabled) bw.Ue(pps.diff_cu_qp_delta_depth);
  bw.Se(pps.cb_qp_offset);
  bw.Se(pps.cr_qp_offset);
  bw.Flag(pps.slice_chroma_qp_offsets_present);
  bw.Flag(pps.weighted_pred);
  bw.Flag(pps.weighted_bipred);
  bw.Flag(pps.transquant_bypass);
  bw.Flag(false);
  bw.Flag(false);
  bw.Flag(pps.loop_filter_across_slices);
  bw.Flag(pps.deblocking_filter_control_present);
  if (pps.deblocking_filter_control_present) {
    bw.Flag(pps.deblocking_filter_override_enabled);
    bw.Flag(pps.pps_deblocking_filter_disabled);
    if (!pps.pps_deblocking_filter_disabled) {
      bw.Se(pps.beta_offset_div2);
      bw.Se(pps.tc_offset_div2);
    }
  }
  bw.Flag(false);
  bw.Flag(pps.lists_modification_present);
  bw.Ue(pps.log2_parallel_merge_level_minus2);
  bw.Flag(false);
  bw.Flag(false);
  bw.TrailingBits();
  uint8_t header[2];
  NalHeader(kNalPps, header);
  AppendNal(header, 2, bw.Bytes(), out);
}

bool WriteSliceHeader(const SliceSyntax& syn, const SliceHeader& sh, BitWriter* bw) {
  if (sh.slice_type != kSliceP && sh.slice_type != kSliceI) return false;
  if (syn.long_term_ref_pics_present || syn.tiles_or_wavefronts) return false;
  if (syn.weighted_pred && sh.slice_type == kSliceP) return false;
  const bool idr = IsIdr(sh.nal_unit_type);
  bw->Flag(true);
  if (IsIrap(sh.nal_unit_type)) bw->Flag(sh.no_output_of_prior_pics);
  bw->Ue(sh.pps_id);
  for (uint32_t i = 0; i < syn.num_extra_slice_header_bits; i++) bw->Flag(false);
  bw->Ue(sh.slice_type);
  if (syn.output_flag_present) bw->Flag(sh.pic_output);
  uint32_t num_pic_total_curr = 0;
  if (!idr) {
    bw->U(static_cast<int>(syn.log2_max_pic_order_cnt_lsb), sh.pic_order_cnt_lsb);
    bw->Flag(sh.st_rps_sps);
    const uint32_t num_sets = static_cast<uint32_t>(syn.sps_rps.size());
    if (!sh.st_rps_sps) {
      if (!ValidRps(sh.rps)) return false;
      WriteStRps(num_sets, sh.rps, bw);
    } else {
      if (sh.st_rps_idx >= num_sets) return false;
      if (num_sets > 1) bw->U(CeilLog2(num_sets), sh.st_rps_idx);
    }
    num_pic_total_curr = sh.rps.NumUsed();
    if (syn.temporal_mvp) bw->Flag(sh.slice_temporal_mvp);
  }
  if (syn.sao) {
    bw->Flag(sh.sao_luma);
    bw->Flag(sh.sao_chroma);
  }
  if (sh.slice_type == kSliceP) {
    bw->Flag(sh.num_ref_idx_active_override);
    if (sh.num_ref_idx_active_override) bw->Ue(sh.num_ref_idx_l0_active_minus1);
    const uint32_t active = sh.num_ref_idx_active_override ? sh.num_ref_idx_l0_active_minus1
                                                           : syn.num_ref_idx_l0_default_active_minus1;
    if (syn.lists_modification_present && num_pic_total_curr > 1) {
      bw->Flag(sh.ref_pic_list_modification_l0);
      if (sh.ref_pic_list_modification_l0) {
        if (sh.list_entry_l0.size() != active + 1) return false;
        for (uint32_t e : sh.list_entry_l0) bw->U(CeilLog2(num_pic_total_curr), e);
      }
    }
    if (syn.cabac_init_present) bw->Flag(sh.cabac_init);
    if (sh.slice_temporal_mvp && active > 0) bw->Ue(sh.collocated_ref_idx);
    bw->Ue(sh.five_minus_max_num_merge_cand);
  }
  bw->Se(sh.slice_qp_delta);
  if (syn.slice_chroma_qp_offsets_present) {
    bw->Se(sh.slice_cb_qp_offset);
    bw->Se(sh.slice_cr_qp_offset);
  }
  if (syn.deblocking_filter_override_enabled) bw->Flag(sh.deblocking_filter_override);
  bool disabled = syn.pps_deblocking_filter_disabled;
  if (sh.deblocking_filter_override) {
    bw->Flag(sh.slice_deblocking_filter_disabled);
    disabled = sh.slice_deblocking_filter_disabled;
    if (!disabled) {
      bw->Se(sh.slice_beta_offset_div2);
      bw->Se(sh.slice_tc_offset_div2);
    }
  }
  if (syn.loop_filter_across_slices && (sh.sao_luma || sh.sao_chroma || !disabled))
    bw->Flag(sh.slice_loop_filter_across_slices);
  if (syn.slice_segment_header_extension_present) bw->Ue(0);
  bw->ByteAlignment();
  return true;
}

bool ParseSliceHeader(const SliceSyntax& syn, uint32_t nal_unit_type, BitReader* br, SliceHeader* sh) {
  *sh = SliceHeader();
  sh->nal_unit_type = nal_unit_type;
  if (syn.long_term_ref_pics_present || syn.tiles_or_wavefronts) return false;
  const bool idr = IsIdr(nal_unit_type);
  if (!br->Flag()) return false;
  if (IsIrap(nal_unit_type)) sh->no_output_of_prior_pics = br->Flag();
  sh->pps_id = br->Ue();
  if (sh->pps_id > 63) return false;
  for (uint32_t i = 0; i < syn.num_extra_slice_header_bits; i++) br->Flag();
  sh->slice_type = br->Ue();
  if (sh->slice_type != kSliceP && sh->slice_type != kSliceI) return false;
  if (IsIrap(nal_unit_type) && sh->slice_type != kSliceI) return false;
  sh->pic_output = syn.output_flag_present ? br->Flag() : true;
  uint32_t num_pic_total_curr = 0;
  if (!idr) {
    if (syn.log2_max_pic_order_cnt_lsb < 4 || syn.log2_max_pic_order_cnt_lsb > 16) return false;
    sh->pic_order_cnt_lsb = br->U(static_cast<int>(syn.log2_max_pic_order_cnt_lsb));
    sh->st_rps_sps = br->Flag();
    const uint32_t num_sets = static_cast<uint32_t>(syn.sps_rps.size());
    if (!sh->st_rps_sps) {
      if (!ParseStRps(num_sets, syn.sps_rps, br, &sh->rps)) return false;
    } else {
      if (num_sets == 0) return false;
      sh->st_rps_idx = num_sets > 1 ? br->U(CeilLog2(num_sets)) : 0;
      if (sh->st_rps_idx >= num_sets) return false;
      sh->rps = syn.sps_rps[sh->st_rps_idx];
    }
    num_pic_total_curr = sh->rps.NumUsed();
    if (syn.temporal_mvp) sh->slice_temporal_mvp = br->Flag();
  }
  if (syn.sao) {
    sh->sao_luma = br->Flag();
    sh->sao_chroma = br->Flag();
  }
  if (sh->slice_type == kSliceP) {
    sh->num_ref_idx_active_override = br->Flag();
    if (sh->num_ref_idx_active_override) {
      sh->num_ref_idx_l0_active_minus1 = br->Ue();
      if (sh->num_ref_idx_l0_active_minus1 > 14) return false;
    }
    const uint32_t active = sh->num_ref_idx_active_override ? sh->num_ref_idx_l0_active_minus1
                                                            : syn.num_ref_idx_l0_default_active_minus1;
    if (syn.lists_modification_present && num_pic_total_curr > 1) {
      sh->ref_pic_list_modification_l0 = br->Flag();
      if (sh->ref_pic_list_modification_l0) {
        for (uint32_t i = 0; i <= active; i++) {
          uint32_t e = br->U(CeilLog2(num_pic_total_curr));
          if (e >= num_pic_total_curr) return false;
          sh->list_entry_l0.push_back(e);
        }
      }
    }
    if (syn.cabac_init_present) sh->cabac_init = br->Flag();
    if (sh->slice_temporal_mvp && active > 0) {
      sh->collocated_ref_idx = br->Ue();
      if (sh->collocated_ref_idx > active) return false;
    }
    if (syn.weighted_pred) return false;
    sh->five_minus_max_num_merge_cand = br->Ue();
    if (sh->five_minus_max_num_merge_cand > 4) return false;
  }
  sh->slice_qp_delta = br->Se();
  if (sh->slice_qp_delta < -87 || sh->slice_qp_delta > 77) return false;
  if (syn.slice_chroma_qp_offsets_present) {
    sh->slice_cb_qp_offset = br->Se();
    sh->slice_cr_qp_offset = br->Se();
    if (sh->slice_cb_qp_offset < -12 || sh->slice_cb_qp_offset > 12 || sh->slice_cr_qp_offset < -12 ||
        sh->slice_cr_qp_offset > 12)
      return false;
  }
  if (syn.deblocking_filter_override_enabled) sh->deblocking_filter_override = br->Flag();
  sh->slice_deblocking_filter_disabled = syn.pps_deblocking_filter_disabled;
  sh->slice_beta_offset_div2 = syn.pps_beta_offset_div2;
  sh->slice_tc_offset_div2 = syn.pps_tc_offset_div2;
  if (sh->deblocking_filter_override) {
    sh->slice_deblocking_filter_disabled = br->Flag();
    if (!sh->slice_deblocking_filter_disabled) {
      sh->slice_beta_offset_div2 = br->Se();
      sh->slice_tc_offset_div2 = br->Se();
      if (sh->slice_beta_offset_div2 < -6 || sh->slice_beta_offset_div2 > 6 || sh->slice_tc_offset_div2 < -6 ||
          sh->slice_tc_offset_div2 > 6)
        return false;
    }
  }
  sh->slice_loop_filter_across_slices = syn.loop_filter_across_slices;
  if (syn.loop_filter_across_slices &&
      (sh->sao_luma || sh->sao_chroma || !sh->slice_deblocking_filter_disabled))
    sh->slice_loop_filter_across_slices = br->Flag();
  if (syn.slice_segment_header_extension_present) {
    uint32_t len = br->Ue();
    if (len > 256) return false;
    br->Skip(static_cast<size_t>(len) * 8);
  }
  if (br->U(1) != 1) return false;
  while (!br->ByteAligned())
    if (br->U(1) != 0) return false;
  return !br->overrun();
}

FixResult FixSlice(const uint8_t* nal, size_t size, const std::vector<SliceSyntax>& driver_syntaxes,
                   const SliceSyntax& out_syntax, const SliceIntent& intent, std::vector<uint8_t>* out_nal) {
  out_nal->clear();
  if (size < 3) return FixResult::kFailed;
  const uint32_t drv_type = (nal[0] >> 1) & 0x3f;
  const uint32_t drv_layer = ((nal[0] & 1u) << 5) | (nal[1] >> 3);
  const uint32_t drv_tid_plus1 = nal[1] & 7;
  const bool idr = IsIdr(intent.nal_unit_type);

  std::vector<uint8_t> rbsp = Unescape(nal + 2, size - 2);
  const SliceSyntax* syn = nullptr;
  SliceHeader sh;
  size_t data_start = 0;
  for (const SliceSyntax& cand : driver_syntaxes) {
    BitReader br(rbsp.data(), rbsp.size());
    if (ParseSliceHeader(cand, intent.nal_unit_type, &br, &sh) && sh.slice_type == intent.slice_type) {
      syn = &cand;
      data_start = br.BitPos();
      break;
    }
  }
  if (!syn || data_start % 8 || data_start > rbsp.size() * 8) return FixResult::kFailed;

  const bool same = drv_type == intent.nal_unit_type && drv_layer == 0 && drv_tid_plus1 == 1 &&
                    !sh.no_output_of_prior_pics &&
                    (idr || (sh.pic_order_cnt_lsb == intent.pic_order_cnt_lsb && sh.rps == intent.rps)) &&
                    *syn == out_syntax;
  if (same) {
    out_nal->assign(nal, nal + size);
    return FixResult::kUnchanged;
  }

  SliceHeader nsh = sh;
  nsh.nal_unit_type = intent.nal_unit_type;
  nsh.no_output_of_prior_pics = false;
  nsh.pic_order_cnt_lsb = intent.pic_order_cnt_lsb;
  nsh.st_rps_sps = false;
  nsh.st_rps_idx = 0;
  nsh.rps = idr ? StRps() : intent.rps;
  if (sh.ref_pic_list_modification_l0 && !(sh.rps == nsh.rps)) return FixResult::kFailed;
  if (!out_syntax.output_flag_present && !sh.pic_output) return FixResult::kFailed;
  if (!out_syntax.temporal_mvp && sh.slice_temporal_mvp) return FixResult::kFailed;
  if (!out_syntax.sao && (sh.sao_luma || sh.sao_chroma)) return FixResult::kFailed;
  if (!out_syntax.cabac_init_present && sh.cabac_init) return FixResult::kFailed;
  if (sh.slice_type == kSliceP) {
    const uint32_t active = sh.num_ref_idx_active_override ? sh.num_ref_idx_l0_active_minus1
                                                           : syn->num_ref_idx_l0_default_active_minus1;
    nsh.num_ref_idx_active_override = active != out_syntax.num_ref_idx_l0_default_active_minus1;
    nsh.num_ref_idx_l0_active_minus1 = active;
  }
  nsh.slice_qp_delta = sh.slice_qp_delta + syn->init_qp_minus26 - out_syntax.init_qp_minus26;
  if (!out_syntax.slice_chroma_qp_offsets_present && (sh.slice_cb_qp_offset || sh.slice_cr_qp_offset))
    return FixResult::kFailed;
  const bool eff_disabled = sh.slice_deblocking_filter_disabled;
  const int32_t eff_beta = sh.slice_beta_offset_div2;
  const int32_t eff_tc = sh.slice_tc_offset_div2;
  const bool differs = eff_disabled != out_syntax.pps_deblocking_filter_disabled ||
                       (!eff_disabled && (eff_beta != out_syntax.pps_beta_offset_div2 ||
                                          eff_tc != out_syntax.pps_tc_offset_div2));
  if (differs && !out_syntax.deblocking_filter_override_enabled) return FixResult::kFailed;
  nsh.deblocking_filter_override = differs;

  BitWriter bw;
  if (!WriteSliceHeader(out_syntax, nsh, &bw)) return FixResult::kFailed;
  bw.AppendBytes(rbsp.data() + data_start / 8, rbsp.size() - data_start / 8);
  uint8_t header[2];
  NalHeader(intent.nal_unit_type, header);
  out_nal->insert(out_nal->end(), header, header + 2);
  std::vector<uint8_t> nrbsp = bw.Bytes();
  AppendEscaped(nrbsp.data(), nrbsp.size(), out_nal, true);
  return FixResult::kRewritten;
}

namespace {

const LevelLimits kLevels[] = {
    {30, 36864, 552960, 128},           {60, 122880, 3686400, 1500},
    {63, 245760, 7372800, 3000},        {90, 552960, 16588800, 6000},
    {93, 983040, 33177600, 10000},      {120, 2228224, 66846720, 12000},
    {123, 2228224, 133693440, 20000},   {150, 8912896, 267386880, 25000},
    {153, 8912896, 534773760, 40000},   {156, 8912896, 1069547520, 60000},
    {180, 35651584, 1069547520, 60000}, {183, 35651584, 2139095040, 120000},
    {186, 35651584, 4278190080ull, 240000},
};

}

const LevelLimits* FindLevel(uint32_t level_idc) {
  for (const LevelLimits& l : kLevels)
    if (l.level_idc == level_idc) return &l;
  return nullptr;
}

uint32_t ChooseLevel(uint32_t requested, uint32_t width, uint32_t height, double frame_rate, uint32_t bitrate) {
  const double ps = static_cast<double>(width) * height;
  for (const LevelLimits& l : kLevels) {
    if (l.level_idc < requested) continue;
    // CTS getMinLevelHEVC uses a CpbBrVclFactor of 1000
    const double max_dim = sqrt(8.0 * static_cast<double>(l.max_luma_ps));
    if (ps > static_cast<double>(l.max_luma_ps) || width > max_dim || height > max_dim) continue;
    if (ps * frame_rate > static_cast<double>(l.max_luma_sr)) continue;
    if (static_cast<double>(bitrate) > 1000.0 * l.max_br) continue;
    return l.level_idc;
  }
  return 0;
}

}

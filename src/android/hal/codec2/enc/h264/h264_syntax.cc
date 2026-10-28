#include "h264_syntax.h"

#include <math.h>

namespace rhizo::c2va::h264enc {

namespace {

// return true when the profile's SPS carries chroma info
bool HasChromaInfo(uint32_t profile_idc) {
  switch (profile_idc) {
    case 100: case 110: case 122: case 244: case 44: case 83: case 86: case 118: case 128: case 138: case 139:
    case 134: case 135:
      return true;
    default:
      return false;
  }
}

// write the vui_parameters()
void WriteVui(const Vui& v, BitWriter* bw) {
  bw->Flag(false);
  bw->Flag(false);
  bw->Flag(v.video_signal_type_present);
  if (v.video_signal_type_present) {
    bw->U(3, v.video_format);
    bw->Flag(v.full_range);
    bw->Flag(v.colour_description_present);
    if (v.colour_description_present) {
      bw->U(8, v.colour_primaries);
      bw->U(8, v.transfer_characteristics);
      bw->U(8, v.matrix_coefficients);
    }
  }
  bw->Flag(false);
  bw->Flag(v.timing_info_present);
  if (v.timing_info_present) {
    bw->U(32, v.num_units_in_tick);
    bw->U(32, v.time_scale);
    bw->Flag(v.fixed_frame_rate);
  }
  bw->Flag(false);
  bw->Flag(false);
  bw->Flag(false);
  bw->Flag(v.bitstream_restriction);
  if (v.bitstream_restriction) {
    bw->Flag(true);
    bw->Ue(0);
    bw->Ue(0);
    bw->Ue(15);
    bw->Ue(15);
    bw->Ue(v.max_num_reorder_frames);
    bw->Ue(v.max_dec_frame_buffering);
  }
}

}

bool SliceSyntax::operator==(const SliceSyntax& o) const {
  return log2_max_frame_num == o.log2_max_frame_num && pic_order_cnt_type == o.pic_order_cnt_type &&
         (pic_order_cnt_type != 0 || log2_max_pic_order_cnt_lsb == o.log2_max_pic_order_cnt_lsb) &&
         delta_pic_order_always_zero == o.delta_pic_order_always_zero &&
         bottom_field_pic_order_in_frame_present == o.bottom_field_pic_order_in_frame_present &&
         redundant_pic_cnt_present == o.redundant_pic_cnt_present && entropy_coding_mode == o.entropy_coding_mode &&
         weighted_pred == o.weighted_pred && weighted_bipred_idc == o.weighted_bipred_idc &&
         deblocking_filter_control_present == o.deblocking_filter_control_present &&
         num_ref_idx_l0_default_active_minus1 == o.num_ref_idx_l0_default_active_minus1 &&
         num_ref_idx_l1_default_active_minus1 == o.num_ref_idx_l1_default_active_minus1 &&
         pic_init_qp_minus26 == o.pic_init_qp_minus26;
}

SliceSyntax SyntaxOf(const Sps& sps, const Pps& pps) {
  SliceSyntax s;
  s.log2_max_frame_num = sps.log2_max_frame_num_minus4 + 4;
  s.pic_order_cnt_type = sps.pic_order_cnt_type;
  s.log2_max_pic_order_cnt_lsb = sps.log2_max_pic_order_cnt_lsb_minus4 + 4;
  s.bottom_field_pic_order_in_frame_present = pps.bottom_field_pic_order_in_frame_present;
  s.redundant_pic_cnt_present = pps.redundant_pic_cnt_present;
  s.entropy_coding_mode = pps.entropy_coding_mode;
  s.weighted_pred = pps.weighted_pred;
  s.weighted_bipred_idc = pps.weighted_bipred_idc;
  s.deblocking_filter_control_present = pps.deblocking_filter_control_present;
  s.num_ref_idx_l0_default_active_minus1 = pps.num_ref_idx_l0_default_active_minus1;
  s.num_ref_idx_l1_default_active_minus1 = pps.num_ref_idx_l1_default_active_minus1;
  s.pic_init_qp_minus26 = pps.pic_init_qp_minus26;
  return s;
}

void AppendSps(const Sps& sps, std::vector<uint8_t>* out) {
  BitWriter bw;
  bw.U(8, sps.profile_idc);
  bw.U(6, sps.constraint_flags);
  bw.U(2, 0);
  bw.U(8, sps.level_idc);
  bw.Ue(sps.sps_id);
  if (HasChromaInfo(sps.profile_idc)) {
    bw.Ue(1);
    bw.Ue(sps.bit_depth_luma_minus8);
    bw.Ue(sps.bit_depth_chroma_minus8);
    bw.Flag(false);
    bw.Flag(false);
  }
  bw.Ue(sps.log2_max_frame_num_minus4);
  bw.Ue(sps.pic_order_cnt_type);
  if (sps.pic_order_cnt_type == 0) bw.Ue(sps.log2_max_pic_order_cnt_lsb_minus4);
  bw.Ue(sps.max_num_ref_frames);
  bw.Flag(sps.gaps_in_frame_num_allowed);
  bw.Ue(sps.width_in_mbs - 1);
  bw.Ue(sps.height_in_mbs - 1);
  bw.Flag(true);
  bw.Flag(sps.direct_8x8_inference);
  bw.Flag(sps.frame_cropping);
  if (sps.frame_cropping) {
    bw.Ue(sps.crop_left);
    bw.Ue(sps.crop_right);
    bw.Ue(sps.crop_top);
    bw.Ue(sps.crop_bottom);
  }
  bw.Flag(sps.vui_present);
  if (sps.vui_present) WriteVui(sps.vui, &bw);
  bw.TrailingBits();
  const uint8_t header = (3 << 5) | kNalSps;
  AppendNal(&header, 1, bw.Bytes(), out);
}

void AppendPps(const Pps& pps, std::vector<uint8_t>* out) {
  BitWriter bw;
  bw.Ue(pps.pps_id);
  bw.Ue(pps.sps_id);
  bw.Flag(pps.entropy_coding_mode);
  bw.Flag(pps.bottom_field_pic_order_in_frame_present);
  bw.Ue(0);
  bw.Ue(pps.num_ref_idx_l0_default_active_minus1);
  bw.Ue(pps.num_ref_idx_l1_default_active_minus1);
  bw.Flag(pps.weighted_pred);
  bw.U(2, pps.weighted_bipred_idc);
  bw.Se(pps.pic_init_qp_minus26);
  bw.Se(pps.pic_init_qs_minus26);
  bw.Se(pps.chroma_qp_index_offset);
  bw.Flag(pps.deblocking_filter_control_present);
  bw.Flag(pps.constrained_intra_pred);
  bw.Flag(pps.redundant_pic_cnt_present);
  if (pps.high_extension) {
    bw.Flag(pps.transform_8x8_mode);
    bw.Flag(false);
    bw.Se(pps.second_chroma_qp_index_offset);
  }
  bw.TrailingBits();
  const uint8_t header = (3 << 5) | kNalPps;
  AppendNal(&header, 1, bw.Bytes(), out);
}

bool WriteSliceHeader(const SliceSyntax& syn, const SliceHeader& sh, BitWriter* bw) {
  const uint32_t type = sh.slice_type % 5;
  if (type != kSliceP && type != kSliceI) return false;
  if (syn.weighted_pred && type == kSliceP) return false;
  if (syn.pic_order_cnt_type == 1) return false;
  const bool idr = sh.nal_unit_type == kNalIdrSlice;
  bw->Ue(sh.first_mb_in_slice);
  bw->Ue(sh.slice_type);
  bw->Ue(sh.pps_id);
  bw->U(static_cast<int>(syn.log2_max_frame_num), sh.frame_num);
  if (idr) bw->Ue(sh.idr_pic_id);
  if (syn.pic_order_cnt_type == 0) {
    bw->U(static_cast<int>(syn.log2_max_pic_order_cnt_lsb), sh.pic_order_cnt_lsb);
    if (syn.bottom_field_pic_order_in_frame_present) bw->Se(sh.delta_pic_order_cnt_bottom);
  }
  if (syn.redundant_pic_cnt_present) bw->Ue(sh.redundant_pic_cnt);
  if (type == kSliceP) {
    bw->Flag(sh.num_ref_idx_active_override);
    if (sh.num_ref_idx_active_override) bw->Ue(sh.num_ref_idx_l0_active_minus1);
    bw->Flag(sh.ref_pic_list_modification_l0);
    if (sh.ref_pic_list_modification_l0) {
      for (const RefListMod& m : sh.mods_l0) {
        bw->Ue(m.idc);
        bw->Ue(m.value);
      }
      bw->Ue(3);
    }
  }
  if (sh.nal_ref_idc != 0) {
    if (idr) {
      bw->Flag(sh.no_output_of_prior_pics);
      bw->Flag(sh.long_term_reference);
    } else {
      bw->Flag(sh.adaptive_ref_pic_marking);
      if (sh.adaptive_ref_pic_marking) {
        for (const Mmco& m : sh.mmcos) {
          bw->Ue(m.op);
          if (m.op == 1 || m.op == 3) bw->Ue(m.difference_of_pic_nums_minus1);
          if (m.op == 2) bw->Ue(m.long_term_pic_num);
          if (m.op == 3 || m.op == 6) bw->Ue(m.long_term_frame_idx);
          if (m.op == 4) bw->Ue(m.max_long_term_frame_idx_plus1);
        }
        bw->Ue(0);
      }
    }
  }
  if (syn.entropy_coding_mode && type != kSliceI) bw->Ue(sh.cabac_init_idc);
  bw->Se(sh.slice_qp_delta);
  if (syn.deblocking_filter_control_present) {
    bw->Ue(sh.disable_deblocking_filter_idc);
    if (sh.disable_deblocking_filter_idc != 1) {
      bw->Se(sh.slice_alpha_c0_offset_div2);
      bw->Se(sh.slice_beta_offset_div2);
    }
  }
  return true;
}

bool ParseSliceHeader(const SliceSyntax& syn, uint32_t nal_ref_idc, uint32_t nal_unit_type, BitReader* br,
                      SliceHeader* sh) {
  *sh = SliceHeader();
  sh->nal_ref_idc = nal_ref_idc;
  sh->nal_unit_type = nal_unit_type;
  const bool idr = nal_unit_type == kNalIdrSlice;
  sh->first_mb_in_slice = br->Ue();
  sh->slice_type = br->Ue();
  if (sh->slice_type > 9) return false;
  const uint32_t type = sh->slice_type % 5;
  if (type != kSliceP && type != kSliceI) return false;
  if (idr && type != kSliceI) return false;
  sh->pps_id = br->Ue();
  if (sh->pps_id > 255) return false;
  if (syn.log2_max_frame_num < 4 || syn.log2_max_frame_num > 16) return false;
  sh->frame_num = br->U(static_cast<int>(syn.log2_max_frame_num));
  if (idr) {
    sh->idr_pic_id = br->Ue();
    if (sh->idr_pic_id > 65535) return false;
  }
  if (syn.pic_order_cnt_type == 0) {
    if (syn.log2_max_pic_order_cnt_lsb < 4 || syn.log2_max_pic_order_cnt_lsb > 16) return false;
    sh->pic_order_cnt_lsb = br->U(static_cast<int>(syn.log2_max_pic_order_cnt_lsb));
    if (syn.bottom_field_pic_order_in_frame_present) sh->delta_pic_order_cnt_bottom = br->Se();
  } else if (syn.pic_order_cnt_type == 1) {
    if (!syn.delta_pic_order_always_zero) {
      sh->delta_pic_order_cnt[0] = br->Se();
      if (syn.bottom_field_pic_order_in_frame_present) sh->delta_pic_order_cnt[1] = br->Se();
    }
  } else if (syn.pic_order_cnt_type != 2) {
    return false;
  }
  if (syn.redundant_pic_cnt_present) {
    sh->redundant_pic_cnt = br->Ue();
    if (sh->redundant_pic_cnt > 127) return false;
  }
  if (type == kSliceP) {
    sh->num_ref_idx_active_override = br->Flag();
    if (sh->num_ref_idx_active_override) {
      sh->num_ref_idx_l0_active_minus1 = br->Ue();
      if (sh->num_ref_idx_l0_active_minus1 > 31) return false;
    }
    sh->ref_pic_list_modification_l0 = br->Flag();
    if (sh->ref_pic_list_modification_l0) {
      for (;;) {
        RefListMod m;
        m.idc = br->Ue();
        if (m.idc == 3) break;
        if (m.idc > 5 || sh->mods_l0.size() > 32 || br->overrun()) return false;
        if (m.idc > 2) return false;
        m.value = br->Ue();
        sh->mods_l0.push_back(m);
      }
    }
    if (syn.weighted_pred) return false;
  }
  if (nal_ref_idc != 0) {
    if (idr) {
      sh->no_output_of_prior_pics = br->Flag();
      sh->long_term_reference = br->Flag();
    } else {
      sh->adaptive_ref_pic_marking = br->Flag();
      if (sh->adaptive_ref_pic_marking) {
        for (;;) {
          Mmco m;
          m.op = br->Ue();
          if (m.op == 0) break;
          if (m.op > 6 || sh->mmcos.size() > 66 || br->overrun()) return false;
          if (m.op == 1 || m.op == 3) m.difference_of_pic_nums_minus1 = br->Ue();
          if (m.op == 2) m.long_term_pic_num = br->Ue();
          if (m.op == 3 || m.op == 6) m.long_term_frame_idx = br->Ue();
          if (m.op == 4) m.max_long_term_frame_idx_plus1 = br->Ue();
          sh->mmcos.push_back(m);
        }
      }
    }
  }
  if (syn.entropy_coding_mode && type != kSliceI) {
    sh->cabac_init_idc = br->Ue();
    if (sh->cabac_init_idc > 2) return false;
  }
  sh->slice_qp_delta = br->Se();
  if (sh->slice_qp_delta < -87 || sh->slice_qp_delta > 77) return false;
  if (syn.deblocking_filter_control_present) {
    sh->disable_deblocking_filter_idc = br->Ue();
    if (sh->disable_deblocking_filter_idc > 2) return false;
    if (sh->disable_deblocking_filter_idc != 1) {
      sh->slice_alpha_c0_offset_div2 = br->Se();
      sh->slice_beta_offset_div2 = br->Se();
      if (sh->slice_alpha_c0_offset_div2 < -6 || sh->slice_alpha_c0_offset_div2 > 6 ||
          sh->slice_beta_offset_div2 < -6 || sh->slice_beta_offset_div2 > 6)
        return false;
    }
  }
  return !br->overrun();
}

FixResult FixSlice(const uint8_t* nal, size_t size, const SliceSyntax& driver_syntax, const SliceSyntax& out_syntax,
                   const SliceIntent& intent, std::vector<uint8_t>* out_nal) {
  out_nal->clear();
  if (size < 2) return FixResult::kFailed;
  if (driver_syntax.entropy_coding_mode != out_syntax.entropy_coding_mode ||
      driver_syntax.weighted_pred != out_syntax.weighted_pred)
    return FixResult::kFailed;
  const uint32_t drv_ref_idc = (nal[0] >> 5) & 3;
  const uint32_t drv_type = nal[0] & 31;
  const bool idr = intent.nal_unit_type == kNalIdrSlice;

  std::vector<uint8_t> rbsp = Unescape(nal + 1, size - 1);
  BitReader br(rbsp.data(), rbsp.size());
  SliceHeader sh;
  if (!ParseSliceHeader(driver_syntax, intent.nal_ref_idc, intent.nal_unit_type, &br, &sh))
    return FixResult::kFailed;
  if (sh.slice_type % 5 != intent.slice_type_mod5 || sh.first_mb_in_slice != 0) return FixResult::kFailed;
  const size_t header_end = br.BitPos();
  size_t data_start = header_end;
  if (driver_syntax.entropy_coding_mode) {
    while (data_start % 8) {
      if (br.U(1) != 1) return FixResult::kFailed;
      data_start++;
    }
  }
  if (br.overrun() || data_start > rbsp.size() * 8) return FixResult::kFailed;

  const bool marking_ok = idr ? (!sh.no_output_of_prior_pics && !sh.long_term_reference)
                              : (intent.nal_ref_idc == 0 || !sh.adaptive_ref_pic_marking);
  const bool poc_ok = driver_syntax.pic_order_cnt_type != 0 || sh.pic_order_cnt_lsb == intent.pic_order_cnt_lsb;
  const bool same = drv_ref_idc == intent.nal_ref_idc && drv_type == intent.nal_unit_type &&
                    sh.frame_num == intent.frame_num && (!idr || sh.idr_pic_id == intent.idr_pic_id) && poc_ok &&
                    marking_ok && driver_syntax == out_syntax;
  if (same) {
    out_nal->assign(nal, nal + size);
    return FixResult::kUnchanged;
  }

  if (sh.ref_pic_list_modification_l0 && sh.frame_num != intent.frame_num) return FixResult::kFailed;

  SliceHeader nsh = sh;
  nsh.nal_ref_idc = intent.nal_ref_idc;
  nsh.nal_unit_type = intent.nal_unit_type;
  nsh.frame_num = intent.frame_num;
  nsh.idr_pic_id = intent.idr_pic_id;
  nsh.pic_order_cnt_lsb = intent.pic_order_cnt_lsb;
  nsh.delta_pic_order_cnt_bottom = 0;
  nsh.no_output_of_prior_pics = false;
  nsh.long_term_reference = false;
  nsh.adaptive_ref_pic_marking = false;
  nsh.mmcos.clear();
  nsh.slice_qp_delta = sh.slice_qp_delta + driver_syntax.pic_init_qp_minus26 - out_syntax.pic_init_qp_minus26;
  if (sh.slice_type % 5 == kSliceP) {
    const uint32_t active = sh.num_ref_idx_active_override ? sh.num_ref_idx_l0_active_minus1
                                                           : driver_syntax.num_ref_idx_l0_default_active_minus1;
    nsh.num_ref_idx_active_override = active != out_syntax.num_ref_idx_l0_default_active_minus1;
    nsh.num_ref_idx_l0_active_minus1 = active;
  }
  if (!out_syntax.deblocking_filter_control_present && driver_syntax.deblocking_filter_control_present &&
      (sh.disable_deblocking_filter_idc != 0 || sh.slice_alpha_c0_offset_div2 != 0 ||
       sh.slice_beta_offset_div2 != 0))
    return FixResult::kFailed;

  BitWriter bw;
  if (!WriteSliceHeader(out_syntax, nsh, &bw)) return FixResult::kFailed;
  if (out_syntax.entropy_coding_mode) {
    bw.AlignWithOnes();
    bw.AppendBytes(rbsp.data() + data_start / 8, rbsp.size() - data_start / 8);
  } else {
    size_t stop;
    if (!RbspStopBit(rbsp, &stop) || stop < data_start) return FixResult::kFailed;
    BitReader data(rbsp.data(), rbsp.size());
    data.Skip(data_start);
    bw.CopyBits(&data, stop - data_start);
    bw.TrailingBits();
  }
  out_nal->push_back(static_cast<uint8_t>((intent.nal_ref_idc << 5) | intent.nal_unit_type));
  std::vector<uint8_t> nrbsp = bw.Bytes();
  AppendEscaped(nrbsp.data(), nrbsp.size(), out_nal, true);
  return FixResult::kRewritten;
}

bool LearnFrameNumBits(const uint8_t* nal, size_t size, const SliceSyntax& syn, const SliceIntent& intent,
                       uint32_t* bits) {
  if (size < 2 || intent.nal_unit_type != kNalIdrSlice || intent.idr_pic_id != 0) return false;
  std::vector<uint8_t> rbsp = Unescape(nal + 1, size - 1);
  for (uint32_t w = 4; w <= 16; w++) {
    SliceSyntax s = syn;
    s.log2_max_frame_num = w;
    BitReader br(rbsp.data(), rbsp.size());
    SliceHeader sh;
    if (!ParseSliceHeader(s, intent.nal_ref_idc, kNalIdrSlice, &br, &sh)) continue;
    if (sh.first_mb_in_slice != 0 || sh.slice_type % 5 != kSliceI || sh.frame_num != 0 || sh.idr_pic_id != 0)
      continue;
    bool aligned = true;
    if (s.entropy_coding_mode)
      for (size_t pos = br.BitPos(); pos % 8; pos++) aligned = aligned && br.U(1) == 1;
    if (!aligned || br.overrun()) continue;
    *bits = w;
    return true;
  }
  return false;
}

namespace {

const LevelLimits kLevels[] = {
    {10, 1485, 99, 396, 64},          {11, 3000, 396, 900, 192},       {12, 6000, 396, 2376, 384},
    {13, 11880, 396, 2376, 768},      {20, 11880, 396, 2376, 2000},    {21, 19800, 792, 4752, 4000},
    {22, 20250, 1620, 8100, 4000},    {30, 40500, 1620, 8100, 10000},  {31, 108000, 3600, 18000, 14000},
    {32, 216000, 5120, 20480, 20000}, {40, 245760, 8192, 32768, 20000}, {41, 245760, 8192, 32768, 50000},
    {42, 522240, 8704, 34816, 50000}, {50, 589824, 22080, 110400, 135000},
    {51, 983040, 36864, 184320, 240000}, {52, 2073600, 36864, 184320, 240000},
    {60, 4177920, 139264, 696320, 240000}, {61, 8355840, 139264, 696320, 480000},
    {62, 16711680, 139264, 696320, 800000},
};

}

const LevelLimits* FindLevel(uint32_t level_idc) {
  for (const LevelLimits& l : kLevels)
    if (l.level_idc == level_idc) return &l;
  return nullptr;
}

uint32_t ChooseLevel(uint32_t profile_idc, uint32_t requested, uint32_t width_in_mbs, uint32_t height_in_mbs,
                     double frame_rate, uint32_t bitrate) {
  // CTS getMinLevelAVC uses a cpbBrVclFactor of 1000
  (void)profile_idc;
  const double br_factor = 1000.0;
  const double fs = static_cast<double>(width_in_mbs) * height_in_mbs;
  if (requested == 9) requested = 11;
  for (const LevelLimits& l : kLevels) {
    if (l.level_idc < requested) continue;
    const double max_dim = sqrt(8.0 * l.max_fs);
    if (fs > l.max_fs || width_in_mbs > max_dim || height_in_mbs > max_dim) continue;
    if (fs * frame_rate > l.max_mbps) continue;
    if (static_cast<double>(bitrate) > br_factor * l.max_br) continue;
    if (l.max_dpb_mbs < fs) continue;
    return l.level_idc;
  }
  return 0;
}

}

#include "h264_dpb.h"

#include <stdint.h>

#include <algorithm>
#include <utility>

namespace rhizo::c2va::h264 {

namespace {

int ParityIndex(uint8_t structure) { return structure == kBottomField ? 1 : 0; }
uint8_t ParityBit(int index) { return index == 0 ? kTopField : kBottomField; }
bool FitsInt32(int64_t v) { return v >= INT32_MIN && v <= INT32_MAX; }
constexpr int64_t kPocOverflow = int64_t{1} << 40;

}

void Dpb::SetSequence(const Sps& sps, uint32_t dpb_size, uint32_t reorder_depth) {
  dpb_size_ = std::min<uint32_t>(std::max<uint32_t>(dpb_size, 1), kMaxDpbFrames);
  reorder_depth_ = std::min(reorder_depth, dpb_size_);
  max_num_ref_frames_ = std::max<uint32_t>(sps.max_num_ref_frames, 1);
  max_frame_num_ = sps.MaxFrameNum();
  max_poc_lsb_ = sps.MaxPicOrderCntLsb();
  poc_type_ = sps.pic_order_cnt_type;
  offset_for_non_ref_pic_ = sps.offset_for_non_ref_pic;
  offset_for_top_to_bottom_field_ = sps.offset_for_top_to_bottom_field;
  offset_for_ref_frame_ = sps.offset_for_ref_frame;
}

int Dpb::FindFree() const {
  for (int i = 0; i < kStoreSlots; i++)
    if (!stores_[i].used) return i;
  return -1;
}

int Dpb::Fullness() const {
  int n = 0;
  for (const FrameStore& fs : stores_) n += fs.used;
  return n;
}

int Dpb::RefCount() const {
  int n = 0;
  for (const FrameStore& fs : stores_) n += fs.used && fs.IsRef();
  return n;
}

void Dpb::Remove(int i) {
  sink_->RemoveStore(stores_[i]);
  if (pending_ == i) pending_ = -1;
  stores_[i] = FrameStore();
}

// remove the stores neither waiting for output nor referenced
void Dpb::RemoveUnneeded() {
  for (int i = 0; i < kStoreSlots; i++) {
    const FrameStore& fs = stores_[i];
    if (fs.used && !fs.needed_for_output && !fs.IsRef() && i != pending_) Remove(i);
  }
}

// output the waiting picture with the lowest POC
bool Dpb::Bump() {
  int best = -1;
  for (int i = 0; i < kStoreSlots; i++) {
    const FrameStore& fs = stores_[i];
    if (!fs.used || !fs.needed_for_output || i == pending_) continue;
    if (best < 0 || fs.Poc() < stores_[best].Poc() || (fs.Poc() == stores_[best].Poc() && fs.id < stores_[best].id))
      best = i;
  }
  if (best < 0) return false;
  FrameStore& fs = stores_[best];
  sink_->OutputStore(fs);
  fs.needed_for_output = false;
  fs.has_tag = false;
  if (!fs.IsRef()) Remove(best);
  return true;
}

// bump until at most max_num_reorder_frames pictures wait
void Dpb::ApplyReorderLimit() {
  if (pending_ >= 0) return;
  for (;;) {
    uint32_t waiting = 0;
    for (const FrameStore& fs : stores_) waiting += fs.used && fs.needed_for_output;
    if (waiting <= reorder_depth_ || !Bump()) return;
  }
}

// pick the reference to evict from an overfull DPB
static int PickEvictee(const std::array<FrameStore, kStoreSlots>& stores, int exclude) {
  int best = -1;
  for (int i = 0; i < kStoreSlots; i++) {
    const FrameStore& fs = stores[i];
    if (!fs.used || i == exclude || !fs.HasMark(Mark::kShort)) continue;
    if (best < 0 || fs.frame_num_wrap < stores[best].frame_num_wrap) best = i;
  }
  if (best >= 0) return best;
  for (int i = 0; i < kStoreSlots; i++) {
    const FrameStore& fs = stores[i];
    if (!fs.used || i == exclude || !fs.IsRef()) continue;
    if (best < 0 || fs.long_term_frame_idx < stores[best].long_term_frame_idx) best = i;
  }
  return best;
}

// update the FrameNumWrap of the stores
void Dpb::UpdateFrameNumWrap(uint32_t frame_num) {
  for (FrameStore& fs : stores_) {
    if (!fs.used) continue;
    const int32_t n = static_cast<int32_t>(fs.frame_num);
    fs.frame_num_wrap = fs.frame_num > frame_num ? n - static_cast<int32_t>(max_frame_num_) : n;
  }
}

// return expectedPicOrderCnt for POC type 1
int64_t Dpb::ExpectedPocType1(int64_t abs_frame_num, bool reference) const {
  int64_t expected = 0;
  int64_t n = static_cast<int64_t>(offset_for_ref_frame_.size());
  if (abs_frame_num > 0 && n > 0) {
    int64_t delta_cycle = 0;
    for (int32_t o : offset_for_ref_frame_) delta_cycle += o;
    int64_t cycle_cnt = (abs_frame_num - 1) / n;
    int64_t in_cycle = (abs_frame_num - 1) % n;
    if (__builtin_mul_overflow(cycle_cnt, delta_cycle, &expected) || expected > kPocOverflow ||
        expected < -kPocOverflow)
      return kPocOverflow;
    for (int64_t i = 0; i <= in_cycle; i++) expected += offset_for_ref_frame_[i];
  }
  if (!reference) expected += offset_for_non_ref_pic_;
  return expected;
}

bool Dpb::ComputePoc(const SliceHeader& sh, bool random_access_start, CurrentPicture* cur) {
  const bool fresh = random_access_start || !have_history_;
  int64_t top = 0, bottom = 0;
  if (poc_type_ == 0) {
    int64_t prev_msb;
    uint32_t prev_lsb;
    if (cur->idr) {
      prev_msb = 0;
      prev_lsb = 0;
    } else if (fresh) {
      prev_msb = 0;
      prev_lsb = sh.pic_order_cnt_lsb;
    } else {
      prev_msb = prev_poc_msb_;
      prev_lsb = prev_poc_lsb_;
    }
    const uint32_t lsb = sh.pic_order_cnt_lsb;
    int64_t msb;
    if (lsb < prev_lsb && (prev_lsb - lsb) >= max_poc_lsb_ / 2)
      msb = prev_msb + max_poc_lsb_;
    else if (lsb > prev_lsb && (lsb - prev_lsb) > max_poc_lsb_ / 2)
      msb = prev_msb - max_poc_lsb_;
    else
      msb = prev_msb;
    cur->poc_msb = msb;
    cur->poc_lsb = lsb;
    if (cur->structure != kBottomField) top = msb + lsb;
    if (cur->structure == kFrame)
      bottom = top + sh.delta_pic_order_cnt_bottom;
    else if (cur->structure == kBottomField)
      bottom = msb + lsb;
  } else {
    const int64_t prev_offset = fresh ? 0 : prev_frame_num_offset_;
    const uint32_t prev_frame_num = fresh ? sh.frame_num : prev_frame_num_;
    int64_t offset;
    if (cur->idr)
      offset = 0;
    else if (prev_frame_num > sh.frame_num)
      offset = prev_offset + max_frame_num_;
    else
      offset = prev_offset;
    cur->frame_num_offset = offset;
    if (poc_type_ == 1) {
      int64_t abs_frame_num = offset_for_ref_frame_.empty() ? 0 : offset + sh.frame_num;
      if (!cur->reference && abs_frame_num > 0) abs_frame_num--;
      const int64_t expected = ExpectedPocType1(abs_frame_num, cur->reference);
      if (cur->structure == kFrame) {
        top = expected + sh.delta_pic_order_cnt[0];
        bottom = top + offset_for_top_to_bottom_field_ + sh.delta_pic_order_cnt[1];
      } else if (cur->structure == kTopField) {
        top = expected + sh.delta_pic_order_cnt[0];
      } else {
        bottom = expected + offset_for_top_to_bottom_field_ + sh.delta_pic_order_cnt[0];
      }
    } else {
      int64_t t;
      if (cur->idr)
        t = 0;
      else if (!cur->reference)
        t = 2 * (offset + sh.frame_num) - 1;
      else
        t = 2 * (offset + sh.frame_num);
      if (cur->structure != kBottomField) top = t;
      if (cur->structure != kTopField) bottom = t;
    }
  }
  if (!FitsInt32(top) || !FitsInt32(bottom)) return false;
  cur->poc[0] = static_cast<int32_t>(top);
  cur->poc[1] = static_cast<int32_t>(bottom);
  return true;
}

// unmark the oldest short-term references beyond max_num_ref_frames
void Dpb::SlidingWindow(int exclude_store) {
  for (;;) {
    uint32_t num_short = 0, num_long = 0;
    for (int i = 0; i < kStoreSlots; i++) {
      const FrameStore& fs = stores_[i];
      if (!fs.used || i == exclude_store) continue;
      num_short += fs.HasMark(Mark::kShort);
      num_long += fs.HasMark(Mark::kLong);
    }
    if (num_short + num_long < max_num_ref_frames_ || num_short == 0) return;
    int best = -1;
    for (int i = 0; i < kStoreSlots; i++) {
      const FrameStore& fs = stores_[i];
      if (!fs.used || i == exclude_store || !fs.HasMark(Mark::kShort)) continue;
      if (best < 0 || fs.frame_num_wrap < stores_[best].frame_num_wrap ||
          (fs.frame_num_wrap == stores_[best].frame_num_wrap && fs.id < stores_[best].id))
        best = i;
    }
    for (Mark& m : stores_[best].mark)
      if (m == Mark::kShort) m = Mark::kUnused;
  }
}

// insert the inferred frames for a frame_num gap
void Dpb::FillFrameNumGap(uint32_t frame_num) {
  uint32_t unused = (prev_ref_frame_num_ + 1) % max_frame_num_;
  for (uint32_t guard = 0; unused != frame_num && guard < max_frame_num_; guard++) {
    UpdateFrameNumWrap(unused);
    SlidingWindow(-1);
    RemoveUnneeded();
    for (int g = 0; Full() && g < 2 * kStoreSlots; g++) {
      if (Bump()) continue;
      int victim = PickEvictee(stores_, -1);
      if (victim < 0) break;
      stores_[victim].mark[0] = stores_[victim].mark[1] = Mark::kUnused;
      RemoveUnneeded();
    }
    int64_t offset = prev_frame_num_ > unused ? prev_frame_num_offset_ + max_frame_num_ : prev_frame_num_offset_;
    int64_t poc = 0;
    if (poc_type_ == 1)
      poc = ExpectedPocType1(offset_for_ref_frame_.empty() ? 0 : offset + unused, true);
    else if (poc_type_ == 2)
      poc = 2 * (offset + unused);
    if (!FitsInt32(poc)) poc = 0;
    prev_frame_num_offset_ = offset;
    prev_frame_num_ = unused;
    int slot = FindFree();
    if (slot < 0) return;
    FrameStore& fs = stores_[slot];
    fs = FrameStore();
    fs.used = true;
    fs.id = next_id_++;
    fs.non_existing = true;
    fs.fields = kFrame;
    fs.mark[0] = fs.mark[1] = Mark::kShort;
    fs.poc[0] = fs.poc[1] = static_cast<int32_t>(poc);
    fs.frame_num = unused;
    prev_ref_frame_num_ = unused;
    unused = (unused + 1) % max_frame_num_;
  }
}

bool Dpb::StartPicture(const SliceHeader& sh, bool random_access_start, CurrentPicture* cur) {
  cur->structure = !sh.field_pic_flag ? kFrame : (sh.bottom_field_flag ? kBottomField : kTopField);
  cur->idr = sh.idr_pic_flag;
  cur->reference = sh.nal.nal_ref_idc != 0;
  cur->mmco5 = sh.HasMmco5();
  cur->frame_num = sh.frame_num;
  cur->second_field = false;
  cur->store = -1;

  if (cur->structure != kFrame && pending_ >= 0) {
    const FrameStore& fs = stores_[pending_];
    if (fs.fields != cur->structure && fs.frame_num == sh.frame_num && !cur->idr) {
      if ((pending_first_ref_ && cur->reference && !cur->mmco5) || (!pending_first_ref_ && !cur->reference)) {
        cur->second_field = true;
        cur->store = pending_;
      }
    }
  }
  if (!cur->second_field) ClosePendingField();

  if (!cur->second_field && !cur->idr && !random_access_start && have_history_ && sh.frame_num != prev_ref_frame_num_ &&
      sh.frame_num != (prev_ref_frame_num_ + 1) % max_frame_num_)
    FillFrameNumGap(sh.frame_num);
  if (random_access_start || !have_history_)
    prev_ref_frame_num_ = cur->reference ? sh.frame_num : (sh.frame_num + max_frame_num_ - 1) % max_frame_num_;
  return ComputePoc(sh, random_access_start, cur);
}

void Dpb::PredictMarking(const SliceHeader& sh, CurrentPicture* cur) const {
  cur->long_term = false;
  if (!cur->reference) return;
  if (cur->idr) {
    cur->long_term = sh.long_term_reference_flag;
    return;
  }
  for (const Mmco& m : sh.mmcos)
    if (m.op == 6) cur->long_term = true;
  if (cur->second_field) {
    const FrameStore& fs = stores_[cur->store];
    if (fs.mark[fs.fields == kTopField ? 0 : 1] == Mark::kLong) cur->long_term = true;
  }
}

int32_t Dpb::PicNumOf(int store, int parity_bit, const CurrentPicture& cur) const {
  const FrameStore& fs = stores_[store];
  if (cur.structure == kFrame) return fs.frame_num_wrap;
  return 2 * fs.frame_num_wrap + (parity_bit == cur.structure ? 1 : 0);
}

int32_t Dpb::LongTermPicNumOf(int store, int parity_bit, const CurrentPicture& cur) const {
  const FrameStore& fs = stores_[store];
  int32_t idx = static_cast<int32_t>(fs.long_term_frame_idx);
  if (cur.structure == kFrame) return idx;
  return 2 * idx + (parity_bit == cur.structure ? 1 : 0);
}

// apply the slice's memory management control operations
void Dpb::ApplyMmcos(const SliceHeader& sh, CurrentPicture* cur, uint32_t* cur_ltfi, bool* cur_long) {
  UpdateFrameNumWrap(cur->frame_num);
  const bool field = cur->structure != kFrame;
  const int64_t curr_pic_num = field ? 2 * int64_t{cur->frame_num} + 1 : cur->frame_num;
  auto find = [&](Mark want, int64_t num, int* out_store, int* out_parity) {
    for (int i = 0; i < kStoreSlots; i++) {
      const FrameStore& fs = stores_[i];
      if (!fs.used) continue;
      if (!field) {
        if (fs.fields != kFrame || fs.mark[0] != want || fs.mark[1] != want) continue;
        int64_t n = want == Mark::kShort ? fs.frame_num_wrap : static_cast<int64_t>(fs.long_term_frame_idx);
        if (n == num) {
          *out_store = i;
          *out_parity = -1;
          return true;
        }
        continue;
      }
      for (int p = 0; p < 2; p++) {
        if (!(fs.fields & ParityBit(p)) || fs.mark[p] != want) continue;
        int64_t n = want == Mark::kShort ? PicNumOf(i, ParityBit(p), *cur) : LongTermPicNumOf(i, ParityBit(p), *cur);
        if (n == num) {
          *out_store = i;
          *out_parity = p;
          return true;
        }
      }
    }
    return false;
  };
  auto unmark_long = [&](FrameStore& fs) {
    for (Mark& m : fs.mark)
      if (m == Mark::kLong) m = Mark::kUnused;
  };

  for (const Mmco& m : sh.mmcos) {
    int s = -1, p = -1;
    switch (m.op) {
      case 1:
        if (find(Mark::kShort, curr_pic_num - (int64_t{m.difference_of_pic_nums_minus1} + 1), &s, &p)) {
          if (p < 0)
            stores_[s].mark[0] = stores_[s].mark[1] = Mark::kUnused;
          else
            stores_[s].mark[p] = Mark::kUnused;
        }
        break;
      case 2:
        if (find(Mark::kLong, m.long_term_pic_num, &s, &p)) {
          if (p < 0)
            stores_[s].mark[0] = stores_[s].mark[1] = Mark::kUnused;
          else
            stores_[s].mark[p] = Mark::kUnused;
        }
        break;
      case 3: {
        if (!find(Mark::kShort, curr_pic_num - (int64_t{m.difference_of_pic_nums_minus1} + 1), &s, &p)) break;
        if (max_long_term_frame_idx_ == kNoLongTermFrameIdx || m.long_term_frame_idx > max_long_term_frame_idx_)
          break;
        for (int i = 0; i < kStoreSlots; i++) {
          FrameStore& fs = stores_[i];
          if (fs.used && i != s && fs.HasMark(Mark::kLong) && fs.long_term_frame_idx == m.long_term_frame_idx)
            unmark_long(fs);
        }
        FrameStore& fs = stores_[s];
        if (p >= 0 && fs.mark[1 - p] == Mark::kLong && fs.long_term_frame_idx != m.long_term_frame_idx)
          fs.mark[1 - p] = Mark::kUnused;
        if (p < 0)
          fs.mark[0] = fs.mark[1] = Mark::kLong;
        else
          fs.mark[p] = Mark::kLong;
        fs.long_term_frame_idx = m.long_term_frame_idx;
        break;
      }
      case 4:
        max_long_term_frame_idx_ =
            m.max_long_term_frame_idx_plus1 == 0 ? kNoLongTermFrameIdx : m.max_long_term_frame_idx_plus1 - 1;
        for (FrameStore& fs : stores_) {
          if (fs.used && fs.HasMark(Mark::kLong) &&
              (max_long_term_frame_idx_ == kNoLongTermFrameIdx || fs.long_term_frame_idx > max_long_term_frame_idx_))
            unmark_long(fs);
        }
        break;
      case 5:
        for (FrameStore& fs : stores_) fs.mark[0] = fs.mark[1] = Mark::kUnused;
        max_long_term_frame_idx_ = kNoLongTermFrameIdx;
        break;
      case 6:
        if (max_long_term_frame_idx_ == kNoLongTermFrameIdx || m.long_term_frame_idx > max_long_term_frame_idx_)
          break;
        for (int i = 0; i < kStoreSlots; i++) {
          FrameStore& fs = stores_[i];
          if (!fs.used || !fs.HasMark(Mark::kLong) || fs.long_term_frame_idx != m.long_term_frame_idx) continue;
          if (cur->second_field && i == cur->store) continue;
          unmark_long(fs);
        }
        *cur_long = true;
        *cur_ltfi = m.long_term_frame_idx;
        break;
      default:
        break;
    }
  }
}

// unmark the references beyond max_num_ref_frames
void Dpb::EnforceRefLimit(const CurrentPicture& cur) {
  int count = RefCount() + ((cur.reference && !cur.second_field) ? 1 : 0);
  while (count > static_cast<int>(max_num_ref_frames_)) {
    int victim = PickEvictee(stores_, cur.second_field ? cur.store : -1);
    if (victim < 0) return;
    stores_[victim].mark[0] = stores_[victim].mark[1] = Mark::kUnused;
    count--;
  }
}

void Dpb::StoreNew(const CurrentPicture& cur, Mark mark, uint32_t ltfi, VASurfaceID surface, bool output,
                   uint64_t tag, const Rect& crop, const ColorInfo& color, uint64_t* id) {
  int slot = FindFree();
  FrameStore& fs = stores_[slot];
  fs = FrameStore();
  fs.used = true;
  fs.id = next_id_++;
  fs.surface = surface;
  fs.fields = cur.structure;
  for (int p = 0; p < 2; p++) {
    if (!(cur.structure & ParityBit(p))) continue;
    fs.mark[p] = mark;
    fs.poc[p] = cur.poc[p];
  }
  fs.frame_num = cur.frame_num;
  fs.long_term_frame_idx = ltfi;
  fs.needed_for_output = output;
  fs.has_tag = output;
  fs.tag = tag;
  fs.crop = crop;
  fs.color = color;
  if (cur.structure != kFrame) {
    pending_ = slot;
    pending_first_ref_ = cur.reference;
  }
  *id = fs.id;
}

uint64_t Dpb::FinishPicture(const SliceHeader& sh, CurrentPicture* cur, VASurfaceID surface, bool output,
                            uint64_t tag, const Rect& crop, const ColorInfo& color) {
  Mark cur_mark = Mark::kUnused;
  uint32_t cur_ltfi = 0;
  if (cur->reference) {
    if (cur->idr) {
      for (FrameStore& fs : stores_) fs.mark[0] = fs.mark[1] = Mark::kUnused;
      if (sh.long_term_reference_flag) {
        cur_mark = Mark::kLong;
        max_long_term_frame_idx_ = 0;
      } else {
        cur_mark = Mark::kShort;
        max_long_term_frame_idx_ = kNoLongTermFrameIdx;
      }
    } else {
      auto first_mark = [&]() {
        if (!cur->second_field) return Mark::kUnused;
        const FrameStore& fs = stores_[cur->store];
        return fs.mark[fs.fields == kTopField ? 0 : 1];
      };
      bool cur_long = false;
      if (sh.adaptive_ref_pic_marking_mode_flag) {
        ApplyMmcos(sh, cur, &cur_ltfi, &cur_long);
      } else if (first_mark() == Mark::kUnused) {
        UpdateFrameNumWrap(cur->frame_num);
        SlidingWindow(cur->second_field ? cur->store : -1);
      }
      if (cur_long) {
        cur_mark = Mark::kLong;
      } else if (first_mark() == Mark::kLong) {
        cur_mark = Mark::kLong;
        cur_ltfi = stores_[cur->store].long_term_frame_idx;
      } else {
        cur_mark = Mark::kShort;
      }
    }
    UpdateFrameNumWrap(cur->frame_num);
    EnforceRefLimit(*cur);
  }

  if (cur->mmco5) {
    const int32_t temp = cur->Poc();
    if (cur->structure & kTopField) cur->poc[0] -= temp;
    if (cur->structure & kBottomField) cur->poc[1] -= temp;
    cur->frame_num = 0;
  }

  uint64_t id = 0;
  if (cur->second_field) {
    FrameStore& fs = stores_[cur->store];
    const int p = ParityIndex(cur->structure);
    fs.fields |= cur->structure;
    fs.mark[p] = cur_mark;
    fs.poc[p] = cur->poc[p];
    if (cur_mark == Mark::kLong) fs.long_term_frame_idx = cur_ltfi;
    if (cur->mmco5) fs.frame_num = 0;
    id = fs.id;
    pending_ = -1;
    RemoveUnneeded();
    if (fs.used && fs.output_when_complete) {
      fs.output_when_complete = false;
      if (fs.needed_for_output) {
        sink_->OutputStore(fs);
        fs.needed_for_output = false;
        fs.has_tag = false;
      }
      if (!fs.IsRef()) Remove(cur->store);
    }
  } else {
    RemoveUnneeded();
    bool direct = false, overflow = false;
    for (int guard = 0; Full() && guard < 2 * kStoreSlots; guard++) {
      if (!cur->reference) {
        bool lowest = true;
        for (const FrameStore& fs : stores_)
          if (fs.used && fs.needed_for_output && fs.Poc() <= cur->Poc()) lowest = false;
        if (lowest) {
          if (cur->structure == kFrame)
            direct = true;
          else
            overflow = true;
          break;
        }
      }
      if (Bump()) continue;
      int victim = PickEvictee(stores_, -1);
      if (victim < 0) break;
      stores_[victim].mark[0] = stores_[victim].mark[1] = Mark::kUnused;
      RemoveUnneeded();
    }
    if (direct || FindFree() < 0) {
      FrameStore tmp;
      tmp.used = true;
      tmp.surface = surface;
      tmp.fields = cur->structure;
      tmp.poc[0] = cur->poc[0];
      tmp.poc[1] = cur->poc[1];
      tmp.crop = crop;
      tmp.color = color;
      tmp.tag = tag;
      if (output) {
        tmp.has_tag = true;
        sink_->OutputStore(tmp);
        tmp.has_tag = false;
      }
      sink_->RemoveStore(tmp);
    } else {
      StoreNew(*cur, cur_mark, cur_ltfi, surface, output, tag, crop, color, &id);
      if (overflow) stores_[pending_].output_when_complete = true;
    }
  }

  have_history_ = true;
  if (cur->reference) {
    if (cur->mmco5) {
      prev_poc_msb_ = 0;
      prev_poc_lsb_ = cur->structure == kBottomField ? 0 : static_cast<uint32_t>(cur->poc[0]);
    } else {
      prev_poc_msb_ = cur->poc_msb;
      prev_poc_lsb_ = cur->poc_lsb;
    }
    prev_ref_frame_num_ = cur->frame_num;
  }
  prev_frame_num_ = cur->frame_num;
  prev_frame_num_offset_ = cur->mmco5 ? 0 : cur->frame_num_offset;
  ApplyReorderLimit();
  return id;
}

void Dpb::ClosePendingField() {
  if (pending_ < 0) return;
  const int i = pending_;
  pending_ = -1;
  FrameStore& fs = stores_[i];
  if (fs.output_when_complete) {
    fs.output_when_complete = false;
    if (fs.needed_for_output) {
      sink_->OutputStore(fs);
      fs.needed_for_output = false;
      fs.has_tag = false;
    }
    if (!fs.IsRef()) Remove(i);
  }
  RemoveUnneeded();
  ApplyReorderLimit();
}

void Dpb::Flush(bool output) {
  ClosePendingField();
  if (output)
    while (Bump()) {
    }
  for (int i = 0; i < kStoreSlots; i++)
    if (stores_[i].used) Remove(i);
}

void Dpb::OutputAll() {
  ClosePendingField();
  while (Bump()) {
  }
  RemoveUnneeded();
}

void Dpb::Clear() {
  pending_ = -1;
  for (int i = 0; i < kStoreSlots; i++)
    if (stores_[i].used) Remove(i);
  max_long_term_frame_idx_ = kNoLongTermFrameIdx;
}

// alternate the fields of the frames by parity
std::vector<RefEntry> Dpb::AlternateFields(const std::vector<int>& frames, Mark want, uint8_t cur_parity) const {
  const int same = ParityIndex(cur_parity), opp = 1 - same;
  auto has = [&](size_t k, int p) {
    const FrameStore& fs = stores_[frames[k]];
    return (fs.fields & ParityBit(p)) && fs.mark[p] == want;
  };
  auto entry = [&](size_t k, int p) {
    RefEntry e;
    e.store = static_cast<int8_t>(frames[k]);
    e.structure = ParityBit(p);
    e.long_term = want == Mark::kLong;
    return e;
  };
  std::vector<RefEntry> out;
  size_t is = 0, io = 0;
  bool take_same = true;
  for (;;) {
    const int p = take_same ? same : opp;
    size_t& k = take_same ? is : io;
    while (k < frames.size() && !has(k, p)) k++;
    if (k < frames.size()) {
      out.push_back(entry(k, p));
      k++;
      take_same = !take_same;
      continue;
    }
    const int q = take_same ? opp : same;
    size_t& r = take_same ? io : is;
    for (; r < frames.size(); r++)
      if (has(r, q)) out.push_back(entry(r, q));
    break;
  }
  return out;
}

// apply the slice's reference list modifications
void Dpb::ModifyList(const SliceHeader& sh, int list, const CurrentPicture& cur, std::vector<RefEntry>* refs,
                     bool* missing) {
  if (!sh.ref_pic_list_modification_flag[list]) return;
  const bool field = cur.structure != kFrame;
  const size_t n = refs->size();
  refs->resize(n + 1);
  const int64_t max_pic_num = field ? 2 * int64_t{max_frame_num_} : max_frame_num_;
  const int64_t curr_pic_num = field ? 2 * int64_t{cur.frame_num} + 1 : cur.frame_num;
  int64_t pred = curr_pic_num;
  size_t ref_idx = 0;
  for (const RefListModification& m : sh.modifications[list]) {
    if (ref_idx > n) break;
    const bool long_term = m.modification_of_pic_nums_idc == 2;
    int64_t key;
    if (!long_term) {
      const int64_t abs_diff = int64_t{m.value} + 1;
      int64_t no_wrap;
      if (m.modification_of_pic_nums_idc == 0) {
        no_wrap = pred - abs_diff;
        if (no_wrap < 0) no_wrap += max_pic_num;
      } else {
        no_wrap = pred + abs_diff;
        if (no_wrap >= max_pic_num) no_wrap -= max_pic_num;
      }
      pred = no_wrap;
      key = no_wrap > curr_pic_num ? no_wrap - max_pic_num : no_wrap;
    } else {
      key = m.value;
    }
    RefEntry target;
    const Mark want = long_term ? Mark::kLong : Mark::kShort;
    for (int i = 0; i < kStoreSlots && target.store < 0; i++) {
      const FrameStore& fs = stores_[i];
      if (!fs.used) continue;
      if (!field) {
        if (fs.fields != kFrame || fs.mark[0] != want || fs.mark[1] != want) continue;
        if ((long_term ? LongTermPicNumOf(i, kFrame, cur) : PicNumOf(i, kFrame, cur)) == key) {
          target.store = static_cast<int8_t>(i);
          target.structure = kFrame;
          target.long_term = long_term;
        }
        continue;
      }
      for (int p = 0; p < 2; p++) {
        if (!(fs.fields & ParityBit(p)) || fs.mark[p] != want) continue;
        if ((long_term ? LongTermPicNumOf(i, ParityBit(p), cur) : PicNumOf(i, ParityBit(p), cur)) == key) {
          target.store = static_cast<int8_t>(i);
          target.structure = ParityBit(p);
          target.long_term = long_term;
          break;
        }
      }
    }
    if (target.store < 0) *missing = true;
    for (size_t c = n; c > ref_idx; c--) (*refs)[c] = (*refs)[c - 1];
    (*refs)[ref_idx++] = target;
    size_t nidx = ref_idx;
    for (size_t c = ref_idx; c <= n; c++) {
      const RefEntry& e = (*refs)[c];
      bool same = false;
      if (e.store >= 0 && e.long_term == long_term)
        same = (long_term ? LongTermPicNumOf(e.store, e.structure, cur) : PicNumOf(e.store, e.structure, cur)) == key;
      if (!same) (*refs)[nidx++] = e;
    }
  }
  refs->resize(n);
}

bool Dpb::BuildRefLists(const SliceHeader& sh, const CurrentPicture& cur, std::vector<RefEntry>* l0,
                        std::vector<RefEntry>* l1) {
  l0->clear();
  l1->clear();
  if (sh.slice_type == kSliceI || sh.slice_type == kSliceSI) return true;
  UpdateFrameNumWrap(cur.frame_num);
  const bool b = sh.slice_type == kSliceB;
  const bool field = cur.structure != kFrame;
  std::vector<int> st, lt;
  for (int i = 0; i < kStoreSlots; i++) {
    const FrameStore& fs = stores_[i];
    if (!fs.used) continue;
    if (!field) {
      if (fs.fields != kFrame) continue;
      if (fs.mark[0] == Mark::kShort && fs.mark[1] == Mark::kShort && !(b && fs.non_existing)) st.push_back(i);
      if (fs.mark[0] == Mark::kLong && fs.mark[1] == Mark::kLong) lt.push_back(i);
    } else {
      bool s = ((fs.fields & kTopField) && fs.mark[0] == Mark::kShort) ||
               ((fs.fields & kBottomField) && fs.mark[1] == Mark::kShort);
      bool l = ((fs.fields & kTopField) && fs.mark[0] == Mark::kLong) ||
               ((fs.fields & kBottomField) && fs.mark[1] == Mark::kLong);
      if (s && !(b && fs.non_existing)) st.push_back(i);
      if (l) lt.push_back(i);
    }
  }
  auto by_ltfi = [&](int a, int c) {
    const FrameStore &x = stores_[a], &y = stores_[c];
    return x.long_term_frame_idx != y.long_term_frame_idx ? x.long_term_frame_idx < y.long_term_frame_idx : x.id < y.id;
  };
  std::sort(lt.begin(), lt.end(), by_ltfi);

  std::vector<RefEntry> init0, init1;
  auto frames_to_entries = [&](const std::vector<int>& v, bool long_term, std::vector<RefEntry>* out) {
    for (int i : v) {
      RefEntry e;
      e.store = static_cast<int8_t>(i);
      e.structure = kFrame;
      e.long_term = long_term;
      out->push_back(e);
    }
  };
  if (!b) {
    std::sort(st.begin(), st.end(), [&](int a, int c) {
      const FrameStore &x = stores_[a], &y = stores_[c];
      return x.frame_num_wrap != y.frame_num_wrap ? x.frame_num_wrap > y.frame_num_wrap : x.id > y.id;
    });
    if (!field) {
      frames_to_entries(st, false, &init0);
      frames_to_entries(lt, true, &init0);
    } else {
      init0 = AlternateFields(st, Mark::kShort, cur.structure);
      std::vector<RefEntry> lf = AlternateFields(lt, Mark::kLong, cur.structure);
      init0.insert(init0.end(), lf.begin(), lf.end());
    }
  } else {
    auto entry_poc = [&](int i) {
      const FrameStore& fs = stores_[i];
      if (!field) return fs.Poc();
      bool t = (fs.fields & kTopField) && fs.mark[0] == Mark::kShort;
      bool bo = (fs.fields & kBottomField) && fs.mark[1] == Mark::kShort;
      if (t && bo) return std::min(fs.poc[0], fs.poc[1]);
      return t ? fs.poc[0] : fs.poc[1];
    };
    const int32_t poc = cur.Poc();
    std::vector<int> before, after;
    for (int i : st) (entry_poc(i) <= poc ? before : after).push_back(i);
    std::sort(before.begin(), before.end(), [&](int a, int c) {
      return entry_poc(a) != entry_poc(c) ? entry_poc(a) > entry_poc(c) : stores_[a].id > stores_[c].id;
    });
    std::sort(after.begin(), after.end(), [&](int a, int c) {
      return entry_poc(a) != entry_poc(c) ? entry_poc(a) < entry_poc(c) : stores_[a].id < stores_[c].id;
    });
    std::vector<int> s0 = before, s1 = after;
    s0.insert(s0.end(), after.begin(), after.end());
    s1.insert(s1.end(), before.begin(), before.end());
    if (!field) {
      frames_to_entries(s0, false, &init0);
      frames_to_entries(lt, true, &init0);
      frames_to_entries(s1, false, &init1);
      frames_to_entries(lt, true, &init1);
    } else {
      std::vector<RefEntry> lf = AlternateFields(lt, Mark::kLong, cur.structure);
      init0 = AlternateFields(s0, Mark::kShort, cur.structure);
      init0.insert(init0.end(), lf.begin(), lf.end());
      init1 = AlternateFields(s1, Mark::kShort, cur.structure);
      init1.insert(init1.end(), lf.begin(), lf.end());
    }
    if (init1.size() > 1 && init1 == init0) std::swap(init1[0], init1[1]);
  }
  init0.resize(sh.num_ref_idx_l0_active_minus1 + 1);
  bool missing = false;
  ModifyList(sh, 0, cur, &init0, &missing);
  *l0 = std::move(init0);
  if (b) {
    init1.resize(sh.num_ref_idx_l1_active_minus1 + 1);
    ModifyList(sh, 1, cur, &init1, &missing);
    *l1 = std::move(init1);
  }
  return !missing;
}

}

#ifndef RHIZO_C2VA_H264_DPB_H
#define RHIZO_C2VA_H264_DPB_H

// the H.264 decoded picture buffer

#include <stddef.h>
#include <stdint.h>

#include <array>
#include <vector>

#include <va/va.h>

#include "../../va/core.h"
#include "h264_syntax.h"

namespace rhizo::c2va::h264 {

enum class Mark : uint8_t { kUnused, kShort, kLong };

enum Structure : uint8_t { kTopField = 1, kBottomField = 2, kFrame = 3 };

constexpr int kMaxDpbFrames = 16;
constexpr int kStoreSlots = kMaxDpbFrames + 1;
constexpr uint32_t kNoLongTermFrameIdx = 0xffffffff;

struct FrameStore {
  bool used = false;
  uint64_t id = 0;
  VASurfaceID surface = VA_INVALID_SURFACE;
  bool non_existing = false;
  uint8_t fields = 0;
  Mark mark[2] = {Mark::kUnused, Mark::kUnused};
  int32_t poc[2] = {0, 0};
  uint32_t frame_num = 0;
  int32_t frame_num_wrap = 0;
  uint32_t long_term_frame_idx = 0;
  bool needed_for_output = false;
  bool has_tag = false;
  uint64_t tag = 0;
  bool output_when_complete = false;
  Rect crop = {};
  ColorInfo color;

  bool IsRef() const { return mark[0] != Mark::kUnused || mark[1] != Mark::kUnused; }
  bool HasMark(Mark m) const { return mark[0] == m || mark[1] == m; }
  // return PicOrderCnt() of the frame, field pair or field
  int32_t Poc() const {
    if (fields == kFrame) return poc[0] < poc[1] ? poc[0] : poc[1];
    return fields == kTopField ? poc[0] : poc[1];
  }
};

// entry of RefPicList0/1
struct RefEntry {
  int8_t store = -1;
  uint8_t structure = kFrame;
  bool long_term = false;

  bool operator==(const RefEntry& o) const {
    return store == o.store && structure == o.structure && long_term == o.long_term;
  }
};

// DPB state of the picture being decoded
struct CurrentPicture {
  uint8_t structure = kFrame;
  bool second_field = false;
  int store = -1;
  bool idr = false;
  bool reference = false;
  bool mmco5 = false;
  bool long_term = false;
  uint32_t frame_num = 0;
  int32_t poc[2] = {0, 0};
  int64_t poc_msb = 0;
  uint32_t poc_lsb = 0;
  int64_t frame_num_offset = 0;

  int32_t Poc() const {
    if (structure == kFrame) return poc[0] < poc[1] ? poc[0] : poc[1];
    return structure == kTopField ? poc[0] : poc[1];
  }
};

// receiver of the pictures leaving the DPB
class DpbSink {
 public:
  virtual ~DpbSink() = default;
  // output a store with a tag
  virtual void OutputStore(const FrameStore& fs) = 0;
  // release an emptied store's tag and surface
  virtual void RemoveStore(const FrameStore& fs) = 0;
};

class Dpb {
 public:
  explicit Dpb(DpbSink* sink) : sink_(sink) {}

  // set the sequence parameters after a flush
  void SetSequence(const Sps& sps, uint32_t dpb_size, uint32_t reorder_depth);

  // start a picture and compute its POC
  bool StartPicture(const SliceHeader& sh, bool random_access_start, CurrentPicture* cur);
  // build the reference lists of a slice
  bool BuildRefLists(const SliceHeader& sh, const CurrentPicture& cur, std::vector<RefEntry>* l0,
                     std::vector<RefEntry>* l1);
  // derive the picture's marking from its first slice
  void PredictMarking(const SliceHeader& sh, CurrentPicture* cur) const;
  // mark, store and output the decoded picture
  uint64_t FinishPicture(const SliceHeader& sh, CurrentPicture* cur, VASurfaceID surface, bool output, uint64_t tag,
                         const Rect& crop, const ColorInfo& color);

  // empty the DPB
  void Flush(bool output);
  // output all waiting pictures and keep the references
  void OutputAll();
  // close a pending first field as a non-paired field
  void ClosePendingField();
  // drop all pictures without output
  void Clear();
  // clear the POC and frame_num history
  void ResetHistory() { have_history_ = false; }

  const FrameStore& store(int i) const { return stores_[i]; }
  int slots() const { return kStoreSlots; }
  bool pending_field() const { return pending_ >= 0; }
  uint32_t max_long_term_frame_idx() const { return max_long_term_frame_idx_; }
  // count the stores holding a reference field or frame
  int RefCount() const;

 private:
  int FindFree() const;
  int Fullness() const;
  bool Full() const { return Fullness() >= static_cast<int>(dpb_size_); }
  void Remove(int i);
  void RemoveUnneeded();
  bool Bump();
  void ApplyReorderLimit();
  void UpdateFrameNumWrap(uint32_t frame_num);
  bool ComputePoc(const SliceHeader& sh, bool random_access_start, CurrentPicture* cur);
  int64_t ExpectedPocType1(int64_t abs_frame_num, bool reference) const;
  void FillFrameNumGap(uint32_t frame_num);
  void SlidingWindow(int exclude_store);
  void ApplyMmcos(const SliceHeader& sh, CurrentPicture* cur, uint32_t* cur_ltfi, bool* cur_long);
  void EnforceRefLimit(const CurrentPicture& cur);
  int32_t PicNumOf(int store, int parity_bit, const CurrentPicture& cur) const;
  int32_t LongTermPicNumOf(int store, int parity_bit, const CurrentPicture& cur) const;
  void ModifyList(const SliceHeader& sh, int list, const CurrentPicture& cur, std::vector<RefEntry>* refs,
                  bool* missing);
  std::vector<RefEntry> AlternateFields(const std::vector<int>& frames, Mark want, uint8_t cur_parity) const;
  void StoreNew(const CurrentPicture& cur, Mark mark, uint32_t ltfi, VASurfaceID surface, bool output, uint64_t tag,
                const Rect& crop, const ColorInfo& color, uint64_t* id);

  DpbSink* sink_;
  std::array<FrameStore, kStoreSlots> stores_;
  uint64_t next_id_ = 1;
  int pending_ = -1;
  bool pending_first_ref_ = false;

  uint32_t dpb_size_ = 1;
  uint32_t reorder_depth_ = 0;
  uint32_t max_num_ref_frames_ = 1;
  uint32_t max_frame_num_ = 16;
  uint32_t max_poc_lsb_ = 16;
  uint32_t poc_type_ = 0;
  int32_t offset_for_non_ref_pic_ = 0;
  int32_t offset_for_top_to_bottom_field_ = 0;
  std::vector<int32_t> offset_for_ref_frame_;

  bool have_history_ = false;
  int64_t prev_poc_msb_ = 0;
  uint32_t prev_poc_lsb_ = 0;
  uint32_t prev_frame_num_ = 0;
  int64_t prev_frame_num_offset_ = 0;
  uint32_t prev_ref_frame_num_ = 0;
  uint32_t max_long_term_frame_idx_ = kNoLongTermFrameIdx;
};

}

#endif

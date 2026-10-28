#include "hevc_decoder.h"

#include <string.h>

#include <memory>
#include <unordered_map>
#include <vector>

#include <va/va.h>
#include <va/va_dec_hevc.h>

#include "../../common/bit_reader.h"
#include "../../va/log.h"
#include "../../va/vendor.h"
#include "hevc_syntax.h"

// the HEVC Main and Main 10 decoder core on VA

#ifdef RHIZO_HEVC_DEBUG
#define HEVC_LOG(...) fprintf(stderr, "hevc: " __VA_ARGS__)
#else
#define HEVC_LOG(...) \
  do {                \
  } while (0)
#endif

namespace rhizo::c2va::hevc {
namespace {

constexpr int kMaxSlicesPerPicture = 600;
constexpr size_t kSliceHeaderPrefix = 4096;
constexpr int kVaRefs = 15;
constexpr int kSlots = kMaxDpbSize + 2;

// raster index of each up-right diagonal scan position
struct DiagScan {
  uint8_t raster4[16];
  uint8_t raster8[64];
  DiagScan() {
    Fill(4, raster4);
    Fill(8, raster8);
  }
  static void Fill(int blk, uint8_t* out) {
    int i = 0, x = 0, y = 0;
    bool stop = false;
    while (!stop) {
      while (y >= 0) {
        if (x < blk && y < blk) out[i++] = static_cast<uint8_t>(y * blk + x);
        y--;
        x++;
      }
      y = x;
      x = 0;
      if (i >= blk * blk) stop = true;
    }
  }
};
const DiagScan kDiag;

enum class RefMark : uint8_t { kUnused, kShort, kLong };

struct Picture {
  bool used = false;
  VASurfaceID surface = VA_INVALID_SURFACE;
  int64_t poc = 0;
  RefMark ref = RefMark::kUnused;
  bool needed_for_output = false;
  bool placeholder = false;
  uint32_t latency = 0;
  uint64_t tag = 0;
  Rect crop{};
  ColorInfo color;
};

struct Slice {
  const uint8_t* nal;
  size_t size;
  uint32_t header_ep_bytes;
  SliceHeader sh;
};

Status Worse(Status a, Status b) {
  auto rank = [](Status s) {
    switch (s) {
      case Status::kOk:
        return 0;
      case Status::kBadStream:
        return 1;
      case Status::kUnsupported:
        return 2;
      case Status::kNoMemory:
        return 3;
      case Status::kVaError:
        return 4;
    }
    return 4;
  };
  return rank(b) > rank(a) ? b : a;
}

Status FromParse(Parse p) { return p == Parse::kUnsupported ? Status::kUnsupported : Status::kBadStream; }

class HevcDecoder final : public DecoderCore {
 public:
  HevcDecoder(DecoderHost* host, TraceSink* trace) : host_(host), trace_(trace) {}
  // release the DPB surfaces without tag callbacks
  ~HevcDecoder() override {
    for (Picture& p : dpb_)
      if (p.used) host_->ReleaseSurface(p.surface);
  }

  Status Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) override;
  Status Drain() override;
  void Reset() override;

 private:
  struct TagState {
    uint32_t pending = 0;
    bool emitted = false;
    bool done = false;
  };

  struct Current {
    bool open = false;
    bool skip = false;
    uint64_t tag = 0;
    NalHeader nal{};
    std::shared_ptr<const Sps> sps;
    std::shared_ptr<const Pps> pps;
    PpsLayout layout{};
    int slot = -1;
    bool output = true;
    bool have_independent = false;
    size_t last_independent = 0;
    std::vector<Slice> slices;
    int st_before[kMaxStRpsEntries], st_after[kMaxStRpsEntries], st_foll[kMaxStRpsEntries];
    int lt_curr[kMaxLtSlice], lt_foll[kMaxLtSlice];
    int n_st_before = 0, n_st_after = 0, n_st_foll = 0, n_lt_curr = 0, n_lt_foll = 0;
    int64_t poc_st_before[kMaxStRpsEntries], poc_st_after[kMaxStRpsEntries], poc_lt_curr[kMaxLtSlice];
  };

  Status HandleSlice(const uint8_t* nal, size_t size, const NalHeader& h, uint64_t tag);
  Parse ParseSlice(const uint8_t* nal, size_t size, Rbsp* rbsp, const NalHeader& h, const Sps& sps, const Pps& pps,
                   const SliceHeader* prev, SliceHeader* out);
  Status StartPicture(const uint8_t* nal, size_t size, const NalHeader& h, Rbsp& rbsp, uint32_t pps_id,
                      uint64_t tag);
  Status FinishPicture();
  Status Submit();
  Status Activate(const std::shared_ptr<const Sps>& sps);
  bool DeriveRps(const SliceHeader& sh, const Sps& sps, int64_t poc, bool irap_no_rasl);
  bool AddPlaceholder(int64_t poc, RefMark mark, int* slot);
  void OutputBeforeDecoding(bool irap_no_rasl, bool no_output_of_prior_pics, bool spliced);
  void AdditionalBumping();

  int FreeSlotIndex() const;
  int Fullness() const;
  int NeededForOutput() const;
  bool LatencyExceeded() const;
  bool BumpOne();
  void FreeSlot(Picture& p);
  void Discard(Picture& p);
  void PictureLeaves(Picture& p, bool output);
  void InputDone(uint64_t tag);
  void Resolve(uint64_t tag);
  bool OnVirgl() {
    if (virgl_ < 0) virgl_ = IsVirgl(host_->display()) ? 1 : 0;
    return virgl_ == 1;
  }

  DecoderHost* host_;
  TraceSink* trace_;
  int virgl_ = -1;
  bool logged_virgl_scaling_ = false;

  std::shared_ptr<const Sps> sps_[16];
  bool sps_unsupported_[16] = {};
  std::shared_ptr<const Pps> pps_[64];
  bool pps_unsupported_[64] = {};
  std::shared_ptr<const Sps> active_sps_;

  bool configured_ = false;
  StreamInfo info_{};
  VAContextID context_ = VA_INVALID_ID;

  bool first_picture_ = true;
  bool after_eos_ = false;
  bool waiting_for_irap_ = true;
  bool irap_no_rasl_output_ = false;
  uint32_t prev_tid0_lsb_ = 0;
  int64_t prev_tid0_msb_ = 0;

  Picture dpb_[kSlots];
  Current cur_;
  std::unordered_map<uint64_t, TagState> tags_;
};

Status HevcDecoder::Decode(const uint8_t* data, size_t size, uint64_t tag, bool codec_config) {
  Status status = Status::kOk;
  tags_[tag];
  for (const NalSpan& nal : SplitAnnexB(data, size)) {
    NalHeader h;
    if (!ParseNalHeader(nal.data, nal.size, &h)) {
      status = Worse(status, Status::kBadStream);
      continue;
    }
    if (h.layer_id != 0) continue;
    switch (h.type) {
      case kVps: {
        Rbsp rbsp;
        UnescapeNal(nal.data, nal.size, &rbsp);
        Vps vps;
        if (ParseVps(rbsp, trace_, &vps) != Parse::kOk) status = Worse(status, Status::kBadStream);
        break;
      }
      case kSps: {
        Rbsp rbsp;
        UnescapeNal(nal.data, nal.size, &rbsp);
        auto sps = std::make_shared<Sps>();
        sps->id = 0xff;
        Parse p = ParseSps(rbsp, trace_, sps.get());
        if (p == Parse::kOk) {
          sps_[sps->id] = sps;
          sps_unsupported_[sps->id] = false;
        } else if (p == Parse::kUnsupported && sps->id < 16) {
          sps_[sps->id].reset();
          sps_unsupported_[sps->id] = true;
          HEVC_LOG("sps %u unsupported\n", sps->id);
        } else {
          status = Worse(status, Status::kBadStream);
        }
        break;
      }
      case kPps: {
        Rbsp rbsp;
        UnescapeNal(nal.data, nal.size, &rbsp);
        auto pps = std::make_shared<Pps>();
        pps->id = 0xff;
        Parse p = ParsePps(rbsp, trace_, pps.get());
        if (p == Parse::kOk) {
          pps_[pps->id] = pps;
          pps_unsupported_[pps->id] = false;
        } else if (p == Parse::kUnsupported && pps->id < 64) {
          pps_[pps->id].reset();
          pps_unsupported_[pps->id] = true;
        } else {
          status = Worse(status, Status::kBadStream);
        }
        break;
      }
      case kAud:
        status = Worse(status, FinishPicture());
        break;
      case kEos:
      case kEob:
        status = Worse(status, FinishPicture());
        after_eos_ = true;
        break;
      default:
        if (IsHandledVcl(h.type) && !codec_config) status = Worse(status, HandleSlice(nal.data, nal.size, h, tag));
        break;
    }
  }
  status = Worse(status, FinishPicture());
  InputDone(tag);
  return status;
}

// parse a slice header from the RBSP prefix
Parse HevcDecoder::ParseSlice(const uint8_t* nal, size_t size, Rbsp* rbsp, const NalHeader& h, const Sps& sps,
                              const Pps& pps, const SliceHeader* prev, SliceHeader* out) {
  Parse p = ParseSliceHeader(*rbsp, h, sps, pps, prev, trace_, out);
  if (p == Parse::kBad && rbsp->truncated) {
    UnescapeNal(nal, size, rbsp);
    p = ParseSliceHeader(*rbsp, h, sps, pps, prev, trace_, out);
  }
  return p;
}

Status HevcDecoder::HandleSlice(const uint8_t* nal, size_t size, const NalHeader& h, uint64_t tag) {
  Rbsp rbsp;
  UnescapeNal(nal, size, &rbsp, trace_ ? SIZE_MAX : kSliceHeaderPrefix);
  bool first = false;
  uint32_t pps_id = 0;
  if (!PeekSliceHeader(rbsp, &first, &pps_id)) return Status::kBadStream;
  if (first) {
    Status s = FinishPicture();
    return Worse(s, StartPicture(nal, size, h, rbsp, pps_id, tag));
  }
  if (!cur_.open) return Status::kBadStream;
  if (cur_.skip) return Status::kOk;
  if (h.type != cur_.nal.type || pps_id != cur_.pps->id) return Status::kBadStream;
  if (cur_.slices.size() >= static_cast<size_t>(kMaxSlicesPerPicture)) return Status::kBadStream;
  Slice s{nal, size, 0, {}};
  const SliceHeader* prev = cur_.have_independent ? &cur_.slices[cur_.last_independent].sh : nullptr;
  Parse p = ParseSlice(nal, size, &rbsp, h, *cur_.sps, *cur_.pps, prev, &s.sh);
  if (p != Parse::kOk) {
    cur_.have_independent = false;
    return FromParse(p);
  }
  const SliceHeader& f = cur_.slices[0].sh;
  if (!s.sh.dependent_slice_segment &&
      (s.sh.pic_order_cnt_lsb != f.pic_order_cnt_lsb || s.sh.num_pic_total_curr != f.num_pic_total_curr ||
       s.sh.pic_output_flag != f.pic_output_flag)) {
    cur_.have_independent = false;
    return Status::kBadStream;
  }
  for (uint32_t ep : rbsp.ep_before)
    if (ep <= s.sh.header_bytes) s.header_ep_bytes++;
  if (!s.sh.dependent_slice_segment) {
    cur_.have_independent = true;
    cur_.last_independent = cur_.slices.size();
  }
  cur_.slices.push_back(s);
  return Status::kOk;
}

Status HevcDecoder::StartPicture(const uint8_t* nal, size_t size, const NalHeader& h, Rbsp& rbsp, uint32_t pps_id,
                                 uint64_t tag) {
  cur_ = Current();
  cur_.open = true;
  cur_.tag = tag;
  cur_.nal = h;
  cur_.skip = true;

  const bool irap = IsIrap(h.type);
  if (!irap && waiting_for_irap_) return Status::kOk;
  if (!pps_[pps_id]) return pps_unsupported_[pps_id] ? Status::kUnsupported : Status::kBadStream;
  std::shared_ptr<const Pps> pps = pps_[pps_id];
  std::shared_ptr<const Sps> candidate = sps_[pps->sps_id];

  bool no_rasl = false;
  bool spliced = false;
  if (irap) {
    no_rasl = IsIdr(h.type) || IsBla(h.type) || first_picture_ || after_eos_ || waiting_for_irap_;
    if (!no_rasl && candidate && (!active_sps_ || candidate->rbsp != active_sps_->rbsp)) no_rasl = spliced = true;
  }
  std::shared_ptr<const Sps> sps;
  if (irap && no_rasl) {
    Status refused = Status::kOk;
    if (!candidate) {
      refused = sps_unsupported_[pps->sps_id] ? Status::kUnsupported : Status::kBadStream;
    } else if (candidate->scaling_list_enabled && OnVirgl()) {
      if (!logged_virgl_scaling_)
        LogErrorf("hevc: refusing a sequence with scaling lists: virgl never passes the host an IQ matrix, so its "
                  "pictures would decode wrong");
      logged_virgl_scaling_ = true;
      refused = Status::kUnsupported;
    }
    if (refused != Status::kOk) {
      active_sps_.reset();
      waiting_for_irap_ = true;
      return refused;
    }
    sps = candidate;
  } else {
    if (!active_sps_ || pps->sps_id != active_sps_->id) return Status::kBadStream;
    sps = active_sps_;
  }
  Parse p = ResolvePps(*pps, *sps, &cur_.layout);
  if (p != Parse::kOk) return FromParse(p);
  Slice first{nal, size, 0, {}};
  p = ParseSlice(nal, size, &rbsp, h, *sps, *pps, nullptr, &first.sh);
  if (p != Parse::kOk) return FromParse(p);
  const SliceHeader& sh = first.sh;
  for (uint32_t ep : rbsp.ep_before)
    if (ep <= sh.header_bytes) first.header_ep_bytes++;

  if (IsRasl(h.type) && irap_no_rasl_output_) return Status::kOk;

  int64_t msb;
  if (irap && no_rasl) {
    msb = 0;
  } else {
    const int64_t max_lsb = sps->max_poc_lsb;
    const int64_t lsb = sh.pic_order_cnt_lsb, prev_lsb = prev_tid0_lsb_;
    if (lsb < prev_lsb && prev_lsb - lsb >= max_lsb / 2)
      msb = prev_tid0_msb_ + max_lsb;
    else if (lsb > prev_lsb && lsb - prev_lsb > max_lsb / 2)
      msb = prev_tid0_msb_ - max_lsb;
    else
      msb = prev_tid0_msb_;
  }
  const int64_t poc = msb + sh.pic_order_cnt_lsb;
  if (poc < INT32_MIN || poc > INT32_MAX) return Status::kBadStream;
  if (irap) irap_no_rasl_output_ = no_rasl;
  if (h.temporal_id == 0 && !IsRasl(h.type) && !IsRadl(h.type) && !IsSlnr(h.type)) {
    prev_tid0_lsb_ = sh.pic_order_cnt_lsb;
    prev_tid0_msb_ = msb;
  }

  if (!DeriveRps(sh, *sps, poc, irap && no_rasl)) return Status::kBadStream;
  OutputBeforeDecoding(irap && no_rasl, sh.no_output_of_prior_pics, spliced);
  if (irap && no_rasl) {
    Status s = Activate(sps);
    if (s != Status::kOk) return s;
  }
  if (!configured_) return Status::kBadStream;

  if (!irap) {
    int* lists[3] = {cur_.st_before, cur_.st_after, cur_.lt_curr};
    const int64_t* wanted[3] = {cur_.poc_st_before, cur_.poc_st_after, cur_.poc_lt_curr};
    const int counts[3] = {cur_.n_st_before, cur_.n_st_after, cur_.n_lt_curr};
    for (int l = 0; l < 3; l++) {
      for (int i = 0; i < counts[l]; i++) {
        if (lists[l][i] >= 0) continue;
        if (!AddPlaceholder(wanted[l][i], l == 2 ? RefMark::kLong : RefMark::kShort, &lists[l][i]))
          return Status::kBadStream;
        HEVC_LOG("poc %lld: generated missing reference poc %lld\n", (long long)poc, (long long)wanted[l][i]);
      }
    }
  }

  if (Fullness() + 1 > static_cast<int>(info_.min_surfaces)) return Status::kBadStream;
  int slot = FreeSlotIndex();
  if (slot < 0) return Status::kBadStream;
  VASurfaceID surface;
  Status s = host_->AcquireSurface(&surface);
  if (s != Status::kOk) return s;
  Picture& pic = dpb_[slot];
  pic = Picture();
  pic.used = true;
  pic.surface = surface;
  pic.poc = poc;
  pic.tag = tag;
  pic.crop = info_.visible;
  pic.color = sps->color;

  cur_.skip = false;
  cur_.slot = slot;
  cur_.sps = sps;
  cur_.pps = pps;
  cur_.output = sh.pic_output_flag;
  cur_.have_independent = true;
  cur_.last_independent = 0;
  cur_.slices.reserve(4);
  cur_.slices.push_back(first);
  first_picture_ = false;
  after_eos_ = false;
  waiting_for_irap_ = false;
  return Status::kOk;
}

// derive the reference picture set of the current picture
bool HevcDecoder::DeriveRps(const SliceHeader& sh, const Sps& sps, int64_t poc, bool irap_no_rasl) {
  if (irap_no_rasl)
    for (Picture& p : dpb_)
      if (p.used) p.ref = RefMark::kUnused;
  cur_.n_st_before = cur_.n_st_after = cur_.n_st_foll = cur_.n_lt_curr = cur_.n_lt_foll = 0;
  if (IsIdr(cur_.nal.type)) {
    for (Picture& p : dpb_)
      if (p.used) p.ref = RefMark::kUnused;
    return true;
  }
  int64_t st_before[kMaxStRpsEntries], st_after[kMaxStRpsEntries], st_foll[kMaxStRpsEntries];
  int64_t lt_curr[kMaxLtSlice], lt_foll[kMaxLtSlice];
  bool lt_curr_msb[kMaxLtSlice], lt_foll_msb[kMaxLtSlice];
  int nb = 0, na = 0, nf = 0, nlc = 0, nlf = 0;
  const StRps& rps = sh.st_rps;
  for (int i = 0; i < rps.num_negative; i++) {
    if (rps.used_s0[i])
      st_before[nb++] = poc + rps.delta_poc_s0[i];
    else
      st_foll[nf++] = poc + rps.delta_poc_s0[i];
  }
  for (int i = 0; i < rps.num_positive; i++) {
    if (rps.used_s1[i])
      st_after[na++] = poc + rps.delta_poc_s1[i];
    else if (nf < kMaxStRpsEntries)
      st_foll[nf++] = poc + rps.delta_poc_s1[i];
    else
      return false;
  }
  const int64_t max_lsb = sps.max_poc_lsb;
  for (int i = 0; i < sh.num_long_term_sps + sh.num_long_term_pics; i++) {
    int64_t poc_lt = sh.poc_lsb_lt[i];
    if (sh.delta_poc_msb_present[i])
      poc_lt += poc - static_cast<int64_t>(sh.delta_poc_msb_cycle_lt[i]) * max_lsb - (poc & (max_lsb - 1));
    if (sh.used_by_curr_pic_lt[i]) {
      lt_curr_msb[nlc] = sh.delta_poc_msb_present[i];
      lt_curr[nlc++] = poc_lt;
    } else {
      lt_foll_msb[nlf] = sh.delta_poc_msb_present[i];
      lt_foll[nlf++] = poc_lt;
    }
  }
  auto find_ref = [&](int64_t want, bool full_poc) {
    for (int s = 0; s < kSlots; s++) {
      const Picture& p = dpb_[s];
      if (!p.used || p.ref == RefMark::kUnused) continue;
      if (full_poc ? p.poc == want : (p.poc & (max_lsb - 1)) == want) return s;
    }
    return -1;
  };
  for (int i = 0; i < nb; i++) cur_.poc_st_before[i] = st_before[i];
  for (int i = 0; i < na; i++) cur_.poc_st_after[i] = st_after[i];
  for (int i = 0; i < nlc; i++) cur_.poc_lt_curr[i] = lt_curr[i];
  for (int i = 0; i < nlc; i++) cur_.lt_curr[i] = find_ref(lt_curr[i], lt_curr_msb[i]);
  for (int i = 0; i < nlf; i++) cur_.lt_foll[i] = find_ref(lt_foll[i], lt_foll_msb[i]);
  cur_.n_lt_curr = nlc;
  cur_.n_lt_foll = nlf;
  for (int i = 0; i < nlc; i++)
    if (cur_.lt_curr[i] >= 0) dpb_[cur_.lt_curr[i]].ref = RefMark::kLong;
  for (int i = 0; i < nlf; i++)
    if (cur_.lt_foll[i] >= 0) dpb_[cur_.lt_foll[i]].ref = RefMark::kLong;
  auto find_short = [&](int64_t want) {
    for (int s = 0; s < kSlots; s++) {
      const Picture& p = dpb_[s];
      if (p.used && p.ref == RefMark::kShort && p.poc == want) return s;
    }
    return -1;
  };
  for (int i = 0; i < nb; i++) cur_.st_before[i] = find_short(st_before[i]);
  for (int i = 0; i < na; i++) cur_.st_after[i] = find_short(st_after[i]);
  for (int i = 0; i < nf; i++) cur_.st_foll[i] = find_short(st_foll[i]);
  cur_.n_st_before = nb;
  cur_.n_st_after = na;
  cur_.n_st_foll = nf;
  bool in_rps[kSlots] = {};
  const int* lists[5] = {cur_.st_before, cur_.st_after, cur_.st_foll, cur_.lt_curr, cur_.lt_foll};
  const int counts[5] = {nb, na, nf, nlc, nlf};
  for (int l = 0; l < 5; l++)
    for (int i = 0; i < counts[l]; i++)
      if (lists[l][i] >= 0) in_rps[lists[l][i]] = true;
  for (int s = 0; s < kSlots; s++)
    if (dpb_[s].used && !in_rps[s]) dpb_[s].ref = RefMark::kUnused;
  return true;
}

// add a never-decoded stand-in for a missing reference
bool HevcDecoder::AddPlaceholder(int64_t poc, RefMark mark, int* slot) {
  if (Fullness() + 2 > static_cast<int>(info_.min_surfaces)) return false;
  int s = FreeSlotIndex();
  if (s < 0) return false;
  VASurfaceID surface;
  if (host_->AcquireSurface(&surface) != Status::kOk) return false;
  Picture& p = dpb_[s];
  p = Picture();
  p.used = true;
  p.surface = surface;
  p.poc = poc;
  p.ref = mark;
  p.placeholder = true;
  *slot = s;
  return true;
}

// output and remove pictures before the current picture decodes
void HevcDecoder::OutputBeforeDecoding(bool irap_no_rasl, bool no_output_of_prior_pics, bool spliced) {
  if (irap_no_rasl) {
    const bool discard = cur_.nal.type == kCraNut ? !spliced : no_output_of_prior_pics;
    if (discard) {
      for (Picture& p : dpb_)
        if (p.used) Discard(p);
    } else {
      for (Picture& p : dpb_)
        if (p.used && !p.needed_for_output) FreeSlot(p);
      while (BumpOne()) {
      }
      for (Picture& p : dpb_)
        if (p.used) FreeSlot(p);
    }
    return;
  }
  for (Picture& p : dpb_)
    if (p.used && !p.needed_for_output && p.ref == RefMark::kUnused) FreeSlot(p);
  const Sps& sps = *active_sps_;
  const uint32_t reorder = sps.max_num_reorder_pics[sps.highest_tid];
  const int dpb_size = static_cast<int>(sps.max_dec_pic_buffering_minus1[sps.highest_tid]) + 1;
  while (static_cast<uint32_t>(NeededForOutput()) > reorder || LatencyExceeded() || Fullness() >= dpb_size) {
    if (!BumpOne()) break;
  }
}

// bump the pictures past the reorder or latency limit
void HevcDecoder::AdditionalBumping() {
  const Sps& sps = *active_sps_;
  const uint32_t reorder = sps.max_num_reorder_pics[sps.highest_tid];
  while (static_cast<uint32_t>(NeededForOutput()) > reorder || LatencyExceeded()) {
    if (!BumpOne()) break;
  }
}

Status HevcDecoder::FinishPicture() {
  if (!cur_.open) return Status::kOk;
  Status s = Status::kOk;
  if (!cur_.skip && cur_.slot >= 0) {
    s = Submit();
    Picture& pic = dpb_[cur_.slot];
    if (s != Status::kOk) {
      FreeSlot(pic);
    } else {
      pic.ref = RefMark::kShort;
      if (cur_.output) {
        for (Picture& p : dpb_)
          if (p.used && p.needed_for_output && &p != &pic && p.poc > pic.poc) p.latency++;
      }
      pic.needed_for_output = cur_.output;
      pic.latency = 0;
      if (pic.needed_for_output) tags_[pic.tag].pending++;
      AdditionalBumping();
    }
  }
  cur_ = Current();
  return s;
}

Status HevcDecoder::Activate(const std::shared_ptr<const Sps>& sps) {
  StreamInfo info{};
  const bool high = sps->bit_depth_luma_minus8 > 0 || sps->bit_depth_chroma_minus8 > 0;
  info.profile = high ? VAProfileHEVCMain10 : VAProfileHEVCMain;
  info.rt_format = high ? VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420;
  info.coded_width = sps->pic_width;
  info.coded_height = sps->pic_height;
  info.visible.left = 2 * sps->conf_win_left;
  info.visible.top = 2 * sps->conf_win_top;
  info.visible.width = sps->pic_width - 2 * (sps->conf_win_left + sps->conf_win_right);
  info.visible.height = sps->pic_height - 2 * (sps->conf_win_top + sps->conf_win_bottom);
  info.bit_depth = high ? 10 : 8;
  info.min_surfaces = sps->max_dec_pic_buffering_minus1[sps->highest_tid] + 2;
  info.reorder_depth = sps->max_num_reorder_pics[sps->highest_tid];
  info.color = sps->color;
  const bool same = configured_ && info.profile == info_.profile && info.rt_format == info_.rt_format &&
                    info.coded_width == info_.coded_width && info.coded_height == info_.coded_height &&
                    info.min_surfaces == info_.min_surfaces && info.reorder_depth == info_.reorder_depth;
  if (!same) {
    configured_ = false;
    Status s = host_->Configure(info, &context_);
    if (s != Status::kOk) {
      active_sps_.reset();
      return s;
    }
    configured_ = true;
  }
  info_ = info;
  active_sps_ = sps;
  return Status::kOk;
}

Status HevcDecoder::Submit() {
  const Sps& sps = *cur_.sps;
  const Pps& pps = *cur_.pps;
  const Picture& pic = dpb_[cur_.slot];
  VADisplay dpy = host_->display();

  VAPictureParameterBufferHEVC pp;
  memset(&pp, 0, sizeof(pp));
  pp.CurrPic.picture_id = pic.surface;
  pp.CurrPic.pic_order_cnt = static_cast<int32_t>(pic.poc);
  for (VAPictureHEVC& r : pp.ReferenceFrames) {
    r.picture_id = VA_INVALID_SURFACE;
    r.flags = VA_PICTURE_HEVC_INVALID;
  }
  int va_index[kSlots];
  for (int& v : va_index) v = -1;
  int n_refs = 0;
  auto add = [&](int slot, uint32_t flag) {
    if (slot < 0 || va_index[slot] >= 0 || n_refs == kVaRefs) return;
    const Picture& r = dpb_[slot];
    pp.ReferenceFrames[n_refs].picture_id = r.surface;
    pp.ReferenceFrames[n_refs].pic_order_cnt = static_cast<int32_t>(r.poc);
    pp.ReferenceFrames[n_refs].flags = flag | (r.ref == RefMark::kLong ? VA_PICTURE_HEVC_LONG_TERM_REFERENCE : 0);
    va_index[slot] = n_refs++;
  };
  for (int i = 0; i < cur_.n_st_before; i++) add(cur_.st_before[i], VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE);
  for (int i = 0; i < cur_.n_st_after; i++) add(cur_.st_after[i], VA_PICTURE_HEVC_RPS_ST_CURR_AFTER);
  for (int i = 0; i < cur_.n_lt_curr; i++) add(cur_.lt_curr[i], VA_PICTURE_HEVC_RPS_LT_CURR);
  for (int i = 0; i < cur_.n_st_foll; i++) add(cur_.st_foll[i], 0);
  for (int i = 0; i < cur_.n_lt_foll; i++) add(cur_.lt_foll[i], 0);

  bool any_b = false, all_i = true;
  for (const Slice& s : cur_.slices) {
    any_b |= s.sh.slice_type == 0;
    all_i &= s.sh.slice_type == 2;
  }
  const SliceHeader& f = cur_.slices[0].sh;
  const uint8_t ht = sps.highest_tid;
  pp.pic_width_in_luma_samples = static_cast<uint16_t>(sps.pic_width);
  pp.pic_height_in_luma_samples = static_cast<uint16_t>(sps.pic_height);
  auto& pf = pp.pic_fields.bits;
  pf.chroma_format_idc = sps.chroma_format_idc;
  pf.separate_colour_plane_flag = sps.separate_colour_plane_flag;
  pf.pcm_enabled_flag = sps.pcm_enabled;
  pf.scaling_list_enabled_flag = sps.scaling_list_enabled;
  pf.transform_skip_enabled_flag = pps.transform_skip_enabled;
  pf.amp_enabled_flag = sps.amp_enabled;
  pf.strong_intra_smoothing_enabled_flag = sps.strong_intra_smoothing_enabled;
  pf.sign_data_hiding_enabled_flag = pps.sign_data_hiding_enabled;
  pf.constrained_intra_pred_flag = pps.constrained_intra_pred;
  pf.cu_qp_delta_enabled_flag = pps.cu_qp_delta_enabled;
  pf.weighted_pred_flag = pps.weighted_pred;
  pf.weighted_bipred_flag = pps.weighted_bipred;
  pf.transquant_bypass_enabled_flag = pps.transquant_bypass_enabled;
  pf.tiles_enabled_flag = pps.tiles_enabled;
  pf.entropy_coding_sync_enabled_flag = pps.entropy_coding_sync_enabled;
  pf.pps_loop_filter_across_slices_enabled_flag = pps.loop_filter_across_slices_enabled;
  pf.loop_filter_across_tiles_enabled_flag = pps.loop_filter_across_tiles_enabled;
  pf.pcm_loop_filter_disabled_flag = sps.pcm_loop_filter_disabled;
  pf.NoPicReorderingFlag = sps.max_num_reorder_pics[ht] == 0;
  pf.NoBiPredFlag = !any_b;
  pp.sps_max_dec_pic_buffering_minus1 = static_cast<uint8_t>(sps.max_dec_pic_buffering_minus1[ht]);
  pp.bit_depth_luma_minus8 = sps.bit_depth_luma_minus8;
  pp.bit_depth_chroma_minus8 = sps.bit_depth_chroma_minus8;
  pp.pcm_sample_bit_depth_luma_minus1 = sps.pcm_bit_depth_luma_minus1;
  pp.pcm_sample_bit_depth_chroma_minus1 = sps.pcm_bit_depth_chroma_minus1;
  pp.log2_min_luma_coding_block_size_minus3 = sps.log2_min_cb_minus3;
  pp.log2_diff_max_min_luma_coding_block_size = sps.log2_diff_max_min_cb;
  pp.log2_min_transform_block_size_minus2 = sps.log2_min_tb_minus2;
  pp.log2_diff_max_min_transform_block_size = sps.log2_diff_max_min_tb;
  pp.log2_min_pcm_luma_coding_block_size_minus3 = sps.log2_min_pcm_cb_minus3;
  pp.log2_diff_max_min_pcm_luma_coding_block_size = sps.log2_diff_max_min_pcm_cb;
  pp.max_transform_hierarchy_depth_intra = sps.max_transform_hierarchy_depth_intra;
  pp.max_transform_hierarchy_depth_inter = sps.max_transform_hierarchy_depth_inter;
  pp.init_qp_minus26 = pps.init_qp_minus26;
  pp.diff_cu_qp_delta_depth = pps.diff_cu_qp_delta_depth;
  pp.pps_cb_qp_offset = pps.cb_qp_offset;
  pp.pps_cr_qp_offset = pps.cr_qp_offset;
  pp.log2_parallel_merge_level_minus2 = pps.log2_parallel_merge_level_minus2;
  pp.num_tile_columns_minus1 = pps.num_tile_columns_minus1;
  pp.num_tile_rows_minus1 = pps.num_tile_rows_minus1;
  for (int i = 0; i < 19; i++) pp.column_width_minus1[i] = cur_.layout.column_width_minus1[i];
  for (int i = 0; i < 21; i++) pp.row_height_minus1[i] = cur_.layout.row_height_minus1[i];
  auto& sf = pp.slice_parsing_fields.bits;
  sf.lists_modification_present_flag = pps.lists_modification_present;
  sf.long_term_ref_pics_present_flag = sps.long_term_ref_pics_present;
  sf.sps_temporal_mvp_enabled_flag = sps.temporal_mvp_enabled;
  sf.cabac_init_present_flag = pps.cabac_init_present;
  sf.output_flag_present_flag = pps.output_flag_present;
  sf.dependent_slice_segments_enabled_flag = pps.dependent_slice_segments_enabled;
  sf.pps_slice_chroma_qp_offsets_present_flag = pps.slice_chroma_qp_offsets_present;
  sf.sample_adaptive_offset_enabled_flag = sps.sao_enabled;
  sf.deblocking_filter_override_enabled_flag = pps.deblocking_filter_override_enabled;
  sf.pps_disable_deblocking_filter_flag = pps.deblocking_filter_disabled;
  sf.slice_segment_header_extension_present_flag = pps.slice_segment_header_extension_present;
  sf.RapPicFlag = cur_.nal.type >= kBlaWLp && cur_.nal.type <= kCraNut;
  sf.IdrPicFlag = IsIdr(cur_.nal.type);
  sf.IntraPicFlag = all_i;
  pp.log2_max_pic_order_cnt_lsb_minus4 = sps.log2_max_poc_lsb_minus4;
  pp.num_short_term_ref_pic_sets = sps.num_short_term_ref_pic_sets;
  pp.num_long_term_ref_pic_sps = sps.num_long_term_ref_pics_sps;
  pp.num_ref_idx_l0_default_active_minus1 = pps.num_ref_idx_l0_default_active_minus1;
  pp.num_ref_idx_l1_default_active_minus1 = pps.num_ref_idx_l1_default_active_minus1;
  pp.pps_beta_offset_div2 = pps.beta_offset_div2;
  pp.pps_tc_offset_div2 = pps.tc_offset_div2;
  pp.num_extra_slice_header_bits = pps.num_extra_slice_header_bits;
  pp.st_rps_bits = f.st_rps_bits;

  // VAIQMatrixBufferHEVC takes its lists in raster order
  VAIQMatrixBufferHEVC iq;
  if (sps.scaling_list_enabled) {
    memset(&iq, 0, sizeof(iq));
    const ScalingLists& sl = pps.scaling_list_data_present ? pps.scaling : sps.scaling;
    for (int m = 0; m < 6; m++) {
      for (int i = 0; i < 16; i++) iq.ScalingList4x4[m][kDiag.raster4[i]] = sl.list[0][m][i];
      for (int i = 0; i < 64; i++) {
        iq.ScalingList8x8[m][kDiag.raster8[i]] = sl.list[1][m][i];
        iq.ScalingList16x16[m][kDiag.raster8[i]] = sl.list[2][m][i];
      }
      iq.ScalingListDC16x16[m] = sl.dc[0][m];
    }
    for (int i = 0; i < 64; i++) {
      iq.ScalingList32x32[0][kDiag.raster8[i]] = sl.list[3][0][i];
      iq.ScalingList32x32[1][kDiag.raster8[i]] = sl.list[3][3][i];
    }
    iq.ScalingListDC32x32[0] = sl.dc[1][0];
    iq.ScalingListDC32x32[1] = sl.dc[1][3];
  }

  std::vector<VABufferID> buffers;
  buffers.reserve(2 + 2 * cur_.slices.size());
  auto destroy_all = [&]() {
    for (VABufferID b : buffers) vaDestroyBuffer(dpy, b);
  };
  auto create = [&](VABufferType type, size_t bytes, const void* data) {
    VABufferID id;
    if (vaCreateBuffer(dpy, context_, type, static_cast<unsigned>(bytes), 1, const_cast<void*>(data), &id) !=
        VA_STATUS_SUCCESS)
      return false;
    buffers.push_back(id);
    return true;
  };
  if (!create(VAPictureParameterBufferType, sizeof(pp), &pp) ||
      (sps.scaling_list_enabled && !create(VAIQMatrixBufferType, sizeof(iq), &iq))) {
    destroy_all();
    return Status::kVaError;
  }
  const size_t picture_buffers = buffers.size();

  int temp[2][16 + kMaxRefIdx];
  for (size_t si = 0; si < cur_.slices.size(); si++) {
    const Slice& s = cur_.slices[si];
    const SliceHeader& sh = s.sh;
    VASliceParameterBufferHEVC sp;
    memset(&sp, 0, sizeof(sp));
    sp.slice_data_size = static_cast<uint32_t>(s.size);
    sp.slice_data_offset = 0;
    sp.slice_data_flag = VA_SLICE_DATA_FLAG_ALL;
    sp.slice_data_byte_offset = sh.header_bytes;
    sp.slice_segment_address = sh.segment_address;
    memset(sp.RefPicList, 0xff, sizeof(sp.RefPicList));
    if (sh.slice_type != 2) {
      const int total = static_cast<int>(sh.num_pic_total_curr);
      for (int l = 0; l < (sh.slice_type == 0 ? 2 : 1); l++) {
        const int active = (l == 0 ? sh.num_ref_idx_l0_active_minus1 : sh.num_ref_idx_l1_active_minus1) + 1;
        const int n_temp = active > total ? active : total;
        int r = 0;
        const int* first = l == 0 ? cur_.st_before : cur_.st_after;
        const int n_first = l == 0 ? cur_.n_st_before : cur_.n_st_after;
        const int* second = l == 0 ? cur_.st_after : cur_.st_before;
        const int n_second = l == 0 ? cur_.n_st_after : cur_.n_st_before;
        if (n_first + n_second + cur_.n_lt_curr == 0) break;
        while (r < n_temp) {
          for (int i = 0; i < n_first && r < n_temp; i++) temp[l][r++] = first[i];
          for (int i = 0; i < n_second && r < n_temp; i++) temp[l][r++] = second[i];
          for (int i = 0; i < cur_.n_lt_curr && r < n_temp; i++) temp[l][r++] = cur_.lt_curr[i];
        }
        const bool modified = l == 0 ? sh.rplm_flag_l0 : sh.rplm_flag_l1;
        const uint8_t* entry = l == 0 ? sh.list_entry_l0 : sh.list_entry_l1;
        for (int i = 0; i < active; i++) {
          int slot = temp[l][modified ? entry[i] : i];
          sp.RefPicList[l][i] = slot >= 0 && va_index[slot] >= 0 ? static_cast<uint8_t>(va_index[slot]) : 0xff;
        }
      }
    }
    auto& lf = sp.LongSliceFlags.fields;
    lf.LastSliceOfPic = si + 1 == cur_.slices.size();
    lf.dependent_slice_segment_flag = sh.dependent_slice_segment;
    lf.slice_type = sh.slice_type;
    lf.color_plane_id = sh.colour_plane_id;
    lf.slice_sao_luma_flag = sh.sao_luma;
    lf.slice_sao_chroma_flag = sh.sao_chroma;
    lf.mvd_l1_zero_flag = sh.mvd_l1_zero;
    lf.cabac_init_flag = sh.cabac_init;
    lf.slice_temporal_mvp_enabled_flag = sh.temporal_mvp_enabled;
    lf.slice_deblocking_filter_disabled_flag = sh.deblocking_filter_disabled;
    lf.collocated_from_l0_flag = sh.collocated_from_l0;
    lf.slice_loop_filter_across_slices_enabled_flag = sh.loop_filter_across_slices_enabled;
    sp.collocated_ref_idx = (sh.temporal_mvp_enabled && sh.slice_type != 2) ? sh.collocated_ref_idx : 0xff;
    if (sh.slice_type != 2) sp.num_ref_idx_l0_active_minus1 = sh.num_ref_idx_l0_active_minus1;
    if (sh.slice_type == 0) sp.num_ref_idx_l1_active_minus1 = sh.num_ref_idx_l1_active_minus1;
    sp.slice_qp_delta = sh.slice_qp_delta;
    sp.slice_cb_qp_offset = sh.cb_qp_offset;
    sp.slice_cr_qp_offset = sh.cr_qp_offset;
    sp.slice_beta_offset_div2 = sh.beta_offset_div2;
    sp.slice_tc_offset_div2 = sh.tc_offset_div2;
    if (sh.has_pred_weights) {
      sp.luma_log2_weight_denom = sh.pw.luma_log2_weight_denom;
      sp.delta_chroma_log2_weight_denom = sh.pw.delta_chroma_log2_weight_denom;
      for (int i = 0; i < kMaxRefIdx; i++) {
        sp.delta_luma_weight_l0[i] = sh.pw.delta_luma_weight[0][i];
        sp.luma_offset_l0[i] = sh.pw.luma_offset[0][i];
        sp.delta_luma_weight_l1[i] = sh.pw.delta_luma_weight[1][i];
        sp.luma_offset_l1[i] = sh.pw.luma_offset[1][i];
        for (int j = 0; j < 2; j++) {
          sp.delta_chroma_weight_l0[i][j] = sh.pw.delta_chroma_weight[0][i][j];
          sp.ChromaOffsetL0[i][j] = sh.pw.chroma_offset[0][i][j];
          sp.delta_chroma_weight_l1[i][j] = sh.pw.delta_chroma_weight[1][i][j];
          sp.ChromaOffsetL1[i][j] = sh.pw.chroma_offset[1][i][j];
        }
      }
    }
    sp.five_minus_max_num_merge_cand = sh.five_minus_max_num_merge_cand;
    sp.num_entry_point_offsets = static_cast<uint16_t>(sh.num_entry_point_offsets);
    sp.entry_offset_to_subset_array = 0;
    sp.slice_data_num_emu_prevn_bytes = static_cast<uint16_t>(s.header_ep_bytes);
    if (!create(VASliceParameterBufferType, sizeof(sp), &sp) || !create(VASliceDataBufferType, s.size, s.nal)) {
      destroy_all();
      return Status::kVaError;
    }
  }

  Status status = Status::kOk;
  if (vaBeginPicture(dpy, context_, pic.surface) != VA_STATUS_SUCCESS) {
    destroy_all();
    return Status::kVaError;
  }
  if (vaRenderPicture(dpy, context_, buffers.data(), static_cast<int>(picture_buffers)) != VA_STATUS_SUCCESS)
    status = Status::kVaError;
  for (size_t i = picture_buffers; status == Status::kOk && i + 1 < buffers.size(); i += 2) {
    if (vaRenderPicture(dpy, context_, &buffers[i], 2) != VA_STATUS_SUCCESS) status = Status::kVaError;
  }
  if (vaEndPicture(dpy, context_) != VA_STATUS_SUCCESS) status = Status::kVaError;
  destroy_all();
  return status;
}

int HevcDecoder::FreeSlotIndex() const {
  for (int s = 0; s < kSlots; s++)
    if (!dpb_[s].used) return s;
  return -1;
}

int HevcDecoder::Fullness() const {
  int n = 0;
  for (const Picture& p : dpb_) n += p.used;
  return n;
}

int HevcDecoder::NeededForOutput() const {
  int n = 0;
  for (const Picture& p : dpb_) n += p.used && p.needed_for_output;
  return n;
}

bool HevcDecoder::LatencyExceeded() const {
  const Sps& sps = *active_sps_;
  const uint32_t plus1 = sps.max_latency_increase_plus1[sps.highest_tid];
  if (plus1 == 0) return false;
  const uint64_t max_latency = static_cast<uint64_t>(sps.max_num_reorder_pics[sps.highest_tid]) + plus1 - 1;
  for (const Picture& p : dpb_)
    if (p.used && p.needed_for_output && p.latency >= max_latency) return true;
  return false;
}

// output the waiting picture with the lowest POC
bool HevcDecoder::BumpOne() {
  Picture* best = nullptr;
  for (Picture& p : dpb_)
    if (p.used && p.needed_for_output && (!best || p.poc < best->poc)) best = &p;
  if (!best) return false;
  PictureLeaves(*best, true);
  if (best->ref == RefMark::kUnused) FreeSlot(*best);
  return true;
}

// take a picture out of output
void HevcDecoder::PictureLeaves(Picture& p, bool output) {
  p.needed_for_output = false;
  auto it = tags_.find(p.tag);
  if (it == tags_.end()) return;
  TagState& t = it->second;
  if (t.pending > 0) t.pending--;
  if (output && !t.emitted) {
    host_->Output(p.surface, p.tag, p.crop, p.color);
    t.emitted = true;
  }
  Resolve(p.tag);
}

void HevcDecoder::FreeSlot(Picture& p) {
  if (!p.used) return;
  if (p.needed_for_output) PictureLeaves(p, false);
  host_->ReleaseSurface(p.surface);
  p = Picture();
}

void HevcDecoder::Discard(Picture& p) { FreeSlot(p); }

void HevcDecoder::InputDone(uint64_t tag) {
  tags_[tag].done = true;
  Resolve(tag);
}

void HevcDecoder::Resolve(uint64_t tag) {
  auto it = tags_.find(tag);
  if (it == tags_.end()) return;
  if (!it->second.done || it->second.pending > 0) return;
  bool emitted = it->second.emitted;
  tags_.erase(it);
  if (!emitted) host_->Skip(tag);
}

// output all waiting pictures and keep the references
Status HevcDecoder::Drain() {
  Status s = FinishPicture();
  while (BumpOne()) {
  }
  return s;
}

void HevcDecoder::Reset() {
  cur_ = Current();
  for (Picture& p : dpb_) FreeSlot(p);
  std::vector<uint64_t> left;
  for (auto& [tag, state] : tags_) {
    state.done = true;
    state.pending = 0;
    left.push_back(tag);
  }
  for (uint64_t tag : left) Resolve(tag);
  first_picture_ = true;
  waiting_for_irap_ = true;
  after_eos_ = false;
  prev_tid0_lsb_ = 0;
  prev_tid0_msb_ = 0;
}

}

std::unique_ptr<DecoderCore> CreateDecoderWithTrace(DecoderHost* host, TraceSink* trace) {
  return std::make_unique<HevcDecoder>(host, trace);
}

}

namespace rhizo::c2va {

std::unique_ptr<DecoderCore> CreateHevcDecoder(DecoderHost* host) {
  return hevc::CreateDecoderWithTrace(host, nullptr);
}

}

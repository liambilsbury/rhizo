#include "codec_map.h"

#include <algorithm>

#include <Codec2Mapper.h>
#include <media/stagefright/foundation/ColorUtils.h>

#include "registry.h"

namespace rhizo::c2store {

namespace {

using c2va::Codec;

// pair a level with its picture-size limit
struct LevelSize {
  C2Config::level_t level;
  uint32_t minor;
  uint64_t max_size;
};

// list H.264's MaxFS in macroblocks
const std::vector<LevelSize>& AvcLevels() {
  static const std::vector<LevelSize> t = {
      {C2Config::LEVEL_AVC_1, 0, 99},      {C2Config::LEVEL_AVC_1B, 0, 99},     {C2Config::LEVEL_AVC_1_1, 1, 396},
      {C2Config::LEVEL_AVC_1_2, 2, 396},   {C2Config::LEVEL_AVC_1_3, 3, 396},   {C2Config::LEVEL_AVC_2, 0, 396},
      {C2Config::LEVEL_AVC_2_1, 1, 792},   {C2Config::LEVEL_AVC_2_2, 2, 1620},  {C2Config::LEVEL_AVC_3, 0, 1620},
      {C2Config::LEVEL_AVC_3_1, 1, 3600},  {C2Config::LEVEL_AVC_3_2, 2, 5120},  {C2Config::LEVEL_AVC_4, 0, 8192},
      {C2Config::LEVEL_AVC_4_1, 1, 8192},  {C2Config::LEVEL_AVC_4_2, 2, 8704},  {C2Config::LEVEL_AVC_5, 0, 22080},
      {C2Config::LEVEL_AVC_5_1, 1, 36864}, {C2Config::LEVEL_AVC_5_2, 2, 36864}, {C2Config::LEVEL_AVC_6, 0, 139264},
      {C2Config::LEVEL_AVC_6_1, 1, 139264}, {C2Config::LEVEL_AVC_6_2, 2, 139264},
  };
  return t;
}

// list H.265's main-tier MaxLumaPs in luma samples
const std::vector<LevelSize>& HevcLevels() {
  static const std::vector<LevelSize> t = {
      {C2Config::LEVEL_HEVC_MAIN_1, 0, 36864},      {C2Config::LEVEL_HEVC_MAIN_2, 0, 122880},
      {C2Config::LEVEL_HEVC_MAIN_2_1, 1, 245760},   {C2Config::LEVEL_HEVC_MAIN_3, 0, 552960},
      {C2Config::LEVEL_HEVC_MAIN_3_1, 1, 983040},   {C2Config::LEVEL_HEVC_MAIN_4, 0, 2228224},
      {C2Config::LEVEL_HEVC_MAIN_4_1, 1, 2228224},  {C2Config::LEVEL_HEVC_MAIN_5, 0, 8912896},
      {C2Config::LEVEL_HEVC_MAIN_5_1, 1, 8912896},  {C2Config::LEVEL_HEVC_MAIN_5_2, 2, 8912896},
      {C2Config::LEVEL_HEVC_MAIN_6, 0, 35651584},   {C2Config::LEVEL_HEVC_MAIN_6_1, 1, 35651584},
      {C2Config::LEVEL_HEVC_MAIN_6_2, 2, 35651584},
  };
  return t;
}

// list VP9 Annex A's MaxPictureSize in luma samples
const std::vector<LevelSize>& Vp9Levels() {
  static const std::vector<LevelSize> t = {
      {C2Config::LEVEL_VP9_1, 0, 36864},     {C2Config::LEVEL_VP9_1_1, 1, 73728},
      {C2Config::LEVEL_VP9_2, 0, 122880},    {C2Config::LEVEL_VP9_2_1, 1, 245760},
      {C2Config::LEVEL_VP9_3, 0, 552960},    {C2Config::LEVEL_VP9_3_1, 1, 983040},
      {C2Config::LEVEL_VP9_4, 0, 2228224},   {C2Config::LEVEL_VP9_4_1, 1, 2228224},
      {C2Config::LEVEL_VP9_5, 0, 8912896},   {C2Config::LEVEL_VP9_5_1, 1, 8912896},
      {C2Config::LEVEL_VP9_5_2, 2, 8912896}, {C2Config::LEVEL_VP9_6, 0, 35651584},
      {C2Config::LEVEL_VP9_6_1, 1, 35651584}, {C2Config::LEVEL_VP9_6_2, 2, 35651584},
  };
  return t;
}

// list AV1's MaxPicSize in luma samples
const std::vector<LevelSize>& Av1Levels() {
  static const std::vector<LevelSize> t = {
      {C2Config::LEVEL_AV1_2, 0, 147456},    {C2Config::LEVEL_AV1_2_1, 1, 278784},
      {C2Config::LEVEL_AV1_3, 0, 665856},    {C2Config::LEVEL_AV1_3_1, 1, 1065024},
      {C2Config::LEVEL_AV1_4, 0, 2359296},   {C2Config::LEVEL_AV1_4_1, 1, 2359296},
      {C2Config::LEVEL_AV1_5, 0, 8912896},   {C2Config::LEVEL_AV1_5_1, 1, 8912896},
      {C2Config::LEVEL_AV1_5_2, 2, 8912896}, {C2Config::LEVEL_AV1_5_3, 3, 8912896},
      {C2Config::LEVEL_AV1_6, 0, 35651584},  {C2Config::LEVEL_AV1_6_1, 1, 35651584},
      {C2Config::LEVEL_AV1_6_2, 2, 35651584}, {C2Config::LEVEL_AV1_6_3, 3, 35651584},
  };
  return t;
}

const std::vector<LevelSize>& LevelsFor(Codec codec) {
  switch (codec) {
    case Codec::kAvc: return AvcLevels();
    case Codec::kHevc: return HevcLevels();
    case Codec::kVp9: return Vp9Levels();
    case Codec::kAv1: return Av1Levels();
  }
  return AvcLevels();
}

}

bool C2ProfileOf(VAProfile va, C2Config::profile_t* out) {
  switch (va) {
    case VAProfileH264ConstrainedBaseline: *out = C2Config::PROFILE_AVC_CONSTRAINED_BASELINE; return true;
    case VAProfileH264Main: *out = C2Config::PROFILE_AVC_MAIN; return true;
    case VAProfileH264High: *out = C2Config::PROFILE_AVC_HIGH; return true;
    case VAProfileH264High10: *out = C2Config::PROFILE_AVC_HIGH_10; return true;
    case VAProfileHEVCMain: *out = C2Config::PROFILE_HEVC_MAIN; return true;
    case VAProfileHEVCMain10: *out = C2Config::PROFILE_HEVC_MAIN_10; return true;
    case VAProfileVP9Profile0: *out = C2Config::PROFILE_VP9_0; return true;
    case VAProfileVP9Profile2: *out = C2Config::PROFILE_VP9_2; return true;
    case VAProfileAV1Profile0: *out = C2Config::PROFILE_AV1_0; return true;
    default: return false;
  }
}

VAProfile VaProfileFor(const c2va::ComponentCaps& caps, C2Config::profile_t profile) {
  for (VAProfile va : caps.va_profiles) {
    C2Config::profile_t p;
    if (C2ProfileOf(va, &p) && p == profile) return va;
  }
  return VAProfileNone;
}

std::vector<uint32_t> ProfilesOf(const c2va::ComponentCaps& caps) {
  std::vector<uint32_t> out;
  for (VAProfile va : caps.va_profiles) {
    C2Config::profile_t p;
    if (C2ProfileOf(va, &p) && std::find(out.begin(), out.end(), static_cast<uint32_t>(p)) == out.end()) {
      out.push_back(p);
    }
  }
  return out;
}

std::vector<uint32_t> LevelsOf(const c2va::ComponentCaps& caps) {
  uint64_t size = caps.codec == Codec::kAvc
                      ? uint64_t((caps.max_width + 15) / 16) * ((caps.max_height + 15) / 16)
                      : uint64_t(caps.max_width) * caps.max_height;
  const std::vector<LevelSize>& table = LevelsFor(caps.codec);
  uint64_t top = 0;
  for (const LevelSize& l : table) {
    if (l.max_size <= size) top = std::max(top, l.max_size);
  }
  std::vector<uint32_t> out;
  for (const LevelSize& l : table) {
    if (l.max_size < top || (l.max_size == top && l.minor <= 1)) out.push_back(l.level);
  }
  return out;
}

C2Config::level_t MinLevelFor(const c2va::ComponentCaps& caps, uint32_t width, uint32_t height) {
  uint64_t size = caps.codec == Codec::kAvc ? uint64_t((width + 15) / 16) * ((height + 15) / 16)
                                            : uint64_t(width) * height;
  std::vector<uint32_t> declared = LevelsOf(caps);
  if (declared.empty()) return C2Config::LEVEL_UNUSED;
  for (const LevelSize& l : LevelsFor(caps.codec)) {
    if (l.max_size >= size && std::find(declared.begin(), declared.end(), l.level) != declared.end()) {
      return l.level;
    }
  }
  return static_cast<C2Config::level_t>(declared.back());
}

uint32_t LevelIdcOf(Codec codec, C2Config::level_t level) {
  if (codec == Codec::kAvc) {
    switch (level) {
      case C2Config::LEVEL_AVC_1: return 10;
      case C2Config::LEVEL_AVC_1B: return 9;
      case C2Config::LEVEL_AVC_1_1: return 11;
      case C2Config::LEVEL_AVC_1_2: return 12;
      case C2Config::LEVEL_AVC_1_3: return 13;
      case C2Config::LEVEL_AVC_2: return 20;
      case C2Config::LEVEL_AVC_2_1: return 21;
      case C2Config::LEVEL_AVC_2_2: return 22;
      case C2Config::LEVEL_AVC_3: return 30;
      case C2Config::LEVEL_AVC_3_1: return 31;
      case C2Config::LEVEL_AVC_3_2: return 32;
      case C2Config::LEVEL_AVC_4: return 40;
      case C2Config::LEVEL_AVC_4_1: return 41;
      case C2Config::LEVEL_AVC_4_2: return 42;
      case C2Config::LEVEL_AVC_5: return 50;
      case C2Config::LEVEL_AVC_5_1: return 51;
      case C2Config::LEVEL_AVC_5_2: return 52;
      case C2Config::LEVEL_AVC_6: return 60;
      case C2Config::LEVEL_AVC_6_1: return 61;
      case C2Config::LEVEL_AVC_6_2: return 62;
      default: return 0;
    }
  }
  if (codec == Codec::kHevc) {
    switch (level) {
      case C2Config::LEVEL_HEVC_MAIN_1: return 30;
      case C2Config::LEVEL_HEVC_MAIN_2: return 60;
      case C2Config::LEVEL_HEVC_MAIN_2_1: return 63;
      case C2Config::LEVEL_HEVC_MAIN_3: return 90;
      case C2Config::LEVEL_HEVC_MAIN_3_1: return 93;
      case C2Config::LEVEL_HEVC_MAIN_4: return 120;
      case C2Config::LEVEL_HEVC_MAIN_4_1: return 123;
      case C2Config::LEVEL_HEVC_MAIN_5: return 150;
      case C2Config::LEVEL_HEVC_MAIN_5_1: return 153;
      case C2Config::LEVEL_HEVC_MAIN_5_2: return 156;
      case C2Config::LEVEL_HEVC_MAIN_6: return 180;
      case C2Config::LEVEL_HEVC_MAIN_6_1: return 183;
      case C2Config::LEVEL_HEVC_MAIN_6_2: return 186;
      default: return 0;
    }
  }
  return 0;
}

uint32_t ResourceIdOf(const c2va::ComponentCaps& caps) {
  uint32_t codec = 0;
  switch (caps.codec) {
    case Codec::kAvc: codec = 1; break;
    case Codec::kHevc: codec = 2; break;
    case Codec::kVp9: codec = 3; break;
    case Codec::kAv1: codec = 4; break;
  }
  return (caps.kind == c2va::Kind::kEncoder ? kResourceIdEncoderBase : kResourceIdDecoderBase) + codec;
}

void ColorAspectsOf(const c2va::ColorInfo& iso, C2Color::range_t* range, C2Color::primaries_t* primaries,
                    C2Color::transfer_t* transfer, C2Color::matrix_t* matrix) {
  android::ColorAspects sf;
  android::ColorUtils::convertIsoColorAspectsToCodecAspects(static_cast<int32_t>(iso.primaries),
                                                            static_cast<int32_t>(iso.transfer),
                                                            static_cast<int32_t>(iso.matrix), iso.full_range, sf);
  if (!android::C2Mapper::map(sf.mRange, range)) *range = C2Color::RANGE_UNSPECIFIED;
  if (!android::C2Mapper::map(sf.mPrimaries, primaries)) *primaries = C2Color::PRIMARIES_UNSPECIFIED;
  if (!android::C2Mapper::map(sf.mTransfer, transfer)) *transfer = C2Color::TRANSFER_UNSPECIFIED;
  if (!android::C2Mapper::map(sf.mMatrixCoeffs, matrix)) *matrix = C2Color::MATRIX_UNSPECIFIED;
}

c2va::ColorInfo IsoColorOf(C2Color::range_t range, C2Color::primaries_t primaries, C2Color::transfer_t transfer,
                           C2Color::matrix_t matrix) {
  android::ColorAspects sf{};
  if (!android::C2Mapper::map(range, &sf.mRange)) sf.mRange = android::ColorAspects::RangeUnspecified;
  if (!android::C2Mapper::map(primaries, &sf.mPrimaries)) sf.mPrimaries = android::ColorAspects::PrimariesUnspecified;
  if (!android::C2Mapper::map(transfer, &sf.mTransfer)) sf.mTransfer = android::ColorAspects::TransferUnspecified;
  if (!android::C2Mapper::map(matrix, &sf.mMatrixCoeffs)) sf.mMatrixCoeffs = android::ColorAspects::MatrixUnspecified;
  int32_t p = 2, t = 2, m = 2;
  bool full = false;
  android::ColorUtils::convertCodecColorAspectsToIsoAspects(sf, &p, &t, &m, &full);
  c2va::ColorInfo out;
  out.primaries = static_cast<uint32_t>(p);
  out.transfer = static_cast<uint32_t>(t);
  out.matrix = static_cast<uint32_t>(m);
  out.full_range = full;
  return out;
}

c2va::ColorInfo SurfaceColorOf(const C2StreamColorAspectsInfo::output& declared, uint32_t width, uint32_t height) {
  android::ColorAspects sf{};
  if (!android::C2Mapper::map(declared.range, &sf.mRange)) sf.mRange = android::ColorAspects::RangeUnspecified;
  if (!android::C2Mapper::map(declared.primaries, &sf.mPrimaries)) {
    sf.mPrimaries = android::ColorAspects::PrimariesUnspecified;
  }
  if (!android::C2Mapper::map(declared.transfer, &sf.mTransfer)) {
    sf.mTransfer = android::ColorAspects::TransferUnspecified;
  }
  if (!android::C2Mapper::map(declared.matrix, &sf.mMatrixCoeffs)) {
    sf.mMatrixCoeffs = android::ColorAspects::MatrixUnspecified;
  }
  int32_t w = static_cast<int32_t>(width), h = static_cast<int32_t>(height);
  android::ColorUtils::setDefaultCodecColorAspectsIfNeeded(sf, w, h);
  int32_t p = 2, t = 2, m = 2;
  bool full = false;
  android::ColorUtils::convertCodecColorAspectsToIsoAspects(sf, &p, &t, &m, &full);
  if (m == 2) {
    android::ColorAspects def{};
    def.mMatrixCoeffs = android::ColorAspects::MatrixUnspecified;
    android::ColorUtils::setDefaultCodecColorAspectsIfNeeded(def, w, h);
    int32_t dp = 2, dt = 2;
    bool dfull = false;
    android::ColorUtils::convertCodecColorAspectsToIsoAspects(def, &dp, &dt, &m, &dfull);
  }
  c2va::ColorInfo out;
  out.primaries = static_cast<uint32_t>(p);
  out.transfer = static_cast<uint32_t>(t);
  out.matrix = static_cast<uint32_t>(m);
  out.full_range = full;
  return out;
}

uint32_t SizeAlignmentOf(Codec codec) { return codec == Codec::kVp9 || codec == Codec::kAv1 ? 1u : 2u; }

bool ContainerAspectsFirst(Codec codec) { return codec == Codec::kVp9; }

C2ColorAspectsStruct MergeColorAspects(const C2ColorAspectsStruct& container, const C2ColorAspectsStruct& coded,
                                       bool container_first) {
  const C2ColorAspectsStruct& first = container_first ? container : coded;
  const C2ColorAspectsStruct& second = container_first ? coded : container;
  C2ColorAspectsStruct out;
  out.range = first.range != C2Color::RANGE_UNSPECIFIED ? first.range : second.range;
  out.primaries = first.primaries != C2Color::PRIMARIES_UNSPECIFIED ? first.primaries : second.primaries;
  out.transfer = first.transfer != C2Color::TRANSFER_UNSPECIFIED ? first.transfer : second.transfer;
  out.matrix = first.matrix != C2Color::MATRIX_UNSPECIFIED ? first.matrix : second.matrix;
  return out;
}

namespace {

bool SameAspects(const C2ColorAspectsStruct& a, const C2ColorAspectsStruct& b) {
  return a.range == b.range && a.primaries == b.primaries && a.transfer == b.transfer && a.matrix == b.matrix;
}

}

void DefaultAspectsLog::Note(uint64_t index, const C2ColorAspectsStruct& def) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!changes_.empty() && index < last_) changes_.clear();
  last_ = index;
  if (!changes_.empty() && SameAspects(std::prev(changes_.end())->second, def)) return;
  changes_[index] = def;
  while (changes_.size() > kMaxChanges) changes_.erase(changes_.begin());
}

bool DefaultAspectsLog::At(uint64_t index, C2ColorAspectsStruct* out) const {
  std::lock_guard<std::mutex> lock(mu_);
  if (changes_.empty()) return false;
  auto it = changes_.upper_bound(index);
  if (it != changes_.begin()) --it;
  *out = it->second;
  return true;
}

void DefaultAspectsLog::Clear() {
  std::lock_guard<std::mutex> lock(mu_);
  changes_.clear();
  last_ = 0;
}

size_t DefaultAspectsLog::ChangesForTest() const {
  std::lock_guard<std::mutex> lock(mu_);
  return changes_.size();
}

}

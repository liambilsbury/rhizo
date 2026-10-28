#ifndef RHIZO_C2STORE_CODEC_MAP_H
#define RHIZO_C2STORE_CODEC_MAP_H

// map the driver's capabilities to c2.rhizo.* component declarations

#include <stdint.h>

#include <map>
#include <mutex>
#include <vector>

#include <C2Config.h>

#include "va/runtime.h"

namespace rhizo::c2store {

// map a VA profile to its Codec2 profile
bool C2ProfileOf(VAProfile va, C2Config::profile_t* out);
// return the VA profile of caps that serves a Codec2 profile
VAProfile VaProfileFor(const c2va::ComponentCaps& caps, C2Config::profile_t profile);

std::vector<uint32_t> ProfilesOf(const c2va::ComponentCaps& caps);
// list the levels whose picture-size limits fit caps' largest picture
std::vector<uint32_t> LevelsOf(const c2va::ComponentCaps& caps);
// return the lowest level that holds width x height
C2Config::level_t MinLevelFor(const c2va::ComponentCaps& caps, uint32_t width, uint32_t height);
// return the H.264 level_idc or H.265 general_level_idc of a level
uint32_t LevelIdcOf(c2va::Codec codec, C2Config::level_t level);

// return a decoder's size alignment
uint32_t SizeAlignmentOf(c2va::Codec codec);

// return the resource a component's instances count against
uint32_t ResourceIdOf(const c2va::ComponentCaps& caps);

// map colour code points to Codec2 colour aspects
void ColorAspectsOf(const c2va::ColorInfo& iso, C2Color::range_t* range, C2Color::primaries_t* primaries,
                    C2Color::transfer_t* transfer, C2Color::matrix_t* matrix);
// map Codec2 colour aspects to colour code points
c2va::ColorInfo IsoColorOf(C2Color::range_t range, C2Color::primaries_t primaries, C2Color::transfer_t transfer,
                           C2Color::matrix_t matrix);
// fill unspecified colour aspects by picture size
c2va::ColorInfo SurfaceColorOf(const C2StreamColorAspectsInfo::output& declared, uint32_t width, uint32_t height);

// return true when container colour aspects outrank coded ones
bool ContainerAspectsFirst(c2va::Codec codec);
// merge container and coded colour aspects field by field
C2ColorAspectsStruct MergeColorAspects(const C2ColorAspectsStruct& container, const C2ColorAspectsStruct& coded,
                                       bool container_first);

// log the app's default colour aspects by input index
class DefaultAspectsLog {
 public:
  // record the default that takes effect at index
  void Note(uint64_t index, const C2ColorAspectsStruct& def);
  // look up the default in effect at index
  bool At(uint64_t index, C2ColorAspectsStruct* out) const;
  void Clear();
  size_t ChangesForTest() const;

  static constexpr size_t kMaxChanges = 64;

 private:
  mutable std::mutex mu_;
  std::map<uint64_t, C2ColorAspectsStruct> changes_;
  uint64_t last_ = 0;
};

}

#endif

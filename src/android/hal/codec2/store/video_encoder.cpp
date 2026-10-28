#include "video_encoder.h"

#include <math.h>
#include <string.h>

#include <algorithm>
#include <atomic>
#include <numeric>

#include <C2PlatformSupport.h>

#include "buffers.h"
#include "codec_map.h"
#include "common/bit_reader.h"
#include "enc/common/level_policy.h"
#include "log.h"
#include "rhizo/memfd_buffer.h"

namespace rhizo::c2store {

namespace {

using c2va::Codec;
using c2va::EncoderConfig;
using c2va::Status;

constexpr uint32_t kMaxBitrate = 200000000;
constexpr c2_nsecs_t kFenceTimeoutNs = 1000000000;

std::atomic<uint32_t> g_coded_min[2][2];

// return caps' coded minimum, else the declared one
uint32_t CodedMinWidth(const c2va::ComponentCaps& caps) {
  return caps.coded_min_width ? caps.coded_min_width : caps.min_width;
}
uint32_t CodedMinHeight(const c2va::ComponentCaps& caps) {
  return caps.coded_min_height ? caps.coded_min_height : caps.min_height;
}

std::vector<uint32_t> BitrateModesOf(const c2va::ComponentCaps& caps) {
  std::vector<uint32_t> out;
  if (caps.va_rate_controls & VA_RC_VBR) out.push_back(C2Config::BITRATE_VARIABLE);
  if (caps.va_rate_controls & VA_RC_CBR) out.push_back(C2Config::BITRATE_CONST);
  if (caps.va_rate_controls & VA_RC_CQP) out.push_back(C2Config::BITRATE_IGNORE);
  return out;
}

}

EncoderIntf::EncoderIntf(const std::shared_ptr<C2ReflectorHelper>& helper, const c2va::ComponentCaps& caps)
    : android::SimpleInterface<void>::BaseParams(helper, caps.name, C2Component::KIND_ENCODER, C2Component::DOMAIN_VIDEO,
                                        caps.mime),
      caps_(caps) {
  noPrivateBuffers();
  noInputReferences();
  noOutputReferences();
  noInputLatency();
  noTimeStretch();
  setDerivedInstance(this);
  g_coded_min[caps.codec == Codec::kHevc][0] = CodedMinWidth(caps);
  g_coded_min[caps.codec == Codec::kHevc][1] = CodedMinHeight(caps);

  const uint64_t input_usage = static_cast<uint64_t>(C2MemoryUsage::CPU_READ) |
                               (caps.imports_yuv_dmabuf ? 0 : rhizo::kUsageGuestMemory);
  addParameter(DefineParam(usage_, C2_PARAMKEY_INPUT_STREAM_USAGE)
                   .withConstValue(new C2StreamUsageTuning::input(0u, input_usage))
                   .build());

  addParameter(DefineParam(attrib_, C2_PARAMKEY_COMPONENT_ATTRIBUTES)
                   .withConstValue(new C2ComponentAttributesSetting(C2Component::ATTRIB_IS_TEMPORAL))
                   .build());

  uint32_t min_w = std::max(caps.min_width, 2u), min_h = std::max(caps.min_height, 2u);
  addParameter(DefineParam(size_, C2_PARAMKEY_PICTURE_SIZE)
                   .withDefault(new C2StreamPictureSizeInfo::input(0u, std::max(320u, min_w), std::max(240u, min_h)))
                   .withFields({C2F(size_, width).inRange(min_w, caps.max_width, 2),
                                C2F(size_, height).inRange(min_h, caps.max_height, 2)})
                   .withSetter(SizeSetter)
                   .build());

  addParameter(DefineParam(frame_rate_, C2_PARAMKEY_FRAME_RATE)
                   .withDefault(new C2StreamFrameRateInfo::output(0u, 30.))
                   .withFields({C2F(frame_rate_, value).greaterThan(0.)})
                   .withSetter(android::Setter<decltype(*frame_rate_)>::StrictValueWithNoDeps)
                   .build());
  addParameter(DefineParam(operating_rate_, C2_PARAMKEY_OPERATING_RATE)
                   .withDefault(new C2OperatingRateTuning(0.))
                   .withFields({C2F(operating_rate_, value).any()})
                   .withSetter(android::Setter<decltype(*operating_rate_)>::NonStrictValueWithNoDeps)
                   .build());

  std::vector<uint32_t> modes = BitrateModesOf(caps);
  if (modes.empty()) modes.push_back(C2Config::BITRATE_VARIABLE);
  addParameter(DefineParam(bitrate_mode_, C2_PARAMKEY_BITRATE_MODE)
                   .withDefault(new C2StreamBitrateModeTuning::output(
                       0u, static_cast<C2Config::bitrate_mode_t>(modes.front())))
                   .withFields({C2F(bitrate_mode_, value).oneOf(modes)})
                   .withSetter(android::Setter<decltype(*bitrate_mode_)>::StrictValueWithNoDeps)
                   .build());

  addParameter(DefineParam(bitrate_, C2_PARAMKEY_BITRATE)
                   .withDefault(new C2StreamBitrateInfo::output(0u, 2000000))
                   .withFields({C2F(bitrate_, value).inRange(4096, kMaxBitrate)})
                   .withSetter(BitrateSetter)
                   .build());

  std::vector<uint32_t> profiles = ProfilesOf(caps);
  std::vector<uint32_t> levels = LevelsOf(caps);
  if (profiles.empty()) profiles.push_back(C2Config::PROFILE_UNUSED);
  if (levels.empty()) levels.push_back(C2Config::LEVEL_UNUSED);
  uint32_t default_profile = profiles.front();
  for (uint32_t p : profiles) {
    if (p == C2Config::PROFILE_AVC_MAIN || p == C2Config::PROFILE_HEVC_MAIN) default_profile = p;
  }
  addParameter(DefineParam(profile_level_, C2_PARAMKEY_PROFILE_LEVEL)
                   .withDefault(new C2StreamProfileLevelInfo::output(
                       0u, static_cast<C2Config::profile_t>(default_profile),
                       static_cast<C2Config::level_t>(levels.front())))
                   .withFields({C2F(profile_level_, profile).oneOf(profiles),
                                C2F(profile_level_, level).oneOf(levels)})
                   .withSetter(caps.codec == Codec::kHevc ? HevcProfileLevelSetter : AvcProfileLevelSetter, size_,
                               frame_rate_, bitrate_mode_, bitrate_)
                   .build());

  addParameter(DefineParam(request_sync_, C2_PARAMKEY_REQUEST_SYNC_FRAME)
                   .withDefault(new C2StreamRequestSyncFrameTuning::output(0u, C2_FALSE))
                   .withFields({C2F(request_sync_, value).oneOf({C2_FALSE, C2_TRUE})})
                   .withSetter(android::Setter<decltype(*request_sync_)>::NonStrictValueWithNoDeps)
                   .build());

  addParameter(DefineParam(sync_interval_, C2_PARAMKEY_SYNC_FRAME_INTERVAL)
                   .withDefault(new C2StreamSyncFrameIntervalTuning::output(0u, 1000000))
                   .withFields({C2F(sync_interval_, value).any()})
                   .withSetter(android::Setter<decltype(*sync_interval_)>::StrictValueWithNoDeps)
                   .build());

  addParameter(DefineParam(color_aspects_, C2_PARAMKEY_COLOR_ASPECTS)
                   .withDefault(new C2StreamColorAspectsInfo::input(
                       0u, C2Color::RANGE_UNSPECIFIED, C2Color::PRIMARIES_UNSPECIFIED,
                       C2Color::TRANSFER_UNSPECIFIED, C2Color::MATRIX_UNSPECIFIED))
                   .withFields({C2F(color_aspects_, range).inRange(C2Color::RANGE_UNSPECIFIED, C2Color::RANGE_OTHER),
                                C2F(color_aspects_, primaries)
                                    .inRange(C2Color::PRIMARIES_UNSPECIFIED, C2Color::PRIMARIES_OTHER),
                                C2F(color_aspects_, transfer)
                                    .inRange(C2Color::TRANSFER_UNSPECIFIED, C2Color::TRANSFER_OTHER),
                                C2F(color_aspects_, matrix)
                                    .inRange(C2Color::MATRIX_UNSPECIFIED, C2Color::MATRIX_OTHER)})
                   .withSetter(ColorAspectsSetter)
                   .build());

  addParameter(DefineParam(coded_color_aspects_, C2_PARAMKEY_VUI_COLOR_ASPECTS)
                   .withDefault(new C2StreamColorAspectsInfo::output(
                       0u, C2Color::RANGE_LIMITED, C2Color::PRIMARIES_UNSPECIFIED, C2Color::TRANSFER_UNSPECIFIED,
                       C2Color::MATRIX_UNSPECIFIED))
                   .withFields({C2F(coded_color_aspects_, range)
                                    .inRange(C2Color::RANGE_UNSPECIFIED, C2Color::RANGE_OTHER),
                                C2F(coded_color_aspects_, primaries)
                                    .inRange(C2Color::PRIMARIES_UNSPECIFIED, C2Color::PRIMARIES_OTHER),
                                C2F(coded_color_aspects_, transfer)
                                    .inRange(C2Color::TRANSFER_UNSPECIFIED, C2Color::TRANSFER_OTHER),
                                C2F(coded_color_aspects_, matrix)
                                    .inRange(C2Color::MATRIX_UNSPECIFIED, C2Color::MATRIX_OTHER)})
                   .withSetter(CodedColorAspectsSetter, color_aspects_)
                   .build());

  helper->addStructDescriptors<C2SystemResourceStruct>();
  addParameter(DefineParam(resources_needed_, C2_PARAMKEY_RESOURCES_NEEDED)
                   .withDefault(InstanceResources(ResourceIdOf(caps), size_->width, size_->height,
                                                  frame_rate_->value, operating_rate_->value))
                   .withFields({C2F(resources_needed_, m.values[0].id).any(),
                                C2F(resources_needed_, m.values[0].kind).any(),
                                C2F(resources_needed_, m.values[0].amount).any()})
                   .calculatedAs(NeedsSetter, size_, frame_rate_, operating_rate_)
                   .build());
}

C2R EncoderIntf::NeedsSetter(bool, C2P<C2ResourcesNeededTuning>& me,
                             const C2P<C2StreamPictureSizeInfo::input>& size,
                             const C2P<C2StreamFrameRateInfo::output>& rate, const C2P<C2OperatingRateTuning>& op) {
  return UpdateNeeds(me, size.v.width, size.v.height, rate.v.value, op.v.value);
}

C2R EncoderIntf::SizeSetter(bool, const C2P<C2StreamPictureSizeInfo::input>& oldMe,
                            C2P<C2StreamPictureSizeInfo::input>& me) {
  C2R res = C2R::Ok();
  if (!me.F(me.v.width).supportsAtAll(me.v.width)) {
    res = res.plus(C2SettingResultBuilder::BadValue(me.F(me.v.width)));
    me.set().width = oldMe.v.width;
  }
  if (!me.F(me.v.height).supportsAtAll(me.v.height)) {
    res = res.plus(C2SettingResultBuilder::BadValue(me.F(me.v.height)));
    me.set().height = oldMe.v.height;
  }
  return res;
}

C2R EncoderIntf::BitrateSetter(bool, C2P<C2StreamBitrateInfo::output>& me) {
  if (me.v.value < 4096) me.set().value = 4096;
  if (me.v.value > kMaxBitrate) me.set().value = kMaxBitrate;
  return C2R::Ok();
}

C2R EncoderIntf::AvcProfileLevelSetter(bool, C2P<C2StreamProfileLevelInfo::output>& me,
                                       const C2P<C2StreamPictureSizeInfo::input>& size,
                                       const C2P<C2StreamFrameRateInfo::output>& frame_rate,
                                       const C2P<C2StreamBitrateModeTuning::output>& mode,
                                       const C2P<C2StreamBitrateInfo::output>& bitrate) {
  return ProfileLevelSetterFor(false, me, size, frame_rate, mode, bitrate);
}

C2R EncoderIntf::HevcProfileLevelSetter(bool, C2P<C2StreamProfileLevelInfo::output>& me,
                                        const C2P<C2StreamPictureSizeInfo::input>& size,
                                        const C2P<C2StreamFrameRateInfo::output>& frame_rate,
                                        const C2P<C2StreamBitrateModeTuning::output>& mode,
                                        const C2P<C2StreamBitrateInfo::output>& bitrate) {
  return ProfileLevelSetterFor(true, me, size, frame_rate, mode, bitrate);
}

// pick the lowest offered level that suffices
C2R EncoderIntf::ProfileLevelSetterFor(bool hevc, C2P<C2StreamProfileLevelInfo::output>& me,
                                       const C2P<C2StreamPictureSizeInfo::input>& size,
                                       const C2P<C2StreamFrameRateInfo::output>& frame_rate,
                                       const C2P<C2StreamBitrateModeTuning::output>& mode,
                                       const C2P<C2StreamBitrateInfo::output>& bitrate) {
  C2R res = C2R::Ok();
  if (!me.F(me.v.profile).supportsAtAll(me.v.profile)) {
    res = res.plus(C2SettingResultBuilder::BadValue(me.F(me.v.profile)));
  }
  const Codec codec = hevc ? Codec::kHevc : Codec::kAvc;
  static const C2Config::level_t kAvc[] = {
      C2Config::LEVEL_AVC_1,   C2Config::LEVEL_AVC_1_1, C2Config::LEVEL_AVC_1_2, C2Config::LEVEL_AVC_1_3,
      C2Config::LEVEL_AVC_2,   C2Config::LEVEL_AVC_2_1, C2Config::LEVEL_AVC_2_2, C2Config::LEVEL_AVC_3,
      C2Config::LEVEL_AVC_3_1, C2Config::LEVEL_AVC_3_2, C2Config::LEVEL_AVC_4,   C2Config::LEVEL_AVC_4_1,
      C2Config::LEVEL_AVC_4_2, C2Config::LEVEL_AVC_5,   C2Config::LEVEL_AVC_5_1, C2Config::LEVEL_AVC_5_2,
      C2Config::LEVEL_AVC_6,   C2Config::LEVEL_AVC_6_1, C2Config::LEVEL_AVC_6_2};
  static const C2Config::level_t kHevc[] = {
      C2Config::LEVEL_HEVC_MAIN_1,   C2Config::LEVEL_HEVC_MAIN_2,   C2Config::LEVEL_HEVC_MAIN_2_1,
      C2Config::LEVEL_HEVC_MAIN_3,   C2Config::LEVEL_HEVC_MAIN_3_1, C2Config::LEVEL_HEVC_MAIN_4,
      C2Config::LEVEL_HEVC_MAIN_4_1, C2Config::LEVEL_HEVC_MAIN_5,   C2Config::LEVEL_HEVC_MAIN_5_1,
      C2Config::LEVEL_HEVC_MAIN_5_2, C2Config::LEVEL_HEVC_MAIN_6,   C2Config::LEVEL_HEVC_MAIN_6_1,
      C2Config::LEVEL_HEVC_MAIN_6_2};
  std::vector<uint32_t> offered;
  std::vector<C2Config::level_t> offered_c2;
  const C2Config::level_t* all = hevc ? kHevc : kAvc;
  const size_t n = hevc ? sizeof(kHevc) / sizeof(kHevc[0]) : sizeof(kAvc) / sizeof(kAvc[0]);
  for (size_t i = 0; i < n; i++) {
    if (!me.F(me.v.level).supportsAtAll(all[i])) continue;
    offered.push_back(LevelIdcOf(codec, all[i]));
    offered_c2.push_back(all[i]);
  }
  if (offered.empty()) return res;
  float fps = frame_rate.v.value > 0.f ? frame_rate.v.value : 30.f;
  const double rate = static_cast<double>(lroundf(fps * 1000.f)) / 1000.0;
  const uint32_t bits = mode.v.value == C2Config::BITRATE_IGNORE ? 0 : bitrate.v.value;
  uint32_t profile_idc = 100;
  if (me.v.profile == C2Config::PROFILE_AVC_BASELINE || me.v.profile == C2Config::PROFILE_AVC_CONSTRAINED_BASELINE)
    profile_idc = 66;
  else if (me.v.profile == C2Config::PROFILE_AVC_MAIN)
    profile_idc = 77;
  const uint32_t needed = c2va::enc::MinLevelIdc(hevc, profile_idc, size.v.width, size.v.height,
                                                 g_coded_min[hevc][0].load(), g_coded_min[hevc][1].load(), rate, bits);
  const bool known = me.F(me.v.level).supportsAtAll(me.v.level) && me.v.level != C2Config::LEVEL_AVC_1B;
  const uint32_t asked = known ? LevelIdcOf(codec, me.v.level) : 0;
  uint32_t ask = asked;
  if (!known && me.v.level != C2Config::LEVEL_UNUSED && me.v.level != C2Config::LEVEL_AVC_1B &&
      me.v.level > offered_c2.back() && (static_cast<uint32_t>(me.v.level) & 0xF000u) ==
                                            (static_cast<uint32_t>(offered_c2.back()) & 0xF000u))
    ask = offered.back() + 1;
  const uint32_t pick = c2va::enc::PickLevelIdc(offered, ask, needed);
  for (size_t i = 0; i < offered.size(); i++) {
    if (offered[i] == pick && offered_c2[i] != me.v.level) {
      me.set().level = offered_c2[i];
      break;
    }
  }
  return res;
}

C2R EncoderIntf::ColorAspectsSetter(bool, C2P<C2StreamColorAspectsInfo::input>& me) {
  if (me.v.range > C2Color::RANGE_OTHER) me.set().range = C2Color::RANGE_OTHER;
  if (me.v.primaries > C2Color::PRIMARIES_OTHER) me.set().primaries = C2Color::PRIMARIES_OTHER;
  if (me.v.transfer > C2Color::TRANSFER_OTHER) me.set().transfer = C2Color::TRANSFER_OTHER;
  if (me.v.matrix > C2Color::MATRIX_OTHER) me.set().matrix = C2Color::MATRIX_OTHER;
  return C2R::Ok();
}

C2R EncoderIntf::CodedColorAspectsSetter(bool, C2P<C2StreamColorAspectsInfo::output>& me,
                                         const C2P<C2StreamColorAspectsInfo::input>& in) {
  me.set().range = in.v.range;
  me.set().primaries = in.v.primaries;
  me.set().transfer = in.v.transfer;
  me.set().matrix = in.v.matrix;
  return C2R::Ok();
}

VideoEncoder::VideoEncoder(const char* name, c2_node_id_t id, const std::shared_ptr<EncoderIntf>& intf,
                           std::unique_ptr<InstanceSlot> slot)
    : SimpleC2Component(std::make_shared<android::SimpleInterface<EncoderIntf>>(name, id, intf)),
      intf_(intf),
      slot_(std::move(slot)) {}

VideoEncoder::~VideoEncoder() { onRelease(); }

c2_status_t VideoEncoder::start() {
  std::unique_ptr<C2Param> needs;
  {
    auto lock = intf_->lock();
    needs = C2Param::Copy(*intf_->resources_needed_l());
  }
  return StartReserved(slot_.get(), *C2ResourcesNeededTuning::From(needs.get()), intf_->caps().name,
                       [this] { return SimpleC2Component::start(); });
}

c2_status_t VideoEncoder::stop() {
  c2_status_t err = SimpleC2Component::stop();
  if (slot_) slot_->Unreserve();
  return err;
}

c2_status_t VideoEncoder::reset() {
  c2_status_t err = SimpleC2Component::reset();
  if (slot_) slot_->Unreserve();
  return err;
}

void VideoEncoder::RestateNeeds(bool force) {
  std::unique_ptr<C2Param> needs;
  {
    auto lock = intf_->lock();
    needs = C2Param::Copy(*intf_->resources_needed_l());
  }
  if (HoldNeeds(slot_.get(), *C2ResourcesNeededTuning::From(needs.get()), force)) updates_.push_back(std::move(needs));
}

c2_status_t VideoEncoder::C2Status(Status status) {
  switch (status) {
    case Status::kOk: return C2_OK;
    case Status::kBadStream: return C2_BAD_VALUE;
    case Status::kUnsupported: return C2_OMITTED;
    case Status::kNoMemory: return C2_NO_MEMORY;
    case Status::kVaError: return C2_CORRUPTED;
  }
  return C2_CORRUPTED;
}

// clear the error state before the first picture
c2_status_t VideoEncoder::onInit() {
  error_ = C2_OK;
  signalled_eos_ = false;
  return C2_OK;
}

// close the session and drop the pending updates
c2_status_t VideoEncoder::onFlush_sm() {
  session_.reset();
  updates_.clear();
  signalled_eos_ = false;
  return C2_OK;
}

c2_status_t VideoEncoder::onStop() {
  (void)onFlush_sm();
  error_ = C2_OK;
  return C2_OK;
}

void VideoEncoder::onReset() { (void)onStop(); }

void VideoEncoder::onRelease() {
  session_.reset();
  slot_.reset();
}

c2_status_t VideoEncoder::Open() {
  const c2va::ComponentCaps& caps = intf_->caps();
  EncoderConfig cfg{};
  int64_t sync_us;
  float fps;
  {
    auto lock = intf_->lock();
    std::shared_ptr<C2StreamPictureSizeInfo::input> size = intf_->size_l();
    std::shared_ptr<C2StreamProfileLevelInfo::output> pl = intf_->profile_level_l();
    std::shared_ptr<C2StreamColorAspectsInfo::input> color = intf_->color_aspects_l();
    cfg.width = size->width;
    cfg.height = size->height;
    cfg.min_coded_width = CodedMinWidth(caps);
    cfg.min_coded_height = CodedMinHeight(caps);
    cfg.profile = VaProfileFor(caps, pl->profile);
    if (cfg.profile == VAProfileNone && !caps.va_profiles.empty()) cfg.profile = caps.va_profiles.front();
    C2Config::level_t level = std::max(pl->level, MinLevelFor(caps, cfg.width, cfg.height));
    cfg.level = LevelIdcOf(caps.codec, level);
    fps = intf_->frame_rate_l()->value;
    cfg.bitrate = intf_->bitrate_l()->value;
    switch (intf_->bitrate_mode_l()->value) {
      case C2Config::BITRATE_CONST: cfg.rate_control = EncoderConfig::RateControl::kCbr; break;
      case C2Config::BITRATE_IGNORE: cfg.rate_control = EncoderConfig::RateControl::kCq; break;
      default: cfg.rate_control = EncoderConfig::RateControl::kVbr; break;
    }
    sync_us = intf_->sync_interval_l()->value;
    cfg.color = IsoColorOf(color->range, color->primaries, color->transfer, color->matrix);
  }
  if (!(fps > 0.f)) fps = 30.f;
  cfg.framerate_num = static_cast<uint32_t>(lroundf(fps * 1000.f));
  cfg.framerate_den = 1000;
  uint32_t g = std::gcd(cfg.framerate_num, cfg.framerate_den);
  if (g > 1) {
    cfg.framerate_num /= g;
    cfg.framerate_den /= g;
  }
  cfg.quality = EncoderIntf::kConstantQp;
  if (sync_us < 0) {
    cfg.keyframe_interval = 0;
  } else if (sync_us == 0) {
    cfg.keyframe_interval = 1;
  } else {
    cfg.keyframe_interval = std::max<uint32_t>(1, static_cast<uint32_t>(llroundf(sync_us * fps / 1e6f)));
  }
  c2va::EncodeCallbacks cb;
  cb.output = [this](const uint8_t* data, size_t size, uint64_t tag, int64_t pts, bool keyframe, bool config) {
    OnOutput(data, size, tag, pts, keyframe, config);
  };
  Status st = Status::kOk;
  session_ = c2va::EncodeSession::Create(caps.codec, cfg, std::move(cb), &st);
  if (!session_) {
    klogf("%s: no VA encode session for %ux%u (%d)", caps.name.c_str(), cfg.width, cfg.height,
          static_cast<int>(st));
    return st == Status::kNoMemory ? C2_NO_MEMORY : C2_CORRUPTED;
  }
  bitrate_ = session_->config().bitrate;
  return C2_OK;
}

// encode a block from its dmabuf or its CPU mapping
Status VideoEncoder::EncodeInput(const C2ConstGraphicBlock& block, uint64_t tag, int64_t pts, bool keyframe) {
  c2_status_t fence = block.fence().wait(kFenceTimeoutNs);
  if (fence != C2_OK) {
    klogf("%s: input fence not signalled (%d)", intf_->caps().name.c_str(), fence);
    return Status::kVaError;
  }
  c2va::DmabufImage img;
  if (DmabufOf(block, &img)) {
    img.width = std::min(img.width, block.crop().width);
    img.height = std::min(img.height, block.crop().height);
    Status st = session_->Encode(img, tag, pts, keyframe);
    if (st != Status::kUnsupported) return st;
  }
  C2GraphicView view = block.map().get();
  if (view.error() != C2_OK) {
    klogf("%s: input map failed (%d)", intf_->caps().name.c_str(), view.error());
    return Status::kVaError;
  }
  c2va::YuvSrc yuv;
  if (YuvSrcOf(view, &yuv)) return session_->Encode(yuv, tag, pts, keyframe);
  c2va::RgbaSrc rgba;
  if (RgbaSrcOf(view, &rgba)) return session_->Encode(rgba, tag, pts, keyframe);
  klogf("%s: the input is neither 8-bit YUV 4:2:0 nor RGBA", intf_->caps().name.c_str());
  return Status::kUnsupported;
}

void VideoEncoder::process(const std::unique_ptr<C2Work>& work, const std::shared_ptr<C2BlockPool>& pool) {
  work->result = C2_OK;
  work->workletsProcessed = 0u;
  work->worklets.front()->output.flags = static_cast<C2FrameData::flags_t>(0);
  work->worklets.front()->output.ordinal = work->input.ordinal;
  if (error_ != C2_OK || signalled_eos_) {
    work->result = C2_BAD_VALUE;
    work->workletsProcessed = 1u;
    return;
  }
  RestateNeeds(false);
  bool eos = (work->input.flags & C2FrameData::FLAG_END_OF_STREAM) != 0;
  uint64_t tag = work->input.ordinal.frameIndex.peeku();
  int64_t pts = work->input.ordinal.timestamp.peekll();

  current_ = &work;
  pool_ = pool;
  current_eos_ = eos;
  current_done_ = false;
  Status st = Status::kOk;
  bool has_picture = !work->input.buffers.empty() && work->input.buffers[0] &&
                     !work->input.buffers[0]->data().graphicBlocks().empty();
  if (has_picture) {
    if (!session_) {
      c2_status_t err = Open();
      if (err != C2_OK) error_ = err;
    }
    if (error_ == C2_OK) {
      bool keyframe = false;
      uint32_t bitrate;
      {
        auto lock = intf_->lock();
        bitrate = intf_->bitrate_l()->value;
        keyframe = intf_->request_sync_l()->value == C2_TRUE;
      }
      if (keyframe) {
        C2StreamRequestSyncFrameTuning::output clear(0u, C2_FALSE);
        std::vector<std::unique_ptr<C2SettingResult>> failures;
        (void)intf_->config({&clear}, C2_MAY_BLOCK, &failures);
        updates_.push_back(C2Param::Copy(clear));
      }
      if (bitrate != bitrate_ && session_->SetBitrate(bitrate) == Status::kOk) bitrate_ = bitrate;
      st = EncodeInput(work->input.buffers[0]->data().graphicBlocks().front(), tag, pts, keyframe);
    }
  } else if (!eos) {
    current_done_ = true;
    work->workletsProcessed = 1u;
  }
  if (st == Status::kOk && error_ == C2_OK && eos && session_) st = session_->Drain();
  if (st != Status::kOk && error_ == C2_OK) error_ = C2Status(st);
  current_ = nullptr;
  pool_.reset();

  if (error_ != C2_OK) {
    klogf("%s: encoding failed (%d)", intf_->caps().name.c_str(), static_cast<int>(error_));
    work->result = error_;
    work->workletsProcessed = 1u;
    return;
  }
  if (eos) {
    for (auto& u : updates_) work->worklets.front()->output.configUpdate.push_back(std::move(u));
    updates_.clear();
    work->worklets.front()->output.flags = C2FrameData::FLAG_END_OF_STREAM;
    work->worklets.front()->output.buffers.clear();
    work->workletsProcessed = 1u;
    signalled_eos_ = true;
  }
}

c2_status_t VideoEncoder::drain(uint32_t drainMode, const std::shared_ptr<C2BlockPool>& pool) {
  if (drainMode == NO_DRAIN) return C2_OK;
  if (drainMode == DRAIN_CHAIN) return C2_OMITTED;
  if (!session_) return C2_OK;
  pool_ = pool;
  current_ = nullptr;
  Status st = session_->Drain();
  pool_.reset();
  return st == Status::kOk ? C2_OK : C2Status(st);
}

void VideoEncoder::OnOutput(const uint8_t* data, size_t size, uint64_t tag, int64_t, bool keyframe,
                            bool codec_config) {
  if (error_ != C2_OK || !pool_) return;
  if (codec_config) {
    std::unique_ptr<C2StreamInitDataInfo::output> csd = C2StreamInitDataInfo::output::AllocUnique(size, 0u);
    if (!csd) {
      error_ = C2_NO_MEMORY;
      return;
    }
    memcpy(csd->m.value, data, size);
    updates_.push_back(std::move(csd));
    PublishSignalledLevel(data, size);
    return;
  }
  if (size == 0) {
    Complete(tag, nullptr);
    return;
  }
  std::shared_ptr<C2LinearBlock> block;
  c2_status_t err = pool_->fetchLinearBlock(static_cast<uint32_t>(size),
                                            C2MemoryUsage(C2MemoryUsage::CPU_READ, C2MemoryUsage::CPU_WRITE), &block);
  if (err != C2_OK || !block) {
    klogf("%s: no %zu-byte output block (%d)", intf_->caps().name.c_str(), size, err);
    error_ = err != C2_OK ? err : C2_NO_MEMORY;
    return;
  }
  {
    C2WriteView view = block->map().get();
    if (view.error() != C2_OK) {
      error_ = view.error();
      return;
    }
    memcpy(view.data(), data, size);
  }
  std::shared_ptr<C2Buffer> buffer = createLinearBuffer(block, 0, size);
  if (keyframe) buffer->setInfo(std::make_shared<C2StreamPictureTypeMaskInfo::output>(0u, C2Config::SYNC_FRAME));
  Complete(tag, buffer);
}

void VideoEncoder::PublishSignalledLevel(const uint8_t* csd, size_t size) {
  const c2va::Codec codec = intf_->caps().codec;
  uint32_t idc = 0;
  for (const c2va::NalSpan& n : c2va::SplitAnnexB(csd, size)) {
    if (codec == c2va::Codec::kAvc && n.size >= 4 && (n.data[0] & 0x1f) == 7) {
      std::vector<uint8_t> rbsp = c2va::Unescape(n.data + 1, n.size - 1);
      if (rbsp.size() >= 3) idc = rbsp[2];
    } else if (codec == c2va::Codec::kHevc && n.size >= 3 && ((n.data[0] >> 1) & 0x3f) == 33) {
      std::vector<uint8_t> rbsp = c2va::Unescape(n.data + 2, n.size - 2);
      if (rbsp.size() >= 13) idc = rbsp[12];
    }
  }
  if (idc == 0) return;
  C2Config::level_t level = C2Config::LEVEL_UNUSED;
  for (uint32_t l : LevelsOf(intf_->caps())) {
    if (LevelIdcOf(codec, static_cast<C2Config::level_t>(l)) == idc && l != C2Config::LEVEL_AVC_1B)
      level = static_cast<C2Config::level_t>(l);
  }
  std::unique_ptr<C2StreamProfileLevelInfo::output> now;
  {
    auto lock = intf_->lock();
    now = std::make_unique<C2StreamProfileLevelInfo::output>(*intf_->profile_level_l());
  }
  if (level == C2Config::LEVEL_UNUSED || level == now->level) return;
  klogf("%s: the parameter sets signal level_idc %u, published as the component's level", intf_->caps().name.c_str(),
        idc);
  now->level = level;
  std::vector<std::unique_ptr<C2SettingResult>> failures;
  (void)intf_->config({now.get()}, C2_MAY_BLOCK, &failures);
  {
    auto lock = intf_->lock();
    updates_.push_back(C2Param::Copy(*intf_->profile_level_l()));
  }
}

void VideoEncoder::Complete(uint64_t tag, const std::shared_ptr<C2Buffer>& buffer) {
  std::vector<std::unique_ptr<C2Param>> ups = std::move(updates_);
  updates_.clear();
  auto fill = [&buffer, &ups](const std::unique_ptr<C2Work>& w, C2FrameData::flags_t flags) {
    w->worklets.front()->output.flags = flags;
    w->worklets.front()->output.buffers.clear();
    if (buffer) w->worklets.front()->output.buffers.push_back(buffer);
    for (auto& u : ups) w->worklets.front()->output.configUpdate.push_back(std::move(u));
    w->worklets.front()->output.ordinal = w->input.ordinal;
    w->workletsProcessed = 1u;
    w->result = C2_OK;
  };
  if (current_ != nullptr && (*current_)->input.ordinal.frameIndex.peeku() == tag) {
    if (current_eos_) {
      cloneAndSend(tag, *current_, [&fill](const std::unique_ptr<C2Work>& w) {
        fill(w, C2FrameData::FLAG_INCOMPLETE);
      });
      return;
    }
    fill(*current_, static_cast<C2FrameData::flags_t>(0));
    current_done_ = true;
    return;
  }
  finish(tag, [&fill](const std::unique_ptr<C2Work>& w) { fill(w, static_cast<C2FrameData::flags_t>(0)); });
}

ComponentEntry EncoderEntry(const c2va::ComponentCaps& caps) {
  ComponentEntry e;
  e.traits = VideoTraits(caps.name, caps.mime, C2Component::KIND_ENCODER);
  e.max_instances = caps.max_instances;
  e.resource_id = ResourceIdOf(caps);
  e.make_interface = [caps](c2_node_id_t id, const std::shared_ptr<C2ReflectorHelper>& reflector) {
    return std::make_shared<android::SimpleInterface<EncoderIntf>>(caps.name.c_str(), id,
                                                                     std::make_shared<EncoderIntf>(reflector, caps));
  };
  e.make_component = [caps](c2_node_id_t id, const std::shared_ptr<C2ReflectorHelper>& reflector,
                            std::unique_ptr<InstanceSlot> slot) -> std::shared_ptr<C2Component> {
    return std::make_shared<VideoEncoder>(caps.name.c_str(), id, std::make_shared<EncoderIntf>(reflector, caps),
                                          std::move(slot));
  };
  return e;
}

}

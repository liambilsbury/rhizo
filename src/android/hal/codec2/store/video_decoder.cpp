#include "video_decoder.h"

#include <string.h>

#include <algorithm>

#include <C2AllocatorGralloc.h>
#include <C2PlatformSupport.h>
#include <media/stagefright/foundation/MediaDefs.h>
#include <system/graphics.h>

#include "buffers.h"
#include "codec_map.h"
#include "log.h"

namespace rhizo::c2store {

namespace {

using c2va::Codec;
using c2va::Status;

constexpr uint32_t kMinInputBufferSize = 2 * 1024 * 1024;

}

uint32_t DecoderIntf::DefaultOutputDelay(Codec codec) {
  return codec == Codec::kAvc || codec == Codec::kHevc ? 8 : 0;
}

DecoderIntf::DecoderIntf(const std::shared_ptr<C2ReflectorHelper>& helper, const c2va::ComponentCaps& caps)
    : android::SimpleInterface<void>::BaseParams(helper, caps.name, C2Component::KIND_DECODER, C2Component::DOMAIN_VIDEO,
                                        caps.mime),
      caps_(caps) {
  noPrivateBuffers();
  noInputReferences();
  noOutputReferences();
  noInputLatency();
  noTimeStretch();
  setDerivedInstance(this);

  addParameter(DefineParam(attrib_, C2_PARAMKEY_COMPONENT_ATTRIBUTES)
                   .withConstValue(new C2ComponentAttributesSetting(C2Component::ATTRIB_IS_TEMPORAL))
                   .build());

  addParameter(DefineParam(output_delay_, C2_PARAMKEY_OUTPUT_DELAY)
                   .withDefault(new C2PortActualDelayTuning::output(DefaultOutputDelay(caps.codec)))
                   .withFields({C2F(output_delay_, value).inRange(0, kMaxOutputDelay)})
                   .withSetter(android::Setter<decltype(*output_delay_)>::StrictValueWithNoDeps)
                   .build());

  const uint32_t step = SizeAlignmentOf(caps.codec);
  uint32_t min_w = std::max(caps.min_width, 2u), min_h = std::max(caps.min_height, 2u);
  addParameter(DefineParam(size_, C2_PARAMKEY_PICTURE_SIZE)
                   .withDefault(new C2StreamPictureSizeInfo::output(0u, std::max(320u, min_w), std::max(240u, min_h)))
                   .withFields({C2F(size_, width).inRange(min_w, caps.max_width, step),
                                C2F(size_, height).inRange(min_h, caps.max_height, step)})
                   .withSetter(SizeSetter)
                   .build());

  addParameter(DefineParam(max_size_, C2_PARAMKEY_MAX_PICTURE_SIZE)
                   .withDefault(new C2StreamMaxPictureSizeTuning::output(0u, 320, 240))
                   .withFields({C2F(max_size_, width).inRange(2, caps.max_width, step),
                                C2F(max_size_, height).inRange(2, caps.max_height, step)})
                   .withSetter(MaxPictureSizeSetter, size_)
                   .build());

  addParameter(DefineParam(max_input_size_, C2_PARAMKEY_INPUT_MAX_BUFFER_SIZE)
                   .withDefault(new C2StreamMaxBufferSizeInfo::input(0u, kMinInputBufferSize))
                   .withFields({C2F(max_input_size_, value).any()})
                   .calculatedAs(MaxInputSizeSetter, max_size_)
                   .build());

  std::vector<uint32_t> profiles = ProfilesOf(caps);
  std::vector<uint32_t> levels = LevelsOf(caps);
  if (profiles.empty()) profiles.push_back(C2Config::PROFILE_UNUSED);
  if (levels.empty()) levels.push_back(C2Config::LEVEL_UNUSED);
  addParameter(DefineParam(profile_level_, C2_PARAMKEY_PROFILE_LEVEL)
                   .withDefault(new C2StreamProfileLevelInfo::input(
                       0u, static_cast<C2Config::profile_t>(profiles.front()),
                       static_cast<C2Config::level_t>(levels.back())))
                   .withFields({C2F(profile_level_, profile).oneOf(profiles),
                                C2F(profile_level_, level).oneOf(levels)})
                   .withSetter(ProfileLevelSetter)
                   .build());

  std::shared_ptr<C2StreamColorInfo::output> color = C2StreamColorInfo::output::AllocShared(
      {C2ChromaOffsetStruct::ITU_YUV_420_0()}, 0u, 8u /* bitDepth */, C2Color::YUV_420);
  helper->addStructDescriptors<C2ChromaOffsetStruct>();
  addParameter(DefineParam(color_info_, C2_PARAMKEY_CODED_COLOR_INFO).withConstValue(color).build());

  addParameter(DefineParam(default_color_aspects_, C2_PARAMKEY_DEFAULT_COLOR_ASPECTS)
                   .withDefault(new C2StreamColorAspectsTuning::output(
                       0u, C2Color::RANGE_UNSPECIFIED, C2Color::PRIMARIES_UNSPECIFIED,
                       C2Color::TRANSFER_UNSPECIFIED, C2Color::MATRIX_UNSPECIFIED))
                   .withFields({C2F(default_color_aspects_, range)
                                    .inRange(C2Color::RANGE_UNSPECIFIED, C2Color::RANGE_OTHER),
                                C2F(default_color_aspects_, primaries)
                                    .inRange(C2Color::PRIMARIES_UNSPECIFIED, C2Color::PRIMARIES_OTHER),
                                C2F(default_color_aspects_, transfer)
                                    .inRange(C2Color::TRANSFER_UNSPECIFIED, C2Color::TRANSFER_OTHER),
                                C2F(default_color_aspects_, matrix)
                                    .inRange(C2Color::MATRIX_UNSPECIFIED, C2Color::MATRIX_OTHER)})
                   .withSetter(DefaultColorAspectsSetter)
                   .build());

  addParameter(DefineParam(coded_color_aspects_, C2_PARAMKEY_VUI_COLOR_ASPECTS)
                   .withDefault(new C2StreamColorAspectsInfo::input(
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
                   .withSetter(CodedColorAspectsSetter)
                   .build());

  addParameter(DefineParam(color_aspects_, C2_PARAMKEY_COLOR_ASPECTS)
                   .withDefault(new C2StreamColorAspectsInfo::output(
                       0u, C2Color::RANGE_UNSPECIFIED, C2Color::PRIMARIES_UNSPECIFIED,
                       C2Color::TRANSFER_UNSPECIFIED, C2Color::MATRIX_UNSPECIFIED))
                   .withFields({C2F(color_aspects_, range).inRange(C2Color::RANGE_UNSPECIFIED, C2Color::RANGE_OTHER),
                                C2F(color_aspects_, primaries)
                                    .inRange(C2Color::PRIMARIES_UNSPECIFIED, C2Color::PRIMARIES_OTHER),
                                C2F(color_aspects_, transfer)
                                    .inRange(C2Color::TRANSFER_UNSPECIFIED, C2Color::TRANSFER_OTHER),
                                C2F(color_aspects_, matrix)
                                    .inRange(C2Color::MATRIX_UNSPECIFIED, C2Color::MATRIX_OTHER)})
                   .withSetter(
                       ContainerAspectsFirst(caps.codec) ? ContainerFirstColorAspectsSetter : ColorAspectsSetter,
                       default_color_aspects_, coded_color_aspects_)
                   .build());

  std::vector<uint32_t> formats = {HAL_PIXEL_FORMAT_YCBCR_420_888, HAL_PIXEL_FORMAT_IMPLEMENTATION_DEFINED};
  addParameter(DefineParam(pixel_format_, C2_PARAMKEY_PIXEL_FORMAT)
                   .withDefault(new C2StreamPixelFormatInfo::output(0u, HAL_PIXEL_FORMAT_YCBCR_420_888))
                   .withFields({C2F(pixel_format_, value).oneOf(formats)})
                   .withSetter((android::Setter<decltype(*pixel_format_)>::StrictValueWithNoDeps))
                   .build());

  addParameter(DefineParam(output_usage_, C2_PARAMKEY_OUTPUT_STREAM_USAGE)
                   .withDefault(new C2StreamUsageTuning::output(0u, 0u))
                   .withFields({C2F(output_usage_, value).any()})
                   .withSetter(UsageSetter)
                   .build());

  addParameter(DefineParam(frame_rate_, C2_PARAMKEY_FRAME_RATE)
                   .withDefault(new C2StreamFrameRateInfo::input(0u, 30.))
                   .withFields({C2F(frame_rate_, value).greaterThan(0.)})
                   .withSetter(android::Setter<decltype(*frame_rate_)>::StrictValueWithNoDeps)
                   .build());
  addParameter(DefineParam(operating_rate_, C2_PARAMKEY_OPERATING_RATE)
                   .withDefault(new C2OperatingRateTuning(0.))
                   .withFields({C2F(operating_rate_, value).any()})
                   .withSetter(android::Setter<decltype(*operating_rate_)>::NonStrictValueWithNoDeps)
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

C2R DecoderIntf::NeedsSetter(bool, C2P<C2ResourcesNeededTuning>& me,
                             const C2P<C2StreamPictureSizeInfo::output>& size,
                             const C2P<C2StreamFrameRateInfo::input>& rate, const C2P<C2OperatingRateTuning>& op) {
  return UpdateNeeds(me, size.v.width, size.v.height, rate.v.value, op.v.value);
}

C2R DecoderIntf::SizeSetter(bool, const C2P<C2StreamPictureSizeInfo::output>& oldMe,
                            C2P<C2StreamPictureSizeInfo::output>& me) {
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

C2R DecoderIntf::MaxPictureSizeSetter(bool, C2P<C2StreamMaxPictureSizeTuning::output>& me,
                                      const C2P<C2StreamPictureSizeInfo::output>& size) {
  me.set().width = std::max(me.v.width, size.v.width);
  me.set().height = std::max(me.v.height, size.v.height);
  if (!me.F(me.v.width).supportsAtAll(me.v.width)) me.set().width = size.v.width;
  if (!me.F(me.v.height).supportsAtAll(me.v.height)) me.set().height = size.v.height;
  return C2R::Ok();
}

// size input buffers at 3072 bytes per 64x64 block
C2R DecoderIntf::MaxInputSizeSetter(bool, C2P<C2StreamMaxBufferSizeInfo::input>& me,
                                    const C2P<C2StreamMaxPictureSizeTuning::output>& maxSize) {
  me.set().value =
      std::max(((maxSize.v.width + 63) / 64) * ((maxSize.v.height + 63) / 64) * 3072, kMinInputBufferSize);
  return C2R::Ok();
}

C2R DecoderIntf::ProfileLevelSetter(bool, C2P<C2StreamProfileLevelInfo::input>& me) {
  C2R res = C2R::Ok();
  if (!me.F(me.v.profile).supportsAtAll(me.v.profile)) {
    res = res.plus(C2SettingResultBuilder::BadValue(me.F(me.v.profile)));
  }
  if (!me.F(me.v.level).supportsAtAll(me.v.level)) {
    res = res.plus(C2SettingResultBuilder::BadValue(me.F(me.v.level)));
  }
  return res;
}

C2R DecoderIntf::DefaultColorAspectsSetter(bool, C2P<C2StreamColorAspectsTuning::output>& me) {
  if (me.v.range > C2Color::RANGE_OTHER) me.set().range = C2Color::RANGE_OTHER;
  if (me.v.primaries > C2Color::PRIMARIES_OTHER) me.set().primaries = C2Color::PRIMARIES_OTHER;
  if (me.v.transfer > C2Color::TRANSFER_OTHER) me.set().transfer = C2Color::TRANSFER_OTHER;
  if (me.v.matrix > C2Color::MATRIX_OTHER) me.set().matrix = C2Color::MATRIX_OTHER;
  return C2R::Ok();
}

C2R DecoderIntf::CodedColorAspectsSetter(bool, C2P<C2StreamColorAspectsInfo::input>& me) {
  if (me.v.range > C2Color::RANGE_OTHER) me.set().range = C2Color::RANGE_OTHER;
  if (me.v.primaries > C2Color::PRIMARIES_OTHER) me.set().primaries = C2Color::PRIMARIES_OTHER;
  if (me.v.transfer > C2Color::TRANSFER_OTHER) me.set().transfer = C2Color::TRANSFER_OTHER;
  if (me.v.matrix > C2Color::MATRIX_OTHER) me.set().matrix = C2Color::MATRIX_OTHER;
  return C2R::Ok();
}

C2R DecoderIntf::ColorAspectsSetter(bool, C2P<C2StreamColorAspectsInfo::output>& me,
                                    const C2P<C2StreamColorAspectsTuning::output>& def,
                                    const C2P<C2StreamColorAspectsInfo::input>& coded) {
  C2ColorAspectsStruct m = MergeColorAspects(def.v, coded.v, false);
  me.set().range = m.range;
  me.set().primaries = m.primaries;
  me.set().transfer = m.transfer;
  me.set().matrix = m.matrix;
  return C2R::Ok();
}

C2R DecoderIntf::ContainerFirstColorAspectsSetter(bool, C2P<C2StreamColorAspectsInfo::output>& me,
                                                  const C2P<C2StreamColorAspectsTuning::output>& def,
                                                  const C2P<C2StreamColorAspectsInfo::input>& coded) {
  C2ColorAspectsStruct m = MergeColorAspects(def.v, coded.v, true);
  me.set().range = m.range;
  me.set().primaries = m.primaries;
  me.set().transfer = m.transfer;
  me.set().matrix = m.matrix;
  return C2R::Ok();
}

C2R DecoderIntf::UsageSetter(bool, C2P<C2StreamUsageTuning::output>&) { return C2R::Ok(); }

VideoDecoder::VideoDecoder(const char* name, c2_node_id_t id, const std::shared_ptr<DecoderIntf>& intf,
                           std::unique_ptr<InstanceSlot> slot)
    : SimpleC2Component(std::make_shared<android::SimpleInterface<DecoderIntf>>(name, id, intf)),
      intf_(intf),
      slot_(std::move(slot)) {}

VideoDecoder::~VideoDecoder() { onRelease(); }

// note each queued input's default colour aspects
c2_status_t VideoDecoder::queue_nb(std::list<std::unique_ptr<C2Work>>* items) {
  C2ColorAspectsStruct def;
  {
    auto lock = intf_->lock();
    def = *intf_->default_color_aspects_l();
  }
  for (const std::unique_ptr<C2Work>& work : *items) {
    if (work) defaults_.Note(work->input.ordinal.frameIndex.peeku(), def);
  }
  return SimpleC2Component::queue_nb(items);
}

c2_status_t VideoDecoder::C2Status(Status status) {
  switch (status) {
    case Status::kOk: return C2_OK;
    case Status::kBadStream: return C2_BAD_VALUE;
    case Status::kUnsupported: return C2_OMITTED;
    case Status::kNoMemory: return C2_NO_MEMORY;
    case Status::kVaError: return C2_CORRUPTED;
  }
  return C2_CORRUPTED;
}

c2_status_t VideoDecoder::start() {
  std::unique_ptr<C2Param> needs;
  {
    auto lock = intf_->lock();
    needs = C2Param::Copy(*intf_->resources_needed_l());
  }
  return StartReserved(slot_.get(), *C2ResourcesNeededTuning::From(needs.get()), intf_->caps().name,
                       [this] { return SimpleC2Component::start(); });
}

c2_status_t VideoDecoder::stop() {
  c2_status_t err = SimpleC2Component::stop();
  if (slot_) slot_->Unreserve();
  return err;
}

c2_status_t VideoDecoder::reset() {
  c2_status_t err = SimpleC2Component::reset();
  if (slot_) slot_->Unreserve();
  return err;
}

void VideoDecoder::RestateNeeds(bool force) {
  std::unique_ptr<C2Param> needs;
  {
    auto lock = intf_->lock();
    needs = C2Param::Copy(*intf_->resources_needed_l());
  }
  if (HoldNeeds(slot_.get(), *C2ResourcesNeededTuning::From(needs.get()), force)) updates_.push_back(std::move(needs));
}

// open the decode session on first init
c2_status_t VideoDecoder::onInit() {
  if (session_) {
    ApplyMaxPictureSize();
    return C2_OK;
  }
  c2va::DecodeCallbacks cb;
  cb.output = [this](const c2va::Frame& f) { OnFrame(f); };
  cb.skip = [this](uint64_t tag) { OnSkip(tag); };
  cb.stream_changed = [this](const c2va::StreamInfo& info) { OnStreamChanged(info); };
  Status st = Status::kOk;
  session_ = c2va::DecodeSession::Create(intf_->caps().codec, std::move(cb), &st);
  if (!session_) {
    klogf("%s: no VA decode session (%d)", intf_->caps().name.c_str(), static_cast<int>(st));
    return st == Status::kNoMemory ? C2_NO_MEMORY : C2_CORRUPTED;
  }
  ApplyMaxPictureSize();
  error_ = C2_OK;
  signalled_eos_ = false;
  return C2_OK;
}

void VideoDecoder::ApplyMaxPictureSize() {
  uint32_t w, h;
  {
    auto lock = intf_->lock();
    w = intf_->max_size_l()->width;
    h = intf_->max_size_l()->height;
  }
  session_->SetMaxPictureSize(w, h);
}

// reset the session and skip the pending tags
c2_status_t VideoDecoder::onFlush_sm() {
  if (session_) {
    resetting_ = true;
    session_->Reset();
    resetting_ = false;
  }
  updates_.clear();
  signalled_eos_ = false;
  return C2_OK;
}

c2_status_t VideoDecoder::onStop() {
  (void)onFlush_sm();
  error_ = C2_OK;
  defaults_.Clear();
  return C2_OK;
}

void VideoDecoder::onReset() { (void)onStop(); }

void VideoDecoder::onRelease() {
  if (session_) {
    resetting_ = true;
    session_.reset();
    resetting_ = false;
  }
  slot_.reset();
}

// decode a work item's input through the session
void VideoDecoder::process(const std::unique_ptr<C2Work>& work, const std::shared_ptr<C2BlockPool>& pool) {
  work->result = C2_OK;
  work->workletsProcessed = 0u;
  work->worklets.front()->output.flags = static_cast<C2FrameData::flags_t>(0);
  work->worklets.front()->output.ordinal = work->input.ordinal;
  if (!session_ || error_ != C2_OK || signalled_eos_) {
    work->result = C2_BAD_VALUE;
    work->workletsProcessed = 1u;
    return;
  }
  RestateNeeds(false);
  const uint8_t* data = nullptr;
  size_t size = 0;
  C2ReadView view = mDummyReadView;
  if (!work->input.buffers.empty()) {
    view = work->input.buffers[0]->data().linearBlocks().front().map().get();
    size = view.capacity();
    if (size && view.error()) {
      klogf("%s: input map failed (%d)", intf_->caps().name.c_str(), view.error());
      work->result = view.error();
      work->workletsProcessed = 1u;
      return;
    }
    data = view.data();
  }
  bool eos = (work->input.flags & C2FrameData::FLAG_END_OF_STREAM) != 0;
  bool config = (work->input.flags & C2FrameData::FLAG_CODEC_CONFIG) != 0;
  uint64_t tag = work->input.ordinal.frameIndex.peeku();

  current_ = &work;
  pool_ = pool;
  current_eos_ = eos;
  current_done_ = false;
  Status st = Status::kOk;
  if (size > 0) {
    st = session_->Decode(data, size, tag, config);
    if (st == Status::kBadStream) {
      klogf("%s: input %llu does not parse; decoding goes on", intf_->caps().name.c_str(),
            static_cast<unsigned long long>(tag));
      st = Status::kOk;
    }
  } else if (!eos) {
    current_done_ = true;
    work->workletsProcessed = 1u;
  }
  if (st == Status::kOk && eos) st = session_->Drain();
  if (st != Status::kOk && error_ == C2_OK) error_ = C2Status(st);
  current_ = nullptr;
  pool_.reset();

  if (error_ != C2_OK) {
    klogf("%s: decoding failed (%d)", intf_->caps().name.c_str(), static_cast<int>(error_));
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
    return;
  }
  if (!current_done_ && !updates_.empty()) {
    std::vector<std::unique_ptr<C2Param>> ups = std::move(updates_);
    updates_.clear();
    cloneAndSend(tag, work, [&ups](const std::unique_ptr<C2Work>& clone) {
      clone->worklets.front()->output.flags = C2FrameData::FLAG_INCOMPLETE;
      clone->worklets.front()->output.buffers.clear();
      for (auto& u : ups) clone->worklets.front()->output.configUpdate.push_back(std::move(u));
      clone->worklets.front()->output.ordinal = clone->input.ordinal;
      clone->workletsProcessed = 1u;
      clone->result = C2_OK;
    });
  }
}

c2_status_t VideoDecoder::drain(uint32_t drainMode, const std::shared_ptr<C2BlockPool>& pool) {
  if (drainMode == NO_DRAIN) return C2_OK;
  if (drainMode == DRAIN_CHAIN) return C2_OMITTED;
  if (!session_) return C2_BAD_STATE;
  pool_ = pool;
  current_ = nullptr;
  Status st = session_->Drain();
  pool_.reset();
  return st == Status::kOk ? C2_OK : C2Status(st);
}

void VideoDecoder::OnStreamChanged(const c2va::StreamInfo& info) {
  uint32_t delay = std::min(info.reorder_depth, DecoderIntf::kMaxOutputDelay);
  C2PortActualDelayTuning::output want(delay);
  {
    auto lock = intf_->lock();
    if (intf_->output_delay_l()->value == delay) return;
  }
  std::vector<std::unique_ptr<C2SettingResult>> failures;
  if (intf_->config({&want}, C2_MAY_BLOCK, &failures) == C2_OK) {
    updates_.push_back(C2Param::Copy(want));
  } else {
    klogf("%s: output delay %u refused", intf_->caps().name.c_str(), delay);
  }
}

std::shared_ptr<C2GraphicBlock> VideoDecoder::FillOutput(const c2va::Frame& frame, uint32_t width, uint32_t height,
                                                         const C2StreamColorAspectsInfo::output& declared) {
  uint32_t pixel_format;
  uint64_t usage;
  {
    auto lock = intf_->lock();
    pixel_format = intf_->pixel_format_l()->value;
    usage = intf_->output_usage_l()->value;
  }
  c2va::ColorInfo surface_color = SurfaceColorOf(declared, width, height);
  // the guest's Mesa samples no YUV textures
  bool rgba = pixel_format == HAL_PIXEL_FORMAT_IMPLEMENTATION_DEFINED && !(usage & C2MemoryUsage::CPU_READ);
  std::shared_ptr<C2GraphicBlock> block;
  C2MemoryUsage want = rgba ? C2MemoryUsage(0, android::C2AndroidMemoryUsage::HW_TEXTURE_WRITE)
                            : C2MemoryUsage(C2MemoryUsage::CPU_READ, C2MemoryUsage::CPU_WRITE);
  uint32_t format = rgba ? HAL_PIXEL_FORMAT_RGBA_8888 : HAL_PIXEL_FORMAT_YCBCR_420_888;
  uint32_t alloc_w = rgba ? width : (width + 1) & ~1u, alloc_h = rgba ? height : (height + 1) & ~1u;
  c2_status_t err = pool_->fetchGraphicBlock(alloc_w, alloc_h, format, want, &block);
  if (err != C2_OK || !block) {
    klogf("%s: no %ux%u output block (%d)", intf_->caps().name.c_str(), alloc_w, alloc_h, err);
    error_ = err != C2_OK ? err : C2_NO_MEMORY;
    return nullptr;
  }
  Status st;
  if (rgba) {
    c2va::DmabufImage img;
    if (!DmabufOf(*block, &img)) {
      klogf("%s: the output block is not a dmabuf this runtime imports", intf_->caps().name.c_str());
      error_ = C2_CORRUPTED;
      return nullptr;
    }
    st = session_->ToRgba(frame, img, surface_color);
  } else {
    C2GraphicView view = block->map().get();
    if (view.error() != C2_OK) {
      klogf("%s: output map failed (%d)", intf_->caps().name.c_str(), view.error());
      error_ = view.error();
      return nullptr;
    }
    c2va::YuvDest dst;
    if (!YuvDestOf(view, &dst)) {
      klogf("%s: the output block is not YUV 4:2:0", intf_->caps().name.c_str());
      error_ = C2_CORRUPTED;
      return nullptr;
    }
    st = session_->ToYuv(frame, dst);
  }
  if (st != Status::kOk) {
    klogf("%s: picture copy-out failed (%d)", intf_->caps().name.c_str(), static_cast<int>(st));
    error_ = C2Status(st);
    return nullptr;
  }
  return block;
}

void VideoDecoder::OnFrame(const c2va::Frame& frame) {
  if (resetting_ || error_ != C2_OK || !pool_) {
    session_->ReleaseFrame(frame);
    return;
  }
  uint32_t width = frame.crop.width, height = frame.crop.height;
  {
    std::shared_ptr<C2StreamPictureSizeInfo::output> size;
    {
      auto lock = intf_->lock();
      size = intf_->size_l();
    }
    if (size->width != width || size->height != height) {
      C2StreamPictureSizeInfo::output want(0u, width, height);
      std::vector<std::unique_ptr<C2SettingResult>> failures;
      if (intf_->config({&want}, C2_MAY_BLOCK, &failures) == C2_OK) {
        updates_.push_back(C2Param::Copy(want));
      } else {
        klogf("%s: picture size %ux%u refused", intf_->caps().name.c_str(), width, height);
      }
      RestateNeeds(true);
    }
  }
  C2StreamColorAspectsInfo::input coded(0u);
  ColorAspectsOf(frame.color, &coded.range, &coded.primaries, &coded.transfer, &coded.matrix);
  if (!have_color_ || memcmp(&last_color_, &frame.color, sizeof(last_color_)) != 0) {
    std::vector<std::unique_ptr<C2SettingResult>> failures;
    (void)intf_->config({&coded}, C2_MAY_BLOCK, &failures);
    last_color_ = frame.color;
    have_color_ = true;
  }
  C2ColorAspectsStruct def;
  if (!defaults_.At(frame.tag, &def)) {
    auto lock = intf_->lock();
    def = *intf_->default_color_aspects_l();
  }
  C2ColorAspectsStruct merged = MergeColorAspects(def, coded, ContainerAspectsFirst(intf_->caps().codec));
  C2StreamColorAspectsInfo::output declared(0u, merged.range, merged.primaries, merged.transfer, merged.matrix);
  std::shared_ptr<C2GraphicBlock> block = FillOutput(frame, width, height, declared);
  session_->ReleaseFrame(frame);
  if (!block) return;
  std::shared_ptr<C2Buffer> buffer = createGraphicBuffer(block, C2Rect(width, height));
  buffer->setInfo(std::make_shared<C2StreamColorAspectsInfo::output>(declared));
  Complete(frame.tag, buffer);
}

// complete an input that shows no picture
void VideoDecoder::OnSkip(uint64_t tag) {
  if (resetting_) return;
  Complete(tag, nullptr);
}

void VideoDecoder::Complete(uint64_t tag, const std::shared_ptr<C2Buffer>& buffer) {
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
      if (buffer || !ups.empty()) {
        cloneAndSend(tag, *current_, [&fill](const std::unique_ptr<C2Work>& w) {
          fill(w, C2FrameData::FLAG_INCOMPLETE);
        });
      }
      return;
    }
    fill(*current_, static_cast<C2FrameData::flags_t>(0));
    current_done_ = true;
    return;
  }
  finish(tag, [&fill](const std::unique_ptr<C2Work>& w) { fill(w, static_cast<C2FrameData::flags_t>(0)); });
}

ComponentEntry DecoderEntry(const c2va::ComponentCaps& caps) {
  ComponentEntry e;
  e.traits = VideoTraits(caps.name, caps.mime, C2Component::KIND_DECODER);
  e.max_instances = caps.max_instances;
  e.resource_id = ResourceIdOf(caps);
  e.make_interface = [caps](c2_node_id_t id, const std::shared_ptr<C2ReflectorHelper>& reflector) {
    return std::make_shared<android::SimpleInterface<DecoderIntf>>(caps.name.c_str(), id,
                                                                     std::make_shared<DecoderIntf>(reflector, caps));
  };
  e.make_component = [caps](c2_node_id_t id, const std::shared_ptr<C2ReflectorHelper>& reflector,
                            std::unique_ptr<InstanceSlot> slot) -> std::shared_ptr<C2Component> {
    return std::make_shared<VideoDecoder>(caps.name.c_str(), id, std::make_shared<DecoderIntf>(reflector, caps),
                                          std::move(slot));
  };
  return e;
}

}

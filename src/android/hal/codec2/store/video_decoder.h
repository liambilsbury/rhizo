#ifndef RHIZO_C2STORE_VIDEO_DECODER_H
#define RHIZO_C2STORE_VIDEO_DECODER_H

// the c2.rhizo.<codec>.decoder components

#include <stdint.h>

#include <memory>
#include <vector>

#include <SimpleC2Component.h>
#include <SimpleC2Interface.h>
#include <util/C2InterfaceHelper.h>

#include "codec_map.h"
#include "registry.h"
#include "va/runtime.h"

namespace rhizo::c2store {

class DecoderIntf : public android::SimpleInterface<void>::BaseParams {
 public:
  DecoderIntf(const std::shared_ptr<C2ReflectorHelper>& helper, const c2va::ComponentCaps& caps);

  const c2va::ComponentCaps& caps() const { return caps_; }

  // return a codec's output delay before the stream sets one
  static uint32_t DefaultOutputDelay(c2va::Codec codec);
  static constexpr uint32_t kMaxOutputDelay = 32;

  std::shared_ptr<C2StreamPixelFormatInfo::output> pixel_format_l() const { return pixel_format_; }
  std::shared_ptr<C2StreamUsageTuning::output> output_usage_l() const { return output_usage_; }
  std::shared_ptr<C2StreamColorAspectsInfo::output> color_aspects_l() const { return color_aspects_; }
  std::shared_ptr<C2StreamPictureSizeInfo::output> size_l() const { return size_; }
  std::shared_ptr<C2StreamMaxPictureSizeTuning::output> max_size_l() const { return max_size_; }
  std::shared_ptr<C2PortActualDelayTuning::output> output_delay_l() const { return output_delay_; }
  std::shared_ptr<C2StreamColorAspectsInfo::input> coded_color_aspects_l() const { return coded_color_aspects_; }
  std::shared_ptr<C2StreamColorAspectsTuning::output> default_color_aspects_l() const {
    return default_color_aspects_;
  }
  std::shared_ptr<C2ResourcesNeededTuning> resources_needed_l() const { return resources_needed_; }

 private:
  static C2R SizeSetter(bool mayBlock, const C2P<C2StreamPictureSizeInfo::output>& oldMe,
                        C2P<C2StreamPictureSizeInfo::output>& me);
  static C2R MaxPictureSizeSetter(bool mayBlock, C2P<C2StreamMaxPictureSizeTuning::output>& me,
                                  const C2P<C2StreamPictureSizeInfo::output>& size);
  static C2R MaxInputSizeSetter(bool mayBlock, C2P<C2StreamMaxBufferSizeInfo::input>& me,
                                const C2P<C2StreamMaxPictureSizeTuning::output>& maxSize);
  static C2R ProfileLevelSetter(bool mayBlock, C2P<C2StreamProfileLevelInfo::input>& me);
  static C2R DefaultColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsTuning::output>& me);
  static C2R CodedColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsInfo::input>& me);
  static C2R ColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsInfo::output>& me,
                                const C2P<C2StreamColorAspectsTuning::output>& def,
                                const C2P<C2StreamColorAspectsInfo::input>& coded);
  static C2R ContainerFirstColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsInfo::output>& me,
                                              const C2P<C2StreamColorAspectsTuning::output>& def,
                                              const C2P<C2StreamColorAspectsInfo::input>& coded);
  static C2R UsageSetter(bool mayBlock, C2P<C2StreamUsageTuning::output>& me);
  static C2R NeedsSetter(bool mayBlock, C2P<C2ResourcesNeededTuning>& me,
                         const C2P<C2StreamPictureSizeInfo::output>& size,
                         const C2P<C2StreamFrameRateInfo::input>& rate, const C2P<C2OperatingRateTuning>& op);

  c2va::ComponentCaps caps_;
  std::shared_ptr<C2ComponentAttributesSetting> attrib_;
  std::shared_ptr<C2PortActualDelayTuning::output> output_delay_;
  std::shared_ptr<C2StreamPictureSizeInfo::output> size_;
  std::shared_ptr<C2StreamMaxPictureSizeTuning::output> max_size_;
  std::shared_ptr<C2StreamMaxBufferSizeInfo::input> max_input_size_;
  std::shared_ptr<C2StreamProfileLevelInfo::input> profile_level_;
  std::shared_ptr<C2StreamColorInfo::output> color_info_;
  std::shared_ptr<C2StreamColorAspectsTuning::output> default_color_aspects_;
  std::shared_ptr<C2StreamColorAspectsInfo::input> coded_color_aspects_;
  std::shared_ptr<C2StreamColorAspectsInfo::output> color_aspects_;
  std::shared_ptr<C2StreamPixelFormatInfo::output> pixel_format_;
  std::shared_ptr<C2StreamUsageTuning::output> output_usage_;
  std::shared_ptr<C2StreamFrameRateInfo::input> frame_rate_;
  std::shared_ptr<C2OperatingRateTuning> operating_rate_;
  std::shared_ptr<C2ResourcesNeededTuning> resources_needed_;
};

class VideoDecoder : public android::SimpleC2Component {
 public:
  VideoDecoder(const char* name, c2_node_id_t id, const std::shared_ptr<DecoderIntf>& intf,
               std::unique_ptr<InstanceSlot> slot);
  ~VideoDecoder() override;

  c2_status_t queue_nb(std::list<std::unique_ptr<C2Work>>* items) override;

  // reserve throughput or return C2_NO_MEMORY
  c2_status_t start() override;
  c2_status_t stop() override;
  c2_status_t reset() override;

 protected:
  c2_status_t onInit() override;
  c2_status_t onStop() override;
  void onReset() override;
  void onRelease() override;
  c2_status_t onFlush_sm() override;
  void process(const std::unique_ptr<C2Work>& work, const std::shared_ptr<C2BlockPool>& pool) override;
  c2_status_t drain(uint32_t drainMode, const std::shared_ptr<C2BlockPool>& pool) override;

 private:
  // size the session's surfaces by the app's KEY_MAX_WIDTH/HEIGHT
  void ApplyMaxPictureSize();

  // send changed or forced resource needs to the client
  void RestateNeeds(bool force);

  // handle a decoded frame on the component's thread
  void OnFrame(const c2va::Frame& frame);
  void OnSkip(uint64_t tag);
  void OnStreamChanged(const c2va::StreamInfo& info);

  // fill an output block with a decoded frame
  std::shared_ptr<C2GraphicBlock> FillOutput(const c2va::Frame& frame, uint32_t width, uint32_t height,
                                             const C2StreamColorAspectsInfo::output& declared);
  // finish a work item with its buffer and pending updates
  void Complete(uint64_t tag, const std::shared_ptr<C2Buffer>& buffer);
  static c2_status_t C2Status(c2va::Status status);

  std::shared_ptr<DecoderIntf> intf_;
  std::unique_ptr<InstanceSlot> slot_;
  std::unique_ptr<c2va::DecodeSession> session_;

  const std::unique_ptr<C2Work>* current_ = nullptr;
  std::shared_ptr<C2BlockPool> pool_;
  bool current_eos_ = false;
  bool current_done_ = false;
  bool resetting_ = false;

  std::vector<std::unique_ptr<C2Param>> updates_;
  c2_status_t error_ = C2_OK;
  bool signalled_eos_ = false;
  c2va::ColorInfo last_color_{};
  bool have_color_ = false;
  DefaultAspectsLog defaults_;
};

ComponentEntry DecoderEntry(const c2va::ComponentCaps& caps);

}

#endif

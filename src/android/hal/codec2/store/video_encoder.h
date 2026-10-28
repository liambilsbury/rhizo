#ifndef RHIZO_C2STORE_VIDEO_ENCODER_H
#define RHIZO_C2STORE_VIDEO_ENCODER_H

// the c2.rhizo.<codec>.encoder components

#include <stdint.h>

#include <memory>
#include <vector>

#include <SimpleC2Component.h>
#include <SimpleC2Interface.h>
#include <util/C2InterfaceHelper.h>

#include "registry.h"
#include "va/runtime.h"

namespace rhizo::c2store {

class EncoderIntf : public android::SimpleInterface<void>::BaseParams {
 public:
  EncoderIntf(const std::shared_ptr<C2ReflectorHelper>& helper, const c2va::ComponentCaps& caps);

  const c2va::ComponentCaps& caps() const { return caps_; }

  static constexpr uint32_t kConstantQp = 26;

  std::shared_ptr<C2StreamPictureSizeInfo::input> size_l() const { return size_; }
  std::shared_ptr<C2StreamFrameRateInfo::output> frame_rate_l() const { return frame_rate_; }
  std::shared_ptr<C2StreamBitrateModeTuning::output> bitrate_mode_l() const { return bitrate_mode_; }
  std::shared_ptr<C2StreamBitrateInfo::output> bitrate_l() const { return bitrate_; }
  std::shared_ptr<C2StreamProfileLevelInfo::output> profile_level_l() const { return profile_level_; }
  std::shared_ptr<C2StreamRequestSyncFrameTuning::output> request_sync_l() const { return request_sync_; }
  std::shared_ptr<C2StreamSyncFrameIntervalTuning::output> sync_interval_l() const { return sync_interval_; }
  std::shared_ptr<C2StreamColorAspectsInfo::input> color_aspects_l() const { return color_aspects_; }
  std::shared_ptr<C2ResourcesNeededTuning> resources_needed_l() const { return resources_needed_; }

 private:
  static C2R SizeSetter(bool mayBlock, const C2P<C2StreamPictureSizeInfo::input>& oldMe,
                        C2P<C2StreamPictureSizeInfo::input>& me);
  static C2R BitrateSetter(bool mayBlock, C2P<C2StreamBitrateInfo::output>& me);
  // set the level from size, frame rate and bit rate
  static C2R AvcProfileLevelSetter(bool mayBlock, C2P<C2StreamProfileLevelInfo::output>& me,
                                   const C2P<C2StreamPictureSizeInfo::input>& size,
                                   const C2P<C2StreamFrameRateInfo::output>& frame_rate,
                                   const C2P<C2StreamBitrateModeTuning::output>& mode,
                                   const C2P<C2StreamBitrateInfo::output>& bitrate);
  static C2R HevcProfileLevelSetter(bool mayBlock, C2P<C2StreamProfileLevelInfo::output>& me,
                                    const C2P<C2StreamPictureSizeInfo::input>& size,
                                    const C2P<C2StreamFrameRateInfo::output>& frame_rate,
                                    const C2P<C2StreamBitrateModeTuning::output>& mode,
                                    const C2P<C2StreamBitrateInfo::output>& bitrate);
  static C2R ProfileLevelSetterFor(bool hevc, C2P<C2StreamProfileLevelInfo::output>& me,
                                   const C2P<C2StreamPictureSizeInfo::input>& size,
                                   const C2P<C2StreamFrameRateInfo::output>& frame_rate,
                                   const C2P<C2StreamBitrateModeTuning::output>& mode,
                                   const C2P<C2StreamBitrateInfo::output>& bitrate);
  static C2R ColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsInfo::input>& me);
  static C2R CodedColorAspectsSetter(bool mayBlock, C2P<C2StreamColorAspectsInfo::output>& me,
                                     const C2P<C2StreamColorAspectsInfo::input>& in);
  static C2R NeedsSetter(bool mayBlock, C2P<C2ResourcesNeededTuning>& me,
                         const C2P<C2StreamPictureSizeInfo::input>& size,
                         const C2P<C2StreamFrameRateInfo::output>& rate, const C2P<C2OperatingRateTuning>& op);

  c2va::ComponentCaps caps_;
  std::shared_ptr<C2StreamUsageTuning::input> usage_;
  std::shared_ptr<C2ComponentAttributesSetting> attrib_;
  std::shared_ptr<C2StreamPictureSizeInfo::input> size_;
  std::shared_ptr<C2StreamFrameRateInfo::output> frame_rate_;
  std::shared_ptr<C2OperatingRateTuning> operating_rate_;
  std::shared_ptr<C2StreamBitrateModeTuning::output> bitrate_mode_;
  std::shared_ptr<C2StreamBitrateInfo::output> bitrate_;
  std::shared_ptr<C2StreamProfileLevelInfo::output> profile_level_;
  std::shared_ptr<C2StreamRequestSyncFrameTuning::output> request_sync_;
  std::shared_ptr<C2StreamSyncFrameIntervalTuning::output> sync_interval_;
  std::shared_ptr<C2StreamColorAspectsInfo::input> color_aspects_;
  std::shared_ptr<C2StreamColorAspectsInfo::output> coded_color_aspects_;
  std::shared_ptr<C2ResourcesNeededTuning> resources_needed_;
};

class VideoEncoder : public android::SimpleC2Component {
 public:
  VideoEncoder(const char* name, c2_node_id_t id, const std::shared_ptr<EncoderIntf>& intf,
               std::unique_ptr<InstanceSlot> slot);
  ~VideoEncoder() override;

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
  c2_status_t Open();
  // publish the level that the csd's parameter sets signal
  void PublishSignalledLevel(const uint8_t* csd, size_t size);
  // handle coded output on the component's thread
  void OnOutput(const uint8_t* data, size_t size, uint64_t tag, int64_t pts, bool keyframe, bool codec_config);
  c2va::Status EncodeInput(const C2ConstGraphicBlock& block, uint64_t tag, int64_t pts, bool keyframe);
  // finish a work item with its buffer and pending updates
  void Complete(uint64_t tag, const std::shared_ptr<C2Buffer>& buffer);
  static c2_status_t C2Status(c2va::Status status);
  // send changed or forced resource needs to the client
  void RestateNeeds(bool force);

  std::shared_ptr<EncoderIntf> intf_;
  std::unique_ptr<InstanceSlot> slot_;
  std::unique_ptr<c2va::EncodeSession> session_;
  uint32_t bitrate_ = 0;

  const std::unique_ptr<C2Work>* current_ = nullptr;
  std::shared_ptr<C2BlockPool> pool_;
  bool current_eos_ = false;
  bool current_done_ = false;

  std::vector<std::unique_ptr<C2Param>> updates_;
  c2_status_t error_ = C2_OK;
  bool signalled_eos_ = false;
};

ComponentEntry EncoderEntry(const c2va::ComponentCaps& caps);

}

#endif

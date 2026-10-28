#ifndef RHIZO_CAMERA_CAMERA_DEVICE_H
#define RHIZO_CAMERA_CAMERA_DEVICE_H

// serve ICameraDevice and ICameraDeviceSession for a host camera

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <aidl/android/hardware/camera/device/BnCameraDevice.h>
#include <aidl/android/hardware/camera/device/BnCameraDeviceSession.h>
#include <aidl/android/hardware/camera/device/ICameraDeviceCallback.h>
#include <fmq/AidlMessageQueue.h>

#include "camerad_client.h"
#include "frame_output.h"
#include "gralloc.h"
#include "session_policy.h"
#include "static_metadata.h"

namespace rhizo::camera {

namespace device = ::aidl::android::hardware::camera::device;

// fixed state of a present host camera
struct CameraContext {
  std::string id;
  std::string deviceName;
  HostCamera host;
  CameraShape shape;
  std::vector<uint8_t> characteristics;
  std::atomic<bool> present{true};
};

std::string CheckStreams(const CameraShape& shape, const device::StreamConfiguration& config);

class CameraSession : public device::BnCameraDeviceSession {
 public:
  CameraSession(std::shared_ptr<CameraContext> ctx, CameradClient* client,
                std::shared_ptr<device::ICameraDeviceCallback> callback);
  ~CameraSession() override;
  bool isClosed();

  ndk::ScopedAStatus close() override;
  ndk::ScopedAStatus configureStreams(const device::StreamConfiguration& config,
                                      std::vector<device::HalStream>* out) override;
  ndk::ScopedAStatus configureStreamsV2(const device::StreamConfiguration& config,
                                        device::ConfigureStreamsRet* out) override;
  ndk::ScopedAStatus constructDefaultRequestSettings(device::RequestTemplate type,
                                                     device::CameraMetadata* out) override;
  ndk::ScopedAStatus flush() override;
  ndk::ScopedAStatus getCaptureRequestMetadataQueue(
      ::aidl::android::hardware::common::fmq::MQDescriptor<
          int8_t, ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>* out) override;
  ndk::ScopedAStatus getCaptureResultMetadataQueue(
      ::aidl::android::hardware::common::fmq::MQDescriptor<
          int8_t, ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>* out) override;
  ndk::ScopedAStatus isReconfigurationRequired(const device::CameraMetadata& oldParams,
                                               const device::CameraMetadata& newParams, bool* out) override;
  ndk::ScopedAStatus processCaptureRequest(const std::vector<device::CaptureRequest>& requests,
                                           const std::vector<device::BufferCache>& cachesToRemove,
                                           int32_t* out) override;
  ndk::ScopedAStatus signalStreamFlush(const std::vector<int32_t>& streamIds, int32_t counter) override;
  ndk::ScopedAStatus switchToOffline(const std::vector<int32_t>& streamsToKeep,
                                     device::CameraOfflineSessionInfo* info,
                                     std::shared_ptr<device::ICameraOfflineSession>* out) override;
  ndk::ScopedAStatus repeatingRequestEnd(int32_t frameNumber, const std::vector<int32_t>& streamIds) override;

 private:
  // an output buffer of a queued request
  struct OutBuffer {
    int32_t streamId = 0;
    int64_t bufferId = 0;
    buffer_handle_t handle = nullptr;
    int acquireFence = -1;
    int32_t width = 0;
    int32_t height = 0;
    bool blob = false;
  };
  // a capture request waiting for a frame
  struct Request {
    int32_t frameNumber = 0;
    std::shared_ptr<camera_metadata_t> settings;
    std::vector<OutBuffer> buffers;
    int32_t depth = 1;
  };

  ndk::ScopedAStatus configure(const device::StreamConfiguration& config, std::vector<device::HalStream>* out);
  ndk::ScopedAStatus enqueue(const device::CaptureRequest& request, Request* out);
  bool readRequestQueue(int64_t n, std::vector<uint8_t>* out);
  void workerLoop();
  void process(Request& r);
  void complete(Request& r, const std::vector<bool>& fenceOk);
  void fail(Request& r, const char* why);
  void deliver(const std::vector<device::NotifyMsg>& msgs, device::CaptureResult result);
  bool fillBuffer(const OutBuffer& b, const camera_metadata_t* settings, int* releaseFence);
  void openStreamLocked(const HostMode& mode, int32_t maxFps);
  void closeStreamLocked();
  void wakeWorkerLocked();
  int64_t timestampFor(const Frame& f);

  const std::shared_ptr<CameraContext> ctx_;
  CameradClient* const client_;
  const std::shared_ptr<device::ICameraDeviceCallback> callback_;
  Gralloc* const gralloc_;
  std::string make_;
  std::string model_;
  const int wakeFd_;
  using MetadataQueue = ::android::AidlMessageQueue<int8_t, ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>;
  std::unique_ptr<MetadataQueue> requestQueue_;
  std::unique_ptr<MetadataQueue> resultQueue_;

  std::mutex mu_;
  std::mutex callbackMu_;
  std::condition_variable queueCv_;
  std::condition_variable idleCv_;
  std::deque<Request> queue_;
  bool busy_ = false;
  bool stopping_ = false;
  bool closed_ = false;
  std::atomic<bool> flushing_{false};
  std::map<int32_t, device::Stream> streams_;
  std::map<std::pair<int32_t, int64_t>, buffer_handle_t> buffers_;
  std::shared_ptr<camera_metadata_t> lastSettings_;
  std::shared_ptr<FrameMailbox> mailbox_;
  HostMode mode_{};
  OpenRate openRate_{};
  bool modeRateOnly_ = false;
  bool haveMode_ = false;
  int32_t largestWidth_ = 0;
  int32_t largestHeight_ = 0;
  std::chrono::steady_clock::time_point lastOpen_{};
  std::thread worker_;

  Frame frame_;
  std::shared_ptr<FrameMailbox> seqOwner_;
  uint64_t lastSeq_ = 0;
  int64_t lastTimestamp_ = 0;
  Scratch scratch_;
  FramePacer pacer_;
  int consecutiveTimeouts_ = 0;
  std::atomic<uint64_t> failures_{0};
  uint64_t completed_ = 0;
};

class CameraDevice : public device::BnCameraDevice {
 public:
  CameraDevice(std::shared_ptr<CameraContext> ctx, CameradClient* client);

  ndk::ScopedAStatus getCameraCharacteristics(device::CameraMetadata* out) override;
  ndk::ScopedAStatus getPhysicalCameraCharacteristics(const std::string& id, device::CameraMetadata* out) override;
  ndk::ScopedAStatus getResourceCost(::aidl::android::hardware::camera::common::CameraResourceCost* out) override;
  ndk::ScopedAStatus isStreamCombinationSupported(const device::StreamConfiguration& streams, bool* out) override;
  ndk::ScopedAStatus open(const std::shared_ptr<device::ICameraDeviceCallback>& callback,
                          std::shared_ptr<device::ICameraDeviceSession>* out) override;
  ndk::ScopedAStatus openInjectionSession(const std::shared_ptr<device::ICameraDeviceCallback>& callback,
                                          std::shared_ptr<device::ICameraInjectionSession>* out) override;
  ndk::ScopedAStatus setTorchMode(bool on) override;
  ndk::ScopedAStatus turnOnTorchWithStrengthLevel(int32_t level) override;
  ndk::ScopedAStatus getTorchStrengthLevel(int32_t* out) override;
  ndk::ScopedAStatus constructDefaultRequestSettings(device::RequestTemplate type,
                                                     device::CameraMetadata* out) override;
  ndk::ScopedAStatus isStreamCombinationWithSettingsSupported(const device::StreamConfiguration& streams,
                                                              bool* out) override;
  ndk::ScopedAStatus getSessionCharacteristics(const device::StreamConfiguration& config,
                                               device::CameraMetadata* out) override;

 private:
  const std::shared_ptr<CameraContext> ctx_;
  CameradClient* const client_;
  std::mutex mu_;
  std::weak_ptr<CameraSession> session_;
};

}

#endif

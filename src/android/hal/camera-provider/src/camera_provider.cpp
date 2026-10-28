// serve ICameraProvider/internal/0 with a camera id per host camera

#include <stdlib.h>
#include <unistd.h>

#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <android/binder_manager.h>
#include <android/binder_process.h>

#include <aidl/android/hardware/camera/common/Status.h>
#include <aidl/android/hardware/camera/provider/BnCameraProvider.h>
#include <aidl/android/hardware/camera/provider/ICameraProviderCallback.h>

#include "camera_device.h"
#include "camera_registry.h"
#include "camerad_client.h"
#include "log.h"
#include "static_metadata.h"

namespace rhizo::camera {

namespace {

using ::aidl::android::hardware::camera::common::CameraDeviceStatus;
using ::aidl::android::hardware::camera::common::Status;
using ::aidl::android::hardware::camera::common::VendorTagSection;
using ::aidl::android::hardware::camera::provider::BnCameraProvider;
using ::aidl::android::hardware::camera::provider::CameraIdAndStreamCombination;
using ::aidl::android::hardware::camera::provider::ConcurrentCameraIdCombination;
using ::aidl::android::hardware::camera::provider::ICameraProviderCallback;
using ndk::ScopedAStatus;

constexpr int kFirstListWaitMs = 1500;
constexpr int kBinderThreads = 6;

ScopedAStatus Error(Status s) { return ScopedAStatus::fromServiceSpecificError(static_cast<int32_t>(s)); }

const char* FacingName(uint32_t facing) {
  switch (facing) {
    case RHIZO_CAMERA_FACING_FRONT: return "front";
    case RHIZO_CAMERA_FACING_BACK: return "back";
    default: return "external";
  }
}

class CameraProvider : public BnCameraProvider {
 public:
  CameraProvider()
      : client_(std::make_unique<CameradClient>(CameradClient::DefaultSocketPath(),
                                                [this](const std::vector<HostCamera>& c) { onList(c); })) {}

  // connect to camerad and await the first camera list
  void start() {
    notifier_ = std::thread([this] { notifierLoop(); });
    client_->start();
    if (client_->waitForFirstList(kFirstListWaitMs)) {
      klogf("first camera list received");
    } else {
      klogf("no camera list within %d ms; cameras are reported as they appear", kFirstListWaitMs);
    }
  }

  // set the callback and replay the present cameras to it
  ScopedAStatus setCallback(const std::shared_ptr<ICameraProviderCallback>& callback) override {
    if (callback == nullptr) return Error(Status::ILLEGAL_ARGUMENT);
    std::lock_guard<std::mutex> lk(mu_);
    callback_ = callback;
    dedupe_.reset();
    for (const std::string& name : registry_.presentNames()) events_.push_back({name, CameraDeviceStatus::PRESENT});
    eventsCv_.notify_all();
    return ScopedAStatus::ok();
  }

  ScopedAStatus getVendorTags(std::vector<VendorTagSection>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }

  // return the empty internal camera id list
  ScopedAStatus getCameraIdList(std::vector<std::string>* out) override {
    *out = CameraRegistry::InternalCameraIdList();
    return ScopedAStatus::ok();
  }

  ScopedAStatus getCameraDeviceInterface(const std::string& name,
                                         std::shared_ptr<device::ICameraDevice>* out) override {
    *out = nullptr;
    std::string id = CameraRegistry::IdOf(name);
    std::lock_guard<std::mutex> lk(mu_);
    auto it = contexts_.find(id);
    if (id.empty() || it == contexts_.end()) return Error(Status::ILLEGAL_ARGUMENT);
    auto& dev = devices_[id];
    if (dev == nullptr) dev = ndk::SharedRefBase::make<CameraDevice>(it->second, client_.get());
    *out = dev;
    return ScopedAStatus::ok();
  }

  ScopedAStatus notifyDeviceStateChange(int64_t) override { return ScopedAStatus::ok(); }

  ScopedAStatus getConcurrentCameraIds(std::vector<ConcurrentCameraIdCombination>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }

  ScopedAStatus isConcurrentStreamCombinationSupported(const std::vector<CameraIdAndStreamCombination>&,
                                                       bool* out) override {
    *out = false;
    return ScopedAStatus::ok();
  }

 private:
  // report the cameras a new camerad list adds and removes
  void onList(const std::vector<HostCamera>& cameras) {
    std::lock_guard<std::mutex> lk(mu_);
    for (const RegistryChange& c : registry_.apply(cameras)) {
      if (!c.added) {
        klogf("camera %s not present: %s", c.id.c_str(), c.why);
        auto it = contexts_.find(c.id);
        if (it != contexts_.end()) {
          it->second->present = false;
          contexts_.erase(it);
        }
        devices_.erase(c.id);
        events_.push_back({c.deviceName, CameraDeviceStatus::NOT_PRESENT});
        continue;
      }
      auto ctx = std::make_shared<CameraContext>();
      ctx->id = c.id;
      ctx->deviceName = c.deviceName;
      ctx->host = c.host;
      ctx->shape = ShapeFor(c.host.modes);
      ctx->characteristics = BuildCharacteristics(ctx->shape);
      if (!ValidMetadataBlob(ctx->characteristics)) {
        klogf("camera %s ('%s'): characteristics did not validate; not reported", c.id.c_str(), c.host.name.c_str());
        registry_.reject(c.id);
        continue;
      }
      klogf("camera %s present: '%s' key=%s host facing %s (reported EXTERNAL), %zu modes, largest %dx%d, %zu sizes",
            c.id.c_str(), c.host.name.c_str(), c.host.key.c_str(), FacingName(c.host.facing), c.host.modes.size(),
            ctx->shape.arrayWidth, ctx->shape.arrayHeight, ctx->shape.sizes.size());
      contexts_[c.id] = ctx;
      events_.push_back({c.deviceName, CameraDeviceStatus::PRESENT});
    }
    eventsCv_.notify_all();
  }

  // send queued status changes to the callback
  void notifierLoop() {
    for (;;) {
      std::pair<std::string, CameraDeviceStatus> ev;
      std::shared_ptr<ICameraProviderCallback> cb;
      {
        std::unique_lock<std::mutex> lk(mu_);
        eventsCv_.wait(lk, [this] { return !events_.empty(); });
        ev = events_.front();
        events_.pop_front();
        cb = callback_;
        if (cb == nullptr) continue;
        if (!dedupe_.shouldSend(ev.first, ev.second == CameraDeviceStatus::PRESENT)) continue;
      }
      ScopedAStatus s = cb->cameraDeviceStatusChange(ev.first, ev.second);
      klogf("%s %s -> cameraserver%s", ev.first.c_str(),
            ev.second == CameraDeviceStatus::PRESENT ? "PRESENT" : "NOT_PRESENT", s.isOk() ? "" : " (failed)");
    }
  }

  std::unique_ptr<CameradClient> client_;
  std::thread notifier_;
  std::mutex mu_;
  std::condition_variable eventsCv_;
  std::deque<std::pair<std::string, CameraDeviceStatus>> events_;
  StatusDedupe dedupe_;
  std::shared_ptr<ICameraProviderCallback> callback_;
  CameraRegistry registry_;
  std::map<std::string, std::shared_ptr<CameraContext>> contexts_;
  std::map<std::string, std::shared_ptr<CameraDevice>> devices_;
};

}

}

// register the provider and join the binder thread pool
int main() {
  using rhizo::camera::klogf;
  klogf("main() entered, pid=%d, camerad socket %s", getpid(),
        rhizo::camera::CameradClient::DefaultSocketPath().c_str());
  ABinderProcess_setThreadPoolMaxThreadCount(rhizo::camera::kBinderThreads);
  auto provider = ndk::SharedRefBase::make<rhizo::camera::CameraProvider>();
  provider->start();
  const std::string instance = std::string(rhizo::camera::CameraProvider::descriptor) + "/internal/0";
  binder_status_t status = AServiceManager_addService(provider->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    klogf("addService %s FAILED status=%d", instance.c_str(), status);
    return 1;
  }
  klogf("registered %s, joining thread pool", instance.c_str());
  ABinderProcess_startThreadPool();
  ABinderProcess_joinThreadPool();
  klogf("joinThreadPool RETURNED (unexpected)");
  return 1;
}

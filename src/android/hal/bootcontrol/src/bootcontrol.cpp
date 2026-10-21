#include "aidl/android/hardware/boot/BnBootControl.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <fcntl.h>
#include <unistd.h>
#include <array>
#include <cstdio>
#include <mutex>

using namespace aidl::android::hardware::boot;
using ndk::ScopedAStatus;

namespace {

// write a message to the kernel log
void klog(const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    dprintf(fd, "<5>rhizo-bootcontrol: %s\n", msg);
    close(fd);
  }
}

// return a service-specific error status
ScopedAStatus bcError(int32_t code) { return ScopedAStatus::fromServiceSpecificError(code); }

constexpr int32_t kNumSlots = 2;

// check that a slot number is in range
bool validSlot(int32_t slot) { return slot >= 0 && slot < kNumSlots; }

class RhizoBootControl : public BnBootControl {
 public:
  // return the active slot
  ScopedAStatus getActiveBootSlot(int32_t* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    *out = activeSlot_;
    return ScopedAStatus::ok();
  }
  // return the current slot
  ScopedAStatus getCurrentSlot(int32_t* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    *out = activeSlot_;
    return ScopedAStatus::ok();
  }
  // return the number of slots
  ScopedAStatus getNumberSlots(int32_t* out) override {
    *out = kNumSlots;
    return ScopedAStatus::ok();
  }
  // return the snapshot merge status
  ScopedAStatus getSnapshotMergeStatus(MergeStatus* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    *out = mergeStatus_;
    return ScopedAStatus::ok();
  }
  // return the suffix for a slot
  ScopedAStatus getSuffix(int32_t slot, std::string* out) override {
    if (slot == 0) {
      *out = "_a";
    } else if (slot == 1) {
      *out = "_b";
    } else {
      *out = "";
    }
    return ScopedAStatus::ok();
  }
  // return whether a slot is bootable
  ScopedAStatus isSlotBootable(int32_t slot, bool* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!validSlot(slot)) return bcError(IBootControl::INVALID_SLOT);
    *out = isBootable_[slot];
    return ScopedAStatus::ok();
  }
  // return whether a slot is marked successful
  ScopedAStatus isSlotMarkedSuccessful(int32_t slot, bool* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!validSlot(slot)) return bcError(IBootControl::INVALID_SLOT);
    *out = isSuccessful_[slot];
    return ScopedAStatus::ok();
  }
  // mark the active slot successful
  ScopedAStatus markBootSuccessful() override {
    std::lock_guard<std::mutex> lg(mutex_);
    isSuccessful_[activeSlot_] = true;
    return ScopedAStatus::ok();
  }
  // make a slot the active slot
  ScopedAStatus setActiveBootSlot(int32_t slot) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!validSlot(slot)) return bcError(IBootControl::INVALID_SLOT);
    activeSlot_ = slot;
    return ScopedAStatus::ok();
  }
  // mark a slot unbootable and unsuccessful
  ScopedAStatus setSlotAsUnbootable(int32_t slot) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!validSlot(slot)) return bcError(IBootControl::INVALID_SLOT);
    isBootable_[slot] = false;
    isSuccessful_[slot] = false;
    return ScopedAStatus::ok();
  }
  // store the snapshot merge status
  ScopedAStatus setSnapshotMergeStatus(MergeStatus status) override {
    std::lock_guard<std::mutex> lg(mutex_);
    mergeStatus_ = status;
    return ScopedAStatus::ok();
  }

 private:
  std::mutex mutex_;
  MergeStatus mergeStatus_ = MergeStatus::NONE;
  int32_t activeSlot_ = 0;
  std::array<bool, kNumSlots> isBootable_ = {true, true};
  std::array<bool, kNumSlots> isSuccessful_ = {true, true};
};

}

// register the boot control service and join the binder thread pool
int main() {
  klog("main() entered");
  auto device = ndk::SharedRefBase::make<RhizoBootControl>();
  const std::string instance = std::string(RhizoBootControl::descriptor) + "/default";
  binder_status_t status = AServiceManager_addService(device->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    char buf[128];
    snprintf(buf, sizeof(buf), "addService FAILED status=%d", status);
    klog(buf);
    return 1;
  }
  klog("registered, joining thread pool");
  ABinderProcess_setThreadPoolMaxThreadCount(0);
  ABinderProcess_joinThreadPool();
  klog("joinThreadPool RETURNED (unexpected)");
  return 0;
}

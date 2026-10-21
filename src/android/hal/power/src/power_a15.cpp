#include "aidl/android/hardware/power/BnPower.h"
#include "aidl/android/hardware/power/BnPowerHintSession.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>

using namespace aidl::android::hardware::power;
using ndk::ScopedAStatus;

namespace {

// write a message to the kernel log
void klog(const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    dprintf(fd, "<5>rhizo-power-a15: %s\n", msg);
    close(fd);
  }
}

// IPowerHintSession for Android 15
class RhizoPowerHintSession : public BnPowerHintSession {
 public:
  // ignore the target work duration
  ScopedAStatus updateTargetWorkDuration(int64_t) override { return ScopedAStatus::ok(); }
  // ignore the actual work durations
  ScopedAStatus reportActualWorkDuration(const std::vector<WorkDuration>&) override {
    return ScopedAStatus::ok();
  }
  // ignore a pause
  ScopedAStatus pause() override { return ScopedAStatus::ok(); }
  // ignore a resume
  ScopedAStatus resume() override { return ScopedAStatus::ok(); }
  // ignore a close
  ScopedAStatus close() override { return ScopedAStatus::ok(); }
  // ignore a session hint
  ScopedAStatus sendHint(SessionHint) override { return ScopedAStatus::ok(); }
  // reject an empty thread id list
  ScopedAStatus setThreads(const std::vector<int32_t>& tids) override {
    if (tids.empty()) {
      return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    return ScopedAStatus::ok();
  }
  // ignore the session mode
  ScopedAStatus setMode(SessionMode, bool) override { return ScopedAStatus::ok(); }
  // return an empty session config
  ScopedAStatus getSessionConfig(SessionConfig* out) override {
    *out = SessionConfig();
    return ScopedAStatus::ok();
  }
};

// IPower HAL for Android 15
class RhizoPower : public BnPower {
 public:
  // ignore the mode
  ScopedAStatus setMode(Mode, bool) override { return ScopedAStatus::ok(); }
  // return true for FIXED_PERFORMANCE mode
  ScopedAStatus isModeSupported(Mode mode, bool* out) override {
    *out = (mode == Mode::FIXED_PERFORMANCE);
    return ScopedAStatus::ok();
  }
  // ignore the boost
  ScopedAStatus setBoost(Boost, int32_t) override { return ScopedAStatus::ok(); }
  // report that boosts are unsupported
  ScopedAStatus isBoostSupported(Boost, bool* out) override { *out = false; return ScopedAStatus::ok(); }

  // return unsupported for hint sessions
  ScopedAStatus createHintSession(int32_t, int32_t, const std::vector<int32_t>& tids, int64_t,
                                   std::shared_ptr<IPowerHintSession>* out) override {
    (void)out;
    if (tids.empty()) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // return the preferred session update interval
  ScopedAStatus getHintSessionPreferredRate(int64_t* out) override {
    *out = 16666667;
    return ScopedAStatus::ok();
  }
  // report that hint sessions are unsupported
  ScopedAStatus createHintSessionWithConfig(int32_t, int32_t, const std::vector<int32_t>& tids,
                                             int64_t, SessionTag, SessionConfig* config,
                                             std::shared_ptr<IPowerHintSession>* out) override {
    (void)config; (void)out;
    if (tids.empty()) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // return unsupported for session channels
  ScopedAStatus getSessionChannel(int32_t, int32_t, ChannelConfig*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // ignore closing a session channel
  ScopedAStatus closeSessionChannel(int32_t, int32_t) override { return ScopedAStatus::ok(); }
};

}

// register the power service and join the binder thread pool
int main() {
  klog("main() entered");
  auto device = ndk::SharedRefBase::make<RhizoPower>();
  const std::string instance = std::string(RhizoPower::descriptor) + "/default";
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

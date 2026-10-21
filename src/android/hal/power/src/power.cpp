#include "aidl/android/hardware/power/BnPower.h"
#include "aidl/android/hardware/power/BnPowerHintSession.h"
#include "headroom_link.h"
#include "rtd_link.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <atomic>
#include <cstdio>
#include <string>
#include <fcntl.h>
#include <unistd.h>

using namespace aidl::android::hardware::power;
using ndk::ScopedAStatus;

namespace {

// write a message to the kernel log
void klog(const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    dprintf(fd, "<5>rhizo-power: %s\n", msg);
    close(fd);
  }
}

constexpr char kRtdSocketPath[] = "/dev/socket/rhizo_rt/rtd";

using rhizo_rtd::RtdLink;

constexpr char kHeadroomSocketPath[] = "/dev/socket/rhizo_headroom/headroomd";

using rhizo_headroom::HeadroomLink;

// IPowerHintSession for rhizo-rtd
class RhizoPowerHintSession : public BnPowerHintSession {
 public:
  // store the session id and the link
  RhizoPowerHintSession(int32_t sid, RtdLink* link) : sid_(sid), link_(link) {}
  // close the session on the link
  ~RhizoPowerHintSession() override { link_->Close(sid_); }

  int32_t sid() const { return sid_; }

  // send the target work duration for the session
  ScopedAStatus updateTargetWorkDuration(int64_t targetDurationNanos) override {
    link_->Target(sid_, targetDurationNanos);
    return ScopedAStatus::ok();
  }
  // send the actual work durations for the session
  ScopedAStatus reportActualWorkDuration(const std::vector<WorkDuration>& durations) override {
    std::vector<int64_t> nanos;
    nanos.reserve(durations.size());
    for (const auto& d : durations) nanos.push_back(d.durationNanos);
    link_->Actual(sid_, nanos);
    return ScopedAStatus::ok();
  }
  // send a pause for the session
  ScopedAStatus pause() override {
    link_->SetPaused(sid_, true);
    return ScopedAStatus::ok();
  }
  // send a resume for the session
  ScopedAStatus resume() override {
    link_->SetPaused(sid_, false);
    return ScopedAStatus::ok();
  }
  // send a close for the session and log it
  ScopedAStatus close() override {
    link_->Close(sid_);
    char buf[64];
    snprintf(buf, sizeof(buf), "session %d close", sid_);
    klog(buf);
    return ScopedAStatus::ok();
  }
  // send the session thread ids to rhizo-rtd
  ScopedAStatus setThreads(const std::vector<int32_t>& tids) override {
    if (tids.empty()) {
      return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    link_->Threads(sid_, tids);
    return ScopedAStatus::ok();
  }
  // return ok for a session hint
  ScopedAStatus sendHint(SessionHint) override { return ScopedAStatus::ok(); }
  // ignore the session mode
  ScopedAStatus setMode(SessionMode, bool) override { return ScopedAStatus::ok(); }
  // return a session config holding the session id
  ScopedAStatus getSessionConfig(SessionConfig* out) override {
    *out = SessionConfig();
    out->id = sid_;
    return ScopedAStatus::ok();
  }

 private:
  int32_t sid_;
  RtdLink* link_;
};

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

  // open a hint session on rhizo-rtd
  ScopedAStatus createHintSession(int32_t tgid, int32_t uid, const std::vector<int32_t>& tids,
                                   int64_t durationNanos,
                                   std::shared_ptr<IPowerHintSession>* out) override {
    if (tids.empty()) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    if (!rtd_.TryConnect()) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    *out = OpenSession(tgid, uid, tids, durationNanos);
    return ScopedAStatus::ok();
  }
  // return the preferred session update interval
  ScopedAStatus getHintSessionPreferredRate(int64_t* out) override {
    *out = 16666667;
    return ScopedAStatus::ok();
  }
  // open a hint session and return its config
  ScopedAStatus createHintSessionWithConfig(int32_t tgid, int32_t uid,
                                            const std::vector<int32_t>& tids, int64_t durationNanos,
                                            SessionTag, SessionConfig* config,
                                            std::shared_ptr<IPowerHintSession>* out) override {
    if (tids.empty()) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    if (!rtd_.TryConnect()) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    auto session = OpenSession(tgid, uid, tids, durationNanos);
    *config = SessionConfig();
    config->id = session->sid();
    *out = session;
    return ScopedAStatus::ok();
  }
  // return unsupported for session channels
  ScopedAStatus getSessionChannel(int32_t, int32_t, ChannelConfig*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // ignore closing a session channel
  ScopedAStatus closeSessionChannel(int32_t, int32_t) override { return ScopedAStatus::ok(); }

  // fill in the power support info
  ScopedAStatus getSupportInfo(SupportInfo* out) override {
    *out = SupportInfo();
    out->usesSessions = rtd_.TryConnect();
    out->boosts = 0;
    out->modes = 1LL << static_cast<int>(Mode::FIXED_PERFORMANCE);
    out->sessionHints = 0;
    out->sessionModes = 0;
    out->sessionTags = 0;
    if (headroom_.Supported()) {
      out->headroom.isCpuSupported = true;
      out->headroom.cpuMinIntervalMillis = 100;
      out->headroom.cpuMinCalculationWindowMillis = 100;
      out->headroom.cpuMaxCalculationWindowMillis = 10000;
      out->headroom.cpuMaxTidCount = 5;
    }
    return ScopedAStatus::ok();
  }
  // return the host CPU headroom
  ScopedAStatus getCpuHeadroom(const CpuHeadroomParams& params, CpuHeadroomResult* out) override {
    if (!headroom_.Supported()) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    bool average = params.calculationType == CpuHeadroomParams::CalculationType::AVERAGE;
    *out = CpuHeadroomResult::make<CpuHeadroomResult::globalHeadroom>(
        headroom_.Query(average, params.calculationWindowMillis));
    return ScopedAStatus::ok();
  }
  // report that GPU headroom is unsupported
  ScopedAStatus getGpuHeadroom(const GpuHeadroomParams&, GpuHeadroomResult*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // ignore composition data
  ScopedAStatus sendCompositionData(const std::vector<CompositionData>&) override {
    return ScopedAStatus::ok();
  }
  // ignore a composition update
  ScopedAStatus sendCompositionUpdate(const CompositionUpdate&) override {
    return ScopedAStatus::ok();
  }

 private:
  // open a session on rhizo-rtd
  std::shared_ptr<RhizoPowerHintSession> OpenSession(int32_t tgid, int32_t uid,
                                                      const std::vector<int32_t>& tids,
                                                      int64_t durationNanos) {
    int32_t sid = next_sid_.fetch_add(1);
    rtd_.Open(sid, tgid, uid, durationNanos, tids);
    char buf[160];
    snprintf(buf, sizeof(buf), "session %d open tgid=%d uid=%d tids=%zu target=%lld", sid, tgid,
             uid, tids.size(), static_cast<long long>(durationNanos));
    klog(buf);
    return ndk::SharedRefBase::make<RhizoPowerHintSession>(sid, &rtd_);
  }

  RtdLink rtd_{kRtdSocketPath, klog};
  HeadroomLink headroom_{kHeadroomSocketPath, klog};
  std::atomic<int32_t> next_sid_{1};
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

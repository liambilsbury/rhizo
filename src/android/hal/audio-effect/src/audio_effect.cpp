#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <fmq/AidlMessageQueue.h>
#include <fmq/EventFlag.h>

#include "aidl/android/hardware/audio/effect/BnEffect.h"
#include "aidl/android/hardware/audio/effect/BnFactory.h"

using namespace aidl::android::hardware::audio::effect;
using aidl::android::media::audio::common::AudioChannelLayout;
using aidl::android::media::audio::common::AudioFormatDescription;
using aidl::android::media::audio::common::AudioFormatType;
using aidl::android::media::audio::common::AudioUuid;
using aidl::android::media::audio::common::PcmType;
using aidl::android::hardware::common::fmq::SynchronizedReadWrite;
using ndk::ScopedAStatus;

namespace {

// write a message to the kernel log
void klog(const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    dprintf(fd, "<5>rhizo-audio-effect: %s\n", msg);
    close(fd);
  }
}

void klogf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
// format a message and write it to the kernel log
void klogf(const char* fmt, ...) {
  char msg[256];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);
  klog(msg);
}

// parse a UUID string
AudioUuid stringToUuid(const char* str) {
  AudioUuid uuid{};
  uint32_t tmp[10];
  if (!str ||
      sscanf(str, "%08x-%04x-%04x-%04x-%02x%02x%02x%02x%02x%02x", &tmp[0], &tmp[1], &tmp[2],
             &tmp[3], &tmp[4], &tmp[5], &tmp[6], &tmp[7], &tmp[8], &tmp[9]) < 10) {
    return uuid;
  }
  uuid.timeLow = static_cast<int32_t>(tmp[0]);
  uuid.timeMid = static_cast<int32_t>(tmp[1]);
  uuid.timeHiAndVersion = static_cast<int32_t>(tmp[2]);
  uuid.clockSeq = static_cast<int32_t>(tmp[3]);
  uuid.node = {static_cast<uint8_t>(tmp[4]), static_cast<uint8_t>(tmp[5]),
               static_cast<uint8_t>(tmp[6]), static_cast<uint8_t>(tmp[7]),
               static_cast<uint8_t>(tmp[8]), static_cast<uint8_t>(tmp[9])};
  return uuid;
}

// return the size of a PCM sample
size_t getPcmSampleSizeInBytes(PcmType pcm) {
  switch (pcm) {
    case PcmType::UINT_8_BIT:
      return 1;
    case PcmType::INT_16_BIT:
      return 2;
    case PcmType::INT_32_BIT:
      return 4;
    case PcmType::FIXED_Q_8_24:
      return 4;
    case PcmType::FLOAT_32_BIT:
      return 4;
    case PcmType::INT_24_BIT:
      return 3;
    default:
      return 0;
  }
}

// return the number of channels set in a channel layout
size_t getChannelCount(const AudioChannelLayout& layout) {
  using Tag = AudioChannelLayout::Tag;
  switch (layout.getTag()) {
    case Tag::indexMask:
      return static_cast<size_t>(__builtin_popcount(
          static_cast<uint32_t>(layout.get<Tag::indexMask>())));
    case Tag::layoutMask:
      return static_cast<size_t>(__builtin_popcount(
          static_cast<uint32_t>(layout.get<Tag::layoutMask>())));
    case Tag::voiceMask:
      return static_cast<size_t>(__builtin_popcount(
          static_cast<uint32_t>(layout.get<Tag::voiceMask>())));
    default:
      return 0;
  }
}

// return the size of a frame in bytes
size_t getFrameSizeInBytes(const AudioFormatDescription& format, const AudioChannelLayout& layout) {
  if (format.type == AudioFormatType::PCM) {
    return getPcmSampleSizeInBytes(format.pcm) * getChannelCount(layout);
  } else if (format.type == AudioFormatType::NON_PCM) {
    return getPcmSampleSizeInBytes(format.pcm);
  }
  return 0;
}

constexpr const char* kImplUuidEqualizerSw = "0bed4300-847d-11df-bb17-0002a5d5c51b";
constexpr const char* kImplUuidLoudnessEnhancerSw = "fa819610-588b-11ed-9b6a-0242ac120002";
constexpr const char* kImplUuidVisualizerSw = "fa81a0f6-588b-11ed-9b6a-0242ac120002";
constexpr const char* kImplUuidDynamicsProcessingSw = "fa818d78-588b-11ed-9b6a-0242ac120002";

constexpr int32_t kDestroyAnyStateSupportedVersion = 3;
constexpr uint32_t kRhizoEventFlagNotEmpty = 0x1;

// create an effect descriptor
Descriptor makeDescriptor(const char* typeUuid, const char* implUuid, const char* name) {
  Descriptor d;
  d.common.id.type = stringToUuid(typeUuid);
  d.common.id.uuid = stringToUuid(implUuid);
  d.common.id.proxy = std::nullopt;
  d.common.flags = Flags();
  d.common.cpuLoad = 0;
  d.common.memoryUsage = 0;
  d.common.name = name;
  d.common.implementor = "Rhizo";
  return d;
}

// return the descriptors of the four effect types
std::vector<Descriptor> makeDescriptors() {
  return {
      makeDescriptor(Descriptor::EFFECT_TYPE_UUID_EQUALIZER, kImplUuidEqualizerSw,
                      "Rhizo Equalizer"),
      makeDescriptor(Descriptor::EFFECT_TYPE_UUID_LOUDNESS_ENHANCER, kImplUuidLoudnessEnhancerSw,
                      "Rhizo Loudness Enhancer"),
      makeDescriptor(Descriptor::EFFECT_TYPE_UUID_VISUALIZER, kImplUuidVisualizerSw,
                      "Rhizo Visualizer"),
      makeDescriptor(Descriptor::EFFECT_TYPE_UUID_DYNAMICS_PROCESSING,
                      kImplUuidDynamicsProcessingSw, "Rhizo Dynamics Processing"),
  };
}

using StatusMQ = ::android::AidlMessageQueue<IEffect::Status, SynchronizedReadWrite>;
using DataMQ = ::android::AidlMessageQueue<float, SynchronizedReadWrite>;

// software audio effect instance
class RhizoEffect : public BnEffect {
 public:
  // store the effect descriptor
  explicit RhizoEffect(Descriptor desc) : mDesc(std::move(desc)) {}

  // stop the processing thread
  ~RhizoEffect() override {
    stopProcessingThread();
  }

  // return the effect descriptor
  ScopedAStatus getDescriptor(Descriptor* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    *out = mDesc;
    return ScopedAStatus::ok();
  }

  // open the effect, set up its queues and start the processing thread
  ScopedAStatus open(const Parameter::Common& common,
                     const std::optional<Parameter::Specific>& specific,
                     IEffect::OpenEffectReturn* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    if (mState != State::INIT) {
      return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    if (!setUpQueues(common, out)) {
      return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    mCommon = common;
    if (specific.has_value()) mSpecific = specific.value();
    mState = State::IDLE;
    mThreadStop.store(false, std::memory_order_release);
    mProcThread = std::thread(&RhizoEffect::processLoop, this);
    return ScopedAStatus::ok();
  }

  // close the effect and release its queues
  ScopedAStatus close() override {
    {
      std::lock_guard<std::mutex> lock(mLock);
      if (mState == State::INIT) return ScopedAStatus::ok();
      if (mState == State::PROCESSING) {
        return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
      }
      mState = State::INIT;
    }
    stopProcessingThread();
    std::lock_guard<std::mutex> lock(mLock);
    mStatusMQ.reset();
    mInputMQ.reset();
    mOutputMQ.reset();
    return ScopedAStatus::ok();
  }

  // change the effect state
  ScopedAStatus command(CommandId id) override {
    std::lock_guard<std::mutex> lock(mLock);
    if (mState == State::INIT) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    switch (id) {
      case CommandId::START:
        if (mState == State::PROCESSING) return ScopedAStatus::ok();
        mState = State::PROCESSING;
        if (mEfGroup) mEfGroup->wake(kRhizoEventFlagNotEmpty);
        return ScopedAStatus::ok();
      case CommandId::STOP:
        mState = State::IDLE;
        return ScopedAStatus::ok();
      case CommandId::RESET:
        mState = State::IDLE;
        return ScopedAStatus::ok();
      default:
        return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
  }

  // return the effect state
  ScopedAStatus getState(State* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    *out = mState;
    return ScopedAStatus::ok();
  }

  // save the parameter
  ScopedAStatus setParameter(const Parameter& param) override {
    std::lock_guard<std::mutex> lock(mLock);
    if (mState == State::INIT) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    if (param.getTag() == Parameter::common) {
      mCommon = param.get<Parameter::common>();
    }
    mLastParam = param;
    return ScopedAStatus::ok();
  }

  // return the common parameters or the last parameter set
  ScopedAStatus getParameter(const Parameter::Id& id, Parameter* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    if (mState == State::INIT) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    if (id.getTag() == Parameter::Id::commonTag) {
      Parameter p;
      p.set<Parameter::common>(mCommon);
      *out = p;
      return ScopedAStatus::ok();
    }
    if (!mLastParam.has_value()) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    *out = mLastParam.value();
    return ScopedAStatus::ok();
  }

 private:
  // create the effect queues
  bool setUpQueues(const Parameter::Common& common, IEffect::OpenEffectReturn* out) {
    constexpr size_t kMinCapacity = 1024;
    auto samplesFor = [](const auto& audioConfig) -> size_t {
      size_t frameSize = getFrameSizeInBytes(audioConfig.base.format, audioConfig.base.channelMask);
      if (frameSize == 0 || audioConfig.frameCount <= 0) return 0;
      return static_cast<size_t>(audioConfig.frameCount) * frameSize / sizeof(float);
    };
    const size_t inputCapacity = std::max(kMinCapacity, samplesFor(common.input));
    const size_t outputCapacity = std::max(kMinCapacity, samplesFor(common.output));
    mStatusMQ = std::make_unique<StatusMQ>(4, true  );
    mInputMQ = std::make_unique<DataMQ>(inputCapacity);
    mOutputMQ = std::make_unique<DataMQ>(outputCapacity);
    if (!mStatusMQ->isValid() || !mInputMQ->isValid() || !mOutputMQ->isValid()) {
      klogf("effect FMQ setup failed for %s", mDesc.common.name.c_str());
      return false;
    }
    if (::android::OK != ::android::hardware::EventFlag::createEventFlag(
                              mStatusMQ->getEventFlagWord(), &mEfGroup) ||
        !mEfGroup) {
      klogf("effect EventFlag setup failed for %s", mDesc.common.name.c_str());
      return false;
    }
    out->statusMQ = mStatusMQ->dupeDesc();
    out->inputDataMQ = mInputMQ->dupeDesc();
    out->outputDataMQ = mOutputMQ->dupeDesc();
    return true;
  }

  // stop the processing thread and delete the event flag
  void stopProcessingThread() {
    mThreadStop.store(true, std::memory_order_release);
    {
      std::lock_guard<std::mutex> lock(mLock);
      if (mEfGroup) mEfGroup->wake(kRhizoEventFlagNotEmpty);
    }
    if (mProcThread.joinable()) mProcThread.join();
    std::lock_guard<std::mutex> lock(mLock);
    if (mEfGroup) {
      ::android::hardware::EventFlag::deleteEventFlag(&mEfGroup);
    }
  }

  // copy the input queue to the output queue
  void processLoop() {
    static constexpr int64_t kProcessPollNs = 20LL * 1000 * 1000;
    while (!mThreadStop.load(std::memory_order_acquire)) {
      ::android::hardware::EventFlag* ef;
      {
        std::lock_guard<std::mutex> lock(mLock);
        ef = mEfGroup;
      }
      uint32_t efState = 0;
      if (ef) {
        ef->wait(kRhizoEventFlagNotEmpty, &efState, kProcessPollNs, false  );
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
      }
      if (mThreadStop.load(std::memory_order_acquire)) return;

      std::lock_guard<std::mutex> lock(mLock);
      if (mState != State::PROCESSING || !mInputMQ || !mOutputMQ || !mStatusMQ) continue;
      const size_t avail = std::min(mInputMQ->availableToRead(), mOutputMQ->availableToWrite());
      if (avail == 0) continue;
      if (mWorkBuffer.size() < avail) mWorkBuffer.resize(avail);
      if (!mInputMQ->read(mWorkBuffer.data(), avail)) continue;
      if (!mOutputMQ->write(mWorkBuffer.data(), avail)) continue;
      IEffect::Status status{};
      status.status = STATUS_OK;
      status.fmqConsumed = static_cast<int32_t>(avail);
      status.fmqProduced = static_cast<int32_t>(avail);
      mStatusMQ->writeBlocking(&status, 1);
    }
  }

  std::mutex mLock;
  const Descriptor mDesc;
  State mState = State::INIT;
  Parameter::Common mCommon{};
  std::optional<Parameter::Specific> mSpecific;
  std::optional<Parameter> mLastParam;
  std::unique_ptr<StatusMQ> mStatusMQ;
  std::unique_ptr<DataMQ> mInputMQ;
  std::unique_ptr<DataMQ> mOutputMQ;
  ::android::hardware::EventFlag* mEfGroup = nullptr;
  std::thread mProcThread;
  std::atomic<bool> mThreadStop{false};
  std::vector<float> mWorkBuffer;
};

class RhizoEffectFactory : public BnFactory {
 public:
  // build the descriptor list
  RhizoEffectFactory() : mDescs(makeDescriptors()) {}

  // list the effects matching the filters
  ScopedAStatus queryEffects(const std::optional<AudioUuid>& type,
                              const std::optional<AudioUuid>& impl,
                              const std::optional<AudioUuid>& proxy,
                              std::vector<Descriptor>* out) override {
    out->clear();
    for (const auto& d : mDescs) {
      if (type.has_value() && !(d.common.id.type == type.value())) continue;
      if (impl.has_value() && !(d.common.id.uuid == impl.value())) continue;
      if (proxy.has_value()) continue;
      out->push_back(d);
    }
    return ScopedAStatus::ok();
  }

  // return an empty processing list
  ScopedAStatus queryProcessing(const std::optional<Processing::Type>&,
                                 std::vector<Processing>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }

  // create an effect
  ScopedAStatus createEffect(const AudioUuid& implUuid,
                              std::shared_ptr<IEffect>* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    for (const auto& d : mDescs) {
      if (d.common.id.uuid == implUuid) {
        auto effect = ndk::SharedRefBase::make<RhizoEffect>(d);
        mCreated.push_back(effect);
        *out = effect;
        return ScopedAStatus::ok();
      }
    }
    return ScopedAStatus::fromExceptionCodeWithMessage(EX_ILLEGAL_ARGUMENT,
                                                         "no such effect implementation uuid");
  }

  // destroy an effect
  ScopedAStatus destroyEffect(const std::shared_ptr<IEffect>& handle) override {
    std::lock_guard<std::mutex> lock(mLock);
    if (handle == nullptr) {
      return ScopedAStatus::fromExceptionCodeWithMessage(EX_ILLEGAL_ARGUMENT, "null effect");
    }
    for (auto it = mCreated.begin(); it != mCreated.end(); ++it) {
      if (it->get() == handle.get()) {
        int32_t effectVersion = 1;
        handle->getInterfaceVersion(&effectVersion);
        State state;
        if (effectVersion < kDestroyAnyStateSupportedVersion &&
            handle->getState(&state).getStatus() == EX_NONE && state != State::INIT) {
          return ScopedAStatus::fromExceptionCodeWithMessage(
              EX_ILLEGAL_STATE, "effect must be closed before destroy on this HAL version");
        }
        mCreated.erase(it);
        return ScopedAStatus::ok();
      }
    }
    return ScopedAStatus::fromExceptionCodeWithMessage(EX_ILLEGAL_ARGUMENT,
                                                         "not an effect this factory created");
  }

 private:
  const std::vector<Descriptor> mDescs;
  std::mutex mLock;
  std::vector<std::shared_ptr<IEffect>> mCreated;
};

}

// register the effect factory and join the binder thread pool
int main() {
  klog("main() entered");
  auto factory = ndk::SharedRefBase::make<RhizoEffectFactory>();
  const std::string instance = std::string(RhizoEffectFactory::descriptor) + "/default";
  binder_status_t status =
      AServiceManager_addService(factory->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    char buf[128];
    snprintf(buf, sizeof(buf), "addService FAILED status=%d", status);
    klog(buf);
    return 1;
  }
  klog("registered IFactory/default with 4 real effect types, joining thread pool");
  ABinderProcess_setThreadPoolMaxThreadCount(0);
  ABinderProcess_joinThreadPool();
  klog("joinThreadPool RETURNED (unexpected)");
  return 0;
}

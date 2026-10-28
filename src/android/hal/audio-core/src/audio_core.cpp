#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <fmq/AidlMessageQueue.h>

#include "aidl/android/hardware/audio/core/BnConfig.h"
#include "aidl/android/hardware/audio/core/BnModule.h"
#include "aidl/android/hardware/audio/core/BnStreamCommon.h"
#include "aidl/android/hardware/audio/core/BnStreamIn.h"
#include "aidl/android/hardware/audio/core/BnStreamOut.h"
#include "aidl/android/media/audio/common/AudioOutputFlags.h"

using namespace aidl::android::hardware::audio::core;
using namespace aidl::android::media::audio::common;
using aidl::android::hardware::audio::common::AudioOffloadMetadata;
using aidl::android::hardware::audio::common::SinkMetadata;
using aidl::android::hardware::audio::common::SourceMetadata;
using aidl::android::hardware::common::fmq::SynchronizedReadWrite;
using ndk::ScopedAStatus;

namespace {

int gKmsgFd = -1;

void klogf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
// format a message and write it to the kernel log
void klogf(const char* fmt, ...) {
  if (gKmsgFd < 0) {
    gKmsgFd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (gKmsgFd < 0) return;
  }
  char msg[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);
  dprintf(gKmsgFd, "<5>rhizo-audio-core: %s\n", msg);
}

constexpr int kWorkerNice = -19;

// set the thread name and priority
void SetWorkerPriority(const char* label, const char* threadName) {
  prctl(PR_SET_NAME, threadName);
  if (setpriority(PRIO_PROCESS, gettid(), kWorkerNice) != 0) {
    klogf("[%s] setpriority(%d) FAILED errno=%d (%s) -- worker stays at nice %d", label, kWorkerNice,
          errno, strerror(errno), getpriority(PRIO_PROCESS, gettid()));
  }
}

// log and return an illegal argument status
ScopedAStatus illegalArgument(const char* msg) {
  klogf("rejected (illegal argument): %s", msg);
  return ScopedAStatus::fromExceptionCodeWithMessage(EX_ILLEGAL_ARGUMENT, msg);
}

// log and return an illegal-state exception status
ScopedAStatus illegalState(const char* msg) {
  klogf("rejected (illegal state): %s", msg);
  return ScopedAStatus::fromExceptionCodeWithMessage(EX_ILLEGAL_STATE, msg);
}

// check the audio mode against allowed values
bool isValidAudioMode(AudioMode mode) {
  switch (mode) {
    case AudioMode::NORMAL:
    case AudioMode::RINGTONE:
    case AudioMode::IN_CALL:
    case AudioMode::IN_COMMUNICATION:
    case AudioMode::CALL_SCREEN:
      return true;
    default:
      return false;
  }
}

// return the monotonic clock in nanoseconds
int64_t monotonicNs() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

constexpr int32_t kPortSpeaker = 20;
constexpr int32_t kPortBus0 = 21;
constexpr int32_t kPortPrimaryOut = 10;
constexpr int32_t kPortBus0Out = 11;
constexpr int32_t kMaxBusCount = 4;
constexpr int32_t kPortMicIn = kPortBus0 + kMaxBusCount;
constexpr int32_t kPortRecordIn = kPortBus0Out + kMaxBusCount;

int gBusCount = kMaxBusCount;

// read the bus count file
void loadBusCount() {
  FILE* f = fopen("/data/misc/rhizo/audio_buses", "r");
  if (f == nullptr) return;
  int n = -1;
  if (fscanf(f, "%d", &n) == 1 && n >= 0 && n <= kMaxBusCount) {
    gBusCount = n;
  }
  fclose(f);
}

constexpr int32_t kSampleRate = 48000;
constexpr int32_t kChannelCount = 2;
constexpr size_t kFrameSizeBytes = 4;
constexpr int32_t kNominalLatencyMs = 20;
constexpr int64_t kMinBufferSizeFrames = kSampleRate * kNominalLatencyMs / 1000;
constexpr int64_t kMaxBufferSizeFrames = kSampleRate;

// return the 16-bit PCM format
AudioFormatDescription pcm16() {
  AudioFormatDescription f;
  f.type = AudioFormatType::PCM;
  f.pcm = PcmType::INT_16_BIT;
  return f;
}

// return the stereo channel layout
AudioChannelLayout stereo() {
  return AudioChannelLayout::make<AudioChannelLayout::layoutMask>(
      AudioChannelLayout::LAYOUT_STEREO);
}

// return the stereo 16-bit PCM profile at the sample rate
AudioProfile pcmProfile() {
  AudioProfile p;
  p.format = pcm16();
  p.channelMasks.push_back(stereo());
  p.sampleRates.push_back(kSampleRate);
  return p;
}

// return the address of a bus by number
std::string busAddress(int i) { return "bus" + std::to_string(i); }

// create a device port
AudioPort makeDevicePort(int32_t id, const std::string& name, AudioDeviceType type,
                         const std::string& connection, const std::string& address,
                         bool isDefault, bool isInput = false) {
  AudioPort port;
  port.id = id;
  port.name = name;
  port.profiles.push_back(pcmProfile());
  port.flags = isInput ? AudioIoFlags::make<AudioIoFlags::input>(0)
                       : AudioIoFlags::make<AudioIoFlags::output>(0);
  AudioPortDeviceExt dev;
  dev.device.type.type = type;
  dev.device.type.connection = connection;
  dev.device.address = AudioDeviceAddress::make<AudioDeviceAddress::id>(address);
  if (isDefault) dev.flags = 1 << AudioPortDeviceExt::FLAG_INDEX_DEFAULT_DEVICE;
  port.ext = AudioPortExt::make<AudioPortExt::device>(dev);
  return port;
}

// create a mix port
AudioPort makeMixPort(int32_t id, const std::string& name, int32_t ioFlags, bool isInput = false) {
  AudioPort port;
  port.id = id;
  port.name = name;
  port.profiles.push_back(pcmProfile());
  port.flags = isInput ? AudioIoFlags::make<AudioIoFlags::input>(ioFlags)
                       : AudioIoFlags::make<AudioIoFlags::output>(ioFlags);
  AudioPortMixExt mix;
  mix.maxOpenStreamCount = 1;
  mix.maxActiveStreamCount = 1;
  port.ext = AudioPortExt::make<AudioPortExt::mix>(mix);
  return port;
}

// create the list of audio ports
std::vector<AudioPort> makePorts() {
  std::vector<AudioPort> ports;
  ports.push_back(
      makeDevicePort(kPortSpeaker, "Speaker", AudioDeviceType::OUT_SPEAKER, "", "", true));
  for (int i = 0; i < gBusCount; i++) {
    ports.push_back(makeDevicePort(kPortBus0 + i, busAddress(i), AudioDeviceType::OUT_DEVICE, "",
                                   busAddress(i), false));
  }
  ports.push_back(
      makeMixPort(kPortPrimaryOut, "primary output", 1 << static_cast<int>(AudioOutputFlags::PRIMARY)));
  for (int i = 0; i < gBusCount; i++) {
    ports.push_back(makeMixPort(kPortBus0Out + i, busAddress(i) + " output", 0));
  }
  ports.push_back(makeDevicePort(kPortMicIn, "Default Input", AudioDeviceType::IN_MICROPHONE, "", "",
                                 true,  true));
  ports.push_back(makeMixPort(kPortRecordIn, "record input", 0,  true));
  return ports;
}

// create the list of audio routes
std::vector<AudioRoute> makeRoutes() {
  std::vector<AudioRoute> routes;
  AudioRoute primary;
  primary.sinkPortId = kPortSpeaker;
  primary.sourcePortIds.push_back(kPortPrimaryOut);
  primary.isExclusive = false;
  routes.push_back(primary);
  for (int i = 0; i < gBusCount; i++) {
    AudioRoute r;
    r.sinkPortId = kPortBus0 + i;
    r.sourcePortIds.push_back(kPortBus0Out + i);
    r.isExclusive = false;
    routes.push_back(r);
  }
  AudioRoute record;
  record.sinkPortId = kPortRecordIn;
  record.sourcePortIds.push_back(kPortMicIn);
  record.isExclusive = false;
  routes.push_back(record);
  return routes;
}

// return the label for a mix port
std::string streamLabelForMixPort(int32_t portId) {
  if (portId == kPortPrimaryOut) return "primary";
  if (portId >= kPortBus0Out && portId < kPortBus0Out + gBusCount) {
    return busAddress(portId - kPortBus0Out);
  }
  return "unknown";
}

// socket connection to rhizo-audiod
class HostSink {
 public:
  explicit HostSink(std::string label) : mLabel(std::move(label)) {}
  // disconnect the sink
  ~HostSink() { disconnect(); }

  // connect to the rhizo-audiod socket
  void connect() {
    disconnect();
    const char* env = getenv("RHIZO_AUDIO_SOCKET");
    const std::string path = env && *env ? env : "/dev/socket/rhizo_audio/audiod";
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) {
      klogf("[%s] socket() failed: %s", mLabel.c_str(), strerror(errno));
      return;
    }
    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) {
      klogf("[%s] socket path too long: %s", mLabel.c_str(), path.c_str());
      close(fd);
      return;
    }
    strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    if (::connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0 &&
        errno != EINPROGRESS) {
      klogf("[%s] no host bridge at %s (%s)", mLabel.c_str(), path.c_str(), strerror(errno));
      close(fd);
      return;
    }
    char hdr[256];
    int n = snprintf(hdr, sizeof(hdr), "rhizo-audio/1 port=%s rate=%d channels=%d format=s16le\n",
                     mLabel.c_str(), kSampleRate, kChannelCount);
    if (send(fd, hdr, n, MSG_NOSIGNAL) != n) {
      klogf("[%s] header write failed: %s", mLabel.c_str(), strerror(errno));
      close(fd);
      return;
    }
    mFd = fd;
    mXruns = 0;
    klogf("[%s] connected to host bridge %s", mLabel.c_str(), path.c_str());
  }

  // close the sink socket
  void disconnect() {
    if (mFd >= 0) {
      close(mFd);
      mFd = -1;
    }
  }

  // send the bytes to rhizo-audiod
  bool write(const void* data, size_t bytes) {
    if (mFd < 0 || bytes == 0) return mFd >= 0;
    const uint8_t* p = static_cast<const uint8_t*>(data);
    size_t left = bytes;
    while (left > 0) {
      ssize_t w = send(mFd, p, left, MSG_NOSIGNAL);
      if (w > 0) {
        p += w;
        left -= static_cast<size_t>(w);
        continue;
      }
      if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        if ((mXruns++ % 100) == 0) {
          klogf("[%s] host bridge behind, dropped %zu bytes (xrun %d)", mLabel.c_str(), left,
                mXruns);
        }
        return true;
      }
      klogf("[%s] host bridge write failed: %s", mLabel.c_str(), strerror(errno));
      disconnect();
      return false;
    }
    return true;
  }

  int xruns() const { return mXruns; }

 private:
  const std::string mLabel;
  int mFd = -1;
  int mXruns = 0;
};

// microphone connection to rhizo-audiod
class HostSource {
 public:
  ~HostSource() { disconnect(); }

  // connect to the rhizo-audiod microphone socket
  void connect() {
    disconnect();
    mLastAttemptNs = monotonicNs();
    const char* env = getenv("RHIZO_AUDIO_MIC_SOCKET");
    const std::string path = env && *env ? env : "/dev/socket/rhizo_audio/mic";
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) {
      klogf("[record] socket() failed: %s", strerror(errno));
      return;
    }
    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) {
      klogf("[record] socket path too long: %s", path.c_str());
      close(fd);
      return;
    }
    strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    if (::connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0 &&
        errno != EINPROGRESS) {
      if (!mSaidAbsent) {
        klogf("[record] no host microphone at %s (%s): recording silence", path.c_str(),
              strerror(errno));
        mSaidAbsent = true;
      }
      close(fd);
      return;
    }
    char hdr[256];
    int n = snprintf(hdr, sizeof(hdr), "rhizo-audio/1 port=mic rate=%d channels=%d format=s16le\n",
                     kSampleRate, kChannelCount);
    if (send(fd, hdr, n, MSG_NOSIGNAL) != n) {
      klogf("[record] header write failed: %s", strerror(errno));
      close(fd);
      return;
    }
    mFd = fd;
    mSaidAbsent = false;
    klogf("[record] connected to the host microphone %s", path.c_str());
  }

  // close the source socket
  void disconnect() {
    if (mFd >= 0) {
      close(mFd);
      mFd = -1;
    }
  }

  // reset the logged absence of the microphone
  void resetNotes() { mSaidAbsent = false; }

  // read whole captured frames
  size_t read(uint8_t* out, size_t bytes) {
    if (mFd < 0 && monotonicNs() - mLastAttemptNs > kRetryNs) connect();
    if (mFd < 0) return 0;
    int queued = 0;
    if (ioctl(mFd, FIONREAD, &queued) != 0) {
      klogf("[record] FIONREAD failed: %s", strerror(errno));
      disconnect();
      return 0;
    }
    size_t have = static_cast<size_t>(std::max(queued, 0));
    if (have > kMaxBacklogBytes) {
      size_t drop = have - kTargetBacklogBytes;
      drop -= drop % kFrameSizeBytes;
      uint8_t sink[4096];
      size_t dropped = 0;
      while (dropped < drop) {
        ssize_t r = recv(mFd, sink, std::min(sizeof(sink), drop - dropped), MSG_DONTWAIT);
        if (r <= 0) break;
        dropped += static_cast<size_t>(r);
      }
      mDroppedBytes += dropped;
      if ((mBacklogDrops++ % 50) == 0) {
        klogf("[record] host microphone ahead by %zu bytes: dropped %zu (drop %d)", have, dropped,
              mBacklogDrops);
      }
      have -= dropped;
    }
    size_t want = std::min(bytes, have);
    want -= want % kFrameSizeBytes;
    size_t got = 0;
    while (got < want) {
      ssize_t r = recv(mFd, out + got, want - got, MSG_DONTWAIT);
      if (r > 0) {
        got += static_cast<size_t>(r);
        continue;
      }
      if (r == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
        klogf("[record] host microphone closed (%s)", r == 0 ? "end of stream" : strerror(errno));
        disconnect();
      }
      break;
    }
    return got - got % kFrameSizeBytes;
  }

  bool connected() const { return mFd >= 0; }
  uint64_t droppedBytes() const { return mDroppedBytes; }

 private:
  static constexpr size_t kMaxBacklogBytes = kSampleRate * kFrameSizeBytes / 5;
  static constexpr size_t kTargetBacklogBytes = kSampleRate * kFrameSizeBytes / 20;
  static constexpr int64_t kRetryNs = 1000LL * 1000 * 1000;
  int mFd = -1;
  int64_t mLastAttemptNs = 0;
  bool mSaidAbsent = false;
  int mBacklogDrops = 0;
  uint64_t mDroppedBytes = 0;
};

using CommandMQ = ::android::AidlMessageQueue<StreamDescriptor::Command, SynchronizedReadWrite>;
using ReplyMQ = ::android::AidlMessageQueue<StreamDescriptor::Reply, SynchronizedReadWrite>;
using DataMQ = ::android::AidlMessageQueue<int8_t, SynchronizedReadWrite>;

// IStreamCommon for input and output streams
class RhizoStreamCommon : public BnStreamCommon {
 public:
  explicit RhizoStreamCommon(int32_t portConfigId) : mPortConfigId(portConfigId) {}

  ScopedAStatus close() override;
  // reject a closed stream
  ScopedAStatus prepareToClose() override {
    if (mClosed.load()) {
      return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    return ScopedAStatus::ok();
  }
  // report that the operation is unsupported
  ScopedAStatus updateHwAvSyncId(int32_t) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // return an unsupported operation error
  ScopedAStatus getVendorParameters(const std::vector<std::string>&,
                                    std::vector<VendorParameter>*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setVendorParameters(const std::vector<VendorParameter>&, bool) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus addEffect(
      const std::shared_ptr<aidl::android::hardware::audio::effect::IEffect>&) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus removeEffect(
      const std::shared_ptr<aidl::android::hardware::audio::effect::IEffect>&) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }

 private:
  const int32_t mPortConfigId;
  std::atomic<bool> mClosed{false};
};

// output stream to rhizo-audiod
class RhizoStreamOut : public BnStreamOut {
 public:
  // construct the output stream
  RhizoStreamOut(int32_t portConfigId, int32_t mixPortId, int64_t bufferSizeFrames)
      : mPortConfigId(portConfigId),
        mLabel(streamLabelForMixPort(mixPortId)),
        mBufferSizeFrames(bufferSizeFrames),
        mCommandMQ(new CommandMQ(1, true  )),
        mReplyMQ(new ReplyMQ(1, true  )),
        mDataMQ(new DataMQ(kFrameSizeBytes * bufferSizeFrames)),
        mSink(mLabel),
        mDataBuffer(kFrameSizeBytes * bufferSizeFrames) {}

  ~RhizoStreamOut() override { stopWorker(); }

  // return whether all three queues are valid
  bool isValid() const {
    return mCommandMQ->isValid() && mReplyMQ->isValid() && mDataMQ->isValid();
  }

  // fill the stream descriptor
  void fillDescriptor(StreamDescriptor* desc) {
    desc->command = mCommandMQ->dupeDesc();
    desc->reply = mReplyMQ->dupeDesc();
    desc->frameSizeBytes = kFrameSizeBytes;
    desc->bufferSizeFrames = mBufferSizeFrames;
    desc->audio.set<StreamDescriptor::AudioBuffer::Tag::fmq>(mDataMQ->dupeDesc());
  }

  // start the worker thread at its priority
  void startWorker() {
    mWorker = std::thread([this] {
      SetWorkerPriority(mLabel.c_str(), "rhizo-aud-out");
      workerLoop();
    });
  }

  // set the exit flag and join the thread
  void stopWorker() {
    if (!mWorker.joinable()) return;
    mExiting = true;
    mWorker.join();
  }

  const std::string& label() const { return mLabel; }
  int32_t portConfigId() const { return mPortConfigId; }

  // return the IStreamCommon object
  ScopedAStatus getStreamCommon(std::shared_ptr<IStreamCommon>* out) override {
    if (mCommon == nullptr) mCommon = ndk::SharedRefBase::make<RhizoStreamCommon>(mPortConfigId);
    *out = mCommon;
    return ScopedAStatus::ok();
  }
  // ignore the source metadata
  ScopedAStatus updateMetadata(const SourceMetadata&) override {
    return ScopedAStatus::ok();
  }
  // report that the operation is unsupported
  ScopedAStatus updateOffloadMetadata(const AudioOffloadMetadata&) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // return the hardware volume
  ScopedAStatus getHwVolume(std::vector<float>* out) override {
    *out = mHwVolume;
    return ScopedAStatus::ok();
  }
  // check and save the hardware volume
  ScopedAStatus setHwVolume(const std::vector<float>& volumes) override {
    if (volumes.size() != static_cast<size_t>(kChannelCount)) {
      return illegalArgument("wrong channel count for hw volume");
    }
    for (float v : volumes) {
      if (!std::isfinite(v) || v < IStreamOut::HW_VOLUME_MIN || v > IStreamOut::HW_VOLUME_MAX) {
        return illegalArgument("hw volume out of range");
      }
    }
    mHwVolume = volumes;
    return ScopedAStatus::ok();
  }
  // report that the operation is unsupported
  ScopedAStatus getAudioDescriptionMixLevel(float*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setAudioDescriptionMixLevel(float) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus getDualMonoMode(AudioDualMonoMode*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setDualMonoMode(AudioDualMonoMode) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // return an unsupported operation error
  ScopedAStatus getRecommendedLatencyModes(std::vector<AudioLatencyMode>*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setLatencyMode(AudioLatencyMode) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus getPlaybackRateParameters(AudioPlaybackRate*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setPlaybackRateParameters(const AudioPlaybackRate&) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus selectPresentation(int32_t, int32_t) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }

 private:
  static constexpr int32_t kExitCookie = 0x52485A41;
  static constexpr int64_t kCommandPollNs = 200LL * 1000 * 1000;

  // fill a reply with the frame count, time and latency
  void populateReply(StreamDescriptor::Reply* reply) {
    reply->status = STATUS_OK;
    reply->observable.frames = mFrameCount;
    reply->observable.timeNs = monotonicNs();
    reply->latencyMs = kNominalLatencyMs;
    reply->xrunFrames = 0;
  }

  // log the rejected command and set an invalid-operation status
  void wrongState(StreamDescriptor::Reply* reply, const char* cmd) {
    klogf("[%s] command %s rejected in state %d", mLabel.c_str(), cmd, static_cast<int>(mState));
    reply->status = STATUS_INVALID_OPERATION;
  }

  // read the data queue and send the bytes
  void transfer(size_t bytes, StreamDescriptor::Reply* reply) {
    const size_t available = mDataMQ->availableToRead();
    if (available > 0) {
      if (!mDataMQ->read(reinterpret_cast<int8_t*>(mDataBuffer.data()), available)) {
        klogf("[%s] data FMQ read of %zu bytes failed", mLabel.c_str(), available);
        reply->status = STATUS_NOT_ENOUGH_DATA;
        return;
      }
    }
    const size_t byteCount = std::min({bytes, available, mDataBuffer.size()});
    if (byteCount > 0) {
      mSink.write(mDataBuffer.data(), byteCount);
    }
    const size_t frames = byteCount / kFrameSizeBytes;
    mFramesSinceStart += frames;
    mFrameCount += frames;
    const int64_t bufferDurationUs =
        static_cast<int64_t>(frames) * 1000000LL / kSampleRate;
    const int64_t elapsedUs = (monotonicNs() - mStartTimeNs) / 1000;
    const int64_t offsetUs = mFramesSinceStart * 1000000LL / kSampleRate - elapsedUs;
    if (offsetUs > 0) usleep(static_cast<useconds_t>(std::min(offsetUs, bufferDurationUs)));
    reply->fmqByteCount += static_cast<int32_t>(byteCount);
    populateReply(reply);
  }

  // run the output stream command loop
  void workerLoop() {
    while (true) {
      if (mExiting) {
        mSink.disconnect();
        klogf("[%s] worker exiting (%llu frames, %d xruns)", mLabel.c_str(),
              static_cast<unsigned long long>(mFrameCount), mSink.xruns());
        return;
      }
      StreamDescriptor::Command command;
      if (!mCommandMQ->readBlocking(&command, 1, kCommandPollNs)) {
        continue;
      }
      StreamDescriptor::Reply reply{};
      reply.status = STATUS_BAD_VALUE;
      using Tag = StreamDescriptor::Command::Tag;
      switch (command.getTag()) {
        case Tag::halReservedExit:
          if (command.get<Tag::halReservedExit>() == kExitCookie && mExiting) {
            mSink.disconnect();
            klogf("[%s] worker exiting (%llu frames, %d xruns)", mLabel.c_str(),
                  static_cast<unsigned long long>(mFrameCount), mSink.xruns());
            return;
          }
          break;
        case Tag::getStatus:
          populateReply(&reply);
          break;
        case Tag::start:
          switch (mState) {
            case StreamDescriptor::State::STANDBY:
              startDriver();
              mState = StreamDescriptor::State::IDLE;
              populateReply(&reply);
              break;
            case StreamDescriptor::State::PAUSED:
              mState = StreamDescriptor::State::ACTIVE;
              populateReply(&reply);
              break;
            case StreamDescriptor::State::DRAIN_PAUSED:
              mState = StreamDescriptor::State::DRAINING;
              populateReply(&reply);
              break;
            default:
              wrongState(&reply, "start");
          }
          break;
        case Tag::burst: {
          const int32_t requested = command.get<Tag::burst>();
          if (requested < 0) {
            klogf("[%s] invalid burst byte count %d", mLabel.c_str(), requested);
            break;
          }
          if (mState == StreamDescriptor::State::ERROR) {
            wrongState(&reply, "burst");
            break;
          }
          transfer(static_cast<size_t>(requested), &reply);
          if (mState == StreamDescriptor::State::STANDBY ||
              mState == StreamDescriptor::State::PAUSED ||
              mState == StreamDescriptor::State::DRAIN_PAUSED) {
            mState = StreamDescriptor::State::PAUSED;
          } else if (mState == StreamDescriptor::State::IDLE ||
                     mState == StreamDescriptor::State::ACTIVE ||
                     mState == StreamDescriptor::State::DRAINING) {
            mState = StreamDescriptor::State::ACTIVE;
          }
        } break;
        case Tag::drain: {
          const auto mode = command.get<Tag::drain>();
          if (mode != StreamDescriptor::DrainMode::DRAIN_ALL &&
              mode != StreamDescriptor::DrainMode::DRAIN_EARLY_NOTIFY) {
            klogf("[%s] invalid drain mode %d for an output stream", mLabel.c_str(),
                  static_cast<int>(mode));
            break;
          }
          if (mState == StreamDescriptor::State::ACTIVE) {
            usleep(static_cast<useconds_t>(mBufferSizeFrames * 1000000LL / kSampleRate));
            mState = StreamDescriptor::State::IDLE;
            populateReply(&reply);
          } else {
            wrongState(&reply, "drain");
          }
        } break;
        case Tag::standby:
          if (mState == StreamDescriptor::State::IDLE) {
            mSink.disconnect();
            mState = StreamDescriptor::State::STANDBY;
            populateReply(&reply);
          } else {
            wrongState(&reply, "standby");
          }
          break;
        case Tag::pause:
          if (mState == StreamDescriptor::State::ACTIVE) {
            mState = StreamDescriptor::State::PAUSED;
            populateReply(&reply);
          } else if (mState == StreamDescriptor::State::DRAINING) {
            mState = StreamDescriptor::State::DRAIN_PAUSED;
            populateReply(&reply);
          } else {
            wrongState(&reply, "pause");
          }
          break;
        case Tag::flush:
          if (mState == StreamDescriptor::State::PAUSED ||
              mState == StreamDescriptor::State::DRAIN_PAUSED) {
            mState = StreamDescriptor::State::IDLE;
            populateReply(&reply);
          } else {
            wrongState(&reply, "flush");
          }
          break;
        default:
          klogf("[%s] unhandled command tag %d", mLabel.c_str(),
                static_cast<int>(command.getTag()));
          break;
      }
      reply.state = mState;
      if (!mReplyMQ->writeBlocking(&reply, 1)) {
        klogf("[%s] reply FMQ write failed", mLabel.c_str());
        mState = StreamDescriptor::State::ERROR;
        return;
      }
    }
  }

  // record the start time and connect the sink
  void startDriver() {
    mStartTimeNs = monotonicNs();
    mFramesSinceStart = 0;
    mSink.connect();
  }

  const int32_t mPortConfigId;
  const std::string mLabel;
  const int64_t mBufferSizeFrames;
  std::unique_ptr<CommandMQ> mCommandMQ;
  std::unique_ptr<ReplyMQ> mReplyMQ;
  std::unique_ptr<DataMQ> mDataMQ;
  HostSink mSink;
  std::vector<uint8_t> mDataBuffer;
  std::thread mWorker;
  std::shared_ptr<RhizoStreamCommon> mCommon;
  std::vector<float> mHwVolume{1.0f, 1.0f};

  StreamDescriptor::State mState = StreamDescriptor::State::STANDBY;
  int64_t mStartTimeNs = 0;
  uint64_t mFramesSinceStart = 0;
  uint64_t mFrameCount = 0;
  std::atomic<bool> mExiting{false};
};

// input stream from the host microphone
class RhizoStreamIn : public BnStreamIn {
 public:
  // construct the input stream
  RhizoStreamIn(int32_t portConfigId, int64_t bufferSizeFrames)
      : mPortConfigId(portConfigId),
        mBufferSizeFrames(bufferSizeFrames),
        mCommandMQ(new CommandMQ(1, true  )),
        mReplyMQ(new ReplyMQ(1, true  )),
        mDataMQ(new DataMQ(kFrameSizeBytes * bufferSizeFrames)),
        mBuffer(kFrameSizeBytes * bufferSizeFrames, 0) {}

  ~RhizoStreamIn() override { stopWorker(); }

  // return whether all three queues are valid
  bool isValid() const {
    return mCommandMQ->isValid() && mReplyMQ->isValid() && mDataMQ->isValid();
  }

  // fill the stream descriptor
  void fillDescriptor(StreamDescriptor* desc) {
    desc->command = mCommandMQ->dupeDesc();
    desc->reply = mReplyMQ->dupeDesc();
    desc->frameSizeBytes = kFrameSizeBytes;
    desc->bufferSizeFrames = mBufferSizeFrames;
    desc->audio.set<StreamDescriptor::AudioBuffer::Tag::fmq>(mDataMQ->dupeDesc());
  }

  // start the worker thread at its priority
  void startWorker() {
    mWorker = std::thread([this] {
      SetWorkerPriority("record", "rhizo-aud-rec");
      workerLoop();
    });
  }

  // set the exit flag and join the thread
  void stopWorker() {
    if (!mWorker.joinable()) return;
    mExiting = true;
    mWorker.join();
  }

  int32_t portConfigId() const { return mPortConfigId; }

  // return the IStreamCommon object
  ScopedAStatus getStreamCommon(std::shared_ptr<IStreamCommon>* out) override {
    if (mCommon == nullptr) mCommon = ndk::SharedRefBase::make<RhizoStreamCommon>(mPortConfigId);
    *out = mCommon;
    return ScopedAStatus::ok();
  }
  // ignore the metadata
  ScopedAStatus updateMetadata(const SinkMetadata&) override {
    return ScopedAStatus::ok();
  }
  // clear the microphone list
  ScopedAStatus getActiveMicrophones(std::vector<MicrophoneDynamicInfo>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }
  // report that the operation is unsupported
  ScopedAStatus getMicrophoneDirection(IStreamIn::MicrophoneDirection*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setMicrophoneDirection(IStreamIn::MicrophoneDirection) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus getMicrophoneFieldDimension(float*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setMicrophoneFieldDimension(float) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus getHwGain(std::vector<float>*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setHwGain(const std::vector<float>&) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }

 private:
  static constexpr int64_t kCommandPollNs = 200LL * 1000 * 1000;

  // fill a reply with the frame count, time and latency
  void populateReply(StreamDescriptor::Reply* reply) {
    reply->status = STATUS_OK;
    reply->observable.frames = mFrameCount;
    reply->observable.timeNs = monotonicNs();
    reply->latencyMs = kNominalLatencyMs;
    reply->xrunFrames = 0;
  }

  // log the rejected command and set an invalid-operation status
  void wrongState(StreamDescriptor::Reply* reply, const char* cmd) {
    klogf("[record] command %s rejected in state %d", cmd, static_cast<int>(mState));
    reply->status = STATUS_INVALID_OPERATION;
  }

  // write the microphone's frames to the data queue
  void produce(size_t bytes, StreamDescriptor::Reply* reply) {
    const size_t byteCount = std::min({bytes, mDataMQ->availableToWrite(), mBuffer.size()});
    const size_t got = mSource.read(mBuffer.data(), byteCount);
    if (got < byteCount) std::fill(mBuffer.begin() + got, mBuffer.begin() + byteCount, 0);
    mHostFrames += got / kFrameSizeBytes;
    if (byteCount > 0 &&
        !mDataMQ->write(reinterpret_cast<const int8_t*>(mBuffer.data()), byteCount)) {
      klogf("[record] data FMQ write of %zu bytes failed", byteCount);
      reply->status = STATUS_NOT_ENOUGH_DATA;
      return;
    }
    const size_t frames = byteCount / kFrameSizeBytes;
    mFramesSinceStart += frames;
    mFrameCount += frames;
    const int64_t bufferDurationUs = static_cast<int64_t>(frames) * 1000000LL / kSampleRate;
    const int64_t elapsedUs = (monotonicNs() - mStartTimeNs) / 1000;
    const int64_t offsetUs = mFramesSinceStart * 1000000LL / kSampleRate - elapsedUs;
    if (offsetUs > 0) usleep(static_cast<useconds_t>(std::min(offsetUs, bufferDurationUs)));
    reply->fmqByteCount += static_cast<int32_t>(byteCount);
    populateReply(reply);
  }

  // run the input stream command loop
  void workerLoop() {
    while (true) {
      if (mExiting) {
        mSource.disconnect();
        klogf("[record] worker exiting (%llu frames, %llu from the host microphone)",
              static_cast<unsigned long long>(mFrameCount),
              static_cast<unsigned long long>(mHostFrames));
        return;
      }
      StreamDescriptor::Command command;
      if (!mCommandMQ->readBlocking(&command, 1, kCommandPollNs)) {
        continue;
      }
      StreamDescriptor::Reply reply{};
      reply.status = STATUS_BAD_VALUE;
      using Tag = StreamDescriptor::Command::Tag;
      switch (command.getTag()) {
        case Tag::halReservedExit:
          if (command.get<Tag::halReservedExit>() == kExitCookie && mExiting) {
            mSource.disconnect();
            klogf("[record] worker exiting (%llu frames, %llu from the host microphone)",
                  static_cast<unsigned long long>(mFrameCount),
                  static_cast<unsigned long long>(mHostFrames));
            return;
          }
          break;
        case Tag::getStatus:
          populateReply(&reply);
          break;
        case Tag::start: {
          const bool wasStandby = mState == StreamDescriptor::State::STANDBY;
          if (wasStandby || mState == StreamDescriptor::State::DRAINING) {
            if (wasStandby) {
              mStartTimeNs = monotonicNs();
              mFramesSinceStart = 0;
              mSource.resetNotes();
              mSource.connect();
            }
            mState = wasStandby ? StreamDescriptor::State::IDLE
                                : StreamDescriptor::State::ACTIVE;
            populateReply(&reply);
          } else {
            wrongState(&reply, "start");
          }
        } break;
        case Tag::burst: {
          const int32_t requested = command.get<Tag::burst>();
          if (requested < 0) {
            klogf("[record] invalid burst byte count %d", requested);
            break;
          }
          if (mState == StreamDescriptor::State::IDLE ||
              mState == StreamDescriptor::State::ACTIVE ||
              mState == StreamDescriptor::State::PAUSED ||
              mState == StreamDescriptor::State::DRAINING) {
            const bool wasDraining = mState == StreamDescriptor::State::DRAINING;
            produce(static_cast<size_t>(requested), &reply);
            if (wasDraining) {
              mSource.disconnect();
              mState = StreamDescriptor::State::STANDBY;
            } else {
              mState = StreamDescriptor::State::ACTIVE;
            }
          } else {
            wrongState(&reply, "burst");
          }
        } break;
        case Tag::drain: {
          const auto mode = command.get<Tag::drain>();
          if (mode != StreamDescriptor::DrainMode::DRAIN_UNSPECIFIED) {
            klogf("[record] invalid drain mode %d for an input stream",
                  static_cast<int>(mode));
            break;
          }
          if (mState == StreamDescriptor::State::ACTIVE) {
            mState = StreamDescriptor::State::DRAINING;
            populateReply(&reply);
          } else {
            wrongState(&reply, "drain");
          }
        } break;
        case Tag::standby:
          if (mState == StreamDescriptor::State::IDLE) {
            mSource.disconnect();
            mState = StreamDescriptor::State::STANDBY;
            populateReply(&reply);
          } else {
            wrongState(&reply, "standby");
          }
          break;
        case Tag::pause:
          if (mState == StreamDescriptor::State::ACTIVE) {
            mState = StreamDescriptor::State::PAUSED;
            populateReply(&reply);
          } else {
            wrongState(&reply, "pause");
          }
          break;
        case Tag::flush:
          if (mState == StreamDescriptor::State::PAUSED) {
            mSource.disconnect();
            mState = StreamDescriptor::State::STANDBY;
            populateReply(&reply);
          } else {
            wrongState(&reply, "flush");
          }
          break;
        default:
          klogf("[record] unhandled command tag %d", static_cast<int>(command.getTag()));
          break;
      }
      reply.state = mState;
      if (!mReplyMQ->writeBlocking(&reply, 1)) {
        klogf("[record] reply FMQ write failed");
        mState = StreamDescriptor::State::ERROR;
        return;
      }
    }
  }

  static constexpr int32_t kExitCookie = 0x52485A41;

  const int32_t mPortConfigId;
  const int64_t mBufferSizeFrames;
  std::unique_ptr<CommandMQ> mCommandMQ;
  std::unique_ptr<ReplyMQ> mReplyMQ;
  std::unique_ptr<DataMQ> mDataMQ;
  HostSource mSource;
  std::vector<uint8_t> mBuffer;
  uint64_t mHostFrames = 0;
  std::thread mWorker;
  std::shared_ptr<RhizoStreamCommon> mCommon;

  StreamDescriptor::State mState = StreamDescriptor::State::STANDBY;
  int64_t mStartTimeNs = 0;
  uint64_t mFramesSinceStart = 0;
  uint64_t mFrameCount = 0;
  std::atomic<bool> mExiting{false};
};

std::function<void(int32_t)> gCloseStream;

ScopedAStatus RhizoStreamCommon::close() {
  bool expected = false;
  if (!mClosed.compare_exchange_strong(expected, true)) {
    return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
  }
  if (gCloseStream) gCloseStream(mPortConfigId);
  return ScopedAStatus::ok();
}

constexpr int32_t kVolumeIndexFromAudioService = -1;

class RhizoConfig : public BnConfig {
 public:
  // return the surround sound config
  ScopedAStatus getSurroundSoundConfig(SurroundSoundConfig* out) override {
    AudioFormatDescription ac3;
    ac3.type = AudioFormatType::NON_PCM;
    ac3.encoding = "audio/ac3";
    AudioFormatDescription eac3;
    eac3.type = AudioFormatType::NON_PCM;
    eac3.encoding = "audio/eac3";
    SurroundSoundConfig::SurroundFormatFamily ac3Family;
    ac3Family.primaryFormat = ac3;
    ac3Family.subFormats = {eac3};
    *out = SurroundSoundConfig();
    out->formatFamilies = {ac3Family};
    return ScopedAStatus::ok();
  }
  // return the audio engine config
  ScopedAStatus getEngineConfig(AudioHalEngineConfig* out) override {
    *out = AudioHalEngineConfig();
    AudioHalVolumeGroup musicGroup;
    musicGroup.name = "AUDIO_STREAM_MUSIC";
    musicGroup.minIndex = kVolumeIndexFromAudioService;
    musicGroup.maxIndex = kVolumeIndexFromAudioService;
    for (auto category : {AudioHalVolumeCurve::DeviceCategory::HEADSET, AudioHalVolumeCurve::DeviceCategory::SPEAKER,
                          AudioHalVolumeCurve::DeviceCategory::EARPIECE, AudioHalVolumeCurve::DeviceCategory::EXT_MEDIA,
                          AudioHalVolumeCurve::DeviceCategory::HEARING_AID}) {
      AudioHalVolumeCurve curve;
      curve.deviceCategory = category;
      curve.curvePoints = {{0, 0}, {100, 0}};
      musicGroup.volumeCurves.push_back(curve);
    }
    out->volumeGroups = {musicGroup};
    return ScopedAStatus::ok();
  }
};

class RhizoModule : public BnModule {
 public:
  // build the port and route lists
  RhizoModule() : mPorts(makePorts()), mRoutes(makeRoutes()) {}

  // ignore the module debug setting
  ScopedAStatus setModuleDebug(const ModuleDebug&) override { return ScopedAStatus::ok(); }

  // set the telephony pointer to null
  ScopedAStatus getTelephony(std::shared_ptr<ITelephony>* out) override {
    *out = nullptr;
    return ScopedAStatus::ok();
  }
  // return no Bluetooth interface
  ScopedAStatus getBluetooth(std::shared_ptr<IBluetooth>* out) override {
    *out = nullptr;
    return ScopedAStatus::ok();
  }
  // return no Bluetooth A2DP interface
  ScopedAStatus getBluetoothA2dp(std::shared_ptr<IBluetoothA2dp>* out) override {
    *out = nullptr;
    return ScopedAStatus::ok();
  }
  // return no Bluetooth LE interface
  ScopedAStatus getBluetoothLe(std::shared_ptr<IBluetoothLe>* out) override {
    *out = nullptr;
    return ScopedAStatus::ok();
  }
  // return no sound dose interface
  ScopedAStatus getSoundDose(
      std::shared_ptr<aidl::android::hardware::audio::core::sounddose::ISoundDose>* out)
      override {
    *out = nullptr;
    return ScopedAStatus::ok();
  }

  // reject connecting an external device
  ScopedAStatus connectExternalDevice(const AudioPort&, AudioPort*) override {
    return illegalArgument("no external devices on this module");
  }
  // reject disconnecting an external device
  ScopedAStatus disconnectExternalDevice(int32_t) override {
    return illegalArgument("no external devices on this module");
  }

  // return the audio ports
  ScopedAStatus getAudioPorts(std::vector<AudioPort>* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    klogf("getAudioPorts -> %zu ports", mPorts.size());
    *out = mPorts;
    return ScopedAStatus::ok();
  }
  // return the audio port with the given id
  ScopedAStatus getAudioPort(int32_t id, AudioPort* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    for (const auto& p : mPorts) {
      if (p.id == id) {
        *out = p;
        return ScopedAStatus::ok();
      }
    }
    return illegalArgument("unknown port id");
  }
  // return the audio routes
  ScopedAStatus getAudioRoutes(std::vector<AudioRoute>* out) override {
    klogf("getAudioRoutes -> %zu routes", mRoutes.size());
    *out = mRoutes;
    return ScopedAStatus::ok();
  }
  // return the routes that use a port as sink or source
  ScopedAStatus getAudioRoutesForAudioPort(int32_t portId,
                                           std::vector<AudioRoute>* out) override {
    out->clear();
    bool known = false;
    for (const auto& p : mPorts) known |= (p.id == portId);
    if (!known) return illegalArgument("unknown port id");
    for (const auto& r : mRoutes) {
      if (r.sinkPortId == portId) {
        out->push_back(r);
        continue;
      }
      for (int32_t src : r.sourcePortIds) {
        if (src == portId) {
          out->push_back(r);
          break;
        }
      }
    }
    return ScopedAStatus::ok();
  }

  // return the port configs
  ScopedAStatus getAudioPortConfigs(std::vector<AudioPortConfig>* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    out->clear();
    for (const auto& [id, cfg] : mPortConfigs) out->push_back(cfg);
    klogf("getAudioPortConfigs -> %zu configs (%zu open output streams, %zu open input streams)",
          out->size(), mStreams.size(), mInputStreams.size());
    return ScopedAStatus::ok();
  }

  // create or update a port config
  ScopedAStatus setAudioPortConfig(const AudioPortConfig& requested, AudioPortConfig* suggested,
                                   bool* applied) override {
    std::lock_guard<std::mutex> lock(mLock);
    klogf("setAudioPortConfig id=%d portId=%d", requested.id, requested.portId);
    *applied = false;
    const AudioPort* port = nullptr;
    int32_t portId = requested.portId;
    if (requested.id != 0) {
      auto it = mPortConfigs.find(requested.id);
      if (it == mPortConfigs.end()) return illegalArgument("unknown port config id");
      portId = it->second.portId;
    }
    for (const auto& p : mPorts) {
      if (p.id == portId) port = &p;
    }
    if (port == nullptr) return illegalArgument("unknown port id");

    AudioPortConfig cfg;
    cfg.id = requested.id != 0 ? requested.id : mNextPortConfigId++;
    cfg.portId = port->id;
    cfg.sampleRate = Int{.value = kSampleRate};
    cfg.channelMask = stereo();
    cfg.format = pcm16();
    cfg.flags = port->flags;
    cfg.ext = port->ext;
    if (port->ext.getTag() == AudioPortExt::mix) {
      auto mix = port->ext.get<AudioPortExt::mix>();
      if (requested.ext.getTag() == AudioPortExt::mix) {
        mix.handle = requested.ext.get<AudioPortExt::mix>().handle;
      }
      cfg.ext = AudioPortExt::make<AudioPortExt::mix>(mix);
    }

    if (requested.sampleRate.has_value() && requested.sampleRate.value().value != kSampleRate) {
      *suggested = cfg;
      return ScopedAStatus::ok();
    }
    if (requested.format.has_value() && requested.format.value() != pcm16()) {
      *suggested = cfg;
      return ScopedAStatus::ok();
    }
    if (requested.channelMask.has_value() && requested.channelMask.value() != stereo()) {
      *suggested = cfg;
      return ScopedAStatus::ok();
    }
    if (requested.id == 0 &&
        (!requested.sampleRate.has_value() || !requested.channelMask.has_value() ||
         !requested.format.has_value())) {
      cfg.id = 0;
      *suggested = cfg;
      return ScopedAStatus::ok();
    }

    mPortConfigs[cfg.id] = cfg;
    *suggested = cfg;
    *applied = true;
    return ScopedAStatus::ok();
  }

  // erase a port config
  ScopedAStatus resetAudioPortConfig(int32_t id) override {
    std::lock_guard<std::mutex> lock(mLock);
    if (mPortConfigs.count(id) == 0) return illegalArgument("unknown port config id");
    if (mStreams.count(id) != 0 || mInputStreams.count(id) != 0) {
      return illegalState("port config has an open stream");
    }
    for (const auto& [patchId, patch] : mPatches) {
      (void)patchId;
      if (std::find(patch.sourcePortConfigIds.begin(), patch.sourcePortConfigIds.end(), id) !=
              patch.sourcePortConfigIds.end() ||
          std::find(patch.sinkPortConfigIds.begin(), patch.sinkPortConfigIds.end(), id) !=
              patch.sinkPortConfigIds.end()) {
        return illegalState("port config is used by a patch");
      }
    }
    mPortConfigs.erase(id);
    return ScopedAStatus::ok();
  }

  // return the audio patches
  ScopedAStatus getAudioPatches(std::vector<AudioPatch>* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    out->clear();
    for (const auto& [id, patch] : mPatches) out->push_back(patch);
    return ScopedAStatus::ok();
  }

  // create or update an audio patch
  ScopedAStatus setAudioPatch(const AudioPatch& requested, AudioPatch* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    klogf("setAudioPatch id=%d", requested.id);
    AudioPatch patch = requested;
    if (patch.sourcePortConfigIds.empty() || patch.sinkPortConfigIds.empty()) {
      return illegalArgument("empty source or sink port config list");
    }
    if (std::set<int32_t>(patch.sourcePortConfigIds.begin(), patch.sourcePortConfigIds.end())
                .size() != patch.sourcePortConfigIds.size() ||
        std::set<int32_t>(patch.sinkPortConfigIds.begin(), patch.sinkPortConfigIds.end()).size() !=
            patch.sinkPortConfigIds.size()) {
      return illegalArgument("duplicate port config id in patch");
    }
    for (int32_t cfgId : patch.sourcePortConfigIds) {
      if (mPortConfigs.count(cfgId) == 0) return illegalArgument("unknown source port config");
    }
    for (int32_t cfgId : patch.sinkPortConfigIds) {
      if (mPortConfigs.count(cfgId) == 0) return illegalArgument("unknown sink port config");
    }
    if (patch.id != 0 && mPatches.count(patch.id) == 0) {
      return illegalArgument("unknown patch id");
    }
    for (int32_t sinkCfgId : patch.sinkPortConfigIds) {
      const int32_t sinkPortId = mPortConfigs[sinkCfgId].portId;
      const AudioRoute* route = nullptr;
      for (const auto& r : mRoutes) {
        if (r.sinkPortId == sinkPortId) {
          route = &r;
          break;
        }
      }
      if (route == nullptr) return illegalArgument("no route to the requested sink");
      for (int32_t srcCfgId : patch.sourcePortConfigIds) {
        const int32_t srcPortId = mPortConfigs[srcCfgId].portId;
        if (std::find(route->sourcePortIds.begin(), route->sourcePortIds.end(), srcPortId) ==
            route->sourcePortIds.end()) {
          return illegalArgument("route does not connect this source to this sink");
        }
      }
    }
    if (patch.id == 0) patch.id = mNextPatchId++;
    patch.latenciesMs.assign(patch.sinkPortConfigIds.size(), kNominalLatencyMs);
    patch.minimumStreamBufferSizeFrames = static_cast<int32_t>(kMinBufferSizeFrames);
    mPatches[patch.id] = patch;
    *out = patch;
    return ScopedAStatus::ok();
  }

  // remove the audio patch with the given id
  ScopedAStatus resetAudioPatch(int32_t id) override {
    std::lock_guard<std::mutex> lock(mLock);
    if (mPatches.erase(id) == 0) return illegalArgument("unknown patch id");
    return ScopedAStatus::ok();
  }

  // open an input stream, rejecting an output port config
  ScopedAStatus openInputStream(const IModule::OpenInputStreamArguments& args,
                                IModule::OpenInputStreamReturn* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    auto cfgIt = mPortConfigs.find(args.portConfigId);
    if (cfgIt == mPortConfigs.end()) return illegalArgument("unknown port config id");
    const AudioPortConfig& cfg = cfgIt->second;
    if (cfg.ext.getTag() != AudioPortExt::mix) {
      return illegalArgument("port config is not a mix port");
    }
    if (!cfg.flags.has_value() || cfg.flags->getTag() != AudioIoFlags::input) {
      return illegalArgument("port config is not an input mix port");
    }
    if (mInputStreams.count(args.portConfigId) != 0) {
      return illegalState("port config already has an open stream");
    }
    int64_t bufferSizeFrames = args.bufferSizeFrames;
    if (bufferSizeFrames < kMinBufferSizeFrames || bufferSizeFrames > kMaxBufferSizeFrames) {
      klogf("rejecting record buffer size %lld frames (allowed %lld..%lld)",
            static_cast<long long>(bufferSizeFrames), static_cast<long long>(kMinBufferSizeFrames),
            static_cast<long long>(kMaxBufferSizeFrames));
      return illegalArgument("unsupported buffer size");
    }

    auto stream = ndk::SharedRefBase::make<RhizoStreamIn>(cfg.id, bufferSizeFrames);
    if (!stream->isValid()) {
      klogf("[record] stream FMQ setup failed");
      return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    stream->fillDescriptor(&out->desc);
    stream->startWorker();
    mInputStreams[args.portConfigId] = stream;
    out->stream = stream;
    klogf("[record] input stream open (portConfig=%d, %lld frames)", cfg.id,
          static_cast<long long>(bufferSizeFrames));
    return ScopedAStatus::ok();
  }

  // open an output stream, rejecting an input port config
  ScopedAStatus openOutputStream(const IModule::OpenOutputStreamArguments& args,
                                 IModule::OpenOutputStreamReturn* out) override {
    std::lock_guard<std::mutex> lock(mLock);
    auto cfgIt = mPortConfigs.find(args.portConfigId);
    if (cfgIt == mPortConfigs.end()) return illegalArgument("unknown port config id");
    const AudioPortConfig& cfg = cfgIt->second;
    if (cfg.ext.getTag() != AudioPortExt::mix) {
      return illegalArgument("port config is not a mix port");
    }
    if (!cfg.flags.has_value() || cfg.flags->getTag() != AudioIoFlags::output) {
      return illegalArgument("port config is not an output mix port");
    }
    if (mStreams.count(args.portConfigId) != 0) {
      return illegalState("port config already has an open stream");
    }
    int64_t bufferSizeFrames = args.bufferSizeFrames;
    if (bufferSizeFrames < kMinBufferSizeFrames || bufferSizeFrames > kMaxBufferSizeFrames) {
      klogf("rejecting buffer size %lld frames (allowed %lld..%lld)",
            static_cast<long long>(bufferSizeFrames), static_cast<long long>(kMinBufferSizeFrames),
            static_cast<long long>(kMaxBufferSizeFrames));
      return illegalArgument("unsupported buffer size");
    }

    auto stream = ndk::SharedRefBase::make<RhizoStreamOut>(cfg.id, cfg.portId, bufferSizeFrames);
    if (!stream->isValid()) {
      klogf("[%s] stream FMQ setup failed", stream->label().c_str());
      return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    stream->fillDescriptor(&out->desc);
    stream->startWorker();
    mStreams[args.portConfigId] = stream;
    out->stream = stream;
    klogf("[%s] output stream open (portConfig=%d, %lld frames)", stream->label().c_str(), cfg.id,
          static_cast<long long>(bufferSizeFrames));
    return ScopedAStatus::ok();
  }

  // erase the stream and stop its thread
  void closeStream(int32_t portConfigId) {
    std::shared_ptr<RhizoStreamOut> outStream;
    std::shared_ptr<RhizoStreamIn> inStream;
    {
      std::lock_guard<std::mutex> lock(mLock);
      if (auto it = mStreams.find(portConfigId); it != mStreams.end()) {
        outStream = it->second;
        mStreams.erase(it);
      } else if (auto it2 = mInputStreams.find(portConfigId); it2 != mInputStreams.end()) {
        inStream = it2->second;
        mInputStreams.erase(it2);
      } else {
        return;
      }
    }
    if (outStream) {
      klogf("[%s] closing stream", outStream->label().c_str());
      outStream->stopWorker();
    } else {
      klogf("[record] closing stream");
      inStream->stopWorker();
    }
  }

  // return empty playback rate factors
  ScopedAStatus getSupportedPlaybackRateFactors(
      IModule::SupportedPlaybackRateFactors* out) override {
    *out = IModule::SupportedPlaybackRateFactors();
    return ScopedAStatus::ok();
  }

  // return the master mute
  ScopedAStatus getMasterMute(bool* out) override {
    *out = mMasterMute;
    return ScopedAStatus::ok();
  }
  // store the master mute state
  ScopedAStatus setMasterMute(bool mute) override {
    mMasterMute = mute;
    return ScopedAStatus::ok();
  }
  // return the master volume
  ScopedAStatus getMasterVolume(float* out) override {
    *out = mMasterVolume;
    return ScopedAStatus::ok();
  }
  // set the master volume
  ScopedAStatus setMasterVolume(float volume) override {
    if (!std::isfinite(volume) || volume < 0.0f || volume > 1.0f) {
      return illegalArgument("master volume out of range");
    }
    mMasterVolume = volume;
    return ScopedAStatus::ok();
  }
  // return the microphone mute state
  ScopedAStatus getMicMute(bool* out) override {
    *out = mMicMute;
    return ScopedAStatus::ok();
  }
  // set the microphone mute
  ScopedAStatus setMicMute(bool mute) override {
    mMicMute = mute;
    return ScopedAStatus::ok();
  }
  // report microphone info as unsupported
  ScopedAStatus getMicrophones(std::vector<MicrophoneInfo>* out) override {
    (void)out;
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }

  // check the audio mode
  ScopedAStatus updateAudioMode(AudioMode mode) override {
    if (!isValidAudioMode(mode)) {
      return illegalArgument("invalid audio mode");
    }
    return ScopedAStatus::ok();
  }
  // ignore the screen rotation
  ScopedAStatus updateScreenRotation(IModule::ScreenRotation) override {
    return ScopedAStatus::ok();
  }
  // ignore the screen state
  ScopedAStatus updateScreenState(bool) override { return ScopedAStatus::ok(); }

  // report that the operation is unsupported
  ScopedAStatus generateHwAvSyncId(int32_t*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // return an unsupported operation error
  ScopedAStatus getVendorParameters(const std::vector<std::string>&,
                                    std::vector<VendorParameter>*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus setVendorParameters(const std::vector<VendorParameter>&, bool) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus addDeviceEffect(
      int32_t, const std::shared_ptr<aidl::android::hardware::audio::effect::IEffect>&) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus removeDeviceEffect(
      int32_t, const std::shared_ptr<aidl::android::hardware::audio::effect::IEffect>&) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // clear the MMAP policy list
  ScopedAStatus getMmapPolicyInfos(AudioMMapPolicyType,
                                   std::vector<AudioMMapPolicyInfo>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }
  // report that variable latency is unsupported
  ScopedAStatus supportsVariableLatency(bool* out) override {
    *out = false;
    return ScopedAStatus::ok();
  }
  // report that the operation is unsupported
  ScopedAStatus getAAudioMixerBurstCount(int32_t*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // report that the operation is unsupported
  ScopedAStatus getAAudioHardwareBurstMinUsec(int32_t*) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }

 private:
  std::mutex mLock;
  const std::vector<AudioPort> mPorts;
  const std::vector<AudioRoute> mRoutes;
  std::map<int32_t, AudioPortConfig> mPortConfigs;
  std::map<int32_t, AudioPatch> mPatches;
  std::map<int32_t, std::shared_ptr<RhizoStreamOut>> mStreams;
  std::map<int32_t, std::shared_ptr<RhizoStreamIn>> mInputStreams;
  int32_t mNextPortConfigId = 100;
  int32_t mNextPatchId = 200;
  bool mMasterMute = false;
  float mMasterVolume = 1.0f;
  bool mMicMute = false;
  std::set<int32_t> mInitialPortConfigIds;
};

}

// register IConfig and IModule
int main() {
  klogf("main() entered, pid=%d", getpid());
  loadBusCount();
  auto config = ndk::SharedRefBase::make<RhizoConfig>();
  auto module = ndk::SharedRefBase::make<RhizoModule>();
  gCloseStream = [module](int32_t portConfigId) { module->closeStream(portConfigId); };

  const std::string configInstance = std::string(RhizoConfig::descriptor) + "/default";
  const std::string moduleInstance = std::string(RhizoModule::descriptor) + "/default";
  binder_status_t status =
      AServiceManager_addService(config->asBinder().get(), configInstance.c_str());
  if (status != STATUS_OK) {
    klogf("IConfig addService FAILED status=%d", status);
    return 1;
  }
  status = AServiceManager_addService(module->asBinder().get(), moduleInstance.c_str());
  if (status != STATUS_OK) {
    klogf("IModule addService FAILED status=%d", status);
    return 1;
  }
  klogf("registered IConfig/default + IModule/default with %d buses, joining thread pool",
        gBusCount);
  ABinderProcess_setThreadPoolMaxThreadCount(0);
  ABinderProcess_joinThreadPool();
  klogf("joinThreadPool RETURNED (unexpected)");
  return 0;
}

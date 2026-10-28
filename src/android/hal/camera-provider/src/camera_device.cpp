#include "camera_device.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>

#include <aidl/android/hardware/camera/common/Status.h>
#include <aidl/android/hardware/graphics/common/BufferUsage.h>
#include <aidl/android/hardware/graphics/common/Dataspace.h>
#include <aidl/android/hardware/graphics/common/PixelFormat.h>

#ifdef __ANDROID__
#include <sys/system_properties.h>
#endif

#include "log.h"

namespace rhizo::camera {

namespace {

using ::aidl::android::hardware::camera::common::CameraResourceCost;
using ::aidl::android::hardware::camera::common::Status;
using ::aidl::android::hardware::common::NativeHandle;
using ::aidl::android::hardware::common::fmq::MQDescriptor;
using ::aidl::android::hardware::common::fmq::SynchronizedReadWrite;
using ::aidl::android::hardware::graphics::common::BufferUsage;
using ::aidl::android::hardware::graphics::common::Dataspace;
using ::aidl::android::hardware::graphics::common::PixelFormat;
using ndk::ScopedAStatus;

constexpr int kFenceTimeoutMs = 1000;
constexpr int kStartTimeoutMs = 10500;
constexpr int kFirstFrameTimeoutMs = 3000;
constexpr int kFrameTimeoutMs = 1500;
constexpr int kStoppedRetryMs = 100;
constexpr int kIdleWaitMs = 2000;
constexpr size_t kMetadataQueueBytes = 1 << 20;
constexpr int64_t kNsPerSecond = 1000000000LL;
constexpr int64_t kGpuUsage = static_cast<int64_t>(BufferUsage::GPU_TEXTURE) |
                              static_cast<int64_t>(BufferUsage::GPU_RENDER_TARGET) |
                              static_cast<int64_t>(BufferUsage::COMPOSER_OVERLAY);

ScopedAStatus Error(Status s) { return ScopedAStatus::fromServiceSpecificError(static_cast<int32_t>(s)); }

int64_t MonotonicNs() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return int64_t(ts.tv_sec) * kNsPerSecond + ts.tv_nsec;
}

// return whether two host modes are the same
bool SameMode(const HostMode& a, const HostMode& b) {
  return a.width == b.width && a.height == b.height && a.fpsNum == b.fpsNum && a.fpsDen == b.fpsDen;
}

// wrap a fence fd in a NativeHandle
NativeHandle FenceHandle(int fd) {
  NativeHandle h;
  if (fd >= 0) h.fds.emplace_back(fd);
  return h;
}

// return the local time in Exif format
std::string ExifDateTime() {
  time_t now = time(nullptr);
  tm local{};
  localtime_r(&now, &local);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y:%m:%d %H:%M:%S", &local);
  return buf;
}

// return a product property, its vendor variant or the fallback
std::string BuildProperty(const char* name, const char* vendorName, const char* fallback) {
#ifdef __ANDROID__
  char value[PROP_VALUE_MAX] = {};
  if (__system_property_get(name, value) > 0) return value;
  if (__system_property_get(vendorName, value) > 0) return value;
#else
  (void)name;
  (void)vendorName;
#endif
  return fallback;
}

// return the metadata id of a request template
int32_t TemplateId(device::RequestTemplate t) { return static_cast<int32_t>(t); }

// duplicate a NativeHandle into a native_handle_t
native_handle_t* DupHandle(const NativeHandle& h) {
  native_handle_t* nh = native_handle_create(static_cast<int>(h.fds.size()), static_cast<int>(h.ints.size()));
  if (nh == nullptr) return nullptr;
  for (size_t i = 0; i < h.fds.size(); i++) {
    nh->data[i] = dup(h.fds[i].get());
    if (nh->data[i] < 0) {
      for (size_t j = 0; j < i; j++) ::close(nh->data[j]);
      native_handle_delete(nh);
      return nullptr;
    }
  }
  if (!h.ints.empty()) memcpy(&nh->data[h.fds.size()], h.ints.data(), h.ints.size() * sizeof(int32_t));
  return nh;
}

}

// return why a configuration is not supported, or empty
std::string CheckStreams(const CameraShape& shape, const device::StreamConfiguration& config) {
  if (config.operationMode != device::StreamConfigurationMode::NORMAL_MODE) return "only NORMAL_MODE";
  if (config.streams.empty()) return "no streams";
  int processed = 0, stalling = 0;
  for (const device::Stream& s : config.streams) {
    if (s.streamType != device::StreamType::OUTPUT) return "input streams are not supported (no reprocessing)";
    if (s.rotation != device::StreamRotation::ROTATION_0) return "stream rotation is not supported";
    if (!s.physicalCameraId.empty()) return "no physical cameras";
    if (!ShapeHasSize(shape, s.width, s.height)) {
      return "size " + std::to_string(s.width) + "x" + std::to_string(s.height) + " is not offered";
    }
    switch (s.format) {
      case PixelFormat::BLOB:
        if (s.dataSpace != Dataspace::JFIF) return "BLOB is offered only as JFIF JPEG";
        stalling++;
        break;
      case PixelFormat::IMPLEMENTATION_DEFINED:
      case PixelFormat::YCBCR_420_888:
        processed++;
        break;
      default:
        return "format " + std::to_string(static_cast<int32_t>(s.format)) + " is not offered";
    }
  }
  if (processed > kMaxProcessedStreams) return "more than " + std::to_string(kMaxProcessedStreams) + " YUV/private streams";
  if (stalling > kMaxStallStreams) return "more than one JPEG stream";
  return "";
}

CameraSession::CameraSession(std::shared_ptr<CameraContext> ctx, CameradClient* client,
                             std::shared_ptr<device::ICameraDeviceCallback> callback)
    : ctx_(std::move(ctx)),
      client_(client),
      callback_(std::move(callback)),
      gralloc_(Gralloc::Get()),
      make_(BuildProperty("ro.product.manufacturer", "ro.product.vendor.manufacturer", "Rhizo")),
      model_(BuildProperty("ro.product.model", "ro.product.vendor.model", "Rhizo")),
      wakeFd_(eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK)) {
  if (wakeFd_ < 0) klogf("camera %s: eventfd failed (%s); fence waits run to their timeout", ctx_->id.c_str(), strerror(errno));
  requestQueue_ = std::make_unique<MetadataQueue>(kMetadataQueueBytes, false);
  resultQueue_ = std::make_unique<MetadataQueue>(kMetadataQueueBytes, false);
  if (!requestQueue_->isValid() || !resultQueue_->isValid()) {
    klogf("camera %s: metadata queues could not be made; settings and results go inline", ctx_->id.c_str());
    if (!requestQueue_->isValid()) requestQueue_.reset();
    if (!resultQueue_->isValid()) resultQueue_.reset();
  }
  worker_ = std::thread([this] { workerLoop(); });
  klogf("camera %s: session opened", ctx_->id.c_str());
}

CameraSession::~CameraSession() {
  close();
  if (worker_.joinable()) {
    if (worker_.get_id() == std::this_thread::get_id()) worker_.detach();
    else worker_.join();
  }
  if (wakeFd_ >= 0) ::close(wakeFd_);
}

// interrupt the worker's frame and fence waits
void CameraSession::wakeWorkerLocked() {
  if (mailbox_) mailbox_->interrupt();
  if (wakeFd_ >= 0) {
    uint64_t one = 1;
    ssize_t ignored = write(wakeFd_, &one, sizeof(one));
    (void)ignored;
  }
  queueCv_.notify_all();
}

bool CameraSession::isClosed() {
  std::lock_guard<std::mutex> lk(mu_);
  return closed_;
}

// open the host camera in a mode
void CameraSession::openStreamLocked(const HostMode& mode, int32_t maxFps) {
  mailbox_ = std::make_shared<FrameMailbox>(client_->nextStreamId());
  mode_ = mode;
  haveMode_ = true;
  lastOpen_ = std::chrono::steady_clock::now();
  openRate_ = ChooseOpenRate(mode.fpsNum, mode.fpsDen, maxFps, modeRateOnly_);
  HostMode asked = mode;
  asked.fpsNum = openRate_.fpsNum;
  asked.fpsDen = openRate_.fpsDen;
  if (client_->open(ctx_->host.key, asked, mailbox_)) {
    klogf("camera %s: OPEN stream %u at %ux%u %u/%u fps (mode %u/%u)", ctx_->id.c_str(), mailbox_->streamId(),
          asked.width, asked.height, asked.fpsNum, asked.fpsDen, mode.fpsNum, mode.fpsDen);
  } else {
    klogf("camera %s: OPEN stream %u failed: camerad is not connected", ctx_->id.c_str(), mailbox_->streamId());
    mailbox_->markStopped(-ENOTCONN);
  }
}

// release the host camera
void CameraSession::closeStreamLocked() {
  if (!mailbox_) return;
  client_->close(mailbox_->streamId());
  klogf("camera %s: CLOSE stream %u", ctx_->id.c_str(), mailbox_->streamId());
  mailbox_->interrupt();
  mailbox_.reset();
}

ScopedAStatus CameraSession::close() {
  std::deque<Request> drained;
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (closed_) return ScopedAStatus::ok();
    closed_ = true;
    stopping_ = true;
    flushing_ = true;
    drained.swap(queue_);
    wakeWorkerLocked();
  }
  if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) worker_.join();
  for (Request& r : drained) fail(r, "session closed");
  std::lock_guard<std::mutex> lk(mu_);
  closeStreamLocked();
  if (gralloc_ != nullptr) {
    for (auto& [key, handle] : buffers_) gralloc_->freeBuffer(handle);
  }
  buffers_.clear();
  streams_.clear();
  lastSettings_.reset();
  klogf("camera %s: session closed after %llu frames, %llu failed requests", ctx_->id.c_str(),
        static_cast<unsigned long long>(completed_), static_cast<unsigned long long>(failures_));
  return ScopedAStatus::ok();
}

ScopedAStatus CameraSession::configureStreams(const device::StreamConfiguration& config,
                                              std::vector<device::HalStream>* out) {
  return configure(config, out);
}

ScopedAStatus CameraSession::configureStreamsV2(const device::StreamConfiguration& config,
                                                device::ConfigureStreamsRet* out) {
  return configure(config, &out->halStreams);
}

// accept a stream set and open its host mode
ScopedAStatus CameraSession::configure(const device::StreamConfiguration& config,
                                       std::vector<device::HalStream>* out) {
  out->clear();
  std::string why = CheckStreams(ctx_->shape, config);
  if (!why.empty()) {
    klogf("camera %s: configureStreams refused: %s", ctx_->id.c_str(), why.c_str());
    return Error(Status::ILLEGAL_ARGUMENT);
  }
  std::unique_lock<std::mutex> lk(mu_);
  if (closed_) return Error(Status::INTERNAL_ERROR);
  if (!idleCv_.wait_for(lk, std::chrono::milliseconds(kIdleWaitMs), [this] { return queue_.empty() && !busy_; })) {
    klogf("camera %s: configureStreams with requests still in flight", ctx_->id.c_str());
    return Error(Status::INTERNAL_ERROR);
  }
  if (closed_) return Error(Status::INTERNAL_ERROR);
  std::map<int32_t, device::Stream> streams;
  const device::Stream* largest = nullptr;
  for (const device::Stream& s : config.streams) {
    streams[s.id] = s;
    if (largest == nullptr || int64_t(s.width) * s.height > int64_t(largest->width) * largest->height) largest = &s;
  }
  for (auto it = buffers_.begin(); it != buffers_.end();) {
    if (streams.count(it->first.first) == 0) {
      if (gralloc_ != nullptr) gralloc_->freeBuffer(it->second);
      it = buffers_.erase(it);
    } else {
      ++it;
    }
  }
  streams_ = streams;
  largestWidth_ = largest->width;
  largestHeight_ = largest->height;

  int m = ChooseMode(ctx_->host.modes, largestWidth_, largestHeight_, ctx_->shape.previewFps[1]);
  if (m < 0) return Error(Status::INTERNAL_ERROR);
  const HostMode& mode = ctx_->host.modes[static_cast<size_t>(m)];
  bool same = haveMode_ && SameMode(mode, mode_);
  if (!same || !mailbox_ || mailbox_->stopped()) {
    closeStreamLocked();
    openStreamLocked(mode, ctx_->shape.previewFps[1]);
  }

  const int64_t producer = static_cast<int64_t>(BufferUsage::CPU_WRITE_OFTEN) |
                           static_cast<int64_t>(BufferUsage::CAMERA_OUTPUT);
  for (const device::Stream& s : config.streams) {
    device::HalStream h;
    h.id = s.id;
    h.overrideFormat = s.format;
    h.overrideDataSpace = s.dataSpace;
    if (s.format == PixelFormat::IMPLEMENTATION_DEFINED) {
      int64_t consumer = static_cast<int64_t>(s.usage);
      bool encoder = (consumer & static_cast<int64_t>(BufferUsage::VIDEO_ENCODER)) != 0;
      if ((consumer & kGpuUsage) != 0 && !encoder) {
        h.overrideFormat = PixelFormat::RGBA_8888;
        h.overrideDataSpace = Dataspace::SRGB;
      } else {
        h.overrideFormat = PixelFormat::YCBCR_420_888;
        h.overrideDataSpace = Dataspace::JFIF;
      }
    }
    h.producerUsage = static_cast<BufferUsage>(producer);
    h.consumerUsage = static_cast<BufferUsage>(0);
    h.maxBuffers = kPipelineMaxDepth;
    h.supportOffline = false;
    h.enableHalBufferManager = false;
    klogf("camera %s: stream %d %dx%d format 0x%x usage 0x%llx -> 0x%x", ctx_->id.c_str(), s.id, s.width,
          s.height, static_cast<int32_t>(s.format), static_cast<unsigned long long>(s.usage),
          static_cast<int32_t>(h.overrideFormat));
    out->push_back(std::move(h));
  }
  return ScopedAStatus::ok();
}

ScopedAStatus CameraSession::constructDefaultRequestSettings(device::RequestTemplate type,
                                                             device::CameraMetadata* out) {
  out->metadata = BuildDefaultRequest(ctx_->shape, TemplateId(type));
  if (out->metadata.empty()) return Error(Status::ILLEGAL_ARGUMENT);
  return ScopedAStatus::ok();
}

// fail the queued requests and wait for the one in flight
ScopedAStatus CameraSession::flush() {
  std::deque<Request> drained;
  {
    std::unique_lock<std::mutex> lk(mu_);
    if (closed_) return ScopedAStatus::ok();
    flushing_ = true;
    drained.swap(queue_);
    wakeWorkerLocked();
    idleCv_.wait(lk, [this] { return !busy_; });
  }
  for (Request& r : drained) fail(r, "flushed");
  std::lock_guard<std::mutex> lk(mu_);
  if (wakeFd_ >= 0) {
    uint64_t count;
    ssize_t ignored = read(wakeFd_, &count, sizeof(count));
    (void)ignored;
  }
  if (!closed_) flushing_ = false;
  return ScopedAStatus::ok();
}

ScopedAStatus CameraSession::getCaptureRequestMetadataQueue(MQDescriptor<int8_t, SynchronizedReadWrite>* out) {
  *out = requestQueue_ ? requestQueue_->dupeDesc() : MQDescriptor<int8_t, SynchronizedReadWrite>();
  return ScopedAStatus::ok();
}

ScopedAStatus CameraSession::getCaptureResultMetadataQueue(MQDescriptor<int8_t, SynchronizedReadWrite>* out) {
  *out = resultQueue_ ? resultQueue_->dupeDesc() : MQDescriptor<int8_t, SynchronizedReadWrite>();
  return ScopedAStatus::ok();
}

// read n bytes from the request queue
bool CameraSession::readRequestQueue(int64_t n, std::vector<uint8_t>* out) {
  if (!requestQueue_ || n <= 0 || static_cast<uint64_t>(n) > kMetadataQueueBytes) return false;
  out->resize(static_cast<size_t>(n));
  return requestQueue_->read(reinterpret_cast<int8_t*>(out->data()), out->size());
}

ScopedAStatus CameraSession::isReconfigurationRequired(const device::CameraMetadata&,
                                                       const device::CameraMetadata&, bool* out) {
  *out = false;
  return ScopedAStatus::ok();
}

// check a request, import its new buffers and dup its fences
ScopedAStatus CameraSession::enqueue(const device::CaptureRequest& request, Request* out) {
  std::vector<uint8_t> queued;
  if (request.fmqSettingsSize > 0 && !readRequestQueue(request.fmqSettingsSize, &queued)) {
    klogf("camera %s: frame %d settings (%lld bytes) are not in the request queue", ctx_->id.c_str(),
          request.frameNumber, static_cast<long long>(request.fmqSettingsSize));
    return Error(Status::ILLEGAL_ARGUMENT);
  }
  for (const device::PhysicalCameraSetting& p : request.physicalCameraSettings) {
    std::vector<uint8_t> ignored;
    if (p.fmqSettingsSize > 0 && !readRequestQueue(p.fmqSettingsSize, &ignored)) return Error(Status::ILLEGAL_ARGUMENT);
  }
  if (request.inputBuffer.streamId != -1) return Error(Status::ILLEGAL_ARGUMENT);
  if (request.outputBuffers.empty()) return Error(Status::ILLEGAL_ARGUMENT);
  const std::vector<uint8_t>& blob = request.fmqSettingsSize > 0 ? queued : request.settings.metadata;
  std::shared_ptr<camera_metadata_t> settings = lastSettings_;
  if (!blob.empty()) {
    MetadataPtr parsed = ParseMetadata(blob);
    if (!parsed) {
      klogf("camera %s: frame %d carries malformed settings", ctx_->id.c_str(), request.frameNumber);
      return Error(Status::ILLEGAL_ARGUMENT);
    }
    settings = std::shared_ptr<camera_metadata_t>(parsed.release(), MetadataDeleter());
  }
  if (!settings) {
    klogf("camera %s: frame %d has no settings and none came before", ctx_->id.c_str(), request.frameNumber);
    return Error(Status::ILLEGAL_ARGUMENT);
  }
  Request r;
  r.frameNumber = request.frameNumber;
  r.settings = settings;
  for (const device::StreamBuffer& sb : request.outputBuffers) {
    auto st = streams_.find(sb.streamId);
    if (st == streams_.end() || sb.bufferId == 0) {
      for (OutBuffer& b : r.buffers) if (b.acquireFence >= 0) ::close(b.acquireFence);
      return Error(Status::ILLEGAL_ARGUMENT);
    }
    auto key = std::make_pair(sb.streamId, sb.bufferId);
    bool hasHandle = !sb.buffer.fds.empty() || !sb.buffer.ints.empty();
    if (hasHandle) {
      native_handle_t* nh = DupHandle(sb.buffer);
      buffer_handle_t imported = (nh != nullptr && gralloc_ != nullptr) ? gralloc_->importBuffer(nh) : nullptr;
      if (nh != nullptr) {
        native_handle_close(nh);
        native_handle_delete(nh);
      }
      if (imported == nullptr) {
        for (OutBuffer& b : r.buffers) if (b.acquireFence >= 0) ::close(b.acquireFence);
        return Error(Status::INTERNAL_ERROR);
      }
      auto old = buffers_.find(key);
      if (old != buffers_.end()) gralloc_->freeBuffer(old->second);
      buffers_[key] = imported;
    }
    auto cached = buffers_.find(key);
    if (cached == buffers_.end()) {
      klogf("camera %s: frame %d names buffer %lld of stream %d, never sent", ctx_->id.c_str(), request.frameNumber,
            static_cast<long long>(sb.bufferId), sb.streamId);
      for (OutBuffer& b : r.buffers) if (b.acquireFence >= 0) ::close(b.acquireFence);
      return Error(Status::ILLEGAL_ARGUMENT);
    }
    OutBuffer b;
    b.streamId = sb.streamId;
    b.bufferId = sb.bufferId;
    b.handle = cached->second;
    b.acquireFence = sb.acquireFence.fds.empty() ? -1 : dup(sb.acquireFence.fds[0].get());
    b.width = st->second.width;
    b.height = st->second.height;
    b.blob = st->second.format == PixelFormat::BLOB;
    r.buffers.push_back(b);
  }
  lastSettings_ = settings;
  *out = std::move(r);
  return ScopedAStatus::ok();
}

ScopedAStatus CameraSession::processCaptureRequest(const std::vector<device::CaptureRequest>& requests,
                                                   const std::vector<device::BufferCache>& cachesToRemove,
                                                   int32_t* out) {
  *out = 0;
  std::lock_guard<std::mutex> lk(mu_);
  if (closed_) return Error(Status::INTERNAL_ERROR);
  for (const device::BufferCache& c : cachesToRemove) {
    auto it = buffers_.find({c.streamId, c.bufferId});
    if (it == buffers_.end()) continue;
    if (gralloc_ != nullptr) gralloc_->freeBuffer(it->second);
    buffers_.erase(it);
  }
  ScopedAStatus status = ScopedAStatus::ok();
  size_t i = 0;
  for (; i < requests.size(); i++) {
    Request r;
    status = enqueue(requests[i], &r);
    if (!status.isOk()) break;
    r.depth = static_cast<int32_t>(queue_.size()) + (busy_ ? 1 : 0) + 1;
    queue_.push_back(std::move(r));
    (*out)++;
  }
  for (size_t j = i + 1; j < requests.size(); j++) {
    std::vector<uint8_t> ignored;
    if (requests[j].fmqSettingsSize > 0) readRequestQueue(requests[j].fmqSettingsSize, &ignored);
    for (const device::PhysicalCameraSetting& p : requests[j].physicalCameraSettings) {
      if (p.fmqSettingsSize > 0) readRequestQueue(p.fmqSettingsSize, &ignored);
    }
  }
  queueCv_.notify_all();
  return status;
}

ScopedAStatus CameraSession::signalStreamFlush(const std::vector<int32_t>&, int32_t) {
  return ScopedAStatus::ok();
}

ScopedAStatus CameraSession::switchToOffline(const std::vector<int32_t>&, device::CameraOfflineSessionInfo*,
                                             std::shared_ptr<device::ICameraOfflineSession>* out) {
  *out = nullptr;
  return Error(Status::OPERATION_NOT_SUPPORTED);
}

ScopedAStatus CameraSession::repeatingRequestEnd(int32_t, const std::vector<int32_t>&) {
  return ScopedAStatus::ok();
}

// pace each queued request to the next host frame
void CameraSession::workerLoop() {
  for (;;) {
    Request r;
    {
      std::unique_lock<std::mutex> lk(mu_);
      queueCv_.wait(lk, [this] { return stopping_ || !queue_.empty(); });
      if (queue_.empty()) return;
      r = std::move(queue_.front());
      queue_.pop_front();
      busy_ = true;
    }
    process(r);
    {
      std::lock_guard<std::mutex> lk(mu_);
      busy_ = false;
    }
    idleCv_.notify_all();
  }
}

// return a strictly increasing timestamp for a frame
int64_t CameraSession::timestampFor(const Frame& f) {
  int64_t now = MonotonicNs();
  int64_t ts = f.monotonicNs;
  if (ts <= 0 || ts > now || now - ts > kNsPerSecond) ts = now;
  if (ts <= lastTimestamp_) ts = lastTimestamp_ + 1;
  lastTimestamp_ = ts;
  return ts;
}

// fill or fail a request after its fences and frame
void CameraSession::process(Request& r) {
  if (flushing_) return fail(r, "flushed");
  std::vector<bool> fenceOk(r.buffers.size(), true);
  auto fenceDeadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kFenceTimeoutMs);
  for (size_t i = 0; i < r.buffers.size(); i++) {
    if (r.buffers[i].acquireFence < 0) continue;
    auto left = std::chrono::duration_cast<std::chrono::milliseconds>(fenceDeadline - std::chrono::steady_clock::now());
    switch (WaitFenceOrWake(r.buffers[i].acquireFence, wakeFd_, std::max<int>(0, static_cast<int>(left.count())))) {
      case FenceWait::kSignalled:
        break;
      case FenceWait::kWoken:
        return fail(r, "flushed");
      case FenceWait::kTimedOut:
        klogf("camera %s: frame %d stream %d acquire fence timed out", ctx_->id.c_str(), r.frameNumber,
              r.buffers[i].streamId);
        fenceOk[i] = false;
        break;
    }
  }

  int32_t maxFps = RequestedMaxFps(ctx_->shape, r.settings.get());
  std::shared_ptr<FrameMailbox> mb;
  {
    std::lock_guard<std::mutex> lk(mu_);
    int64_t msSinceOpen = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now() - lastOpen_).count();
    int32_t error = 0;
    bool stopped = !mailbox_ || mailbox_->stopped(&error);
    bool olderCamerad = stopped && error == -EINVAL && openRate_.belowMode && !modeRateOnly_;
    if (olderCamerad) {
      klogf("camera %s: camerad refused %u/%u fps; opening at mode rates from now on", ctx_->id.c_str(),
            openRate_.fpsNum, openRate_.fpsDen);
      modeRateOnly_ = true;
    }
    int m = haveMode_ ? ChooseMode(ctx_->host.modes, largestWidth_, largestHeight_, maxFps) : -1;
    const HostMode* want = m >= 0 ? &ctx_->host.modes[static_cast<size_t>(m)] : nullptr;
    double streamFps = mailbox_ && mailbox_->started() ? mailbox_->startedFps()
                                                       : double(openRate_.fpsNum) / std::max(1u, openRate_.fpsDen);
    bool faster = !stopped && NeedsFasterStream(streamFps, double(mode_.fpsNum) / std::max(1u, mode_.fpsDen), maxFps);
    bool retarget = want != nullptr && (!SameMode(*want, mode_) || faster) && ctx_->present &&
                    msSinceOpen >= kReopenIntervalMs;
    if (haveMode_ && ((olderCamerad && ctx_->present) || retarget ||
                      ShouldReopen(stopped, consecutiveTimeouts_, ctx_->present, msSinceOpen))) {
      if (!stopped && !retarget) klogf("camera %s: host stream silent; reopening it", ctx_->id.c_str());
      closeStreamLocked();
      openStreamLocked(want != nullptr ? *want : mode_, maxFps);
      consecutiveTimeouts_ = 0;
    }
    mb = mailbox_;
  }
  if (!mb) return fail(r, "no host stream");
  if (mb != seqOwner_) {
    seqOwner_ = mb;
    lastSeq_ = 0;
    pacer_.reset();
  }
  uint64_t generation = mb->generation();
  if (flushing_) return fail(r, "flushed");
  int timeout = !mb->started() ? kStartTimeoutMs : lastSeq_ == 0 ? kFirstFrameTimeoutMs : kFrameTimeoutMs;
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
  for (;;) {
    auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
    switch (mb->waitNewer(lastSeq_, std::max<int>(0, static_cast<int>(left.count())), generation, &frame_)) {
      case FrameMailbox::Wait::kFrame:
        lastSeq_ = frame_.seq;
        if (!pacer_.accept(frame_.monotonicNs > 0 ? frame_.monotonicNs : MonotonicNs(), maxFps)) continue;
        consecutiveTimeouts_ = 0;
        return complete(r, fenceOk);
      case FrameMailbox::Wait::kStopped: {
        std::unique_lock<std::mutex> lk(mu_);
        queueCv_.wait_for(lk, std::chrono::milliseconds(kStoppedRetryMs), [this] { return flushing_ || stopping_; });
        lk.unlock();
        return fail(r, "host stream stopped");
      }
      case FrameMailbox::Wait::kTimeout:
        consecutiveTimeouts_++;
        return fail(r, "no host frame in time");
      case FrameMailbox::Wait::kInterrupted:
        return fail(r, "flushed");
    }
  }
}

// write a host frame into an output buffer
bool CameraSession::fillBuffer(const OutBuffer& b, const camera_metadata_t* settings, int* releaseFence) {
  *releaseFence = -1;
  if (gralloc_ == nullptr) return false;
  LockedBuffer lb;
  if (!gralloc_->lock(b.handle, &lb)) return false;
  I420View view{frame_.data.data(), static_cast<int32_t>(frame_.width), static_cast<int32_t>(frame_.height)};
  bool ok = false;
  if (b.blob) {
    if (lb.kind == LockedBuffer::Kind::kBlob) {
      JpegSettings js = JpegSettingsFrom(ctx_->shape, settings);
      JpegRequest req;
      req.quality = js.quality;
      req.thumbnailQuality = js.thumbnailQuality;
      req.thumbnailWidth = js.thumbnailWidth;
      req.thumbnailHeight = js.thumbnailHeight;
      req.exif.make = make_;
      req.exif.model = model_;
      req.exif.dateTime = ExifDateTime();
      req.exif.orientation = js.orientation;
      ssize_t n = FillJpeg(view, b.width, b.height, req, lb.blob, lb.blobSize, scratch_);
      ok = n > 0;
      if (!ok) klogf("camera %s: JPEG %dx%d did not fit a %zu-byte buffer", ctx_->id.c_str(), b.width, b.height, lb.blobSize);
    }
  } else if (lb.kind == LockedBuffer::Kind::kYuv) {
    FillYuv(view, lb.yuv, scratch_);
    ok = true;
  } else if (lb.kind == LockedBuffer::Kind::kRgba) {
    FillRgba(view, lb.rgba, lb.rgbaStride, lb.width, lb.height, scratch_);
    ok = true;
  }
  if (!ok && lb.kind != LockedBuffer::Kind::kBlob) {
    klogf("camera %s: stream %d buffer layout %d cannot take a %s frame", ctx_->id.c_str(), b.streamId,
          static_cast<int>(lb.kind), b.blob ? "JPEG" : "YUV/RGBA");
  }
  bool published = gralloc_->unlock(b.handle, releaseFence);
  return ok && published;
}

// deliver a request's shutter, filled buffers and result metadata
void CameraSession::complete(Request& r, const std::vector<bool>& fenceOk) {
  int64_t ts = timestampFor(frame_);
  std::vector<device::NotifyMsg> msgs;
  msgs.push_back(device::NotifyMsg::make<device::NotifyMsg::Tag::shutter>(
      device::ShutterMsg{.frameNumber = r.frameNumber, .timestamp = ts, .readoutTimestamp = ts}));

  device::CaptureResult result;
  result.frameNumber = r.frameNumber;
  result.fmqResultSize = 0;
  result.inputBuffer.streamId = -1;
  result.partialResult = 1;
  for (size_t i = 0; i < r.buffers.size(); i++) {
    OutBuffer& b = r.buffers[i];
    device::StreamBuffer sb;
    sb.streamId = b.streamId;
    sb.bufferId = b.bufferId;
    int release = -1;
    bool ok = fenceOk[i] && fillBuffer(b, r.settings.get(), &release);
    if (ok) {
      if (b.acquireFence >= 0) ::close(b.acquireFence);
      sb.status = device::BufferStatus::OK;
      sb.releaseFence = FenceHandle(release);
    } else {
      if (release >= 0) ::close(release);
      sb.status = device::BufferStatus::ERROR;
      sb.releaseFence = FenceHandle(b.acquireFence);
      msgs.push_back(device::NotifyMsg::make<device::NotifyMsg::Tag::error>(device::ErrorMsg{
          .frameNumber = r.frameNumber, .errorStreamId = b.streamId, .errorCode = device::ErrorCode::ERROR_BUFFER}));
    }
    b.acquireFence = -1;
    result.outputBuffers.push_back(std::move(sb));
  }
  result.result.metadata = BuildResult(ctx_->shape, r.settings.get(), ts, r.depth);
  deliver(msgs, std::move(result));
  if (completed_++ == 0) {
    klogf("camera %s: first frame %ux%u delivered to frame %d", ctx_->id.c_str(), frame_.width, frame_.height,
          r.frameNumber);
  }
}

// return a request's buffers unfilled with ERROR_REQUEST
void CameraSession::fail(Request& r, const char* why) {
  if (failures_++ % 100 == 0) {
    klogf("camera %s: frame %d failed (%s; %llu failures so far)", ctx_->id.c_str(), r.frameNumber, why,
          static_cast<unsigned long long>(failures_));
  }
  std::vector<device::NotifyMsg> msgs;
  msgs.push_back(device::NotifyMsg::make<device::NotifyMsg::Tag::error>(device::ErrorMsg{
      .frameNumber = r.frameNumber, .errorStreamId = -1, .errorCode = device::ErrorCode::ERROR_REQUEST}));
  device::CaptureResult result;
  result.frameNumber = r.frameNumber;
  result.fmqResultSize = 0;
  result.inputBuffer.streamId = -1;
  result.partialResult = 0;
  for (OutBuffer& b : r.buffers) {
    device::StreamBuffer sb;
    sb.streamId = b.streamId;
    sb.bufferId = b.bufferId;
    sb.status = device::BufferStatus::ERROR;
    sb.releaseFence = FenceHandle(b.acquireFence);
    b.acquireFence = -1;
    result.outputBuffers.push_back(std::move(sb));
  }
  deliver(msgs, std::move(result));
}

// send the notify messages, then the capture result
void CameraSession::deliver(const std::vector<device::NotifyMsg>& msgs, device::CaptureResult result) {
  std::lock_guard<std::mutex> lk(callbackMu_);
  const std::vector<uint8_t>& md = result.result.metadata;
  if (resultQueue_ && !md.empty() && resultQueue_->availableToWrite() >= md.size() &&
      resultQueue_->write(reinterpret_cast<const int8_t*>(md.data()), md.size())) {
    result.fmqResultSize = static_cast<int64_t>(md.size());
    result.result.metadata.clear();
  }
  callback_->notify(msgs);
  std::vector<device::CaptureResult> results;
  results.push_back(std::move(result));
  auto status = callback_->processCaptureResult(results);
  if (!status.isOk()) klogf("camera %s: processCaptureResult failed: %s", ctx_->id.c_str(), status.getMessage());
}

CameraDevice::CameraDevice(std::shared_ptr<CameraContext> ctx, CameradClient* client)
    : ctx_(std::move(ctx)), client_(client) {}

ScopedAStatus CameraDevice::getCameraCharacteristics(device::CameraMetadata* out) {
  out->metadata = ctx_->characteristics;
  return ScopedAStatus::ok();
}

ScopedAStatus CameraDevice::getPhysicalCameraCharacteristics(const std::string&, device::CameraMetadata*) {
  return Error(Status::ILLEGAL_ARGUMENT);
}

ScopedAStatus CameraDevice::getResourceCost(CameraResourceCost* out) {
  out->resourceCost = 100;
  out->conflictingDevices.clear();
  return ScopedAStatus::ok();
}

ScopedAStatus CameraDevice::isStreamCombinationSupported(const device::StreamConfiguration& streams, bool* out) {
  *out = CheckStreams(ctx_->shape, streams).empty();
  return ScopedAStatus::ok();
}

ScopedAStatus CameraDevice::open(const std::shared_ptr<device::ICameraDeviceCallback>& callback,
                                 std::shared_ptr<device::ICameraDeviceSession>* out) {
  *out = nullptr;
  if (callback == nullptr) return Error(Status::ILLEGAL_ARGUMENT);
  if (!ctx_->present) return Error(Status::CAMERA_DISCONNECTED);
  if (Gralloc::Get() == nullptr) {
    klogf("camera %s: open refused: no mapper to write buffers with", ctx_->id.c_str());
    return Error(Status::INTERNAL_ERROR);
  }
  std::lock_guard<std::mutex> lk(mu_);
  if (auto existing = session_.lock(); existing != nullptr && !existing->isClosed()) {
    return Error(Status::CAMERA_IN_USE);
  }
  auto session = ndk::SharedRefBase::make<CameraSession>(ctx_, client_, callback);
  session_ = session;
  *out = session;
  return ScopedAStatus::ok();
}

ScopedAStatus CameraDevice::openInjectionSession(const std::shared_ptr<device::ICameraDeviceCallback>&,
                                                 std::shared_ptr<device::ICameraInjectionSession>* out) {
  *out = nullptr;
  return Error(Status::OPERATION_NOT_SUPPORTED);
}

ScopedAStatus CameraDevice::setTorchMode(bool) { return Error(Status::OPERATION_NOT_SUPPORTED); }

ScopedAStatus CameraDevice::turnOnTorchWithStrengthLevel(int32_t) { return Error(Status::OPERATION_NOT_SUPPORTED); }

ScopedAStatus CameraDevice::getTorchStrengthLevel(int32_t*) { return Error(Status::OPERATION_NOT_SUPPORTED); }

ScopedAStatus CameraDevice::constructDefaultRequestSettings(device::RequestTemplate type,
                                                            device::CameraMetadata* out) {
  out->metadata = BuildDefaultRequest(ctx_->shape, TemplateId(type));
  if (out->metadata.empty()) return Error(Status::ILLEGAL_ARGUMENT);
  return ScopedAStatus::ok();
}

ScopedAStatus CameraDevice::isStreamCombinationWithSettingsSupported(const device::StreamConfiguration& streams,
                                                                     bool* out) {
  *out = false;
  if (!CheckStreams(ctx_->shape, streams).empty()) return ScopedAStatus::ok();
  if (!streams.sessionParams.metadata.empty()) {
    MetadataPtr params = ParseMetadata(streams.sessionParams.metadata);
    if (!params) return ScopedAStatus::ok();
    camera_metadata_ro_entry_t e;
    if (find_camera_metadata_ro_entry(params.get(), ANDROID_CONTROL_AE_TARGET_FPS_RANGE, &e) == 0) {
      bool listed = false;
      for (const auto& r : ctx_->shape.fpsRanges) {
        if (e.count == 2 && e.type == TYPE_INT32 && e.data.i32[0] == r[0] && e.data.i32[1] == r[1]) listed = true;
      }
      if (!listed) return ScopedAStatus::ok();
    }
    if (find_camera_metadata_ro_entry(params.get(), ANDROID_CONTROL_VIDEO_STABILIZATION_MODE, &e) == 0 &&
        (e.count != 1 || e.type != TYPE_BYTE || e.data.u8[0] != ANDROID_CONTROL_VIDEO_STABILIZATION_MODE_OFF)) {
      return ScopedAStatus::ok();
    }
  }
  *out = true;
  return ScopedAStatus::ok();
}

ScopedAStatus CameraDevice::getSessionCharacteristics(const device::StreamConfiguration& config,
                                                      device::CameraMetadata* out) {
  if (!CheckStreams(ctx_->shape, config).empty()) return Error(Status::ILLEGAL_ARGUMENT);
  out->metadata = BuildSessionCharacteristics();
  return ScopedAStatus::ok();
}

}

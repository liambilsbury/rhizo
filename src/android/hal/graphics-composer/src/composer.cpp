#include <drm/drm.h>
#include <drm/virtgpu_drm.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <poll.h>
#include <sched.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <cstring>
#include <map>
#include <condition_variable>
#include <mutex>
#include <set>
#include <string>
#include <cmath>
#include <thread>
#include <vector>

#include <android/binder_ibinder_platform.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <log/log.h>
#include <openssl/sha.h>
#include "aidl/android/hardware/graphics/composer3/BnComposer.h"
#include "aidl/android/hardware/graphics/composer3/BnComposerClient.h"

#include "input/pointer_icon.h"
#include "input/pointer_observation.h"
#include "input/uinput.h"
#include "input/us_kcm_table.h"
#include "rhizo/buffer_metadata.h"
#include "rhizo/virtgpu_transfer.h"
#include "stream/stream_export.h"
#include "wayland/shm_present.h"
#include "wayland/wayland_backend.h"

using namespace aidl::android::hardware::graphics::composer3;
using aidl::android::hardware::common::NativeHandle;
using ndk::ScopedAStatus;
using ndk::ScopedFileDescriptor;

namespace {

// write the message to logcat and kmsg
void klog(const char* msg) {
  __android_log_print(ANDROID_LOG_INFO, "rhizo-composer", "%s", msg);
  static int kmsgFd = -1;
  static bool kmsgTried = false;
  if (!kmsgTried) {
    kmsgTried = true;
    kmsgFd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  }
  if (kmsgFd >= 0) {
    std::string line = std::string("<6>rhizo-composer: ") + msg + "\n";
    ssize_t ignored = write(kmsgFd, line.data(), line.size());
    (void)ignored;
  }
  static FILE* debugLog = nullptr;
  if (!debugLog) debugLog = fopen("/data/rhizo_control/composer-debug.log", "ae");
  if (debugLog) { fprintf(debugLog, "%s\n", msg); fflush(debugLog); }
}

// read RHIZO_COMPOSER_VERBOSE from the environment
bool composerVerboseFrames() {
  static const bool on = getenv("RHIZO_COMPOSER_VERBOSE") != nullptr;
  return on;
}

// read RHIZO_COMPOSER_UNRELIABLE_FENCES from the environment
bool composerUnreliableFences() {
  static const bool off = getenv("RHIZO_COMPOSER_UNRELIABLE_FENCES") != nullptr;
  return !off;
}

// present time pacing modes
enum class ComposerPacingMode { kOff, kNatural, kFull };
// read RHIZO_COMPOSER_PACING from the environment
ComposerPacingMode composerPacingMode() {
  static const ComposerPacingMode mode = [] {
    const char* v = getenv("RHIZO_COMPOSER_PACING");
    if (!v) return ComposerPacingMode::kOff;
    if (!strcmp(v, "natural")) return ComposerPacingMode::kNatural;
    if (!strcmp(v, "full")) return ComposerPacingMode::kFull;
    return ComposerPacingMode::kOff;
  }();
  return mode;
}

// read RHIZO_RESIZE_TRACE from the environment
bool resizeTraceEnabled() {
  static const bool on = [] {
    const char* v = getenv("RHIZO_RESIZE_TRACE");
    return v && strcmp(v, "1") == 0;
  }();
  return on;
}

// check for the desktop profile's freeform feature file
bool freeformEnabled() {
  static const bool on = access("/vendor/etc/permissions/rhizo-freeform.xml", F_OK) == 0;
  return on;
}

constexpr int32_t kFreeformCaptionDp = 42;

// read RHIZO_COMPOSER_DEVICE from the environment
bool composerDeviceEnabled() {
  static const bool on = [] {
    const char* v = getenv("RHIZO_COMPOSER_DEVICE");
    return !(v && strcmp(v, "0") == 0);
  }();
  return on;
}

// read RHIZO_COMPOSER_VSYNC_MIN_GAP from the environment, default 90
int composerVsyncMinGapPct() {
  static const int pct = [] {
    const char* v = getenv("RHIZO_COMPOSER_VSYNC_MIN_GAP");
    if (!v) return 90;
    char* end = nullptr;
    long n = strtol(v, &end, 10);
    if (end == v || *end != '\0' || n < 0 || n > 100) {
      klog("bad RHIZO_COMPOSER_VSYNC_MIN_GAP, keeping 90");
      return 90;
    }
    return static_cast<int>(n);
  }();
  return pct;
}

// read RHIZO_COMPOSER_DEBUG from the environment
bool composerDebugEnabled() {
  static const bool on = getenv("RHIZO_COMPOSER_DEBUG") != nullptr;
  return on;
}

// read RHIZO_DISPLAY_POOL_IDLE_S from the environment
int displayPoolIdleSeconds() {
  static const int s = [] {
    const char* v = getenv("RHIZO_DISPLAY_POOL_IDLE_S");
    if (!v) return 0;
    char* end = nullptr;
    long n = strtol(v, &end, 10);
    if (end == v || *end != '\0' || n < 0) {
      klog("bad RHIZO_DISPLAY_POOL_IDLE_S, keeping 0 (never)");
      return 0;
    }
    return static_cast<int>(n);
  }();
  return s;
}

// read RHIZO_DISPLAY_POOL_ENABLED from the environment
bool displayPoolEnabled() {
  static const bool on = [] {
    const char* v = getenv("RHIZO_DISPLAY_POOL_ENABLED");
    return !(v && strcmp(v, "0") == 0);
  }();
  return on;
}

void klogf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
// format the message and write it with klog
void klogf(const char* fmt, ...) {
  char buf[320];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  klog(buf);
}

// set the thread to SCHED_FIFO priority 2
void SetFifoPriority2(const char* threadLabel) {
  struct sched_param sp {};
  sp.sched_priority = 2;
  if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0) {
    klogf("%s: sched_setscheduler(SCHED_FIFO, pri=2) FAILED errno=%d (%s) -- thread stays SCHED_OTHER",
          threadLabel, errno, strerror(errno));
  }
}

void LifecycleKlogf(int64_t id, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
// log a display lifecycle message when composer debugging is on
void LifecycleKlogf(int64_t id, const char* fmt, ...) {
  if (!composerDebugEnabled()) return;
  char body[256];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(body, sizeof(body), fmt, ap);
  va_end(ap);
  klogf("display %lld lifecycle %s", static_cast<long long>(id), body);
}

// return a service-specific error status with the code and message
ScopedAStatus clientErr(int32_t code, const char* msg) {
  return ScopedAStatus::fromServiceSpecificErrorWithMessage(code, msg);
}
ScopedAStatus ok() { return ScopedAStatus::ok(); }
// return the bad display error status
ScopedAStatus badDisplay() {
  return clientErr(IComposerClient::EX_BAD_DISPLAY, "bad display");
}

constexpr int64_t kPrimaryDisplayId = 1;
constexpr int32_t kConfigId = 0;
constexpr int64_t kVsyncStatsIntervalNs = 5000000000;

struct DisplayGeometry {
  int32_t width;
  int32_t height;
  int64_t vsyncPeriodNs;
  float dpi;
};
// read RHIZO_DISPLAY_GEOMETRY as WxH@fps/dpi
const DisplayGeometry& PrimaryGeometry() {
  static const DisplayGeometry g = [] {
    const char* v = getenv("RHIZO_DISPLAY_GEOMETRY");
    if (!v) return DisplayGeometry{1280, 800, 16666667, 400.0f};
    int w = 0, h = 0, fps = 0, dpi = 0;
    char extra = 0;
    if (sscanf(v, "%dx%d@%d/%d%c", &w, &h, &fps, &dpi, &extra) != 4 ||
        w <= 0 || h <= 0 || fps <= 0 || dpi <= 0) {
      klogf("bad RHIZO_DISPLAY_GEOMETRY=%s, expected WxH@fps/dpi", v);
      abort();
    }
    return DisplayGeometry{w, h, 1000000000LL / fps, static_cast<float>(dpi)};
  }();
  return g;
}
const int32_t kDefaultWidth = PrimaryGeometry().width;
const int32_t kDefaultHeight = PrimaryGeometry().height;
const int64_t kVsyncPeriodNs = PrimaryGeometry().vsyncPeriodNs;
const float kBaseDpi = PrimaryGeometry().dpi;

// primary display geometry kept across clients
struct KeptPrimaryGeometry {
  int32_t width = kDefaultWidth;
  int32_t height = kDefaultHeight;
  int32_t scale120 = 120;
  float dpi = kBaseDpi;
  int64_t vsyncPeriodNs = kVsyncPeriodNs;
};
// return the lock for the kept primary geometry
std::mutex& KeptPrimaryMutex() {
  static std::mutex m;
  return m;
}
// return the primary geometry the last client applied
KeptPrimaryGeometry& KeptPrimary() {
  static KeptPrimaryGeometry g;
  return g;
}

constexpr const char* kDumpRequestPath = "/data/rhizo_control/dump_request";
constexpr const char* kDumpOutPath = "/data/rhizo_control/client_target.raw";

constexpr const char* kControlPath = "/data/rhizo_control/control";
constexpr const char* kControlReplyPath = "/data/rhizo_control/control.out";

constexpr size_t kMaxControlLineBytes = 12 * 1024 * 1024;

constexpr int64_t kVsyncWatchdogNs = 250000000;

constexpr int64_t kResizeThrottleNs = 50000000;
constexpr int64_t kRefreshAfterHotplugNs = 1000000000;

constexpr int64_t kInjectTouchTimeoutNs = 3000000000;

constexpr int kClientTargetFenceWaitMs = 200;

constexpr int64_t kSfReleaseDeadlineNs = 2000000000;
constexpr int kSfReleaseMaxAttempts = 3;
constexpr int kRemovingCallKlogMax = 8;

// move-only file descriptor
struct OwnedFd {
  int fd = -1;
  OwnedFd() = default;
  // close the fd
  ~OwnedFd() { reset(); }
  OwnedFd(const OwnedFd&) = delete;
  OwnedFd& operator=(const OwnedFd&) = delete;
  // take the fd from another OwnedFd
  OwnedFd(OwnedFd&& o) noexcept : fd(o.fd) { o.fd = -1; }
  OwnedFd& operator=(OwnedFd&& o) noexcept {
    if (this != &o) {
      reset(o.fd);
      o.fd = -1;
    }
    return *this;
  }
  int get() const { return fd; }
  // close the current fd and store the new one
  void reset(int f = -1) {
    if (fd >= 0) close(fd);
    fd = f;
  }
};

std::atomic<int> g_heldFdsLive{0};

// duplicated fd and decoded handle
struct HeldBuffer {
  int fd = -1;
  ino_t ino = 0;
  rhizo::DecodedHandle decoded;
  HeldBuffer() = default;
  ~HeldBuffer() { Reset(); }
  HeldBuffer(const HeldBuffer&) = delete;
  HeldBuffer& operator=(const HeldBuffer&) = delete;
  // take the fd, inode and decoded handle from another HeldBuffer
  HeldBuffer(HeldBuffer&& o) noexcept : fd(o.fd), ino(o.ino), decoded(std::move(o.decoded)) {
    o.fd = -1;
    o.ino = 0;
  }
  HeldBuffer& operator=(HeldBuffer&& o) noexcept {
    if (this != &o) {
      Reset();
      fd = o.fd;
      ino = o.ino;
      decoded = std::move(o.decoded);
      o.fd = -1;
      o.ino = 0;
    }
    return *this;
  }
  // store the duplicated fd and its inode
  void Adopt(int dupFd) {
    Reset();
    fd = dupFd;
    if (fd < 0) return;
    g_heldFdsLive.fetch_add(1, std::memory_order_relaxed);
    struct stat st{};
    ino = fstat(fd, &st) == 0 ? st.st_ino : 0;
  }
  // close the fd and clear the buffer
  void Reset() {
    if (fd >= 0) {
      close(fd);
      g_heldFdsLive.fetch_sub(1, std::memory_order_relaxed);
    }
    fd = -1;
    ino = 0;
    decoded = rhizo::DecodedHandle();
  }
};

// wait for the fence fd and close it
void WaitAndCloseFence(int fenceFd) {
  if (fenceFd < 0) return;
  struct pollfd pfd{fenceFd, POLLIN, 0};
  poll(&pfd, 1, 3000);
  close(fenceFd);
}

// start or end CPU access on a dma-buf
void DmaBufSync(int fd, bool start, bool write) {
  if (fd < 0) return;
  struct dma_buf_sync sync{};
  sync.flags = (start ? DMA_BUF_SYNC_START : DMA_BUF_SYNC_END) |
               (write ? DMA_BUF_SYNC_WRITE : DMA_BUF_SYNC_READ);
  int rc = ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
  if (rc != 0) {
    klogf("DmaBufSync(fd=%d,start=%d) FAILED rc=%d errno=%d (%s)", fd, start, rc, errno,
          strerror(errno));
  }
}

std::mutex g_syncobjMutex;
int g_syncobjHandle = -1;
bool g_syncobjTried = false;

// return the handle of a shared signaled DRM syncobj
int SyncobjHandleLocked(int drmFd) {
  if (!g_syncobjTried) {
    g_syncobjTried = true;
    struct drm_syncobj_create create_req {};
    create_req.flags = DRM_SYNCOBJ_CREATE_SIGNALED;
    if (ioctl(drmFd, DRM_IOCTL_SYNCOBJ_CREATE, &create_req) < 0) {
      klogf("DRM_IOCTL_SYNCOBJ_CREATE FAILED errno=%d (%s) -- no syncobj fence path available",
            errno, strerror(errno));
    } else {
      g_syncobjHandle = static_cast<int>(create_req.handle);
    }
  }
  return g_syncobjHandle;
}

int TriviallySignaledFence();
// return a dup of the shared signaled fence
int SharedSignaledReleaseFence() {
  static const int shared = [] {
    int fd = TriviallySignaledFence();
    if (fd < 0) klog("SharedSignaledReleaseFence: no signaled fence to share, release fences fall back per call");
    return fd;
  }();
  if (shared < 0) return TriviallySignaledFence();
  int fd = fcntl(shared, F_DUPFD_CLOEXEC, 0);
  if (fd < 0) {
    klogf("SharedSignaledReleaseFence: dup FAILED errno=%d (%s), falling back per call", errno, strerror(errno));
    return TriviallySignaledFence();
  }
  return fd;
}

// return a signaled sync_file fd
int TriviallySignaledFence() {
  std::lock_guard<std::mutex> lg(g_syncobjMutex);
  int drmFd = rhizo::OpenRenderNode();
  if (drmFd < 0) {
    klog("TriviallySignaledFence: OpenRenderNode FAILED, falling back to /dev/null fence");
    return open("/dev/null", O_RDONLY | O_CLOEXEC);
  }
  struct drm_syncobj_create create_req {};
  create_req.flags = DRM_SYNCOBJ_CREATE_SIGNALED;
  if (ioctl(drmFd, DRM_IOCTL_SYNCOBJ_CREATE, &create_req) < 0) {
    klogf("DRM_IOCTL_SYNCOBJ_CREATE FAILED errno=%d (%s), falling back to /dev/null fence",
          errno, strerror(errno));
    return open("/dev/null", O_RDONLY | O_CLOEXEC);
  }
  struct drm_syncobj_handle export_req {};
  export_req.handle = create_req.handle;
  export_req.flags = DRM_SYNCOBJ_HANDLE_TO_FD_FLAGS_EXPORT_SYNC_FILE;
  export_req.fd = -1;
  int rc = ioctl(drmFd, DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD, &export_req);
  int exportErrno = errno;
  struct drm_syncobj_destroy destroy_req {};
  destroy_req.handle = create_req.handle;
  ioctl(drmFd, DRM_IOCTL_SYNCOBJ_DESTROY, &destroy_req);
  if (rc < 0) {
    klogf(
        "DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD FAILED errno=%d (%s), falling back to /dev/null fence",
        exportErrno, strerror(exportErrno));
    return open("/dev/null", O_RDONLY | O_CLOEXEC);
  }
  return export_req.fd;
}

// decoded view of a NativeHandle
struct NhView {
  int fd = -1;
  rhizo::DecodedHandle decoded;
};
// return the first fd and the decoded ints of a NativeHandle
NhView ViewNativeHandle(const NativeHandle& nh) {
  NhView v;
  if (!nh.fds.empty()) v.fd = nh.fds[0].get();
  v.decoded = rhizo::DecodeInts(nh.ints.data(), nh.ints.size());
  return v;
}

// return CLOCK_MONOTONIC in nanoseconds
int64_t NowNanos() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

constexpr size_t kDragPayloadMaxBytes = 8 * 1024 * 1024;

// decode a base64 string into bytes
bool Base64Decode(const std::string& in, std::vector<uint8_t>* out) {
  static const auto kTable = [] {
    std::array<int8_t, 256> t{};
    t.fill(-1);
    const char* alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (int i = 0; i < 64; i++) t[static_cast<uint8_t>(alphabet[i])] = static_cast<int8_t>(i);
    return t;
  }();

  std::string s = in;
  size_t padCount = 0;
  while (!s.empty() && s.back() == '=') {
    s.pop_back();
    padCount++;
  }
  if (padCount > 2 || (s.size() + padCount) % 4 != 0) return false;

  out->clear();
  out->reserve(s.size() / 4 * 3 + 3);
  uint32_t buffer = 0;
  int bits = 0;
  for (unsigned char c : s) {
    int8_t v = kTable[c];
    if (v < 0) return false;
    buffer = (buffer << 6) | static_cast<uint32_t>(v);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out->push_back(static_cast<uint8_t>((buffer >> bits) & 0xff));
    }
  }
  return true;
}

constexpr size_t kClipPayloadMaxBytes = 8 * 1024 * 1024;

// return the sha256 hex digest of the bytes
std::string Sha256Hex(const std::vector<uint8_t>& bytes) {
  uint8_t digest[SHA256_DIGEST_LENGTH];
  SHA256(bytes.data(), bytes.size(), digest);
  static const char kHex[] = "0123456789abcdef";
  std::string out(SHA256_DIGEST_LENGTH * 2, '0');
  for (size_t i = 0; i < SHA256_DIGEST_LENGTH; i++) {
    out[i * 2] = kHex[digest[i] >> 4];
    out[i * 2 + 1] = kHex[digest[i] & 0xf];
  }
  return out;
}

// build a 128 byte EDID block
std::vector<uint8_t> BuildEdidBlock(int64_t displayId, uint8_t port) {
  uint8_t b[128] = {0};
  static const uint8_t kHeader[8] = {0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00};
  memcpy(b, kHeader, sizeof(kHeader));
  auto letter = [](char c) -> uint16_t { return static_cast<uint16_t>(c - 'A' + 1); };
  uint16_t mfg = static_cast<uint16_t>((letter('R') << 10) | (letter('H') << 5) | letter('Z'));
  b[8] = static_cast<uint8_t>(mfg >> 8);
  b[9] = static_cast<uint8_t>(mfg & 0xFF);
  b[10] = 0x01;
  b[11] = 0x00;
  uint32_t serial = static_cast<uint32_t>(displayId);
  b[12] = static_cast<uint8_t>(serial & 0xFF);
  b[13] = static_cast<uint8_t>((serial >> 8) & 0xFF);
  b[14] = static_cast<uint8_t>((serial >> 16) & 0xFF);
  b[15] = static_cast<uint8_t>((serial >> 24) & 0xFF);
  b[16] = 1;
  b[17] = 36;
  b[18] = 1;
  b[19] = 3;
  b[20] = 0xA0;
  b[21] = 0;
  b[22] = 0;
  b[23] = 120;
  b[24] = 0x04;
  auto chrom10 = [](int numerator, int denominator) -> uint16_t {
    return static_cast<uint16_t>((numerator * 1024 + denominator / 2) / denominator);
  };
  uint16_t rx = chrom10(640, 1000), ry = chrom10(330, 1000);
  uint16_t gx = chrom10(300, 1000), gy = chrom10(600, 1000);
  uint16_t bx = chrom10(150, 1000), by = chrom10(60, 1000);
  uint16_t wx = chrom10(3127, 10000), wy = chrom10(3290, 10000);
  b[25] = static_cast<uint8_t>(((rx & 0x3) << 6) | ((ry & 0x3) << 4) | ((gx & 0x3) << 2) | (gy & 0x3));
  b[26] = static_cast<uint8_t>(((bx & 0x3) << 6) | ((by & 0x3) << 4) | ((wx & 0x3) << 2) | (wy & 0x3));
  b[27] = static_cast<uint8_t>(rx >> 2);
  b[28] = static_cast<uint8_t>(ry >> 2);
  b[29] = static_cast<uint8_t>(gx >> 2);
  b[30] = static_cast<uint8_t>(gy >> 2);
  b[31] = static_cast<uint8_t>(bx >> 2);
  b[32] = static_cast<uint8_t>(by >> 2);
  b[33] = static_cast<uint8_t>(wx >> 2);
  b[34] = static_cast<uint8_t>(wy >> 2);
  b[35] = b[36] = b[37] = 0x00;
  for (int i = 0; i < 8; ++i) {
    b[38 + i * 2] = 0x01;
    b[39 + i * 2] = 0x01;
  }
  static const char kName[13] = {'R', 'h', 'i', 'z', 'o', ' ', 'D', 'i', 's', 'p', 'l', 'a', 'y'};
  b[54] = b[55] = b[56] = 0x00;
  b[57] = 0xFC;
  b[58] = 0x00;
  memcpy(&b[59], kName, sizeof(kName));
  for (int d = 0; d < 3; ++d) {
    int off = 72 + d * 18;
    b[off] = b[off + 1] = b[off + 2] = 0x00;
    b[off + 3] = 0x10;
    b[off + 4] = 0x00;
  }
  b[126] = 0x00;
  int sum = 0;
  for (int i = 0; i < 127; ++i) sum += b[i];
  b[127] = static_cast<uint8_t>((256 - (sum % 256)) % 256);
  (void)port;
  std::vector<uint8_t> out(128);
  memcpy(out.data(), b, 128);
  return out;
}

// thread counter increment and decrement
struct ThreadGuard {
  // increment the thread counter
  explicit ThreadGuard(std::atomic<int>& counter) : counter_(counter) {
    counter_.fetch_add(1, std::memory_order_acq_rel);
  }
  // decrement the thread counter
  ~ThreadGuard() { counter_.fetch_sub(1, std::memory_order_acq_rel); }
  std::atomic<int>& counter_;
};

// IComposerClient for all displays
class RhizoComposerClient : public BnComposerClient {
 public:
  // create the primary display state
  RhizoComposerClient() {
    DisplayState& ds = displays_[kPrimaryDisplayId];
    ds.id = kPrimaryDisplayId;
    ds.port = 0;
    ds.internal = true;
    {
      std::lock_guard<std::mutex> lg(KeptPrimaryMutex());
      const KeptPrimaryGeometry& kept = KeptPrimary();
      ds.width = kept.width;
      ds.height = kept.height;
      ds.scale120 = kept.scale120;
      ds.dpi = kept.dpi;
      ds.vsyncPeriodNs = kept.vsyncPeriodNs;
    }
    ds.SyncConfig();
  }

  ~RhizoComposerClient() override { Shutdown(); }
  // stop the threads and remove the displays
  void Shutdown() {
    shuttingDown_.store(true, std::memory_order_release);
    vsyncCv_.notify_all();
    WakeControlThread();
    if (controlThread_.joinable()) controlThread_.join();
    if (vsyncThread_.joinable()) vsyncThread_.join();
    {
      const int64_t deadline = NowNanos() + kQuiescenceMaxWaitNs;
      for (;;) {
        int remaining = transientThreads_.load(std::memory_order_acquire);
        if (remaining <= 0) break;
        if (NowNanos() >= deadline) {
          klogf("Shutdown: %d transient thread(s) still running after %lldms -- "
                "proceeding anyway",
                remaining, static_cast<long long>(kQuiescenceMaxWaitNs / 1000000));
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
    }
    {
      std::vector<int64_t> leftover;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        for (auto& kv : displays_) {
          if (kv.first != kPrimaryDisplayId) leftover.push_back(kv.first);
        }
      }
      for (int64_t id : leftover) RemoveDisplay(id);
      std::vector<int64_t> pending;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        for (const auto& kv : awaitingSfRelease_) pending.push_back(kv.first);
      }
      for (int64_t id : pending) FinishRemoval(id,  true);
    }
    wayland_.Shutdown();
    wayland_.Disconnect();
    stream_.Disconnect();
  }

  // create a layer on the display
  ScopedAStatus createLayer(int64_t display, int32_t  ,
                             int64_t* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    int64_t id = ds->nextLayerId++;
    ds->layers[id] = LayerState{};
    *out = id;
    return ok();
  }

  // destroy a layer and release its buffers
  ScopedAStatus destroyLayer(int64_t display, int64_t layer) override {
    bool released = false;
    std::vector<int32_t> wlSlots;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLocked(display);
      if (!ds) return badDisplay();
      auto lit = ds->layers.find(layer);
      if (lit == ds->layers.end()) return clientErr(IComposerClient::EX_BAD_LAYER, "no such layer");
      for (const auto& kv : lit->second.slots) wlSlots.push_back(kDeviceSlotBase + kv.first);
      lit->second.Reset();
      ds->layers.erase(lit);
      if (ds->deviceLayer == layer) ds->deviceLayer = -1;
      if (ds->removing) {
        LifecycleKlogf(display, "sf destroyLayer %lld while removing",
                       static_cast<long long>(layer));
        if (ds->layers.empty()) released = MarkSfReleasedLocked(display);
      }
    }
    int dropped = 0;
    for (int32_t wlSlot : wlSlots) dropped += wayland_.ReleaseSlot(display, wlSlot);
    if (dropped) LifecycleKlogf(display, "layer %lld gone: %d compositor buffer(s) released",
                                static_cast<long long>(layer), dropped);
    if (released) WakeControlThread();
    return ok();
  }

  // refuse virtual displays as unsupported
  ScopedAStatus createVirtualDisplay(int32_t, int32_t,
                                      ::aidl::android::hardware::graphics::common::PixelFormat,
                                      int32_t, VirtualDisplay*) override {
    return clientErr(IComposerClient::EX_UNSUPPORTED, "no virtual displays in v1");
  }
  // refuse virtual displays as unsupported
  ScopedAStatus destroyVirtualDisplay(int64_t) override {
    return clientErr(IComposerClient::EX_UNSUPPORTED, "no virtual displays in v1");
  }

  // build a command error payload
  static CommandResultPayload MakeCommandError(int32_t errorCode) {
    CommandError err;
    err.commandIndex = 0;
    err.errorCode = errorCode;
    CommandResultPayload p;
    p.set<CommandResultPayload::error>(std::move(err));
    return p;
  }

  // apply display commands and present frames
  ScopedAStatus executeCommands(const std::vector<DisplayCommand>& commands,
                                 std::vector<CommandResultPayload>* out) override {
    const int64_t tCall = NowNanos();
    std::unique_lock<std::mutex> lg(mutex_);
    const int64_t tLocked = NowNanos();
    for (const auto& cmd : commands) {
      DisplayState* ds = FindLocked(cmd.display);
      if (!ds) continue;
      ds->costLock.add(tLocked - tCall);
      const int64_t tApply0 = NowNanos();

      if (cmd.brightness.has_value()) {
        out->push_back(MakeCommandError(IComposerClient::EX_UNSUPPORTED));
      }
      for (const auto& lc : cmd.layers) {
        if (lc.brightness.has_value()) {
          float b = lc.brightness->brightness;
          if (!(b >= 0.0f && b <= 1.0f)) {
            out->push_back(MakeCommandError(IComposerClient::EX_BAD_PARAMETER));
          }
        }
      }

      if (cmd.colorTransformMatrix.has_value()) {
        ds->displayColorTransformed = !IsIdentityMatrix(*cmd.colorTransformMatrix);
      }
      ApplyLayerCommands(*ds, cmd);
      bool presentedNow = false;
      int64_t tValidated = 0;

      if (cmd.validateDisplay || cmd.presentOrValidateDisplay) {
        ds->expectedPresentTimeNanos =
            cmd.expectedPresentTime.has_value() ? cmd.expectedPresentTime->timestampNanos : 0;

        const int64_t device = DeviceCandidate(*ds);
        ds->deviceLayer = device;
        tValidated = NowNanos();
        ds->costApply.add(tValidated - tApply0);
        ChangedCompositionTypes changed;
        changed.display = cmd.display;
        for (const auto& lc : cmd.layers) {
          if (!lc.composition.has_value()) continue;
          if (lc.layer == device) continue;
          if (lc.composition->composition == Composition::DISPLAY_DECORATION) {
            out->push_back(MakeCommandError(IComposerClient::EX_UNSUPPORTED));
          }
        }
        for (const auto& [layerId, ls] : ds->layers) {
          if (layerId == device) continue;
          if (ls.requested == Composition::DISPLAY_DECORATION) continue;
          if (ls.requested == Composition::CURSOR) {
            continue;
          }
          if (layerId == ds->cursor.layerId || ls.haveCursorPos) continue;
          if (ls.requested != Composition::CLIENT) {
            ChangedCompositionLayer ccl;
            ccl.layer = layerId;
            ccl.composition = Composition::CLIENT;
            changed.layers.push_back(std::move(ccl));
          }
        }
        if (!changed.layers.empty()) {
          CommandResultPayload p;
          p.set<CommandResultPayload::changedCompositionTypes>(std::move(changed));
          out->push_back(std::move(p));
        }
        if (cmd.presentOrValidateDisplay) {
          presentedNow = ds->deviceLayer >= 0;
          PresentOrValidate pov;
          pov.display = cmd.display;
          pov.result = presentedNow ? PresentOrValidate::Result::Presented
                                    : PresentOrValidate::Result::Validated;
          CommandResultPayload p;
          p.set<CommandResultPayload::presentOrValidateResult>(std::move(pov));
          out->push_back(std::move(p));
        }
      }

      if (cmd.presentDisplay || presentedNow) {
        if (composerVerboseFrames()) {
          klogf("CMD display=%lld present=%d povd=%d validate=%d clientTarget=%d layers=%zu",
                static_cast<long long>(cmd.display), cmd.presentDisplay,
                cmd.presentOrValidateDisplay, cmd.validateDisplay, cmd.clientTarget.has_value(),
                cmd.layers.size());
        }
        const int64_t tPresent0 = NowNanos();
        fenceWaitNs_ = 0;
        if (ds->deviceLayer >= 0) {
          PresentDeviceFrame(*ds);
        } else {
          PresentBufferedFrame(*ds, cmd);
        }
        if (!ds->mousePublished && !ds->layers.empty() && cmd.display != kPrimaryDisplayId) {
          ds->mousePublished = true;
          uinput_.PublishMouse(cmd.display);
        }
        const int64_t tPresent1 = NowNanos();
        ds->costFenceWait.add(fenceWaitNs_);
        ds->costPresent.add(tPresent1 - tPresent0 - fenceWaitNs_);
        (void)tValidated;
        ReportCompositionStatsLocked(ds, cmd.display);

        if (!PaceExpectedPresentTime(lg, cmd.display)) continue;

        const int64_t tFences0 = NowNanos();
        PresentFence pf;
        pf.display = cmd.display;
        pf.fence = ScopedFileDescriptor(TriviallySignaledFence());
        CommandResultPayload p1;
        p1.set<CommandResultPayload::presentFence>(std::move(pf));
        out->push_back(std::move(p1));

        ReleaseFences rf;
        rf.display = cmd.display;
        bool cursorReleased = false;
        int64_t owedCursorLayer = -1;
        if (DisplayState* dsr = FindLocked(cmd.display)) owedCursorLayer = dsr->cursor.pendingRelease;
        for (const auto& lc : cmd.layers) {
          ReleaseFences::Layer rl;
          rl.layer = lc.layer;
          rl.fence = ScopedFileDescriptor(SharedSignaledReleaseFence());
          rf.layers.push_back(std::move(rl));
          if (lc.layer == owedCursorLayer) cursorReleased = true;
        }
        if (owedCursorLayer >= 0 && !cursorReleased) {
          ReleaseFences::Layer rl;
          rl.layer = owedCursorLayer;
          rl.fence = ScopedFileDescriptor(SharedSignaledReleaseFence());
          rf.layers.push_back(std::move(rl));
          cursorReleased = true;
        }
        if (cursorReleased) {
          if (DisplayState* dsr = FindLocked(cmd.display)) {
            if (dsr->cursor.pendingRelease >= 0) {
              dsr->cursor.releasesEmitted++;
              dsr->cursor.pendingRelease = -1;
            }
          }
        }
        CommandResultPayload p2;
        p2.set<CommandResultPayload::releaseFences>(std::move(rf));
        out->push_back(std::move(p2));
        const int64_t tEnd = NowNanos();
        if (DisplayState* ds2 = FindLocked(cmd.display)) {
          ds2->costFences.add(tEnd - tFences0);
          ds2->costTotal.add(tEnd - tCall);
        }
      }
    }
    std::vector<std::pair<int64_t, int32_t>> toRelease;
    for (const auto& cmd : commands) {
      DisplayState* ds = FindLocked(cmd.display);
      if (!ds || ds->pendingSlotReleases.empty()) continue;
      for (int32_t wlSlot : ds->pendingSlotReleases) toRelease.push_back({ds->id, wlSlot});
      ds->pendingSlotReleases.clear();
    }
    lg.unlock();
    int dropped = 0;
    for (const auto& ds_slot : toRelease) dropped += wayland_.ReleaseSlot(ds_slot.first, ds_slot.second);
    if (dropped && !toRelease.empty())
      LifecycleKlogf(toRelease.front().first, "slots cleared: %d compositor buffer(s) released",
                     dropped);
    return ok();
  }

  // return the display's config id
  ScopedAStatus getActiveConfig(int64_t display, int32_t* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    *out = ds->configId;
    return ok();
  }
  // accept a known config id without changing the display
  ScopedAStatus setActiveConfig(int64_t display, int32_t config) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    if (!KnownConfig(*ds, config)) {
      return clientErr(IComposerClient::EX_BAD_CONFIG, "unknown config");
    }
    return ok();
  }
  // accept a known config id
  ScopedAStatus setActiveConfigWithConstraints(
      int64_t display, int32_t config, const VsyncPeriodChangeConstraints&,
      VsyncPeriodChangeTimeline* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    if (!KnownConfig(*ds, config)) {
      return clientErr(IComposerClient::EX_BAD_CONFIG, "unknown config");
    }
    out->newVsyncAppliedTimeNanos = NowNanos();
    out->refreshRequired = false;
    out->refreshTimeNanos = 0;
    return ok();
  }
  // reject setting the boot display config
  ScopedAStatus setBootDisplayConfig(int64_t, int32_t) override {
    return clientErr(IComposerClient::EX_UNSUPPORTED, "boot display config unsupported");
  }
  // refuse boot display configs as unsupported
  ScopedAStatus clearBootDisplayConfig(int64_t) override {
    return clientErr(IComposerClient::EX_UNSUPPORTED, "boot display config unsupported");
  }
  // refuse boot display configs as unsupported
  ScopedAStatus getPreferredBootDisplayConfig(int64_t, int32_t*) override {
    return clientErr(IComposerClient::EX_UNSUPPORTED, "boot display config unsupported");
  }

  // return the native color mode only
  ScopedAStatus getColorModes(int64_t display, std::vector<ColorMode>* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    *out = {ColorMode::NATIVE};
    return ok();
  }
  // return the render intents for a color mode
  ScopedAStatus getRenderIntents(int64_t display, ColorMode mode,
                                  std::vector<RenderIntent>* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    if (mode != ColorMode::NATIVE) {
      return clientErr(IComposerClient::EX_BAD_PARAMETER, "unsupported color mode");
    }
    *out = {RenderIntent::COLORIMETRIC};
    return ok();
  }
  // check the color mode and intent
  ScopedAStatus setColorMode(int64_t display, ColorMode mode, RenderIntent intent) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    if (mode != ColorMode::NATIVE || intent != RenderIntent::COLORIMETRIC) {
      return clientErr(IComposerClient::EX_BAD_PARAMETER, "unsupported color mode/intent");
    }
    return ok();
  }
  // return the identity saturation matrix
  ScopedAStatus getDataspaceSaturationMatrix(
      ::aidl::android::hardware::graphics::common::Dataspace dataspace,
      std::vector<float>* out) override {
    if (dataspace != ::aidl::android::hardware::graphics::common::Dataspace::SRGB_LINEAR) {
      return clientErr(IComposerClient::EX_BAD_PARAMETER, "unsupported dataspace");
    }
    *out = {1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1};
    return ok();
  }

  // return an attribute of a known config
  ScopedAStatus getDisplayAttribute(int64_t display, int32_t config, DisplayAttribute attribute,
                                     int32_t* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    if (!KnownConfig(*ds, config)) {
      return clientErr(IComposerClient::EX_BAD_CONFIG, "unknown config");
    }
    switch (attribute) {
      case DisplayAttribute::WIDTH: *out = ConfigById(*ds, config).width; return ok();
      case DisplayAttribute::HEIGHT: *out = ConfigById(*ds, config).height; return ok();
      case DisplayAttribute::VSYNC_PERIOD: *out = ConfigById(*ds, config).vsyncPeriod; return ok();
      case DisplayAttribute::DPI_X: *out = static_cast<int32_t>(ds->dpi * 1000.0f); return ok();
      case DisplayAttribute::DPI_Y: *out = static_cast<int32_t>(ds->dpi * 1000.0f); return ok();
      case DisplayAttribute::CONFIG_GROUP: *out = ConfigById(*ds, config).group; return ok();
      default: return clientErr(IComposerClient::EX_BAD_PARAMETER, "unknown attribute");
    }
  }
  // list the display's config ids
  ScopedAStatus getDisplayConfigs(int64_t display, std::vector<int32_t>* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    out->clear();
    for (const auto& c : ds->configs) out->push_back(c.id);
    return ok();
  }
  // list the display's configs
  ScopedAStatus getDisplayConfigurations(int64_t display, int32_t,
                                          std::vector<DisplayConfiguration>* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    out->clear();
    for (const auto& cfg : ds->configs) {
      DisplayConfiguration c;
      c.configId = cfg.id;
      c.width = cfg.width;
      c.height = cfg.height;
      DisplayConfiguration::Dpi dpi;
      dpi.x = ds->dpi;
      dpi.y = ds->dpi;
      c.dpi = dpi;
      c.configGroup = cfg.group;
      c.vsyncPeriod = cfg.vsyncPeriod;
      c.vrrConfig = std::nullopt;
      c.hdrOutputType = OutputType::SDR;
      out->push_back(c);
    }
    return ok();
  }

  // return an empty display capability list
  ScopedAStatus getDisplayCapabilities(int64_t display,
                                        std::vector<DisplayCapability>* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    *out = {};
    return ok();
  }
  // return the display connection type
  ScopedAStatus getDisplayConnectionType(int64_t display, DisplayConnectionType* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    *out = ds->internal ? DisplayConnectionType::INTERNAL : DisplayConnectionType::EXTERNAL;
    return ok();
  }
  // return the port and EDID of a display
  ScopedAStatus getDisplayIdentificationData(int64_t display, DisplayIdentification* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    out->port = static_cast<int8_t>(ds->port);
    out->data = BuildEdidBlock(ds->id, ds->port);
    out->screenPartStatus = ScreenPartStatus::UNSUPPORTED;
    return ok();
  }
  // return "Rhizo Display" followed by the display id
  ScopedAStatus getDisplayName(int64_t display, std::string* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    *out = "Rhizo Display " + std::to_string(ds->id);
    return ok();
  }
  // return the display's vsync period in nanoseconds
  ScopedAStatus getDisplayVsyncPeriod(int64_t display, int32_t* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    *out = static_cast<int32_t>(ds->vsyncPeriodNs);
    return ok();
  }
  // return no transform for a known display
  ScopedAStatus getDisplayPhysicalOrientation(
      int64_t display, ::aidl::android::hardware::graphics::common::Transform* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    *out = ::aidl::android::hardware::graphics::common::Transform::NONE;
    return ok();
  }
  // report no display decoration support
  ScopedAStatus getDisplayDecorationSupport(
      int64_t, std::optional<::aidl::android::hardware::graphics::common::DisplayDecorationSupport>* out) override {
    *out = std::nullopt;
    return ok();
  }
  // refuse content sampling as unsupported
  ScopedAStatus getDisplayedContentSample(int64_t, int64_t, int64_t,
                                           DisplayContentSample*) override {
    return clientErr(IComposerClient::EX_UNSUPPORTED, "content sampling unsupported");
  }
  // refuse content sampling as unsupported
  ScopedAStatus getDisplayedContentSamplingAttributes(
      int64_t, DisplayContentSamplingAttributes*) override {
    return clientErr(IComposerClient::EX_UNSUPPORTED, "content sampling unsupported");
  }
  // refuse content sampling as unsupported
  ScopedAStatus setDisplayedContentSamplingEnabled(int64_t, bool, FormatColorComponent,
                                                    int64_t) override {
    return clientErr(IComposerClient::EX_UNSUPPORTED, "content sampling unsupported");
  }

  // report no hdr types and zero luminance for a known display
  ScopedAStatus getHdrCapabilities(int64_t display, HdrCapabilities* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    out->types = {};
    out->maxLuminance = out->maxAverageLuminance = out->minLuminance = 0;
    return ok();
  }
  // return no per-frame metadata keys for a known display
  ScopedAStatus getPerFrameMetadataKeys(int64_t display,
                                         std::vector<PerFrameMetadataKey>* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    *out = {};
    return ok();
  }
  // report no overlay combinations, mixed color spaces or luts
  ScopedAStatus getOverlaySupport(OverlayProperties* out) override {
    out->combinations = {};
    out->supportMixedColorSpaces = false;
    out->lutProperties = std::nullopt;
    return ok();
  }
  // return no hdr conversion capabilities
  ScopedAStatus getHdrConversionCapabilities(
      std::vector<::aidl::android::hardware::graphics::common::HdrConversionCapability>* out) override {
    *out = {};
    return ok();
  }
  // return Hdr::INVALID for any strategy
  ScopedAStatus setHdrConversionStrategy(
      const ::aidl::android::hardware::graphics::common::HdrConversionStrategy&,
      ::aidl::android::hardware::graphics::common::Hdr* out) override {
    *out = ::aidl::android::hardware::graphics::common::Hdr::INVALID;
    return ok();
  }
  // return zero virtual displays
  ScopedAStatus getMaxVirtualDisplayCount(int32_t* out) override {
    *out = 0;
    return ok();
  }
  // return no content types for a known display
  ScopedAStatus getSupportedContentTypes(int64_t display,
                                          std::vector<ContentType>* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    *out = {};
    return ok();
  }
  // accept only the NONE content type
  ScopedAStatus setContentType(int64_t display, ContentType type) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    if (type != ContentType::NONE) return clientErr(IComposerClient::EX_UNSUPPORTED, "no content types supported");
    return ok();
  }
  // reject auto low latency mode
  ScopedAStatus setAutoLowLatencyMode(int64_t display, bool) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    return clientErr(IComposerClient::EX_UNSUPPORTED, "ALLM unsupported");
  }
  // reject the idle timer
  ScopedAStatus setIdleTimerEnabled(int64_t display, int32_t) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    return clientErr(IComposerClient::EX_UNSUPPORTED, "idle timer unsupported");
  }
  // refuse the refresh rate changed debug callback as unsupported
  ScopedAStatus setRefreshRateChangedCallbackDebugEnabled(int64_t display, bool) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    return clientErr(IComposerClient::EX_UNSUPPORTED, "refresh rate changed callback debug unsupported");
  }
  // accept and ignore an expected present time
  ScopedAStatus notifyExpectedPresent(int64_t, const ClockMonotonicTimestamp&, int32_t) override {
    return ok();
  }
  // refuse picture profiles as unsupported
  ScopedAStatus getMaxLayerPictureProfiles(int64_t display, int32_t*) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    return clientErr(IComposerClient::EX_UNSUPPORTED, "picture profiles unsupported");
  }
  // accept and ignore an hdcp negotiation request
  ScopedAStatus startHdcpNegotiation(
      int64_t, const ::aidl::android::hardware::drm::HdcpLevels&) override {
    return ok();
  }
  // return no luts
  ScopedAStatus getLuts(int64_t, const std::vector<Buffer>&, std::vector<Luts>* out) override {
    out->clear();
    return ok();
  }

  // accept and ignore a client target slot count
  ScopedAStatus setClientTargetSlotCount(int64_t, int32_t) override { return ok(); }
  // set the display power mode
  ScopedAStatus setPowerMode(int64_t display, PowerMode mode) override {
    int32_t announcePort = -1;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLocked(display);
      if (!ds) return badDisplay();
      switch (mode) {
        case PowerMode::OFF:
        case PowerMode::ON:
          break;
        case PowerMode::DOZE:
        case PowerMode::DOZE_SUSPEND:
        case PowerMode::ON_SUSPEND:
          return clientErr(IComposerClient::EX_UNSUPPORTED, "power mode unsupported");
        default:
          return clientErr(IComposerClient::EX_BAD_PARAMETER, "unknown power mode");
      }
      klogf("setPowerMode(display=%lld, %d)", static_cast<long long>(display),
            static_cast<int32_t>(mode));
      if (ds->removing) {
        LifecycleKlogf(display, "sf setPowerMode %d while removing",
                       static_cast<int32_t>(mode));
      }
      if (mode == PowerMode::ON && ds->powerMode != PowerMode::ON &&
          display != kPrimaryDisplayId) {
        announcePort = ds->port;
      }
      ds->powerMode = mode;
    }
    if (announcePort >= 0) {
      WriteControlReply("display powered id=" + std::to_string(display) + " port=" +
                        std::to_string(announcePort));
    }
    return ok();
  }
  // enable or disable vsync on a display
  ScopedAStatus setVsyncEnabled(int64_t display, bool enabled) override {
    bool released = false;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLocked(display);
      if (!ds) return badDisplay();
      ds->vsyncEnabled = enabled;
      ds->timerNextNs = 0;
      if (ds->removing) {
        LifecycleKlogf(display, "sf setVsyncEnabled %d while removing", enabled ? 1 : 0);
        if (!enabled) released = MarkSfReleasedLocked(display);
      }
      wayland_.SetVsyncEnabled(enabled);
      vsyncCv_.notify_all();
    }
    if (released) WakeControlThread();
    return ok();
  }

  // report RGBA_8888 with an unknown dataspace for readback
  ScopedAStatus getReadbackBufferAttributes(int64_t display, ReadbackBufferAttributes* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    out->format = ::aidl::android::hardware::graphics::common::PixelFormat::RGBA_8888;
    out->dataspace = ::aidl::android::hardware::graphics::common::Dataspace::UNKNOWN;
    return ok();
  }
  // wait for the release fence and hold the readback buffer
  ScopedAStatus setReadbackBuffer(int64_t display, const NativeHandle& buffer,
                                   const ScopedFileDescriptor& releaseFence) override {
    klog("setReadbackBuffer() CALLED");
    if (releaseFence.get() >= 0) WaitAndCloseFence(dup(releaseFence.get()));
    NhView v = ViewNativeHandle(buffer);
    if (v.fd < 0 || !v.decoded.valid) return clientErr(IComposerClient::EX_BAD_PARAMETER, "bad readback buffer");
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(display);
    if (!ds) return badDisplay();
    for (auto& kv : ds->layers) kv.second.Reset();
    ds->readback.Adopt(dup(v.fd));
    ds->readback.decoded = v.decoded;
    return ok();
  }
  // return an invalid fence fd
  ScopedAStatus getReadbackBufferFence(int64_t display, ScopedFileDescriptor* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (!FindLocked(display)) return badDisplay();
    *out = ScopedFileDescriptor(-1);
    return ok();
  }

  // store the callback and send primary hotplug
  ScopedAStatus registerCallback(const std::shared_ptr<IComposerCallback>& cb) override {
    klog("registerCallback() entered");
    {
      std::lock_guard<std::mutex> lg(mutex_);
      callback_ = cb;
    }
    klog("calling onHotplugEvent synchronously");
    auto st = cb->onHotplugEvent(
        kPrimaryDisplayId,
        ::aidl::android::hardware::graphics::common::DisplayHotplugEvent::CONNECTED);
    klogf("onHotplugEvent status: isOk=%d exceptionCode=%d", st.isOk(),
          st.isOk() ? 0 : st.getExceptionCode());
    StartVsyncThreadOnce();
    StartControlThreadOnce();
    std::thread([this] {
      ThreadGuard g(transientThreads_);
      if (shuttingDown_.load(std::memory_order_acquire)) return;
      TryStartPrimaryWaylandSurface();
    }).detach();
    klog("registerCallback() returning");
    return ok();
  }

  bool ready() const { return true; }

 private:
  struct LayerState {
    std::map<int32_t, HeldBuffer> slots;
    int32_t slot = -1;
    OwnedFd acquire;
    Composition requested = Composition::CLIENT;
    ::aidl::android::hardware::graphics::common::Rect displayFrame{};
    ::aidl::android::hardware::graphics::common::FRect sourceCrop{};
    ::aidl::android::hardware::graphics::common::BlendMode blend =
        ::aidl::android::hardware::graphics::common::BlendMode::NONE;
    float alpha = 1.0f;
    ::aidl::android::hardware::graphics::common::Transform transform =
        ::aidl::android::hardware::graphics::common::Transform::NONE;
    int32_t z = 0;
    bool colorTransformed = false;
    bool sideband = false;
    bool cursorContentPending = false;
    bool haveCursorPos = false;
    int32_t cursorPosX = 0;
    int32_t cursorPosY = 0;
    LayerState() = default;
    ~LayerState() { Reset(); }
    LayerState(const LayerState&) = delete;
    LayerState& operator=(const LayerState&) = delete;
    LayerState(LayerState&&) = default;
    LayerState& operator=(LayerState&&) = default;
    // clear the buffer slots and close the acquire fence
    void Reset() {
      slots.clear();
      acquire.reset();
    }
  };

  struct DisplayState {
    int64_t id = -1;
    int32_t width = kDefaultWidth;
    int32_t height = kDefaultHeight;
    int32_t configGroup = 0;
    struct Config {
      int32_t id = kConfigId;
      int32_t width = kDefaultWidth;
      int32_t height = kDefaultHeight;
      int32_t group = 0;
      int32_t vsyncPeriod = kVsyncPeriodNs;
    };
    std::vector<Config> configs{Config{}};
    int32_t configId = kConfigId;
    int64_t vsyncPeriodNs = kVsyncPeriodNs;

    // copy the display size into the last config
    void SyncConfig() {
      configs.back().id = configId;
      configs.back().width = width;
      configs.back().height = height;
      configs.back().group = configGroup;
      configs.back().vsyncPeriod = static_cast<int32_t>(vsyncPeriodNs);
    }
    int32_t port = 0;
    bool internal = false;
    float dpi = kBaseDpi;
    int32_t cursorScaleMilli = 1000;
    bool cursorAccelerated = false;
    int32_t scale120 = 120;
    int32_t cropX = 0;
    int32_t cropY = 0;
    int32_t cropW = 0;
    int32_t cropH = 0;
    int32_t taskW = 0;
    int32_t taskH = 0;
    bool taskDrawn = false;
    bool fillSampled = false;
    int32_t framesSinceFill = 0;
    uint32_t fillRgba = 0xffffffffu;
    PowerMode powerMode = PowerMode::OFF;
    bool vsyncEnabled = false;
    bool waylandBacked = false;
    bool claimed = true;
    int64_t lastVsyncNs = 0;
    int64_t lastSentVsyncNs = 0;
    int64_t timerNextNs = 0;
    bool timerDriving = false;
    uint64_t vsyncRecv = 0;
    uint64_t vsyncSent = 0;
    uint64_t vsyncDropped = 0;
    uint64_t presented = 0;
    uint32_t presentsSinceFeedback = 0;
    int64_t lastFeedbackNs = 0;
    uint64_t discarded = 0;
    uint64_t timerTicks = 0;
    uint64_t timerTakeovers = 0;
    uint64_t vsyncRecvReported = 0;
    uint64_t vsyncSentReported = 0;
    uint64_t vsyncDroppedReported = 0;
    uint64_t presentedReported = 0;
    uint64_t discardedReported = 0;
    uint64_t timerTicksReported = 0;
    uint64_t timerTakeoversReported = 0;
    int64_t lastVsyncStatsNs = 0;
    std::map<int64_t, LayerState> layers;
    struct CursorLayerState {
      bool valid = false;
      uint64_t bufferId = 0;
      int32_t width = 0;
      int32_t height = 0;
      int32_t hotspotX = 0;
      int32_t hotspotY = 0;
      bool hotspotMeasured = false;
      uint32_t digest = 0;
      uint64_t imageChanges = 0;
      rhizo::PointerTypeAsk typeAsk;
      uint64_t layerCmds = 0;
      uint64_t offered = 0;
      uint64_t seen = 0;
      uint64_t uploads = 0;
      uint64_t bufferCmds = 0;
      uint64_t releasesOwed = 0;
      uint64_t releasesEmitted = 0;
      int64_t pendingRelease = -1;
      uint64_t namedCursor = 0;
      uint64_t idChanges = 0;
      const char* lastSkip = "none";
      int64_t layerId = -1;
    } cursor;
    int64_t nextLayerId = 1;
    int64_t deviceLayer = -1;
    const char* deviceReason = "no-validate";
    // timing totals for a stage
    struct StageCost {
      uint64_t n = 0, ns = 0, maxNs = 0;
      void add(int64_t d) { n++; ns += d; if (static_cast<uint64_t>(d) > maxNs) maxNs = d; }
      void reset() { n = 0; ns = 0; maxNs = 0; }
      std::string str() const {
        char b[48];
        snprintf(b, sizeof b, "%.0f/%llu", n ? ns / 1000.0 / n : 0.0, (unsigned long long)(maxNs / 1000));
        return b;
      }
    };
    StageCost costLock, costApply, costFenceWait, costPresent, costFences, costTotal;
    uint64_t deviceFrames = 0, clientFrames = 0, deviceFramesReported = 0, clientFramesReported = 0;
    uint64_t releaseHeld = 0, releaseHeldReported = 0;
    int32_t lastDeviceSlot = -1;
    std::vector<int32_t> pendingSlotReleases;
    int64_t lastCompositionStatsNs = 0;
    std::map<std::string, uint64_t> deviceRefusals;
    bool displayColorTransformed = false;
    HeldBuffer current;
    HeldBuffer readback;
    std::map<int32_t, HeldBuffer> clientTargetSlots;
    uint64_t presentCount = 0;
    bool mousePublished = false;
    // latency from tap to presentation
    struct TapLatency {
      bool armed = false;
      uint32_t armTimeMsec = 0;
      int64_t armQueuedNs = 0;
      uint64_t armPresentCount = 0;
      uint64_t count = 0;
      int64_t sumNs = 0;
      int64_t minNs = 0;
      int64_t maxNs = 0;
      int64_t lastNs = 0;
      uint64_t wireDeltaCount = 0;
      int64_t wireDeltaSumNs = 0;
      int64_t wireDeltaMinNs = 0;
      int64_t wireDeltaMaxNs = 0;
      int64_t wireDeltaLastNs = 0;
      int64_t uinputNs = 0;
      int64_t sfPresentNs = 0;
      int64_t hopUinputNs = 0;
      int64_t hopSfPresentNs = 0;
      int64_t hopCommitNs = 0;
    } tap;
    // timing of the first present
    struct FirstPresent {
      bool armed = false;
      int64_t armNs = 0;
      int64_t sfPresentNs = 0;
      int64_t commitNs = 0;
      int64_t presentedNs = 0;
      uint64_t count = 0;
    } firstPresent;
    std::chrono::steady_clock::time_point lastConnectAt{};
    bool removing = false;
    int removingCallsLogged = 0;
    int64_t lastFrameworkQueryNs = 0;
    int64_t lastPresentSignalNs = 0;
    int64_t expectedPresentTimeNanos = 0;
  };

  // wait for the target present time
  bool PaceExpectedPresentTime(std::unique_lock<std::mutex>& lg, int64_t display) {
    DisplayState* ds = FindLocked(display);
    if (!ds) return false;
    const ComposerPacingMode mode = composerPacingMode();
    if (mode == ComposerPacingMode::kOff) {
      ds->expectedPresentTimeNanos = 0;
      ds->lastPresentSignalNs = NowNanos();
      return true;
    }
    int64_t natural, target;
    if (mode == ComposerPacingMode::kNatural) {
      const int64_t kNaturalSpacingNs = kVsyncPeriodNs / 2 + 1000000;
      natural = ds->lastPresentSignalNs > 0 ? ds->lastPresentSignalNs + kNaturalSpacingNs : 0;
      target = natural;
    } else {
      natural = ds->lastPresentSignalNs > 0 ? ds->lastPresentSignalNs + kVsyncPeriodNs : 0;
      target = std::max(natural, ds->expectedPresentTimeNanos);
    }
    ds->expectedPresentTimeNanos = 0;
    if (target > 0) {
      int64_t deltaNs = target - NowNanos();
      constexpr int64_t kMaxWaitNs = 2LL * 1000 * 1000 * 1000;
      if (deltaNs > 0) {
        if (deltaNs > kMaxWaitNs) deltaNs = kMaxWaitNs;
        struct timespec ts;
        ts.tv_sec = deltaNs / 1000000000LL;
        ts.tv_nsec = deltaNs % 1000000000LL;
        lg.unlock();
        nanosleep(&ts, nullptr);
        lg.lock();
        ds = FindLocked(display);
        if (!ds) return false;
      }
    }
    ds->lastPresentSignalNs = NowNanos();
    return true;
  }

  static constexpr int64_t kQuiescenceGapNs = 50LL * 1000 * 1000;
  static constexpr int64_t kQuiescenceMaxWaitNs = 1500LL * 1000 * 1000;
  static constexpr useconds_t kQuiescencePollUs = 10 * 1000;

  // search the display configs for an id
  static bool KnownConfig(const DisplayState& ds, int32_t config) {
    for (const auto& c : ds.configs) {
      if (c.id == config) return true;
    }
    return false;
  }

  // return the config with the given id
  static const DisplayState::Config& ConfigById(const DisplayState& ds, int32_t config) {
    for (const auto& c : ds.configs) {
      if (c.id == config) return c;
    }
    return ds.configs.back();
  }

  // return the display state for an id
  DisplayState* FindLocked(int64_t display, const char* who = __builtin_FUNCTION()) {
    auto it = displays_.find(display);
    if (it != displays_.end()) {
      it->second.lastFrameworkQueryNs = NowNanos();
      return &it->second;
    }
    auto rit = removingDisplays_.find(display);
    if (rit != removingDisplays_.end()) {
      rit->second.lastFrameworkQueryNs = NowNanos();
      NoteRemovingCallLocked(rit->second, who);
      return &rit->second;
    }
    return nullptr;
  }

  // log a call to a removing display
  void NoteRemovingCallLocked(DisplayState& ds, const char* who) {
    if (!who || ds.removingCallsLogged >= kRemovingCallKlogMax) return;
    if (!strcmp(who, "destroyLayer") || !strcmp(who, "setVsyncEnabled") ||
        !strcmp(who, "setPowerMode")) {
      return;
    }
    ds.removingCallsLogged++;
    LifecycleKlogf(ds.id, "call fn=%s while removing", who);
  }

  // mark the display removal released
  bool MarkSfReleasedLocked(int64_t id) {
    auto it = awaitingSfRelease_.find(id);
    if (it == awaitingSfRelease_.end() || it->second.released) return false;
    it->second.released = true;
    LifecycleKlogf(id, "sf-released after %lldms",
                   static_cast<long long>((NowNanos() - it->second.sentNs) / 1000000));
    return true;
  }

  // return the live display state for an id
  DisplayState* FindLiveRaw(int64_t display) {
    auto it = displays_.find(display);
    return it == displays_.end() ? nullptr : &it->second;
  }

  // return a live or removing display state
  DisplayState* FindAnyRaw(int64_t display) {
    auto it = displays_.find(display);
    if (it != displays_.end()) return &it->second;
    auto rit = removingDisplays_.find(display);
    return rit == removingDisplays_.end() ? nullptr : &rit->second;
  }

  // wait for queries on a display to stop
  void WaitForQuiescence(int64_t id) {
    const int64_t deadline = NowNanos() + kQuiescenceMaxWaitNs;
    for (;;) {
      int64_t now = NowNanos();
      int64_t lastQuery;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindAnyRaw(id);
        if (!ds) return;
        lastQuery = ds->lastFrameworkQueryNs;
      }
      if (now - lastQuery >= kQuiescenceGapNs) return;
      if (now >= deadline) return;
      usleep(kQuiescencePollUs);
    }
  }

  // wait for hotplug events to stop
  void WaitForGlobalQuiescence() {
    const int64_t deadline = NowNanos() + kQuiescenceMaxWaitNs;
    for (;;) {
      int64_t now = NowNanos();
      int64_t last;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        last = lastAnyHotplugNs_;
      }
      if (now - last >= kQuiescenceGapNs) return;
      if (now >= deadline) return;
      usleep(kQuiescencePollUs);
    }
  }

  // check for the identity matrix
  static bool IsIdentityMatrix(const std::vector<float>& m) {
    if (m.size() != 16) return false;
    for (int i = 0; i < 16; i++) {
      const float want = (i % 5 == 0) ? 1.0f : 0.0f;
      if (std::fabs(m[i] - want) > 1e-4f) return false;
    }
    return true;
  }

  static constexpr int32_t kDeviceSlotBase = 4096;

  static constexpr int32_t kMaxCursorEdge = 512;

  // return the 32-bit FNV-1a hash of the bytes
  static uint32_t Fnv1a32(const uint8_t* data, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) { h ^= data[i]; h *= 16777619u; }
    return h;
  }

  // send the cursor image to the compositor
  void UpdateCursorLayerLocked(DisplayState& ds, LayerState& ls, bool byName = true) {
    ds.cursor.offered++;
    auto sit = ls.slots.find(ls.slot);
    if (ls.slot < 0) { ds.cursor.lastSkip = "no-slot"; return; }
    if (sit == ls.slots.end()) { ds.cursor.lastSkip = "slot-not-held"; return; }
    if (sit->second.fd < 0) { ds.cursor.lastSkip = "no-fd"; return; }
    const rhizo::DecodedHandle& d = sit->second.decoded;
    ds.cursor.seen++;
    if (!ls.cursorContentPending && ds.cursor.valid) return;
    if (d.width <= 0 || d.height <= 0 || d.stride <= 0) return;
    if (!byName && (d.width > kMaxCursorEdge || d.height > kMaxCursorEdge)) {
      ds.cursor.layerId = -1;
      return;
    }
    const bool isBgra = d.drmFourcc == rhizo::kDrmFormatArgb8888;
    const bool isRgba = d.drmFourcc == rhizo::kDrmFormatAbgr8888;
    if (!isBgra && !isRgba) {
      klogf("cursor layer: unsupported drm format 0x%x for display %lld", d.drmFourcc,
            static_cast<long long>(ds.id));
      return;
    }
    ls.cursorContentPending = false;
    ds.cursor.releasesOwed++;
    ds.cursor.pendingRelease = ds.cursor.layerId;
    if (ls.acquire.get() >= 0) {
      struct pollfd pfd{ls.acquire.get(), POLLIN, 0};
      poll(&pfd, 1, kClientTargetFenceWaitMs);
    }
    const size_t srcSize =
        d.allocSize ? d.allocSize : static_cast<size_t>(d.stride) * d.height;
    void* s = mmap(nullptr, srcSize, PROT_READ, MAP_SHARED, sit->second.fd, 0);
    if (s == MAP_FAILED) {
      klogf("cursor layer: mmap failed for display %lld", static_cast<long long>(ds.id));
      return;
    }
    std::vector<uint8_t> argb(static_cast<size_t>(d.width) * d.height * 4);
    const uint8_t* src = static_cast<const uint8_t*>(s);
    for (int32_t row = 0; row < d.height; row++) {
      const uint8_t* srow = src + static_cast<size_t>(row) * d.stride;
      uint8_t* drow = argb.data() + static_cast<size_t>(row) * d.width * 4;
      for (int32_t col = 0; col < d.width; col++) {
        const uint8_t* sp = srow + col * 4;
        uint8_t* dp = drow + col * 4;
        if (isBgra) {
          dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2]; dp[3] = sp[3];
        } else {
          dp[0] = sp[2]; dp[1] = sp[1]; dp[2] = sp[0]; dp[3] = sp[3];
        }
      }
    }
    munmap(s, srcSize);

    // the hotspot is the pointer less the sprite origin
    int32_t hotspotX = 0, hotspotY = 0;
    int32_t px = 0, py = 0;
    if (GetCursorPointerAbs(ds.id, &px, &py)) {
      hotspotX = px - (ls.haveCursorPos ? ls.cursorPosX : ls.displayFrame.left);
      hotspotY = py - (ls.haveCursorPos ? ls.cursorPosY : ls.displayFrame.top);
    }
    const bool measured = hotspotX >= 0 && hotspotY >= 0 && hotspotX < d.width && hotspotY < d.height;
    if (hotspotX < 0) hotspotX = 0;
    if (hotspotY < 0) hotspotY = 0;
    if (hotspotX > d.width - 1) hotspotX = d.width - 1;
    if (hotspotY > d.height - 1) hotspotY = d.height - 1;

    const uint32_t digest = Fnv1a32(argb.data(), argb.size());
    const bool newImage = !ds.cursor.valid || digest != ds.cursor.digest;
    // keep an image's first hotspot; later ones differ only by pointer lag
    if (ds.cursor.valid && digest == ds.cursor.digest && d.width == ds.cursor.width &&
        d.height == ds.cursor.height &&
        (ds.cursor.hotspotMeasured || !measured ||
         (hotspotX == ds.cursor.hotspotX && hotspotY == ds.cursor.hotspotY))) {
      ds.cursor.bufferId = d.bufferId;
      return;
    }

    wayland_.SetCursorSurface(ds.id, argb.data(), d.width, d.height, d.width * 4, hotspotX,
                              hotspotY);

    ds.cursor.valid = true;
    ds.cursor.bufferId = d.bufferId;
    ds.cursor.width = d.width;
    ds.cursor.height = d.height;
    ds.cursor.hotspotX = hotspotX;
    ds.cursor.hotspotY = hotspotY;
    ds.cursor.hotspotMeasured = measured;
    ds.cursor.digest = digest;
    ds.cursor.uploads++;
    klogf("cursor layer: display %lld upload #%llu %dx%d hotspot %d,%d digest %u (batches seen %llu)",
          static_cast<long long>(ds.id), (unsigned long long)ds.cursor.uploads, d.width, d.height,
          hotspotX, hotspotY, digest, (unsigned long long)ds.cursor.seen);
    if (newImage) {
      ds.cursor.imageChanges++;
      ShowPointerTypeLocked(ds);
    }
  }

  // show the host shape for the cursor image's pointer type
  void ShowPointerTypeLocked(DisplayState& ds) {
    auto known = pointerTypeByImage_.find(ds.cursor.digest);
    if (known != pointerTypeByImage_.end()) {
      wayland_.SetCursorType(ds.id, known->second);
      return;
    }
    const int64_t now = NowNanos();
    if (pointerTypeAsks_.size() >= kMaxPointerTypeImages) pointerTypeAsks_.clear();
    int& attempts = pointerTypeAsks_[ds.cursor.digest];
    if (!rhizo::ShouldAskPointerType(ds.cursor.typeAsk, now, attempts)) return;
    attempts++;
    ds.cursor.typeAsk = {true, ds.cursor.digest, ds.cursor.imageChanges, now};
    WriteControlReply("display cursor-unknown id=" + std::to_string(ds.id) + " port=" +
                      std::to_string(ds.port) + " digest=" + std::to_string(ds.cursor.digest));
  }

  // copy layer command fields into LayerState
  void ApplyLayerCommands(DisplayState& ds, const DisplayCommand& cmd) {
    for (const auto& lc : cmd.layers) {
      auto it = ds.layers.find(lc.layer);
      if (it == ds.layers.end()) continue;
      LayerState& ls = it->second;
      if (lc.bufferSlotsToClear.has_value()) {
        for (int32_t s : *lc.bufferSlotsToClear) {
          auto sit = ls.slots.find(s);
          if (sit != ls.slots.end()) { sit->second.Reset(); ls.slots.erase(sit); }
          if (ls.slot == s) ls.slot = -1;
          ds.pendingSlotReleases.push_back(kDeviceSlotBase + s);
        }
      }
      if (lc.buffer.has_value()) {
        const Buffer& b = *lc.buffer;
        if (b.handle.has_value()) {
          NhView v = ViewNativeHandle(*b.handle);
          if (v.fd >= 0 && v.decoded.valid) {
            HeldBuffer& hb = ls.slots[b.slot];
            hb.Adopt(dup(v.fd));
            hb.decoded = v.decoded;
          }
        }
        ls.slot = b.slot;
        ls.acquire.reset(b.fence.get() >= 0 ? dup(b.fence.get()) : -1);
        ls.cursorContentPending = true;
      }
      if (lc.cursorPosition.has_value()) {
        ls.haveCursorPos = true;
        ls.cursorPosX = lc.cursorPosition->x;
        ls.cursorPosY = lc.cursorPosition->y;
        int32_t spriteW = 0, spriteH = 0;
        auto spriteIt = ls.slots.find(ls.slot);
        if (ls.slot >= 0 && spriteIt != ls.slots.end()) {
          spriteW = spriteIt->second.decoded.width;
          spriteH = spriteIt->second.decoded.height;
        }
        SetObservedPointer(ds.id, ls.cursorPosX, ls.cursorPosY, spriteW, spriteH);
      }
      if (lc.composition.has_value()) ls.requested = lc.composition->composition;
      if (lc.displayFrame.has_value()) ls.displayFrame = *lc.displayFrame;
      if (lc.sourceCrop.has_value()) ls.sourceCrop = *lc.sourceCrop;
      if (lc.blendMode.has_value()) ls.blend = lc.blendMode->blendMode;
      if (lc.planeAlpha.has_value()) ls.alpha = lc.planeAlpha->alpha;
      if (lc.transform.has_value()) ls.transform = lc.transform->transform;
      if (lc.z.has_value()) ls.z = lc.z->z;
      if (lc.colorTransform.has_value()) ls.colorTransformed = !IsIdentityMatrix(*lc.colorTransform);
      if (lc.sidebandStream.has_value()) ls.sideband = true;
      if (ls.requested == Composition::CURSOR) {
        ds.cursor.namedCursor++;
        if (ds.cursor.layerId != lc.layer) ds.cursor.idChanges++;
        ds.cursor.layerId = lc.layer;
      }
      if (ds.cursor.layerId >= 0 && lc.layer == ds.cursor.layerId) {
        ds.cursor.layerCmds++;
        if (lc.buffer.has_value()) ds.cursor.bufferCmds++;
      }
      if (ls.requested == Composition::CURSOR || lc.layer == ds.cursor.layerId) {
        UpdateCursorLayerLocked(ds, ls,  ls.requested == Composition::CURSOR);
      }
    }
  }

  // return the device-composed layer id
  int64_t DeviceCandidate(DisplayState& ds) {
    auto refuse = [&](const char* why) { ds.deviceReason = why; ds.deviceRefusals[why]++; return -1; };
    if (!composerDeviceEnabled()) return refuse("disabled");
    if (!ds.waylandBacked) return refuse("headless");
    if (ds.readback.fd >= 0) return refuse("readback-armed");
    if (ds.displayColorTransformed) return refuse("display-color-transform");
    if (ds.layers.size() != 1) return refuse(ds.layers.empty() ? "no-layer" : "multiple-layers");
    auto& [id, ls] = *ds.layers.begin();
    if (ls.requested != Composition::DEVICE) return refuse("not-requested");
    if (ls.sideband) return refuse("sideband");
    auto sit = ls.slots.find(ls.slot);
    if (ls.slot < 0 || sit == ls.slots.end() || sit->second.fd < 0) return refuse("no-buffer");
    const rhizo::DecodedHandle& d = sit->second.decoded;
    if (d.width <= 0 || d.height <= 0 || d.stride <= 0) return refuse("bad-geometry");
    using ::aidl::android::hardware::graphics::common::Transform;
    if (ls.transform != Transform::NONE) return refuse("transform");
    if (ls.colorTransformed) return refuse("layer-color-transform");
    if (ls.alpha < 0.999f) return refuse("alpha");
    const uint32_t fmt = static_cast<uint32_t>(d.drmFourcc);
    const bool hasAlpha = fmt == static_cast<uint32_t>(rhizo::kDrmFormatAbgr8888) ||
                          fmt == static_cast<uint32_t>(rhizo::kDrmFormatArgb8888);
    const bool known = hasAlpha || fmt == static_cast<uint32_t>(rhizo::kDrmFormatXbgr8888) ||
                       fmt == static_cast<uint32_t>(rhizo::kDrmFormatRgb565);
    if (!known) return refuse("format");
    if (ls.blend != ::aidl::android::hardware::graphics::common::BlendMode::NONE && hasAlpha) return refuse("blend");
    const auto& f = ls.displayFrame;
    if (f.left != 0 || f.top != 0 || f.right != ds.width || f.bottom != ds.height) return refuse("frame");
    const auto& c = ls.sourceCrop;
    if (std::fabs(c.left) > 0.5f || std::fabs(c.top) > 0.5f ||
        std::fabs(c.right - d.width) > 0.5f || std::fabs(c.bottom - d.height) > 0.5f) return refuse("crop");
    if (d.width != ds.width || d.height != ds.height) return refuse("size");
    if (rhizo::IsShmemFile(sit->second.fd)) {
      if (!rhizo::ShmemSealedAgainstShrink(sit->second.fd)) return refuse("shm-unsealed");
      if (!wayland_.AcceptsShmFormat(fmt)) return refuse("shm-format");
    } else if (!wayland_.AcceptsBuffer(fmt, d.modifier)) {
      return refuse("modifier");
    }
    ds.deviceReason = "device";
    return id;
  }

  int64_t fenceWaitNs_ = 0;

  // present the device layer buffer to Wayland
  void PresentDeviceFrame(DisplayState& ds) {
    auto lit = ds.layers.find(ds.deviceLayer);
    if (lit == ds.layers.end()) return;
    LayerState& ls = lit->second;
    auto sit = ls.slots.find(ls.slot);
    if (sit == ls.slots.end() || sit->second.fd < 0) return;
    const int32_t wlSlot = kDeviceSlotBase + ls.slot;
    if (ds.lastDeviceSlot >= 0 && !wayland_.SlotReleased(ds.id, ds.lastDeviceSlot)) ds.releaseHeld++;
    ds.current.Adopt(dup(sit->second.fd));
    ds.current.decoded = sit->second.decoded;
    ds.presentCount++;
    ds.deviceFrames++;
    rhizo::WaylandFrame wf;
    wf.slot = wlSlot;
    wf.dmabufFd = ds.current.fd;
    wf.width = ds.current.decoded.width;
    wf.height = ds.current.decoded.height;
    wf.strideBytes = ds.current.decoded.stride;
    wf.drmFormat = static_cast<uint32_t>(ds.current.decoded.drmFourcc);
    wf.modifier = ds.current.decoded.modifier;
    wf.acquireFenceFd = ls.acquire.get();
    PresentToWayland(ds, wf, "PresentDeviceFrame");
    ls.acquire.reset();
    ds.lastDeviceSlot = wlSlot;
  }

  // check the layers for a buffer
  static bool LayerHasBufferLocked(const DisplayState& ds) {
    for (const auto& kv : ds.layers) {
      if (kv.second.slot >= 0) return true;
    }
    return false;
  }

  // return the most common color in a column segment
  uint32_t SampleEdgeColor(const rhizo::WaylandFrame& f, int32_t x, int32_t y0, int32_t y1) {
    if (f.dmabufFd < 0 || f.strideBytes <= 0 || x < 0 || x >= f.width || y0 < 0 || y1 > f.height || y1 <= y0) {
      return 0xffffffffu;
    }
    rhizo::VirtgpuTransferFromHost(f.dmabufFd, f.width, f.height, f.strideBytes, true);
    const size_t size = static_cast<size_t>(f.strideBytes) * f.height;
    void* s = mmap(nullptr, size, PROT_READ, MAP_SHARED, f.dmabufFd, 0);
    if (s == MAP_FAILED) return 0xffffffffu;
    DmaBufSync(f.dmabufFd, true, false);
    const uint8_t* p = static_cast<const uint8_t*>(s);
    std::map<uint32_t, int> counts;
    for (int32_t y = y0; y < y1; y += 8) {
      const uint8_t* px = p + static_cast<size_t>(y) * f.strideBytes + static_cast<size_t>(x) * 4;
      counts[(uint32_t{px[0]} << 24) | (uint32_t{px[1]} << 16) | (uint32_t{px[2]} << 8) | 0xffu]++;
    }
    DmaBufSync(f.dmabufFd, false, false);
    munmap(s, size);
    uint32_t best = 0xffffffffu;
    int bestCount = 0;
    for (const auto& [rgba, n] : counts) {
      if (n > bestCount) {
        best = rgba;
        bestCount = n;
      }
    }
    return best;
  }

  // crop a freeform display's frame to its task below the caption
  void FreeformCropLocked(DisplayState& ds, rhizo::WaylandFrame* f) {
    const LayerState* app = nullptr;
    int64_t best = 0;
    bool bestOpaque = false;
    using ::aidl::android::hardware::graphics::common::BlendMode;
    for (const auto& [layerId, ls] : ds.layers) {
      if (ls.slot < 0 || ls.requested == Composition::SOLID_COLOR || ls.requested == Composition::CURSOR ||
          ls.haveCursorPos || layerId == ds.cursor.layerId) {
        continue;
      }
      const auto& r = ls.displayFrame;
      const int64_t area = static_cast<int64_t>(r.right - r.left) * (r.bottom - r.top);
      const bool opaque = ls.blend == BlendMode::NONE;
      if ((opaque && !bestOpaque) || (opaque == bestOpaque && area > best)) {
        best = area;
        bestOpaque = opaque;
        app = &ls;
      }
    }
    if (!app) return;
    if (resizeTraceEnabled() && wayland_.DraggedSize(ds.id, nullptr, nullptr)) {
      for (const auto& [layerId, ls] : ds.layers) {
        klogf("LAYER_TRACE display %lld layer %lld req=%d slot=%d frame=%d,%d,%d,%d crop=%.0f,%.0f,%.0f,%.0f z=%d "
              "alpha=%.2f blend=%d", static_cast<long long>(ds.id), static_cast<long long>(layerId),
              static_cast<int>(ls.requested), ls.slot, ls.displayFrame.left, ls.displayFrame.top, ls.displayFrame.right,
              ls.displayFrame.bottom, ls.sourceCrop.left, ls.sourceCrop.top, ls.sourceCrop.right, ls.sourceCrop.bottom,
              ls.z, ls.alpha, static_cast<int>(ls.blend));
      }
    }
    const auto& r = app->displayFrame;
    const int32_t captionPx = (kFreeformCaptionDp * ds.scale120 + 60) / 120;
    const int32_t x = std::max(0, r.left), y = std::max(0, r.top + captionPx);
    const auto& sc = app->sourceCrop;
    const int32_t frameW = r.right - r.left, frameH = r.bottom - r.top;
    const int32_t bufW = static_cast<int32_t>(sc.right - sc.left), bufH = static_cast<int32_t>(sc.bottom - sc.top);
    if (ds.taskW > 0 && std::abs(frameW - ds.taskW) <= 1 && std::abs(frameH - (ds.taskH + captionPx)) <= 1 &&
        std::abs(bufW - frameW) <= 1 && std::abs(bufH - frameH) <= 1) {
      ds.taskDrawn = true;
    }
    const int32_t drawnRight = std::min(r.right, r.left + bufW);
    const int32_t drawnBottom = std::min(r.bottom, r.top + bufH);
    int32_t w = std::min(f->width, drawnRight) - x, h = std::min(f->height, drawnBottom) - y;
    int32_t dragW = 0, dragH = 0;
    const bool dragging = wayland_.DraggedSize(ds.id, &dragW, &dragH);
    if (dragging) {
      w = std::min(w, std::min(dragW, f->width - x));
      h = std::min(h, std::min(dragH, f->height - y));
    } else if (!ds.fillSampled || ds.fillRgba == 0x000000ffu || ++ds.framesSinceFill >= 30) {
      ds.fillRgba = SampleEdgeColor(*f, x + w - 3, y, y + h);
      ds.fillSampled = true;
      ds.framesSinceFill = 0;
    }
    if (!dragging && ds.taskW > 0 && !ds.taskDrawn) {
      w = std::min(w, std::min(ds.taskW, f->width - x));
      h = std::min(h, std::min(ds.taskH, f->height - y));
    } else if (!dragging && ds.taskW > 0) {
      const int32_t taskW = std::min(ds.taskW, f->width - x), taskH = std::min(ds.taskH, f->height - y);
      w = std::min(w, taskW);
      h = std::min(h, taskH);
      if (w < taskW || h < taskH) {
        f->fillWidth = taskW;
        f->fillHeight = taskH;
        f->fillRgba = ds.fillRgba;
      }
    }
    if (w <= 0 || h <= 0) return;
    if (resizeTraceEnabled() && (x != ds.cropX || y != ds.cropY || w != ds.cropW || h != ds.cropH)) {
      klogf("CROP_TRACE display %lld %dx%d src=%d,%d %dx%d app=%d,%d,%d,%d buf=%.0fx%.0f layers=%zu",
            static_cast<long long>(ds.id), f->width, f->height, x, y, w, h, r.left, r.top, r.right, r.bottom,
            sc.right - sc.left, sc.bottom - sc.top, ds.layers.size());
    }
    ds.cropW = w;
    ds.cropH = h;
    f->srcX = x;
    f->srcY = y;
    f->srcWidth = w;
    f->srcHeight = h;
    ds.cropX = x;
    ds.cropY = y;
  }

  // send a frame to the Wayland surface
  void PresentToWayland(DisplayState& ds, const rhizo::WaylandFrame& wf, const char* who) {
    if (ds.waylandBacked) {
      const int64_t now = NowNanos();
      if (ds.tap.armed && ds.tap.sfPresentNs == 0) ds.tap.sfPresentNs = now;
      if (ds.firstPresent.armed && ds.firstPresent.sfPresentNs == 0 && LayerHasBufferLocked(ds)) ds.firstPresent.sfPresentNs = now;
      ds.presentsSinceFeedback++;
      rhizo::WaylandFrame shown = wf;
      if (freeformEnabled()) FreeformCropLocked(ds, &shown);
      if (!wayland_.PresentFrameWhenSignaled(ds.id, shown)) {
        klogf("%s: WaylandBackend::PresentFrame FAILED for display %lld", who,
              static_cast<long long>(ds.id));
      }
    }
  }

  // send a frame to the stream export
  void PresentToStream(DisplayState& ds, const HeldBuffer& buf, int64_t presentedNs) {
    if (ds.id != kPrimaryDisplayId) return;
    if (!stream_.EnsureConnected()) return;
    rhizo::StreamFrame sf;
    sf.dmabufFd = buf.fd;
    sf.width = buf.decoded.width;
    sf.height = buf.decoded.height;
    sf.strideBytes = buf.decoded.stride;
    sf.offsetBytes = 0;
    sf.drmFormat = static_cast<uint32_t>(buf.decoded.drmFourcc);
    sf.modifier = buf.decoded.modifier;
    sf.presentedNs = presentedNs;
    if (!stream_.Present(sf)) {
      klog("PresentToStream: StreamExportBackend::Present FAILED, consumer dropped");
    }
  }

  // log composition counts and frame costs
  void ReportCompositionStatsLocked(DisplayState* ds, int64_t displayId) {
    const int64_t now = NowNanos();
    if (ds->lastCompositionStatsNs == 0) { ds->lastCompositionStatsNs = now; return; }
    if (now - ds->lastCompositionStatsNs < kVsyncStatsIntervalNs) return;
    std::string refusals;
    for (const auto& kv : ds->deviceRefusals) {
      refusals += (refusals.empty() ? "" : ",") + kv.first + "=" + std::to_string(kv.second);
    }
    klogf("composition stats: display %lld device=%llu client=%llu release-held=%llu over %lldms "
          "(boot total device=%llu client=%llu) last=%s refusals{%s}",
          static_cast<long long>(displayId),
          (unsigned long long)(ds->deviceFrames - ds->deviceFramesReported),
          (unsigned long long)(ds->clientFrames - ds->clientFramesReported),
          (unsigned long long)(ds->releaseHeld - ds->releaseHeldReported),
          (long long)((now - ds->lastCompositionStatsNs) / 1000000),
          (unsigned long long)ds->deviceFrames, (unsigned long long)ds->clientFrames,
          ds->deviceReason, refusals.c_str());
    klogf("frame cost: display %lld us mean/max lock=%s apply=%s fencewait=%s present=%s fences=%s "
          "total=%s over %llu calls",
          static_cast<long long>(displayId), ds->costLock.str().c_str(), ds->costApply.str().c_str(),
          ds->costFenceWait.str().c_str(), ds->costPresent.str().c_str(), ds->costFences.str().c_str(),
          ds->costTotal.str().c_str(), (unsigned long long)ds->costTotal.n);
    ds->costLock.reset(); ds->costApply.reset(); ds->costFenceWait.reset();
    ds->costPresent.reset(); ds->costFences.reset(); ds->costTotal.reset();
    ds->deviceFramesReported = ds->deviceFrames;
    ds->clientFramesReported = ds->clientFrames;
    ds->releaseHeldReported = ds->releaseHeld;
    ds->deviceRefusals.clear();
    ds->lastCompositionStatsNs = now;
  }

  // present the target buffer
  void PresentBufferedFrame(DisplayState& ds, const DisplayCommand& cmd) {
    if (!cmd.clientTarget.has_value()) return;
    const Buffer& buf = cmd.clientTarget->buffer;
    int fenceFd = buf.fence.get();
    if (fenceFd >= 0 && ds.readback.fd >= 0) {
      struct pollfd pfd{fenceFd, POLLIN, 0};
      const int64_t tWait0 = NowNanos();
      int pr = poll(&pfd, 1, kClientTargetFenceWaitMs);
      fenceWaitNs_ += NowNanos() - tWait0;
      if (composerVerboseFrames()) {
        klogf("clientTarget fence=%d poll_ret=%d revents=0x%x (timeout=%d)", fenceFd, pr,
              pfd.revents, pr == 0);
      }
    }

    const rhizo::DecodedHandle* decoded = nullptr;
    int fd = -1;
    bool newHandle = buf.handle.has_value();
    if (newHandle) {
      NhView v = ViewNativeHandle(*buf.handle);
      if (v.fd < 0 || !v.decoded.valid) {
        klog("presentDisplay: client target handle undecodable, skipping frame");
        return;
      }
      HeldBuffer& slot = ds.clientTargetSlots[buf.slot];
      slot.Adopt(dup(v.fd));
      slot.decoded = v.decoded;
      fd = slot.fd;
      decoded = &slot.decoded;
    } else {
      auto it = ds.clientTargetSlots.find(buf.slot);
      if (it == ds.clientTargetSlots.end() || it->second.fd < 0) {
        klogf("presentDisplay: display %lld slot %d has no cached handle, skipping frame",
              static_cast<long long>(ds.id), buf.slot);
        return;
      }
      fd = it->second.fd;
      decoded = &it->second.decoded;
    }

    if (decoded->width <= 0 || decoded->height <= 0 || decoded->stride <= 0 || fd < 0) {
      klogf("presentDisplay: display %lld invalid client target geometry "
            "w=%d h=%d stride=%d fd=%d -- skipping frame",
            static_cast<long long>(ds.id), decoded->width, decoded->height, decoded->stride, fd);
      return;
    }

    if (composerDebugEnabled() && ds.presentCount % 30 == 0) {
      char link[256] = {0};
      char procPath[64];
      snprintf(procPath, sizeof(procPath), "/proc/self/fd/%d", fd);
      ssize_t n = readlink(procPath, link, sizeof(link) - 1);
      if (n < 0) snprintf(link, sizeof(link), "readlink failed errno=%d", errno);
      struct stat st{};
      int fstatRc = fstat(fd, &st);
      klogf("clientTarget fd identity: display=%lld new=%d slot=%d fd=%d -> %s fstat_rc=%d size=%lld",
            static_cast<long long>(ds.id), newHandle, buf.slot, fd, link, fstatRc,
            (long long)st.st_size);
    }

    ds.current.Adopt(dup(fd));
    ds.current.decoded = *decoded;
    ds.clientFrames++;

    if (ds.waylandBacked) {
      rhizo::WaylandFrame wf;
      wf.slot = buf.slot;
      wf.dmabufFd = ds.current.fd;
      wf.width = ds.current.decoded.width;
      wf.height = ds.current.decoded.height;
      wf.strideBytes = ds.current.decoded.stride;
      wf.drmFormat = static_cast<uint32_t>(ds.current.decoded.drmFourcc);
      wf.modifier = ds.current.decoded.modifier;
      wf.acquireFenceFd = fenceFd;
      PresentToWayland(ds, wf, "PresentBufferedFrame");
    }
    PresentToStream(ds, ds.current, NowNanos());

    InspectClientTarget(ds);

    if (ds.readback.fd >= 0) {
      CopyBuffer(ds.current, ds.readback);
      ds.readback.Reset();
    }
  }

  // log statistics of the current buffer
  void InspectClientTarget(DisplayState& ds) {
    const HeldBuffer& src = ds.current;
    const rhizo::DecodedHandle& d = src.decoded;
    size_t size = d.allocSize ? d.allocSize
                              : static_cast<size_t>(d.stride) * (d.height > 0 ? d.height : 1);
    ++ds.presentCount;
    if (size == 0 || src.fd < 0) {
      klogf("CLIENT TARGET display=%lld bad buffer: size=%zu fd=%d w=%d h=%d stride=%d",
            static_cast<long long>(ds.id), size, src.fd, d.width, d.height, d.stride);
      return;
    }
    if (!composerDebugEnabled()) return;
    if (ds.presentCount != 1 && (ds.presentCount % 30) != 0) return;
    bool wantDump = (access(kDumpRequestPath, F_OK) == 0);

    bool xferOk = rhizo::VirtgpuTransferFromHost(src.fd, d.width, d.height, d.stride,  false);
    if (ds.presentCount == 1 || wantDump) {
      klogf("VirtgpuTransferFromHost -> %s", xferOk ? "ok" : "FAILED");
    }

    void* s = mmap(nullptr, size, PROT_READ, MAP_SHARED, src.fd, 0);
    if (s == MAP_FAILED) { klog("InspectClientTarget: mmap failed"); return; }
    DmaBufSync(src.fd,  true,  false);
    const uint8_t* p = static_cast<const uint8_t*>(s);

    size_t nonZero = 0, rgbNonZero = 0, total = 0;
    for (int y = 0; y < d.height; y += 4) {
      const uint8_t* row = p + static_cast<size_t>(y) * d.stride;
      for (int x = 0; x < d.width; x += 4) {
        const uint8_t* px = row + static_cast<size_t>(x) * 4;
        total++;
        if (px[0] | px[1] | px[2] | px[3]) nonZero++;
        if (px[0] | px[1] | px[2]) rgbNonZero++;
      }
    }
    klogf("CLIENT TARGET display=%lld %dx%d stride=%d sampled=%zu nonZero=%zu (%zu%%) "
          "rgbNonZero=%zu (%zu%%) first px=%02x%02x%02x%02x",
          static_cast<long long>(ds.id), d.width, d.height, d.stride, total, nonZero,
          total ? nonZero * 100 / total : 0, rgbNonZero, total ? rgbNonZero * 100 / total : 0, p[0],
          p[1], p[2], p[3]);

    if (wantDump) {
      int fd = open(kDumpOutPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
      if (fd >= 0) {
        fchmod(fd, 0644);
        size_t off = 0;
        while (off < size) {
          ssize_t w = write(fd, p + off, size - off);
          if (w <= 0) break;
          off += static_cast<size_t>(w);
        }
        close(fd);
        klogf("CLIENT TARGET dumped %zu/%zu bytes to %s", off, size, kDumpOutPath);
      } else {
        klogf("CLIENT TARGET dump open(%s) failed errno=%d (%s)", kDumpOutPath, errno,
              strerror(errno));
      }
      unlink(kDumpRequestPath);
    }
    DmaBufSync(src.fd,  false,  false);
    munmap(s, size);
  }

  // write the current buffer to a file
  std::string DumpClientTargetLocked(DisplayState& ds) {
    const HeldBuffer& src = ds.current;
    const rhizo::DecodedHandle& d = src.decoded;
    size_t size = d.allocSize ? d.allocSize
                              : static_cast<size_t>(d.stride) * (d.height > 0 ? d.height : 1);
    if (size == 0 || src.fd < 0) {
      klogf("CLIENT TARGET dump-now display=%lld: no client target (size=%zu fd=%d)",
            static_cast<long long>(ds.id), size, src.fd);
      return "dump-client-target-failed reason=no-client-target";
    }
    bool xferOk = rhizo::VirtgpuTransferFromHost(src.fd, d.width, d.height, d.stride,  true);
    void* s = mmap(nullptr, size, PROT_READ, MAP_SHARED, src.fd, 0);
    if (s == MAP_FAILED) {
      klogf("CLIENT TARGET dump-now display=%lld: mmap failed errno=%d", static_cast<long long>(ds.id),
            errno);
      return std::string("dump-client-target-failed reason=mmap-") + strerror(errno);
    }
    DmaBufSync(src.fd,  true,  false);
    const uint8_t* p = static_cast<const uint8_t*>(s);
    std::string reply;
    int fd = open(kDumpOutPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
      klogf("CLIENT TARGET dump-now open(%s) failed errno=%d (%s)", kDumpOutPath, errno,
            strerror(errno));
      reply = std::string("dump-client-target-failed reason=open-") + strerror(errno);
    } else {
      fchmod(fd, 0644);
      size_t off = 0;
      while (off < size) {
        ssize_t w = write(fd, p + off, size - off);
        if (w <= 0) break;
        off += static_cast<size_t>(w);
      }
      close(fd);
      klogf("CLIENT TARGET dumped %zu/%zu bytes to %s (now: display=%lld %dx%d stride=%d xfer=%s)",
            off, size, kDumpOutPath, static_cast<long long>(ds.id), d.width, d.height, d.stride,
            xferOk ? "ok" : "FAILED");
      if (off == size) {
        reply = "dump-client-target done size=" + std::to_string(d.width) + "x" +
                std::to_string(d.height) + " stride=" + std::to_string(d.stride) +
                " bytes=" + std::to_string(off) + " xfer=" + (xferOk ? "ok" : "failed");
      } else {
        reply = "dump-client-target-failed reason=short-write";
      }
    }
    DmaBufSync(src.fd,  false,  false);
    munmap(s, size);
    return reply;
  }

  // copy a buffer's bytes from src to dst
  void CopyBuffer(const HeldBuffer& src, const HeldBuffer& dst) {
    size_t srcSize = src.decoded.allocSize
                          ? src.decoded.allocSize
                          : static_cast<size_t>(src.decoded.stride) * src.decoded.height;
    size_t dstSize = dst.decoded.allocSize
                          ? dst.decoded.allocSize
                          : static_cast<size_t>(dst.decoded.stride) * dst.decoded.height;
    size_t n = std::min(srcSize, dstSize);
    if (n == 0) return;
    void* s = mmap(nullptr, srcSize, PROT_READ, MAP_SHARED, src.fd, 0);
    void* d = mmap(nullptr, dstSize, PROT_WRITE, MAP_SHARED, dst.fd, 0);
    if (s != MAP_FAILED && d != MAP_FAILED) {
      memcpy(d, s, n);
      const uint8_t* sp = static_cast<const uint8_t*>(s);
      klogf("CopyBuffer: n=%zu srcFirst8=%02x%02x%02x%02x%02x%02x%02x%02x", n, sp[0], sp[1], sp[2],
            sp[3], sp[4], sp[5], sp[6], sp[7]);
    } else {
      klog("readback CopyBuffer: mmap failed");
    }
    if (s != MAP_FAILED) munmap(s, srcSize);
    if (d != MAP_FAILED) munmap(d, dstSize);
  }

  // store the cursor pointer position
  void SetCursorPointerAbs(int64_t displayId, int32_t x, int32_t y) {
    std::lock_guard<std::mutex> lg(cursorPointerMutex_);
    cursorPointerAbs_[displayId] = {x, y};
  }
  // return the stored absolute cursor position of a display
  bool GetCursorPointerAbs(int64_t displayId, int32_t* x, int32_t* y) {
    std::lock_guard<std::mutex> lg(cursorPointerMutex_);
    auto it = cursorPointerAbs_.find(displayId);
    if (it == cursorPointerAbs_.end()) return false;
    *x = it->second.first;
    *y = it->second.second;
    return true;
  }

  // return the display scale in 120ths
  int32_t DisplayScale120(int64_t displayId) {
    std::lock_guard<std::mutex> lg(mutex_);
    const DisplayState* ds = FindLocked(displayId);
    return ds && ds->scale120 > 0 ? ds->scale120 : 120;
  }

  // read the window's top-left corner on the display
  void DisplayCropOrigin(int64_t displayId, int32_t* x, int32_t* y) {
    std::lock_guard<std::mutex> lg(mutex_);
    const DisplayState* ds = FindLocked(displayId);
    *x = ds ? ds->cropX : 0;
    *y = ds ? ds->cropY : 0;
  }

  // remove a freeform display's task through the task helper before the display
  bool RequestTaskClose(int64_t displayId) {
    char path[96];
    snprintf(path, sizeof(path), "/data/rhizo_control/task-close-%lld", static_cast<long long>(displayId));
    const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
      klogf("freeform: cannot write %s: errno=%d", path, errno);
      return false;
    }
    fchmod(fd, 0644);
    const bool ok = write(fd, "close\n", 6) == 6;
    close(fd);
    if (!ok) {
      unlink(path);
      return false;
    }
    // remove the display if the helper has not within 3s
    std::thread([this, displayId] {
      std::this_thread::sleep_for(std::chrono::seconds(3));
      {
        std::lock_guard<std::mutex> lg(mutex_);
        if (displays_.find(displayId) == displays_.end()) return;
      }
      klogf("freeform: display %lld still up 3s after its close request, removing it",
            static_cast<long long>(displayId));
      {
        std::lock_guard<std::mutex> lg(workMutex_);
        pendingRemovals_.push_back(displayId);
      }
      WakeControlThread();
    }).detach();
    return true;
  }

  // grow the display to the work area for a freeform window
  void OnFreeformWindowSize(int64_t displayId, int32_t width, int32_t height, int32_t scale120) {
    int32_t boundsW = 0, boundsH = 0;
    wayland_.DisplayBounds(displayId, &boundsW, &boundsH);
    const int32_t captionPx = (kFreeformCaptionDp * scale120 + 60) / 120;
    const int32_t workW = std::max(width, (boundsW * scale120 + 60) / 120);
    const int32_t workH = std::max(height, (boundsH * scale120 + 60) / 120) + captionPx;
    bool grow = false;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(displayId)) {
        grow = ds->width < workW || ds->height < workH || ds->scale120 != scale120;
        if (ds->taskW != width || ds->taskH != height) ds->taskDrawn = false;
        ds->taskW = width;
        ds->taskH = height;
      }
    }
    if (grow) {
      {
        std::lock_guard<std::mutex> lg(workMutex_);
        pendingResizes_[displayId] = {workW, workH, scale120, NowNanos()};
      }
      WakeControlThread();
    }
    char path[96];
    snprintf(path, sizeof(path), "/data/rhizo_control/task-bounds-%lld", static_cast<long long>(displayId));
    const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
      klogf("freeform: cannot write %s: errno=%d", path, errno);
      return;
    }
    fchmod(fd, 0644);
    char line[48];
    const int n = snprintf(line, sizeof(line), "%d %d\n", width, height + captionPx);
    if (write(fd, line, n) != n) klogf("freeform: short write to %s", path);
    close(fd);
  }

  // convert the scale to text
  static std::string ScaleText(int32_t scale120) {
    char buf[32];
    snprintf(buf, sizeof buf, "%.4g", scale120 / 120.0);
    return buf;
  }

  // move Android's pointer to the target position
  void ResyncPointer(int64_t displayId, int32_t targetX, int32_t targetY) {
    const bool accelerated = CursorAccelerated(displayId);
    if (accelerated) DropHeldPointerMove(displayId);
    uinput_.MoveHome(displayId);
    const int32_t milli = CursorScaleMilli(displayId);
    const int32_t dx = static_cast<int32_t>(static_cast<int64_t>(targetX) * 1000 / milli);
    const int32_t dy = static_cast<int32_t>(static_cast<int64_t>(targetY) * 1000 / milli);
    if (accelerated) {
      // keep the move out of the speed estimate of the move home
      std::this_thread::sleep_for(std::chrono::nanoseconds(rhizo::kVelocityResetNs));
    }
    if (dx != 0 || dy != 0) uinput_.Move(displayId, dx, dy);
    if (accelerated) {
      std::lock_guard<std::mutex> lg(pacerMutex_);
      pacer_[displayId].lastSendNs = NowNanos();
    }
  }

  // return whether Android accelerates the display's mouse past a flat low-speed gain
  bool CursorAccelerated(int64_t displayId) {
    std::lock_guard<std::mutex> lg(mutex_);
    const DisplayState* ds = FindLocked(displayId);
    return ds && ds->cursorAccelerated;
  }

  // send a relative move to an accelerated display
  void PaceAcceleratedMove(int64_t displayId, int32_t dx, int32_t dy) {
    bool hold = false;
    {
      std::lock_guard<std::mutex> lg(pacerMutex_);
      HeldPointerMove& p = pacer_[displayId];
      p.dx += dx;
      p.dy += dy;
      const int64_t now = NowNanos();
      if (!rhizo::CanSendUnaccelerated(now - p.lastSendNs, p.dx, p.dy)) {
        p.dueNs = p.lastSendNs + rhizo::kVelocityResetNs;
        hold = true;
      } else {
        if (p.dx != 0 || p.dy != 0) uinput_.Move(displayId, p.dx, p.dy);
        p = HeldPointerMove{};
        p.lastSendNs = now;
      }
    }
    if (hold) WakeControlThread();
  }

  // drop a display's held move
  void DropHeldPointerMove(int64_t displayId) {
    std::lock_guard<std::mutex> lg(pacerMutex_);
    auto it = pacer_.find(displayId);
    if (it == pacer_.end()) return;
    it->second.dx = it->second.dy = 0;
    it->second.dueNs = 0;
  }

  // return whether a display has a held move
  bool HoldingPointerMove(int64_t displayId) {
    std::lock_guard<std::mutex> lg(pacerMutex_);
    auto it = pacer_.find(displayId);
    return it != pacer_.end() && it->second.dueNs != 0;
  }

  // send all of the held moves that are due
  void SendDueHeldPointerMoves() {
    std::lock_guard<std::mutex> lg(pacerMutex_);
    const int64_t now = NowNanos();
    for (auto& [id, p] : pacer_) {
      if (p.dueNs == 0 || now < p.dueNs) continue;
      if (p.dx != 0 || p.dy != 0) uinput_.Move(id, p.dx, p.dy);
      p = HeldPointerMove{};
      p.lastSendNs = now;
    }
  }

  // return the display's cursor scale in thousandths
  int32_t CursorScaleMilli(int64_t displayId) {
    std::lock_guard<std::mutex> lg(mutex_);
    const DisplayState* ds = FindLocked(displayId);
    return ds && ds->cursorScaleMilli > 0 ? ds->cursorScaleMilli : 1000;
  }

  // move Android's pointer to the new position
  void StepAndroidPointer(int64_t displayId, int32_t mx, int32_t my) {
    auto& ap = androidPointer_[displayId];
    const int32_t milli = CursorScaleMilli(displayId);
    auto& rem = pointerRemainder_[displayId];
    const int64_t nx = static_cast<int64_t>(mx - ap.first) * 1000 + rem.first;
    const int64_t ny = static_cast<int64_t>(my - ap.second) * 1000 + rem.second;
    const int32_t dx = static_cast<int32_t>(nx / milli);
    const int32_t dy = static_cast<int32_t>(ny / milli);
    rem = {static_cast<int32_t>(nx - static_cast<int64_t>(dx) * milli),
           static_cast<int32_t>(ny - static_cast<int64_t>(dy) * milli)};
    if (dx != 0 || dy != 0) {
      if (CursorAccelerated(displayId)) {
        PaceAcceleratedMove(displayId, dx, dy);
      } else {
        uinput_.Move(displayId, dx, dy);
      }
    }
    ap = {mx, my};
  }

  // clamp x and y to the display size
  void ClampToDisplay(int64_t displayId, int32_t* x, int32_t* y) {
    std::lock_guard<std::mutex> lg(mutex_);
    const DisplayState* ds = FindLocked(displayId);
    if (!ds || ds->width <= 0 || ds->height <= 0) return;
    if (*x < 0) *x = 0;
    if (*y < 0) *y = 0;
    if (*x > ds->width - 1) *x = ds->width - 1;
    if (*y > ds->height - 1) *y = ds->height - 1;
  }

  // start tap latency tracking for a display
  void ArmTapLatency(int64_t displayId, uint32_t timeMsec, int64_t queuedNs) {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(displayId);
    if (!ds) return;
    ds->tap.armed = true;
    ds->tap.armTimeMsec = timeMsec;
    ds->tap.armQueuedNs = queuedNs;
    ds->tap.armPresentCount = ds->presentCount;
    ds->tap.uinputNs = 0;
    ds->tap.sfPresentNs = 0;
    if (timeMsec == 0) return;
    const uint32_t queuedMs32 = static_cast<uint32_t>(queuedNs / 1000000);
    const int64_t deltaNs =
        static_cast<int64_t>(static_cast<int32_t>(queuedMs32 - timeMsec)) * 1000000LL;
    if (ds->tap.wireDeltaCount == 0 || deltaNs < ds->tap.wireDeltaMinNs) ds->tap.wireDeltaMinNs = deltaNs;
    if (ds->tap.wireDeltaCount == 0 || deltaNs > ds->tap.wireDeltaMaxNs) ds->tap.wireDeltaMaxNs = deltaNs;
    ds->tap.wireDeltaSumNs += deltaNs;
    ds->tap.wireDeltaLastNs = deltaNs;
    ds->tap.wireDeltaCount++;
  }

  // record the time of the uinput tap write
  void NoteTapUinputWritten(int64_t displayId) {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(displayId);
    if (!ds || !ds->tap.armed || ds->tap.uinputNs != 0) return;
    ds->tap.uinputNs = NowNanos();
  }

  // translate a Wayland input event to uinput
  void OnWaylandInput(const rhizo::WaylandInputEvent& ev) {
    using Kind = rhizo::WaylandInputEvent::Kind;
    const int32_t scale120 = DisplayScale120(ev.displayId);
    int32_t cropX = 0, cropY = 0;
    DisplayCropOrigin(ev.displayId, &cropX, &cropY);
    const int32_t x = static_cast<int32_t>(ev.x * scale120 / 120.0 + 0.5) + cropX;
    const int32_t y = static_cast<int32_t>(ev.y * scale120 / 120.0 + 0.5) + cropY;
    int32_t mx = x, my = y;
    ClampToDisplay(ev.displayId, &mx, &my);
    switch (ev.kind) {
      case Kind::PointerEnter: {
        lastPointerAbs_[ev.displayId] = {x, y};
        SetCursorPointerAbs(ev.displayId, x, y);
        int32_t obsX = 0, obsY = 0;
        if (TakeObservedPointer(ev.displayId, &obsX, &obsY)) {  // NOLINT
          if (!HoldingPointerMove(ev.displayId)) {
            androidPointer_[ev.displayId] = {obsX, obsY};
            pointerRemainder_[ev.displayId] = {0, 0};
          }
          StepAndroidPointer(ev.displayId, mx, my);
        } else {
          ResyncPointer(ev.displayId, mx, my);
          androidPointer_[ev.displayId] = {mx, my};
          pointerRemainder_[ev.displayId] = {0, 0};
        }
        break;
      }
      case Kind::PointerMotion: {
        auto it = lastPointerAbs_.find(ev.displayId);
        const bool haveLast = it != lastPointerAbs_.end();
        const int32_t lastX = haveLast ? it->second.first : x;
        const int32_t lastY = haveLast ? it->second.second : y;
        lastPointerAbs_[ev.displayId] = {x, y};
        SetCursorPointerAbs(ev.displayId, x, y);
        if (pointerDown_.count(ev.displayId)) {
          uinput_.Touch(ev.displayId, x, y,  true);
        } else if (haveLast && (x != lastX || y != lastY)) {
          int32_t obsX = 0, obsY = 0;
          if (TakeObservedPointer(ev.displayId, &obsX, &obsY) && !HoldingPointerMove(ev.displayId)) {
            androidPointer_[ev.displayId] = {obsX, obsY};
            pointerRemainder_[ev.displayId] = {0, 0};
          }
          StepAndroidPointer(ev.displayId, mx, my);
        }
        break;
      }
      case Kind::PointerButton:
        if (ev.code == 0x110  ) {
          if (ev.value) {
            pointerDown_.insert(ev.displayId);
            ArmTapLatency(ev.displayId, ev.timeMsec, ev.queuedNs);
          } else {
            pointerDown_.erase(ev.displayId);
          }
          if (!uinput_.Touch(ev.displayId, x, y, ev.value != 0)) {
            klogf("OnWaylandInput: uinput_.Touch(display=%lld,x=%d,y=%d,down=%d) FAILED",
                  static_cast<long long>(ev.displayId), x, y, ev.value != 0);
          } else if (ev.value) {
            NoteTapUinputWritten(ev.displayId);
          }
        }
        break;
      case Kind::PointerAxis:
        uinput_.Scroll(ev.displayId, ev.code != 0, ev.value);
        break;
      case Kind::KeyboardKey:
        TranslateAndEmitKey(ev.displayId, ev.code, ev.value != 0);
        break;
      case Kind::KeyboardModifiers:
        keyTranslate_[ev.displayId].effectiveMods = ev.code;
        keyTranslate_[ev.displayId].group = ev.value;
        break;
      case Kind::TouchDown:
      case Kind::TouchMotion:
        uinput_.Touch(ev.displayId, x, y,  true);
        break;
      case Kind::TouchUp:
        uinput_.Touch(ev.displayId, 0, 0,  false);
        break;
    }
  }

  static constexpr uint32_t kEvdevLeftShift = 42;
  static constexpr uint32_t kEvdevRightShift = 54;
  static constexpr uint32_t kEvdevRightAlt = 100;
  static constexpr uint32_t kHostShiftMask = 1u << 0;
  static constexpr uint32_t kHostAltGrMask = 1u << 7;

  // translate a host key event to Android keys
  void TranslateAndEmitKey(int64_t displayId, uint32_t scancode, bool pressed) {
    KeyTranslateState& st = keyTranslate_[displayId];
    if (scancode == kEvdevLeftShift || scancode == kEvdevRightShift) {
      if (pressed) st.heldShift.insert(scancode); else st.heldShift.erase(scancode);
    } else if (scancode == kEvdevRightAlt) {
      if (pressed) st.heldAltGr.insert(scancode); else st.heldAltGr.erase(scancode);
    }

    bool haveTable;
    {
      std::lock_guard<std::mutex> lg(keymapMutex_);
      haveTable = !keymapTable_.empty();
    }
    if (!haveTable) {
      uinput_.Key(displayId, scancode, pressed);
      return;
    }

    if (!pressed) {
      auto it = st.active.find(scancode);
      if (it == st.active.end()) {
        uinput_.Key(displayId, scancode, false);
        return;
      }
      const KeyTranslateState::Emitted em = it->second;
      st.active.erase(it);
      if (em.androidCode == 0) return;
      uinput_.Key(displayId, em.androidCode, false);
      if (em.forcedShiftOn && st.heldShift.empty()) uinput_.Key(displayId, kEvdevLeftShift, false);
      for (uint32_t code : em.forcedShiftOff) {
        if (st.heldShift.count(code)) uinput_.Key(displayId, code, true);
      }
      for (uint32_t code : em.forcedAltGrOff) {
        if (st.heldAltGr.count(code)) uinput_.Key(displayId, code, true);
      }
      return;
    }

    std::string ch;
    {
      std::lock_guard<std::mutex> lg(keymapMutex_);
      auto it = st.group == 0 ? keymapTable_.find(scancode) : keymapTable_.end();
      if (it != keymapTable_.end()) {
        const int level = ((st.effectiveMods & kHostAltGrMask) ? 2 : 0) |
                          ((st.effectiveMods & kHostShiftMask) ? 1 : 0);
        ch = it->second[level];
      }
    }
    if (ch.empty()) {
      uinput_.Key(displayId, scancode, true);
      return;
    }

    const rhizo::input::AsciiKey* match = nullptr;
    if (ch.size() == 1) {
      for (const auto& k : rhizo::input::kUsAsciiKeys) {
        if (k.c == ch[0]) { match = &k; break; }
      }
    }
    if (!match) {
      bool firstTime;
      {
        std::lock_guard<std::mutex> lg(keymapMutex_);
        firstTime = unmappableChars_.insert(ch).second;
      }
      if (firstTime) {
        klogf("TranslateAndEmitKey: host character '%s' has no Android ASCII-table entry, dropping",
              ch.c_str());
      }
      st.active[scancode] = KeyTranslateState::Emitted{};
      return;
    }

    KeyTranslateState::Emitted em;
    em.androidCode = match->code;
    if (!st.heldAltGr.empty()) {
      for (uint32_t code : st.heldAltGr) uinput_.Key(displayId, code, false);
      em.forcedAltGrOff = st.heldAltGr;
    }
    const bool physicalShift = !st.heldShift.empty();
    if (match->shift && !physicalShift) {
      uinput_.Key(displayId, kEvdevLeftShift, true);
      em.forcedShiftOn = true;
    } else if (!match->shift && physicalShift) {
      for (uint32_t code : st.heldShift) uinput_.Key(displayId, code, false);
      em.forcedShiftOff = st.heldShift;
    }
    uinput_.Key(displayId, match->code, true);
    st.active[scancode] = em;
  }

  // parse the keymap bytes into a table
  static bool ParseKeymapTable(const std::vector<uint8_t>& raw,
                               std::map<uint32_t, std::array<std::string, 4>>* out) {
    size_t i = 0;
    while (i < raw.size()) {
      if (i + 2 > raw.size()) return false;
      const uint32_t scancode = raw[i] | (static_cast<uint32_t>(raw[i + 1]) << 8);
      i += 2;
      std::array<std::string, 4> levels;
      for (int lvl = 0; lvl < 4; lvl++) {
        if (i >= raw.size()) return false;
        const uint8_t len = raw[i++];
        if (i + len > raw.size()) return false;
        levels[lvl].assign(reinterpret_cast<const char*>(raw.data() + i), len);
        i += len;
      }
      (*out)[scancode] = std::move(levels);
    }
    return true;
  }

  // write the host keymap to a file
  void OnHostKeymap(const std::string& text) {
    const uint32_t digest =
        Fnv1a32(reinterpret_cast<const uint8_t*>(text.data()), text.size());
    {
      std::lock_guard<std::mutex> lg(keymapMutex_);
      if (digest == hostKeymapDigest_) return;
      hostKeymapDigest_ = digest;
      keymapTable_.clear();
      keymapTableDigest_ = 0;
    }
    const std::string path = "/data/rhizo_control/keymap-" + std::to_string(getpid()) + "-" +
                              std::to_string(NowNanos()) + "-" +
                              std::to_string(nextKeymapFileSeq_.fetch_add(1));
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
      klogf("OnHostKeymap: open(%s) FAILED errno=%d (%s)", path.c_str(), errno, strerror(errno));
      return;
    }
    fchmod(fd, 0666);
    size_t off = 0;
    while (off < text.size()) {
      ssize_t w = write(fd, text.data() + off, text.size() - off);
      if (w <= 0) {
        klogf("OnHostKeymap: write(%s) FAILED at %zu/%zu errno=%d (%s)", path.c_str(), off,
              text.size(), errno, strerror(errno));
        break;
      }
      off += static_cast<size_t>(w);
    }
    close(fd);
    WriteControlReply("keymap ready bytes=" + std::to_string(text.size()) +
                      " digest=" + std::to_string(digest) + " path=" + path);
  }

  // write the dropped bytes to a file
  void OnWaylandDrop(const rhizo::WaylandDropEvent& ev) {
    const std::string path = "/data/rhizo_control/drop-" + std::to_string(ev.displayId) + "-" +
                              std::to_string(getpid()) + "-" + std::to_string(NowNanos()) + "-" +
                              std::to_string(nextDropSeq_.fetch_add(1));
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
      klogf("OnWaylandDrop: open(%s) FAILED errno=%d (%s)", path.c_str(), errno, strerror(errno));
      return;
    }
    fchmod(fd, 0666);
    size_t off = 0;
    while (off < ev.bytes.size()) {
      ssize_t w = write(fd, ev.bytes.data() + off, ev.bytes.size() - off);
      if (w <= 0) {
        klogf("OnWaylandDrop: write(%s) FAILED at %zu/%zu errno=%d (%s)", path.c_str(), off,
              ev.bytes.size(), errno, strerror(errno));
        break;
      }
      off += static_cast<size_t>(w);
    }
    close(fd);
    int32_t port = -1;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(ev.displayId)) port = ds->port;
    }
    WriteControlReply("drop id=" + std::to_string(ev.displayId) + " port=" + std::to_string(port) +
                       " mime=" + ev.mime + " path=" + path + " x=" +
                       std::to_string(static_cast<int>(ev.x)) + " y=" +
                       std::to_string(static_cast<int>(ev.y)));
  }

  // write the clipboard bytes to a file
  void OnWaylandSelection(const rhizo::WaylandSelectionEvent& ev) {
    if (!ev.carried) {
      WriteControlReply("clip none");
      return;
    }
    const int64_t seq = nextClipSeq_.fetch_add(1);
    const std::string path = "/data/rhizo_control/clip-" + std::to_string(getpid()) + "-" +
                              std::to_string(NowNanos()) + "-" + std::to_string(seq);
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
      klogf("OnWaylandSelection: open(%s) FAILED errno=%d (%s)", path.c_str(), errno, strerror(errno));
      return;
    }
    fchmod(fd, 0666);
    size_t off = 0;
    while (off < ev.bytes.size()) {
      ssize_t w = write(fd, ev.bytes.data() + off, ev.bytes.size() - off);
      if (w <= 0) {
        klogf("OnWaylandSelection: write(%s) FAILED at %zu/%zu errno=%d (%s)", path.c_str(), off,
              ev.bytes.size(), errno, strerror(errno));
        break;
      }
      off += static_cast<size_t>(w);
    }
    close(fd);
    WriteControlReply("clip id=" + std::to_string(seq) + " mime=" + ev.mime + " path=" + path +
                       " sha256=" + Sha256Hex(ev.bytes));
  }

  // send touch up for a stalled touch
  void RunInjectTouchWatchdog(int64_t id) {
    ThreadGuard g(transientThreads_);
    for (;;) {
      if (shuttingDown_.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lg(injectMutex_);
        if (auto it = injectedTouch_.find(id); it != injectedTouch_.end()) it->second.watcherRunning = false;
        return;
      }
      usleep(200 * 1000);
      bool timedOut = false;
      {
        std::lock_guard<std::mutex> lg(injectMutex_);
        auto it = injectedTouch_.find(id);
        if (it == injectedTouch_.end() || !it->second.down) {
          if (it != injectedTouch_.end()) it->second.watcherRunning = false;
          return;
        }
        if (NowNanos() - it->second.lastActivityNs >= kInjectTouchTimeoutNs) {
          it->second.down = false;
          it->second.watcherRunning = false;
          timedOut = true;
        }
      }
      if (timedOut) {
        uinput_.Touch(id, 0, 0,  false);
        klogf("inject touch: display %lld down with no move/up for %lldms, synthesizing up",
              static_cast<long long>(id), static_cast<long long>(kInjectTouchTimeoutNs / 1000000));
        WriteControlReply("inject timeout id=" + std::to_string(id));
        return;
      }
    }
  }

  // store the primary display's geometry for the next client
  static void KeepPrimaryGeometry(const DisplayState& ds) {
    std::lock_guard<std::mutex> lg(KeptPrimaryMutex());
    KeptPrimaryGeometry& kept = KeptPrimary();
    kept.width = ds.width;
    kept.height = ds.height;
    kept.scale120 = ds.scale120;
    kept.dpi = ds.dpi;
    kept.vsyncPeriodNs = ds.vsyncPeriodNs;
  }

  // resize a display and send hotplug
  void ApplyResize(int64_t id, int32_t width, int32_t height, int32_t scale120) {
    if (getenv("RHIZO_NO_RESIZE") != nullptr) return;
    bool scaleChanged = false;
    const float wantDpi = kBaseDpi * static_cast<float>(scale120) / 120.0f;
    std::shared_ptr<IComposerCallback> cb;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLocked(id);
      if (!ds) return;
      if (ds->removing) return;
      if (ds->width == width && ds->height == height && ds->dpi == wantDpi) return;
      scaleChanged = ds->dpi != wantDpi;
      ds->width = width;
      ds->height = height;
      ds->dpi = wantDpi;
      ds->scale120 = scale120;
      ds->configGroup++;
      ds->SyncConfig();
      if (id == kPrimaryDisplayId) KeepPrimaryGeometry(*ds);
      cb = callback_;
    }
    if (!cb) return;
    auto st = cb->onHotplugEvent(
        id, ::aidl::android::hardware::graphics::common::DisplayHotplugEvent::CONNECTED);
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(id)) ds->lastConnectAt = std::chrono::steady_clock::now();
      lastAnyHotplugNs_ = NowNanos();
    }
    int32_t port = 0;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds2 = FindLocked(id)) port = ds2->port;
    }
    uinput_.Resize(id, port, width, height);
    klogf("ApplyResize: display %lld now %dx%d, re-hotplug CONNECTED isOk=%d",
          static_cast<long long>(id), width, height, st.isOk());
    LifecycleKlogf(id, "hotplug CONNECTED sent");
    if (scaleChanged) {
      WriteControlReply("display scaled id=" + std::to_string(id) + " port=" + std::to_string(port) +
                        " scale=" + ScaleText(scale120) + " dpi=" +
                        std::to_string(static_cast<int32_t>(wantDpi + 0.5f)));
    }
  }

  // create a display and send hotplug
  int64_t AddDisplay(int32_t width, int32_t height, bool claimed = true) {
    int64_t id;
    int32_t port;
    std::shared_ptr<IComposerCallback> cb;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (freePorts_.empty()) {
        klogf("AddDisplay: refusing -- all 8 external input ports are in use");
        return -1;
      }
      port = *freePorts_.begin();
      freePorts_.erase(freePorts_.begin());
      id = nextDisplayId_++;
      DisplayState& ds = displays_[id];
      ds.id = id;
      ds.width = width;
      ds.height = height;
      ds.port = port;
      ds.internal = false;
      ds.claimed = claimed;
      ds.SyncConfig();
      cb = callback_;
      vsyncCv_.notify_all();
    }
    LifecycleKlogf(id, "add port=%d claimed=%d", port, claimed ? 1 : 0);

    bool wayland = false;
    if (claimed && EnsureWaylandConnected()) {
      std::string title = "Rhizo display " + std::to_string(id);
      wayland = wayland_.CreateDisplay(id, title, width, height);
      if (!wayland) {
        klogf("AddDisplay: WaylandBackend::CreateDisplay FAILED for display %lld",
              static_cast<long long>(id));
      }
    }
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(id)) ds->waylandBacked = wayland;
    }

    if (cb) {
      auto st = cb->onHotplugEvent(
          id, ::aidl::android::hardware::graphics::common::DisplayHotplugEvent::CONNECTED);
      {
        std::lock_guard<std::mutex> lg(mutex_);
        if (DisplayState* ds = FindLocked(id)) ds->lastConnectAt = std::chrono::steady_clock::now();
        lastAnyHotplugNs_ = NowNanos();
      }
      klogf("AddDisplay: display %lld %dx%d hotplug CONNECTED isOk=%d", static_cast<long long>(id),
            width, height, st.isOk());
      LifecycleKlogf(id, "hotplug CONNECTED sent");
    } else {
      klogf("AddDisplay: display %lld created but no composer callback is registered yet",
            static_cast<long long>(id));
    }
    if (wayland) wayland_.KickVsync(id);
    uinput_.Create(id, port, width, height);

    if (claimed) {
      std::thread([this, id] {
        ThreadGuard g(transientThreads_);
        for (int i = 0; i < 40; ++i) {
          if (shuttingDown_.load(std::memory_order_acquire)) return;
          usleep((i == 0 ? 60 : 250) * 1000);
          std::shared_ptr<IComposerCallback> refreshCb;
          {
            std::lock_guard<std::mutex> lg(mutex_);
            DisplayState* ds = FindLocked(id);
            if (!ds) return;
            if (ds->presentCount > 0) return;
            refreshCb = callback_;
          }
          if (!refreshCb) return;
          refreshCb->onRefresh(id);
        }
        klogf("AddDisplay: display %lld still never presented after 5s of onRefresh",
              static_cast<long long>(id));
      }).detach();
    }
    return id;
  }

  // erase the input state of a display
  void ForgetDisplayInputState(int64_t id) {
    lastPointerAbs_.erase(id);
    androidPointer_.erase(id);
    pointerRemainder_.erase(id);
    {
      std::lock_guard<std::mutex> lg(pacerMutex_);
      pacer_.erase(id);
    }
    {
      std::lock_guard<std::mutex> lg(observedPointerMutex_);
      observedPointer_.erase(id);
    }
    pointerDown_.erase(id);
    keyTranslate_.erase(id);
    {
      std::lock_guard<std::mutex> lg(cursorPointerMutex_);
      cursorPointerAbs_.erase(id);
    }
  }

  // outcome of a display removal
  enum class RemoveOutcome { kOk, kRefused, kStillClaimed };

  // remove a display
  RemoveOutcome RemoveDisplayImpl(int64_t id, bool requireUnclaimed) {
    if (requireUnclaimed && id == kPrimaryDisplayId) {
      klog("RemoveDisplay: refusing to release the primary display as a spare");
      return RemoveOutcome::kStillClaimed;
    }
    if (id == kPrimaryDisplayId) {
      klog("RemoveDisplay: refusing to remove the primary display");
      bool wasWayland;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(id);
        wasWayland = ds && ds->waylandBacked;
        if (ds) ds->waylandBacked = false;
      }
      if (wasWayland) {
        wayland_.DestroyDisplay(id);
        uinput_.Destroy(id);
    ForgetDisplayInputState(id);
        ForgetDisplayInputState(id);
        klog("RemoveDisplay: primary display's Wayland surface torn down (display object stays, now headless)");
        MaybeTeardownWaylandConnection();
      }
      return RemoveOutcome::kRefused;
    }
    std::shared_ptr<IComposerCallback> cb;
    bool wasWayland = false;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLiveRaw(id);
      if (!ds) return RemoveOutcome::kRefused;
      if (requireUnclaimed && ds->claimed) return RemoveOutcome::kStillClaimed;
      ds->removing = true;
      ds->vsyncEnabled = false;
      wasWayland = ds->waylandBacked;
      removingDisplays_[id] = std::move(*ds);
      displays_.erase(id);
      cb = callback_;
    }

    WaitForQuiescence(id);
    WaitForGlobalQuiescence();

    if (cb) {
      auto st = cb->onHotplugEvent(
          id, ::aidl::android::hardware::graphics::common::DisplayHotplugEvent::DISCONNECTED);
      klogf("RemoveDisplay: display %lld hotplug DISCONNECTED isOk=%d", static_cast<long long>(id),
            st.isOk());
      LifecycleKlogf(id, "DISCONNECTED sent attempt=1");
      {
        std::lock_guard<std::mutex> lg(mutex_);
        AwaitingRelease& ar = awaitingSfRelease_[id];
        ar.port = 0;
        auto rit = removingDisplays_.find(id);
        if (rit != removingDisplays_.end()) ar.port = rit->second.port;
        ar.sentNs = NowNanos();
        ar.deadlineNs = ar.sentNs + kSfReleaseDeadlineNs;
        ar.attempts = 1;
        ar.released = false;
      }
      {
        std::lock_guard<std::mutex> lg(mutex_);
        if (DisplayState* ds = FindLiveRaw(id)) ds->lastFrameworkQueryNs = NowNanos();
        auto rit = removingDisplays_.find(id);
        if (rit != removingDisplays_.end()) rit->second.lastFrameworkQueryNs = NowNanos();
      }
      WaitForQuiescence(id);
    }
    if (wasWayland) wayland_.DestroyDisplay(id);
    uinput_.Destroy(id);
    {
      std::lock_guard<std::mutex> lg(mutex_);
      auto rit = removingDisplays_.find(id);
      if (rit != removingDisplays_.end()) rit->second.waylandBacked = false;
    }

    bool awaiting = false;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      auto ait = awaitingSfRelease_.find(id);
      awaiting = ait != awaitingSfRelease_.end() && !ait->second.released;
    }
    if (awaiting) {
      WakeControlThread();
    } else {
      FinishRemoval(id,  true);
    }
    if (!requireUnclaimed) MaybeTeardownOnLastAppDisplayClosed();
    return RemoveOutcome::kOk;
  }

  // free a removed display and its port
  void FinishRemoval(int64_t id, bool returnPort) {
    DisplayState taken;
    bool have = false;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      auto it = removingDisplays_.find(id);
      if (it != removingDisplays_.end()) {
        taken = std::move(it->second);
        removingDisplays_.erase(it);
        have = true;
      }
      awaitingSfRelease_.erase(id);
      if (!returnPort && taken.port >= 1) orphanedPorts_[id] = taken.port;
    }
    if (!have) return;
    size_t ctFds = 0;
    for (const auto& kv : taken.clientTargetSlots) {
      if (kv.second.fd >= 0) ctFds++;
    }
    size_t layerSlotFds = 0;
    for (const auto& kv : taken.layers) {
      for (const auto& sl : kv.second.slots) {
        if (sl.second.fd >= 0) layerSlotFds++;
      }
    }
    const int curFds = taken.current.fd >= 0 ? 1 : 0;
    const int rbFds = taken.readback.fd >= 0 ? 1 : 0;
    const size_t layerCount = taken.layers.size();
    const int heldBefore = g_heldFdsLive.load(std::memory_order_relaxed);
    taken.current.Reset();
    taken.readback.Reset();
    taken.clientTargetSlots.clear();
    taken.layers.clear();
    const int heldAfter = g_heldFdsLive.load(std::memory_order_relaxed);
    LifecycleKlogf(id,
                   "freed ct=%zu layers=%zu layer_slots=%zu current=%d readback=%d "
                   "held_before=%d held_after=%d",
                   ctFds, layerCount, layerSlotFds, curFds, rbFds, heldBefore, heldAfter);
    if (taken.port >= 1 && returnPort) {
      std::lock_guard<std::mutex> lg(mutex_);
      freePorts_.insert(taken.port);
    } else if (taken.port >= 1) {
      LifecycleKlogf(id, "SF-ORPHANED port=%d withheld", taken.port);
    }
    klogf("RemoveDisplay: display %lld gone, port %d %s", static_cast<long long>(id), taken.port,
          returnPort ? "free" : "WITHHELD (SurfaceFlinger never released it)");
  }

  // finish or resend pending display removals
  void ServiceSfReleases() {
    std::vector<int64_t> finish, orphan;
    std::vector<std::pair<int64_t, int>> resend;
    std::shared_ptr<IComposerCallback> cb;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      cb = callback_;
      const int64_t now = NowNanos();
      for (auto& [id, ar] : awaitingSfRelease_) {
        if (ar.released) {
          finish.push_back(id);
        } else if (now < ar.deadlineNs) {
          continue;
        } else if (ar.attempts >= kSfReleaseMaxAttempts || !cb) {
          orphan.push_back(id);
        } else {
          ar.attempts++;
          ar.deadlineNs = now + kSfReleaseDeadlineNs;
          resend.push_back({id, ar.attempts});
        }
      }
    }
    for (int64_t id : finish) FinishRemoval(id,  true);
    for (const auto& [id, attempt] : resend) {
      auto st = cb->onHotplugEvent(
          id, ::aidl::android::hardware::graphics::common::DisplayHotplugEvent::DISCONNECTED);
      klogf("RemoveDisplay: display %lld re-sent DISCONNECTED attempt=%d isOk=%d",
            static_cast<long long>(id), attempt, st.isOk());
      LifecycleKlogf(id, "DISCONNECTED sent attempt=%d", attempt);
    }
    for (int64_t id : orphan) FinishRemoval(id,  false);
  }

  bool RemoveDisplay(int64_t id) { return RemoveDisplayImpl(id, false) == RemoveOutcome::kOk; }

  // append a line to the control reply file
  void WriteControlReply(const std::string& line) {
    int fd = open(kControlReplyPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd < 0) return;
    fchmod(fd, 0666);
    std::string out = line + "\n";
    ssize_t ignored = write(fd, out.c_str(), out.size());
    (void)ignored;
    close(fd);
    klogf("control: %s", line.c_str());
  }

  // run a control command line
  void HandleControlLine(const std::string& line) {
    char verb[32] = {0}, noun[32] = {0};
    int a = 0, b = 0;
    int n = sscanf(line.c_str(), "%31s %31s %d %d", verb, noun, &a, &b);
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "add")) {
      int32_t w = (n >= 3 && a > 0) ? a : kDefaultWidth;
      int32_t h = (n >= 4 && b > 0) ? b : kDefaultHeight;
      int64_t id = AddDisplay(w, h);
      if (id < 0) {
        WriteControlReply("display add-failed no-free-port");
        return;
      }
      int32_t port = -1;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        if (DisplayState* ds = FindLocked(id)) port = ds->port;
      }
      WriteControlReply("display added id=" + std::to_string(id) + " port=" +
                        std::to_string(port) + " " + std::to_string(w) + "x" +
                        std::to_string(h));
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "arm-first-present")) {
      std::string reply;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(a);
        if (!ds) {
          reply = "display arm-first-present-failed id=" + std::to_string(a) + " no-such-display";
        } else {
          ds->firstPresent = DisplayState::FirstPresent{};
          ds->firstPresent.armed = true;
          ds->firstPresent.armNs = NowNanos();
          reply = "display first-present-armed id=" + std::to_string(a) +
                  " arm_ns=" + std::to_string(ds->firstPresent.armNs) +
                  " presents=" + std::to_string(ds->presentCount);
        }
      }
      WriteControlReply(reply);
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "stats")) {
      std::string reply;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(a);
        if (!ds) {
          reply = "display stats-failed id=" + std::to_string(a) + " no-such-display";
        } else {
          reply = "display stats id=" + std::to_string(a) +
                  " presented=" + std::to_string(ds->presented) +
                  " discarded=" + std::to_string(ds->discarded) +
                  " timer=" + std::to_string(ds->timerTicks) +
                  " recv=" + std::to_string(ds->vsyncRecv) +
                  " sent=" + std::to_string(ds->vsyncSent) +
                  " presents=" + std::to_string(ds->presentCount) +
                  " device=" + std::to_string(ds->deviceFrames) +
                  " client=" + std::to_string(ds->clientFrames) +
                  " period_ns=" + std::to_string(ds->vsyncPeriodNs) +
                  " tap_count=" + std::to_string(ds->tap.count) +
                  " tap_last_ns=" + std::to_string(ds->tap.lastNs) +
                  " tap_min_ns=" + std::to_string(ds->tap.minNs) +
                  " tap_max_ns=" + std::to_string(ds->tap.maxNs) +
                  " tap_sum_ns=" + std::to_string(ds->tap.sumNs) +
                  " tap_wire_delta_count=" + std::to_string(ds->tap.wireDeltaCount) +
                  " tap_wire_delta_last_ns=" + std::to_string(ds->tap.wireDeltaLastNs) +
                  " tap_wire_delta_min_ns=" + std::to_string(ds->tap.wireDeltaMinNs) +
                  " tap_wire_delta_max_ns=" + std::to_string(ds->tap.wireDeltaMaxNs) +
                  " tap_wire_delta_sum_ns=" + std::to_string(ds->tap.wireDeltaSumNs) +
                  " tap_hop_uinput_ns=" + std::to_string(ds->tap.hopUinputNs) +
                  " tap_hop_sf_present_ns=" + std::to_string(ds->tap.hopSfPresentNs) +
                  " tap_hop_commit_ns=" + std::to_string(ds->tap.hopCommitNs) +
                  " first_present_armed=" + std::to_string(ds->firstPresent.armed ? 1 : 0) +
                  " first_present_arm_ns=" + std::to_string(ds->firstPresent.armNs) +
                  " first_present_sf_ns=" + std::to_string(ds->firstPresent.sfPresentNs) +
                  " first_present_commit_ns=" + std::to_string(ds->firstPresent.commitNs) +
                  " first_present_ns=" + std::to_string(ds->firstPresent.presentedNs) +
                  " first_present_count=" + std::to_string(ds->firstPresent.count);
        }
      }
      WriteControlReply(reply);
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "dump-client-target")) {
      std::string reply;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(kPrimaryDisplayId);
        reply = ds ? DumpClientTargetLocked(*ds)
                   : std::string("dump-client-target-failed reason=no-primary-display");
      }
      WriteControlReply(reply);
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "pool-add")) {
      if (!displayPoolEnabled()) {
        WriteControlReply("display add-failed pool-disabled");
        return;
      }
      int32_t w = (n >= 3 && a > 0) ? a : kDefaultWidth;
      int32_t h = (n >= 4 && b > 0) ? b : kDefaultHeight;
      int64_t id = AddDisplay(w, h,  false);
      if (id < 0) {
        WriteControlReply("display add-failed no-free-port");
        return;
      }
      int32_t port = -1;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        if (DisplayState* ds = FindLocked(id)) port = ds->port;
      }
      WriteControlReply("display pooled id=" + std::to_string(id) + " port=" +
                        std::to_string(port) + " " + std::to_string(w) + "x" +
                        std::to_string(h));
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "claim")) {
      int64_t id = a;
      uint64_t presentAtClaim = 0;
      int32_t claimWidth = 0, claimHeight = 0;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(id);
        if (!ds) {
          WriteControlReply("display claim-failed id=" + std::to_string(id) + " no-such-display");
          return;
        }
        if (ds->claimed && ds->waylandBacked) {
          WriteControlReply("display claim-failed id=" + std::to_string(id) + " already-claimed");
          return;
        }
        presentAtClaim = ds->presentCount;
        claimWidth = ds->width;
        claimHeight = ds->height;
      }
      bool wayland = false;
      if (EnsureWaylandConnected()) {
        std::string title = "Rhizo display " + std::to_string(id);
        wayland = wayland_.CreateDisplay(id, title, claimWidth, claimHeight);
        if (!wayland) {
          klogf("HandleControlLine: WaylandBackend::CreateDisplay FAILED for claimed display %lld",
                static_cast<long long>(id));
        }
      }
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(id);
        if (!ds) {
          WriteControlReply("display claim-failed id=" + std::to_string(id) + " no-such-display");
          return;
        }
        ds->waylandBacked = wayland;
        ds->claimed = true;
        vsyncCv_.notify_all();
      }
      if (!wayland) {
        WriteControlReply("display claim-failed id=" + std::to_string(id) + " no-wayland-surface");
        return;
      }
      wayland_.KickVsync(id);
      bool hadClock = false;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        if (DisplayState* ds = FindLocked(id)) hadClock = ds->vsyncEnabled;
      }
      klogf("claim: display %lld vsyncEnabled=%d at claim", static_cast<long long>(id),
            hadClock ? 1 : 0);
      std::thread([this, id, presentAtClaim] {
        ThreadGuard g(transientThreads_);
        for (int i = 0; i < 40; ++i) {
          if (shuttingDown_.load(std::memory_order_acquire)) return;
          usleep((i == 0 ? 60 : 250) * 1000);
          std::shared_ptr<IComposerCallback> refreshCb;
          {
            std::lock_guard<std::mutex> lg(mutex_);
            DisplayState* ds = FindLocked(id);
            if (!ds) return;
            if (ds->presentCount > presentAtClaim) return;
            refreshCb = callback_;
          }
          if (!refreshCb) return;
          refreshCb->onRefresh(id);
        }
        klogf("HandleControlLine: claimed display %lld still never presented after 5s of onRefresh",
              static_cast<long long>(id));
      }).detach();
      WriteControlReply("display claimed id=" + std::to_string(id));
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "remove")) {
      bool okRemoved = RemoveDisplay(a);
      WriteControlReply("display remove id=" + std::to_string(a) +
                        (okRemoved ? " ok" : " no-such-display"));
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "release-spare")) {
      RemoveOutcome outcome = RemoveDisplayImpl(a, /*requireUnclaimed=*/true);
      if (outcome == RemoveOutcome::kOk) {
        WriteControlReply("display spare-released id=" + std::to_string(a));
      } else if (outcome == RemoveOutcome::kStillClaimed) {
        WriteControlReply("display release-spare-failed id=" + std::to_string(a) +
                          " still-claimed");
      } else {
        WriteControlReply("display release-spare-failed id=" + std::to_string(a) +
                          " no-such-display");
      }
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "list")) {
      std::string ids;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        for (auto& kv : displays_) {
          ids += std::to_string(kv.first) + "(" + std::to_string(kv.second.width) + "x" +
                 std::to_string(kv.second.height) +
                 (kv.second.claimed ? "" : ",pool") + ") ";
        }
      }
      WriteControlReply("display list " + ids);
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "audit")) {
      std::string live, awaiting, orphaned, presents, vsyncs;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        const int64_t now = NowNanos();
        for (const auto& kv : displays_) {
          if (!live.empty()) live += ",";
          live += std::to_string(kv.first) + ":" + std::to_string(kv.second.port);
          if (!presents.empty()) presents += ",";
          presents += std::to_string(kv.first) + ":" + std::to_string(kv.second.presentCount);
          if (!vsyncs.empty()) vsyncs += ",";
          vsyncs += std::to_string(kv.first) + ":" + std::to_string(kv.second.vsyncEnabled ? 1 : 0);
        }
        for (const auto& kv : awaitingSfRelease_) {
          if (!awaiting.empty()) awaiting += ",";
          awaiting += std::to_string(kv.first) + ":" + std::to_string(kv.second.port) + ":" +
                      std::to_string((now - kv.second.sentNs) / 1000000);
        }
        for (const auto& kv : orphanedPorts_) {
          if (!orphaned.empty()) orphaned += ",";
          orphaned += std::to_string(kv.first) + ":" + std::to_string(kv.second);
        }
      }
      WriteControlReply("display audit live=" + live + " awaiting_sf=" + awaiting + " orphaned=" +
                        orphaned + " held_fds_live=" +
                        std::to_string(g_heldFdsLive.load(std::memory_order_relaxed)) +
                        " presents=" + presents + " vsyncs=" + vsyncs);
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "buffers")) {
      char which[32] = {0};
      if (sscanf(line.c_str(), "%*31s %*31s %31s", which) != 1) {
        WriteControlReply("display buffers-failed reason=bad-command");
        return;
      }
      const bool all = !strcmp(which, "all");
      if (!all && n < 3) {
        WriteControlReply("display buffers-failed reason=bad-command");
        return;
      }
      std::vector<int64_t> ids;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        for (const auto& kv : displays_) {
          if (all || kv.first == a) ids.push_back(kv.first);
        }
        for (const auto& kv : removingDisplays_) {
          if (all || kv.first == a) ids.push_back(kv.first);
        }
      }
      if (ids.empty()) {
        WriteControlReply("display buffers id=" + std::to_string(a) + " no-such-display");
        return;
      }
      for (int64_t id : ids) {
        std::string reply;
        {
          std::lock_guard<std::mutex> lg(mutex_);
          DisplayState* ds = FindAnyRaw(id);
          if (!ds) continue;
          int acq = 0;
          reply = "display buffers id=" + std::to_string(id) + " current=" +
                  std::to_string(static_cast<unsigned long long>(ds->current.ino)) + " readback=" +
                  std::to_string(static_cast<unsigned long long>(ds->readback.ino));
          for (const auto& kv : ds->clientTargetSlots) {
            reply += " ct[" + std::to_string(kv.first) + "]=" +
                     std::to_string(static_cast<unsigned long long>(kv.second.ino));
          }
          for (const auto& lkv : ds->layers) {
            if (lkv.second.acquire.get() >= 0) acq++;
            for (const auto& skv : lkv.second.slots) {
              reply += " layer[" + std::to_string(lkv.first) + "].slot[" +
                       std::to_string(skv.first) + "]=" +
                       std::to_string(static_cast<unsigned long long>(skv.second.ino));
            }
          }
          reply += " acq=" + std::to_string(acq);
        }
        for (const auto& sl : wayland_.DescribeSlots(id)) {
          reply += " wl[" + std::to_string(sl.slot) + "]=" +
                   std::to_string(static_cast<unsigned long long>(sl.dev)) + ":" +
                   std::to_string(static_cast<unsigned long long>(sl.ino));
        }
        WriteControlReply(reply);
      }
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "identity")) {
      int64_t id = a;
      int consumed = 0;
      char appIdB64[4096] = {0};
      if (sscanf(line.c_str(), "%*31s %*31s %*d %4095s%n", appIdB64, &consumed) != 1) {
        WriteControlReply("display identity-failed id=" + std::to_string(id) + " reason=bad-command");
        return;
      }
      if (strlen(appIdB64) >= sizeof(appIdB64) - 1) {
        WriteControlReply("display identity-failed id=" + std::to_string(id) + " reason=app-id-too-long");
        return;
      }
      size_t titleStart = static_cast<size_t>(consumed);
      while (titleStart < line.size() && line[titleStart] == ' ') titleStart++;
      if (titleStart >= line.size()) {
        WriteControlReply("display identity-failed id=" + std::to_string(id) + " reason=bad-command");
        return;
      }
      std::vector<uint8_t> appIdBytes, titleBytes;
      if (!Base64Decode(appIdB64, &appIdBytes) || !Base64Decode(line.substr(titleStart), &titleBytes)) {
        WriteControlReply("display identity-failed id=" + std::to_string(id) + " reason=bad-base64");
        return;
      }
      std::string appId(appIdBytes.begin(), appIdBytes.end());
      std::string title(titleBytes.begin(), titleBytes.end());
      if (!wayland_.SetToplevelIdentity(id, appId, title)) {
        WriteControlReply("display identity-failed id=" + std::to_string(id) + " reason=no-such-display");
        return;
      }
      WriteControlReply("display identity set id=" + std::to_string(id));
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "cursor-type")) {
      long long id = 0;
      unsigned int digest = 0;
      int type = 0;
      if (sscanf(line.c_str(), "%*31s %*31s %lld %u %d", &id, &digest, &type) != 3) {
        WriteControlReply("display cursor-type-failed reason=bad-command");
        return;
      }
      bool kept = false;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(id);
        if (!ds) {
          WriteControlReply("display cursor-type-failed id=" + std::to_string(id) + " reason=no-display");
          return;
        }
        auto& ask = ds->cursor.typeAsk;
        if (!ask.outstanding || ask.digest != digest) {
          WriteControlReply("display cursor-type id=" + std::to_string(id) + " digest=" +
                            std::to_string(digest) + " type=" + std::to_string(type) + " kept=0 stale=1");
          return;
        }
        kept = rhizo::PointerTypeAnswerFits(ask, digest, ds->cursor.digest, ds->cursor.imageChanges);
        ask.outstanding = false;
        if (kept) {
          if (pointerTypeByImage_.size() >= kMaxPointerTypeImages) pointerTypeByImage_.clear();
          pointerTypeByImage_[digest] = static_cast<int32_t>(type);
        } else {
          // the image changed during the read: show Android's newest type until the image is named
          wayland_.SetCursorType(ds->id, static_cast<int32_t>(type));
        }
        ShowPointerTypeLocked(*ds);
      }
      WriteControlReply("display cursor-type id=" + std::to_string(id) + " digest=" + std::to_string(digest) +
                        " type=" + std::to_string(type) + " kept=" + (kept ? "1" : "0"));
      return;
    }
    if (n >= 4 && !strcmp(verb, "display") && !strcmp(noun, "cursor-scale")) {
      const int64_t id = a;
      const int32_t milli = static_cast<int32_t>(b);
      int accelerated = 0;
      sscanf(line.c_str(), "%*s %*s %*d %*d %d", &accelerated);
      if (milli <= 0) {
        WriteControlReply("display cursor-scale-failed id=" + std::to_string(id) + " reason=bad-milli");
        return;
      }
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(id);
        if (!ds) {
          WriteControlReply("display cursor-scale-failed id=" + std::to_string(id) + " reason=no-such-display");
          return;
        }
        ds->cursorScaleMilli = milli;
        ds->cursorAccelerated = accelerated != 0;
      }
      int32_t hx = 0, hy = 0;
      if (GetCursorPointerAbs(id, &hx, &hy)) {
        ResyncPointer(id, hx, hy);
        SetObservedPointer(id, hx, hy);
      } else {
        uinput_.MoveHome(id);
        SetObservedPointer(id, 0, 0);
      }
      WriteControlReply("display cursor-scale id=" + std::to_string(id) + " milli=" + std::to_string(milli) +
                        (accelerated ? " accelerated=1" : ""));
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "toplevel")) {
      int64_t id = a;
      rhizo::WaylandToplevelInfo info = wayland_.GetToplevelInfo(id);
      if (!info.found) {
        WriteControlReply("display toplevel-failed id=" + std::to_string(id) + " reason=no-such-display");
        return;
      }
      WriteControlReply(
          "display toplevel id=" + std::to_string(id) +
          " app_id=" + info.appId +
          " maximized=" + std::to_string(info.maximized) +
          " fullscreen=" + std::to_string(info.fullscreen) +
          " activated=" + std::to_string(info.activated) +
          " resizing=" + std::to_string(info.resizing) +
          " scale=" + ScaleText(info.scale120) +
          " output=" + (info.outputName.empty() ? "(none)" : info.outputName) +
          " title=" + info.title);
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "cursor")) {
      int64_t id = a;
      std::string reply;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        DisplayState* ds = FindLocked(id);
        if (!ds) {
          reply = "display cursor-failed id=" + std::to_string(id) + " reason=no-such-display";
        } else {
          reply = "display cursor id=" + std::to_string(id) +
                  " valid=" + std::to_string(ds->cursor.valid) +
                  " width=" + std::to_string(ds->cursor.width) +
                  " height=" + std::to_string(ds->cursor.height) +
                  " hotspot_x=" + std::to_string(ds->cursor.hotspotX) +
                  " hotspot_y=" + std::to_string(ds->cursor.hotspotY) +
                  " digest=" + std::to_string(ds->cursor.digest) +
                  " layer_cmds=" + std::to_string(ds->cursor.layerCmds) +
                  " offered=" + std::to_string(ds->cursor.offered) +
                  " seen=" + std::to_string(ds->cursor.seen) +
                  " uploads=" + std::to_string(ds->cursor.uploads) +
                  " buffer_cmds=" + std::to_string(ds->cursor.bufferCmds) +
                  " rel_owed=" + std::to_string(ds->cursor.releasesOwed) +
                  " rel_emitted=" + std::to_string(ds->cursor.releasesEmitted) +
                  " named_cursor=" + std::to_string(ds->cursor.namedCursor) +
                  " id_changes=" + std::to_string(ds->cursor.idChanges) +
                  " last_skip=" + std::string(ds->cursor.lastSkip) +
                  " layer=" + std::to_string(ds->cursor.layerId);
          auto named = pointerTypeByImage_.find(ds->cursor.digest);
          reply += " pointer_type=" +
                   (named == pointerTypeByImage_.end() ? std::string("unnamed") : std::to_string(named->second)) +
                   " type_ask=" + std::to_string(ds->cursor.typeAsk.outstanding);
        }
      }
      WriteControlReply(reply);
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "outputs")) {
      std::string reply = "display outputs";
      for (const auto& o : wayland_.ListOutputs()) {
        reply += " name=" + (o.name.empty() ? "(unnamed)" : o.name) +
                 ",scale=" + std::to_string(o.scale) +
                 ",size=" + std::to_string(o.width) + "x" + std::to_string(o.height);
      }
      WriteControlReply(reply);
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "keymap")) {
      std::lock_guard<std::mutex> lg(keymapMutex_);
      WriteControlReply("display keymap loaded=" + std::to_string(keymapTableDigest_ != 0) +
                        " entries=" + std::to_string(keymapTable_.size()) +
                        " digest=" + std::to_string(keymapTableDigest_) +
                        " unmappable=" + std::to_string(unmappableChars_.size()));
      return;
    }
    if (n >= 2 && !strcmp(verb, "keymap") && !strcmp(noun, "table")) {
      uint32_t digest = 0;
      int consumed = 0;
      if (sscanf(line.c_str(), "%*31s %*31s %u%n", &digest, &consumed) != 1) {
        WriteControlReply("keymap table-failed reason=bad-command");
        return;
      }
      size_t b64Start = static_cast<size_t>(consumed);
      while (b64Start < line.size() && line[b64Start] == ' ') b64Start++;
      std::map<uint32_t, std::array<std::string, 4>> table;
      std::vector<uint8_t> raw;
      if (b64Start >= line.size() || !Base64Decode(line.substr(b64Start), &raw) ||
          !ParseKeymapTable(raw, &table)) {
        WriteControlReply("keymap table-failed reason=bad-encoding");
        return;
      }
      const size_t entries = table.size();
      std::string reply;
      {
        std::lock_guard<std::mutex> lg(keymapMutex_);
        if (digest != hostKeymapDigest_) {
          reply = "keymap table-rejected reason=outdated digest=" + std::to_string(digest);
        } else {
          keymapTable_ = std::move(table);
          keymapTableDigest_ = digest;
          unmappableChars_.clear();
          reply = "keymap table-loaded digest=" + std::to_string(digest) +
                  " entries=" + std::to_string(entries);
        }
      }
      WriteControlReply(reply);
      return;
    }
    if (n >= 3 && !strcmp(verb, "drag") && !strcmp(noun, "start")) {
      int64_t id = a;
      char mime[256] = {0};
      int consumed = 0;
      if (sscanf(line.c_str(), "%*31s %*31s %*d %255s%n", mime, &consumed) != 1) {
        WriteControlReply("drag-failed id=" + std::to_string(id) + " reason=bad-command");
        return;
      }
      size_t payloadStart = static_cast<size_t>(consumed);
      while (payloadStart < line.size() && line[payloadStart] == ' ') payloadStart++;
      if (payloadStart >= line.size()) {
        WriteControlReply("drag-failed id=" + std::to_string(id) + " reason=bad-command");
        return;
      }
      std::vector<uint8_t> payload;
      if (!Base64Decode(line.substr(payloadStart), &payload)) {
        WriteControlReply("drag-failed id=" + std::to_string(id) + " reason=bad-base64");
        return;
      }
      if (payload.size() > kDragPayloadMaxBytes) {
        WriteControlReply("drag-failed id=" + std::to_string(id) + " reason=payload-too-large");
        return;
      }
      bool started = wayland_.StartDrag(id, mime, std::move(payload));
      WriteControlReply(started ? "drag started id=" + std::to_string(id)
                                 : "drag-failed id=" + std::to_string(id) + " reason=refused");
      return;
    }
    if (n >= 3 && !strcmp(verb, "clip") && !strcmp(noun, "set")) {
      int64_t cid = a;
      char mime[256] = {0};
      int consumed = 0;
      if (sscanf(line.c_str(), "%*31s %*31s %*d %255s%n", mime, &consumed) != 1) {
        WriteControlReply("clip set-failed cid=" + std::to_string(cid) + " reason=bad-command");
        return;
      }
      size_t payloadStart = static_cast<size_t>(consumed);
      while (payloadStart < line.size() && line[payloadStart] == ' ') payloadStart++;
      if (payloadStart >= line.size()) {
        WriteControlReply("clip set-failed cid=" + std::to_string(cid) + " reason=bad-command");
        return;
      }
      std::vector<uint8_t> payload;
      if (!Base64Decode(line.substr(payloadStart), &payload)) {
        WriteControlReply("clip set-failed cid=" + std::to_string(cid) + " reason=bad-base64");
        return;
      }
      if (payload.size() > kClipPayloadMaxBytes) {
        WriteControlReply("clip set-failed cid=" + std::to_string(cid) + " reason=payload-too-large");
        return;
      }
      bool ok = wayland_.SetSelection(mime, std::move(payload));
      WriteControlReply(ok ? "clip set-ok cid=" + std::to_string(cid)
                            : "clip set-failed cid=" + std::to_string(cid) + " reason=refused");
      return;
    }
    if (n >= 2 && !strcmp(verb, "clip") && !strcmp(noun, "clear")) {
      wayland_.ClearSelection();
      WriteControlReply("clip cleared");
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "clipboard-state")) {
      WriteControlReply(std::string("display clipboard-state bound=") +
                        (wayland_.ClipboardBound() ? "1" : "0"));
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "decorations")) {
      int64_t id = a;
      const rhizo::WaylandDecorationMode mode = wayland_.GetDecorationMode(id);
      const char* modeStr = mode == rhizo::WaylandDecorationMode::kServerSide ? "ssd"
                            : mode == rhizo::WaylandDecorationMode::kClientSide ? "csd" : "none";
      WriteControlReply("display decorations id=" + std::to_string(id) + " mode=" + modeStr);
      return;
    }
    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "activate")) {
      int64_t id = a;
      char token[256] = {0};
      sscanf(line.c_str(), "%*31s %*31s %*d %255s", token);
      bool held = false;
      bool ok = wayland_.ActivateDisplay(id, token, &held);
      WriteControlReply(!ok ? "display activate-failed id=" + std::to_string(id) + " reason=refused"
                        : held ? "display activate-held id=" + std::to_string(id)
                               : "display activated id=" + std::to_string(id));
      return;
    }
    if (n >= 2 && !strcmp(verb, "display") && !strcmp(noun, "minimize-all")) {
      std::vector<int64_t> ids;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        for (const auto& kv : displays_) {
          if (!kv.second.internal && kv.second.waylandBacked) ids.push_back(kv.first);
        }
      }
      std::string minimized;
      for (int64_t id : ids) {
        if (wayland_.MinimizeDisplay(id)) minimized += (minimized.empty() ? "" : ",") + std::to_string(id);
      }
      WriteControlReply("display minimized ids=" + minimized);
      return;
    }
    if (n >= 2 && !strcmp(verb, "inject") && !strcmp(noun, "touch")) {
      char sub[32] = {0};
      int id = 0, ix = 0, iy = 0;
      int got = sscanf(line.c_str(), "%*31s %*31s %31s %d %d %d", sub, &id, &ix, &iy);
      int32_t port = -1;
      {
        std::lock_guard<std::mutex> lg(mutex_);
        if (DisplayState* ds = FindLocked(id)) port = ds->port;
      }
      if (port < 0) {
        WriteControlReply("inject-failed id=" + std::to_string(id) + " reason=unknown-display");
        return;
      }
      if (!strcmp(sub, "down")) {
        if (got != 4) {
          WriteControlReply("inject-failed id=0 reason=bad-command");
          return;
        }
        if (!uinput_.Touch(id, ix, iy, /*down=*/true)) {
          WriteControlReply("inject-failed id=" + std::to_string(id) + " reason=uinput-touch-failed");
          return;
        }
        klogf("inject touch down: id=%d -> port=%d x=%d y=%d", id, port, ix, iy);
        bool needWatchdog = false;
        {
          std::lock_guard<std::mutex> lg(injectMutex_);
          InjectedTouch& st = injectedTouch_[id];
          st.down = true;
          st.lastActivityNs = NowNanos();
          if (!st.watcherRunning) {
            st.watcherRunning = true;
            needWatchdog = true;
          }
        }
        if (needWatchdog) std::thread([this, id] { RunInjectTouchWatchdog(id); }).detach();
        WriteControlReply("inject down id=" + std::to_string(id));
        return;
      }
      if (!strcmp(sub, "move")) {
        if (got != 4) {
          WriteControlReply("inject-failed id=0 reason=bad-command");
          return;
        }
        bool active = false;
        {
          std::lock_guard<std::mutex> lg(injectMutex_);
          auto it = injectedTouch_.find(id);
          if (it != injectedTouch_.end() && it->second.down) {
            it->second.lastActivityNs = NowNanos();
            active = true;
          }
        }
        if (!active && pointerDown_.count(id)) active = true;
        if (!active) {
          WriteControlReply("inject-failed id=" + std::to_string(id) + " reason=no-active-down");
          return;
        }
        if (!uinput_.Touch(id, ix, iy, /*down=*/true)) {
          WriteControlReply("inject-failed id=" + std::to_string(id) + " reason=uinput-touch-failed");
          return;
        }
        klogf("inject touch move: id=%d -> port=%d x=%d y=%d", id, port, ix, iy);
        WriteControlReply("inject move id=" + std::to_string(id));
        return;
      }
      if (!strcmp(sub, "up")) {
        if (got < 2) {
          WriteControlReply("inject-failed id=0 reason=bad-command");
          return;
        }
        {
          std::lock_guard<std::mutex> lg(injectMutex_);
          if (auto it = injectedTouch_.find(id); it != injectedTouch_.end()) it->second.down = false;
        }
        if (!uinput_.Touch(id, 0, 0, /*down=*/false)) {
          WriteControlReply("inject-failed id=" + std::to_string(id) + " reason=uinput-touch-failed");
          return;
        }
        klogf("inject touch up: id=%d -> port=%d", id, port);
        WriteControlReply("inject up id=" + std::to_string(id));
        return;
      }
      WriteControlReply("error unknown command: " + line);
      return;
    }
    if (n >= 2 && !strcmp(verb, "wl") && !strcmp(noun, "status")) {
      rhizo::WaylandDebugSnapshot snap = wayland_.DebugSnapshot();
      std::string reply = "wl status connected=" + std::to_string(snap.connected) +
                          " pump=" + std::to_string(snap.pumpRunning) +
                          " connects=" + std::to_string(snap.connectCount) +
                          " wlerr=" + std::to_string(snap.wlError) +
                          " wlerr_iface=" +
                          (snap.protoErrorInterface.empty() ? "(none)" : snap.protoErrorInterface) +
                          " wlerr_code=" + std::to_string(snap.protoErrorCode) + " displays=[";
      for (auto& d : snap.displays) {
        reply += std::to_string(d.id) + ":surf=" + std::to_string(d.hasSurface) +
                 ",top=" + std::to_string(d.hasToplevel) +
                 ",cfg=" + std::to_string(d.configured) + " ";
      }
      reply += "] log=\"";
      std::string msg = snap.lastLogMessage;
      for (char& c : msg) {
        if (c == '\n' || c == '\r') c = ' ';
      }
      reply += msg + "\" paramsid=" + std::to_string(snap.failedParamsId) +
               " paramsid_reused=" + std::to_string(snap.failedParamsIdWasReused) +
               " paramsid_prior_attempt=" + std::to_string(snap.failedParamsIdPriorAllocAttempt) +
               " firsterr_at=" + std::to_string(snap.firstErrorAtAttempt) +
               " firsterr_captured=" + std::to_string(snap.firstErrorCaptured) +
               " firsterr_display=" + std::to_string(snap.firstErrorDisplayId) +
               " firsterr_wh=" + std::to_string(snap.firstErrorWidth) + "x" +
               std::to_string(snap.firstErrorHeight) +
               " firsterr_stride=" + std::to_string(snap.firstErrorStride) +
               " firsterr_fd=" + std::to_string(snap.firstErrorFd) +
               " firsterr_fmt=0x" + [&] {
                 char b[16];
                 snprintf(b, sizeof(b), "%08x", snap.firstErrorFormat);
                 return std::string(b);
               }() +
               " presentAttempts=" + std::to_string(snap.presentAttempts);
      WriteControlReply(reply);
      return;
    }
    WriteControlReply("error unknown command: " + line);
  }

  // start the control thread
  void StartControlThreadOnce() {
    bool expected = false;
    if (!controlThreadStarted_.compare_exchange_strong(expected, true)) return;
    controlThread_ = std::thread([this] {
      prctl(PR_SET_NAME, "rhizo-control");
      unlink(kControlPath);
      if (mkfifo(kControlPath, 0666) != 0 && errno != EEXIST) {
        klogf("control: mkfifo(%s) FAILED errno=%d (%s) -- no host control channel", kControlPath,
              errno, strerror(errno));
        return;
      }
      chmod(kControlPath, 0666);
      int fd = open(kControlPath, O_RDWR | O_CLOEXEC);
      if (fd < 0) {
        klogf("control: open(%s) FAILED errno=%d (%s)", kControlPath, errno, strerror(errno));
        return;
      }
      controlWakeFd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
      if (controlWakeFd_ < 0) {
        klogf("control: eventfd() FAILED errno=%d (%s) -- falling back to a 100ms poll bound",
              errno, strerror(errno));
      }
      klogf("control: listening on %s", kControlPath);
      std::string buffered;
      for (;;) {
        if (shuttingDown_.load(std::memory_order_acquire)) break;
        int timeoutMs = controlWakeFd_ < 0 ? 100 : -1;
        {
          std::lock_guard<std::mutex> lg(workMutex_);
          const int64_t now = NowNanos();
          for (const auto& [id, pr] : pendingResizes_) {
            int64_t remainMs = (pr.dueNs - now) / 1000000;
            if (remainMs < 0) remainMs = 0;
            if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);
          }
          for (const auto& [id, held] : heldRefresh_) {
            int64_t remainMs = (held.second - now + 999999) / 1000000;
            if (remainMs < 0) remainMs = 0;
            if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);
          }
        }
        {
          std::lock_guard<std::mutex> lg(mutex_);
          const int64_t now = NowNanos();
          for (const auto& [id, ar] : awaitingSfRelease_) {
            int64_t remainMs = ar.released ? 0 : (ar.deadlineNs - now) / 1000000;
            if (remainMs < 0) remainMs = 0;
            if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);
          }
        }
        {
          std::lock_guard<std::mutex> lg(pacerMutex_);
          const int64_t now = NowNanos();
          for (const auto& [id, p] : pacer_) {
            if (p.dueNs == 0) continue;
            int64_t remainMs = (p.dueNs - now + 999999) / 1000000;
            if (remainMs < 0) remainMs = 0;
            if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);
          }
        }
        struct pollfd pfds[2] = {{fd, POLLIN, 0}, {controlWakeFd_, POLLIN, 0}};
        poll(pfds, 2, timeoutMs);
        if (controlWakeFd_ >= 0 && (pfds[1].revents & POLLIN)) {
          uint64_t drained;
          read(controlWakeFd_, &drained, sizeof(drained));
        }
        if (pfds[0].revents & POLLIN) {
          char buf[65536];
          ssize_t got = read(fd, buf, sizeof(buf));
          if (got > 0) {
            buffered.append(buf, static_cast<size_t>(got));
            size_t nl;
            while ((nl = buffered.find('\n')) != std::string::npos) {
              std::string line = buffered.substr(0, nl);
              buffered.erase(0, nl + 1);
              while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
              if (line.size() > kMaxControlLineBytes) {
                klogf("control: refusing a %zu-byte line, over the %zu-byte cap",
                      line.size(), kMaxControlLineBytes);
              } else if (!line.empty()) {
                klogf("control: <- %.80s%s", line.c_str(), line.size() > 80 ? "..." : "");
                HandleControlLine(line);
              }
            }
            if (buffered.size() > kMaxControlLineBytes) {
              klogf("control: unterminated line exceeded %zu bytes, dropping %zu buffered bytes",
                    kMaxControlLineBytes, buffered.size());
              buffered.clear();
            }
          }
        }
        std::vector<int64_t> removals;
        std::vector<std::pair<int64_t, PendingResize>> resizes;
        std::map<int64_t, int64_t> refreshes;
        {
          std::lock_guard<std::mutex> lg(workMutex_);
          removals.swap(pendingRemovals_);
          refreshes.swap(pendingRefresh_);
          int64_t now = NowNanos();
          for (auto it = heldRefresh_.begin(); it != heldRefresh_.end();) {
            if (now >= it->second.second) {
              refreshes.emplace(it->first, it->second.first);
              it = heldRefresh_.erase(it);
            } else {
              ++it;
            }
          }
          for (auto it = pendingResizes_.begin(); it != pendingResizes_.end();) {
            if (now >= it->second.dueNs) {
              resizes.push_back(*it);
              it = pendingResizes_.erase(it);
            } else {
              ++it;
            }
          }
        }
        for (auto& r : resizes) {
          ApplyResize(r.first, r.second.width, r.second.height, r.second.scale120);
          if (resizes.size() > 1) WaitForQuiescence(r.first);
        }
        for (const auto& [id, refreshNs] : refreshes) {
          const int64_t due = RefreshDueNs(id);
          if (due > NowNanos()) {
            std::lock_guard<std::mutex> lg(workMutex_);
            heldRefresh_[id] = {refreshNs, due};
            continue;
          }
          ApplyRefresh(id, refreshNs);
        }
        for (int64_t id : removals) RemoveDisplay(id);
        SendDueHeldPointerMoves();
        ServiceSfReleases();
      }
      if (controlWakeFd_ >= 0) {
        close(controlWakeFd_);
        controlWakeFd_ = -1;
      }
    });
  }

  // start the vsync thread
  void StartVsyncThreadOnce() {
    bool expected = false;
    if (!vsyncThreadStarted_.compare_exchange_strong(expected, true)) return;
    vsyncThread_ = std::thread([this] {
      prctl(PR_SET_NAME, "rhizo-vsync");
      SetFifoPriority2("rhizo-vsync");
      std::unique_lock<std::mutex> lk(mutex_);
      for (;;) {
        if (shuttingDown_.load(std::memory_order_acquire)) return;
        const int64_t now = NowNanos();
        int64_t wakeNs = INT64_MAX;
        std::vector<std::pair<int64_t, int64_t>> due;
        for (auto& [id, ds] : displays_) {
          if (!ds.claimed) continue;
          if (!ds.vsyncEnabled) {
            ds.timerDriving = false;
            continue;
          }
          if (ds.waylandBacked && now - ds.lastVsyncNs < kVsyncWatchdogNs) {
            ds.timerDriving = false;
            wakeNs = std::min(wakeNs, ds.lastVsyncNs + kVsyncWatchdogNs);
            continue;
          }
          if (ds.waylandBacked && !ds.timerDriving) {
            ds.timerDriving = true;
            ds.timerTakeovers++;
            ds.timerNextNs = 0;
            if (ds.presentsSinceFeedback >= 2) {
              klogf("display %lld timer takeover with %u presents unanswered for %.1fms",
                    static_cast<long long>(id), ds.presentsSinceFeedback, (now - ds.lastVsyncNs) / 1e6);
            }
          }
          const int64_t period = ds.vsyncPeriodNs;
          if (ds.timerNextNs == 0 || now >= ds.timerNextNs) {
            const int64_t anchor = ds.lastVsyncNs > 0 ? ds.lastVsyncNs : now;
            int64_t next = anchor + ((now - anchor) / period + 1) * period;
            if (ds.timerNextNs != 0 && ds.timerNextNs > now) next = ds.timerNextNs;
            ds.timerNextNs = next;
            while (ds.timerNextNs <= now) ds.timerNextNs += period;
            ds.lastSentVsyncNs = now;
            ds.timerTicks++;
            due.push_back({id, period});
          }
          wakeNs = std::min(wakeNs, ds.timerNextNs);
        }
        if (!due.empty()) {
          std::shared_ptr<IComposerCallback> cb = callback_;
          lk.unlock();
          if (cb) {
            for (const auto& [id, period] : due) cb->onVsync(id, now, period);
          }
          lk.lock();
          continue;
        }
        if (wakeNs == INT64_MAX) {
          vsyncCv_.wait(lk);
        } else {
          vsyncCv_.wait_until(lk, std::chrono::steady_clock::time_point(std::chrono::nanoseconds(wakeNs)));
        }
      }
    });
  }

  // connect to Wayland and start the event pump
  bool EnsureWaylandConnected() {
    if (waylandActive_.load(std::memory_order_acquire)) return true;
    std::lock_guard<std::mutex> lg(waylandLifecycleMutex_);
    if (waylandActive_.load(std::memory_order_acquire)) return true;
    if (!getenv("WAYLAND_DISPLAY")) {
      klog("EnsureWaylandConnected: WAYLAND_DISPLAY unset, staying headless (expected in the M2 config)");
      return false;
    }
    if (!wayland_.Connect()) {
      klog("EnsureWaylandConnected: WaylandBackend::Connect FAILED, staying headless");
      return false;
    }
    wayland_.StartEventPump(
        [this](int64_t displayId, int64_t timestampNs) { WaylandVsync(displayId, timestampNs); },
        [this](int64_t displayId) {
          klogf("Wayland compositor requested close of display %lld",
                static_cast<long long>(displayId));
          if (freeformEnabled() && RequestTaskClose(displayId)) return;
          {
            std::lock_guard<std::mutex> lg(workMutex_);
            pendingRemovals_.push_back(displayId);
          }
          WakeControlThread();
        },
        [this](int64_t displayId, int32_t width, int32_t height, int32_t scale120) {
          if (freeformEnabled()) {
            OnFreeformWindowSize(displayId, width, height, scale120);
            return;
          }
          {
            std::lock_guard<std::mutex> lg(workMutex_);
            auto it = pendingResizes_.find(displayId);
            const int64_t due = it != pendingResizes_.end() ? it->second.dueNs : NowNanos() + kResizeThrottleNs;
            pendingResizes_[displayId] = {width, height, scale120, due};
          }
          WakeControlThread();
        },
        [this](const rhizo::WaylandInputEvent& ev) { OnWaylandInput(ev); },
        [this](int64_t displayId, int64_t presentedNs, int64_t refreshNs, bool discarded,
               int64_t commitNs) {
          WaylandPresented(displayId, presentedNs, refreshNs, discarded, commitNs);
        },
        [this](const rhizo::WaylandDropEvent& ev) { OnWaylandDrop(ev); },
        [this](const std::string& keymapText) { OnHostKeymap(keymapText); },
        [this](const rhizo::WaylandSelectionEvent& ev) { OnWaylandSelection(ev); });
    waylandActive_.store(true, std::memory_order_release);
    klogf("EnsureWaylandConnected: Wayland connection established, presenting via %s", wayland_.PresentPaths());
    return true;
  }

  // create the primary display Wayland surface
  void TryStartPrimaryWaylandSurface() {
    bool expected = false;
    if (!bootPrimarySurfaceAttempted_.compare_exchange_strong(expected, true)) return;
    int32_t primaryW = kDefaultWidth, primaryH = kDefaultHeight;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(kPrimaryDisplayId)) {
        primaryW = ds->width;
        primaryH = ds->height;
      }
    }
    bool surface = EnsureWaylandConnected();
    const char* primaryWindow = getenv("RHIZO_PRIMARY_WINDOW");
    if (surface && primaryWindow && strcmp(primaryWindow, "0") == 0) {
      klog("TryStartPrimaryWaylandSurface: RHIZO_PRIMARY_WINDOW=0, primary stays headless, apps get windows");
      surface = false;
    } else if (surface && !wayland_.CreateDisplay(kPrimaryDisplayId, "Rhizo", primaryW, primaryH)) {
      klog("TryStartPrimaryWaylandSurface: WaylandBackend::CreateDisplay FAILED, staying headless");
      surface = false;
    }
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(kPrimaryDisplayId)) {
        if (surface) ds->waylandBacked = true;
        primaryW = ds->width;
        primaryH = ds->height;
      }
    }
    uinput_.PreCreatePool();
    uinput_.Create(kPrimaryDisplayId, 0, primaryW, primaryH);
    klog(surface ? "TryStartPrimaryWaylandSurface: primary display's Wayland surface live"
                 : "TryStartPrimaryWaylandSurface: primary display headless, its input devices live");
  }

  // log the display pool idle release time
  void ArmPoolIdleRelease() {
    int idleS = displayPoolIdleSeconds();
    if (idleS <= 0) return;
    klogf("RHIZO_MARKER pool_idle_armed release_at=%lld",
          static_cast<long long>(time(nullptr)) + idleS);
  }

  // tear down the primary surface and Wayland connection
  void MaybeTeardownOnLastAppDisplayClosed() {
    bool anyAppSurfaceLeft = false;
    bool primaryWasBacked = false;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      for (auto& kv : displays_) {
        if (kv.first == kPrimaryDisplayId) continue;
        if (kv.second.waylandBacked) { anyAppSurfaceLeft = true; break; }
      }
      if (!anyAppSurfaceLeft) {
        DisplayState* primary = FindLocked(kPrimaryDisplayId);
        primaryWasBacked = primary && primary->waylandBacked;
        if (primary) primary->waylandBacked = false;
      }
    }
    if (anyAppSurfaceLeft) return;
    ArmPoolIdleRelease();

    if (primaryWasBacked) {
      wayland_.DestroyDisplay(kPrimaryDisplayId);
      uinput_.Destroy(kPrimaryDisplayId);
      ForgetDisplayInputState(kPrimaryDisplayId);
      klog("MaybeTeardownOnLastAppDisplayClosed: last app display closed -- "
           "primary's own surface dropped too, connection going down");
    }
    MaybeTeardownWaylandConnection();
  }

  // disconnect the Wayland connection
  void MaybeTeardownWaylandConnection() {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      for (auto& kv : displays_) {
        if (kv.second.waylandBacked) return;
      }
    }
    std::lock_guard<std::mutex> lg(waylandLifecycleMutex_);
    if (!waylandActive_.load(std::memory_order_acquire)) return;
    {
      std::lock_guard<std::mutex> lg2(mutex_);
      for (auto& kv : displays_) {
        if (kv.second.waylandBacked) return;
      }
    }
    waylandActive_.store(false, std::memory_order_release);
    wayland_.Shutdown();
    wayland_.Disconnect();
    klog("Wayland: connection torn down, zero displays mapped (DEEP-ASLEEP freeze precondition met)");
  }

  // log vsync counts for a display
  void ReportVsyncStatsLocked(DisplayState* ds, int64_t displayId, int64_t now) {
    if (ds->lastVsyncStatsNs == 0) {
      ds->lastVsyncStatsNs = now;
      return;
    }
    int64_t elapsedNs = now - ds->lastVsyncStatsNs;
    if (elapsedNs < kVsyncStatsIntervalNs) return;
    klogf("vsync stats: display %lld recv=%llu sent=%llu dropped=%llu presented=%llu "
          "discarded=%llu timer=%llu takeovers=%llu over %lldms (boot total recv=%llu sent=%llu), "
          "period=%.3fms min_gap=%d%%",
          static_cast<long long>(displayId),
          (unsigned long long)(ds->vsyncRecv - ds->vsyncRecvReported),
          (unsigned long long)(ds->vsyncSent - ds->vsyncSentReported),
          (unsigned long long)(ds->vsyncDropped - ds->vsyncDroppedReported),
          (unsigned long long)(ds->presented - ds->presentedReported),
          (unsigned long long)(ds->discarded - ds->discardedReported),
          (unsigned long long)(ds->timerTicks - ds->timerTicksReported),
          (unsigned long long)(ds->timerTakeovers - ds->timerTakeoversReported),
          (long long)(elapsedNs / 1000000),
          (unsigned long long)ds->vsyncRecv, (unsigned long long)ds->vsyncSent,
          ds->vsyncPeriodNs / 1e6, composerVsyncMinGapPct());
    ds->vsyncRecvReported = ds->vsyncRecv;
    ds->vsyncSentReported = ds->vsyncSent;
    ds->vsyncDroppedReported = ds->vsyncDropped;
    ds->presentedReported = ds->presented;
    ds->discardedReported = ds->discarded;
    ds->timerTicksReported = ds->timerTicks;
    ds->timerTakeoversReported = ds->timerTakeovers;
    ds->lastVsyncStatsNs = now;
  }

  // forward a Wayland vsync to the callback
  void WaylandVsync(int64_t displayId, int64_t  ) {
    std::shared_ptr<IComposerCallback> cb;
    int64_t period = 0;
    int64_t now = NowNanos();
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLocked(displayId);
      if (!ds || !ds->vsyncEnabled) return;
      const int64_t minGapNs = (ds->vsyncPeriodNs * composerVsyncMinGapPct()) / 100;
      ds->vsyncRecv++;
      ds->lastVsyncNs = now;
      if (now - ds->lastSentVsyncNs < minGapNs) {
        ds->vsyncDropped++;
        ReportVsyncStatsLocked(ds, displayId, now);
        return;
      }
      ds->lastSentVsyncNs = now;
      ds->vsyncSent++;
      ReportVsyncStatsLocked(ds, displayId, now);
      period = ds->vsyncPeriodNs;
      cb = callback_;
    }
    if (cb) cb->onVsync(displayId, now, period);
  }

  // record presentation feedback and forward vsync
  void WaylandPresented(int64_t displayId, int64_t presentedNs, int64_t refreshNs, bool discarded,
                        int64_t commitNs) {
    std::shared_ptr<IComposerCallback> cb;
    int64_t stamp = 0;
    int64_t period = 0;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLocked(displayId);
      if (!ds) return;
      if (discarded) {
        ds->discarded++;
        return;
      }
      ds->presented++;
      ds->vsyncRecv++;
      const int64_t now = NowNanos();
      if (ds->presentsSinceFeedback >= 3 && ds->lastFeedbackNs > 0) {
        klogf("display %lld compositor stall: %u presents fed over %.1fms before feedback (%lld periods)",
              static_cast<long long>(displayId), ds->presentsSinceFeedback,
              (now - ds->lastFeedbackNs) / 1e6,
              static_cast<long long>(ds->vsyncPeriodNs > 0 ? (now - ds->lastFeedbackNs) / ds->vsyncPeriodNs : 0));
      }
      ds->presentsSinceFeedback = 0;
      ds->lastFeedbackNs = now;
      const bool clockUsable = wayland_.PresentationClockId() == CLOCK_MONOTONIC && presentedNs > 0;
      stamp = clockUsable ? presentedNs : now;
      if (ds->tap.armed && ds->presentCount > ds->tap.armPresentCount &&
          ds->tap.sfPresentNs != 0 && commitNs >= ds->tap.sfPresentNs) {
        if (clockUsable) {
          const int64_t deltaNs = presentedNs - ds->tap.armQueuedNs;
          if (ds->tap.count == 0 || deltaNs < ds->tap.minNs) ds->tap.minNs = deltaNs;
          if (ds->tap.count == 0 || deltaNs > ds->tap.maxNs) ds->tap.maxNs = deltaNs;
          ds->tap.sumNs += deltaNs;
          ds->tap.lastNs = deltaNs;
          ds->tap.hopUinputNs = ds->tap.uinputNs != 0 ? ds->tap.uinputNs - ds->tap.armQueuedNs : 0;
          ds->tap.hopSfPresentNs = ds->tap.sfPresentNs - ds->tap.armQueuedNs;
          ds->tap.hopCommitNs = commitNs - ds->tap.armQueuedNs;
          ds->tap.count++;
          if (ds->tap.count == 1) {
            klogf("display %lld first input-to-photon: press->presented %lldns, wire delta %lldns",
                  static_cast<long long>(displayId), (long long)deltaNs,
                  (long long)ds->tap.wireDeltaLastNs);
          }
        }
        ds->tap.armed = false;
      }
      if (ds->firstPresent.armed && ds->firstPresent.sfPresentNs != 0 &&
          commitNs >= ds->firstPresent.sfPresentNs && clockUsable) {
        ds->firstPresent.commitNs = commitNs;
        ds->firstPresent.presentedNs = presentedNs;
        ds->firstPresent.count++;
        ds->firstPresent.armed = false;
      }
      const int64_t feedbackRefreshNs = refreshNs;
      if (refreshNs <= 0) refreshNs = wayland_.OutputRefreshNs(displayId);
      if (ds->presented == 1) {
        klogf("display %lld first presentation feedback: presented=%lld now=%lld (delta %.3fms) "
              "refresh=%lldns (feedback %lldns, output mode %lldns) clock=%d",
              static_cast<long long>(displayId), (long long)presentedNs, (long long)now,
              (now - presentedNs) / 1e6, (long long)refreshNs, (long long)feedbackRefreshNs,
              (long long)wayland_.OutputRefreshNs(displayId), wayland_.PresentationClockId());
      }
      if (!clockUsable && !presentationClockWarned_) {
        presentationClockWarned_ = true;
        klogf("presentation feedback is on clock %d, not CLOCK_MONOTONIC -- vsync timestamps "
              "stay pump-time", wayland_.PresentationClockId());
      }
      if (refreshNs > 0 && RefreshDiffers(refreshNs, ds->vsyncPeriodNs)) {
        {
          std::lock_guard<std::mutex> lw(workMutex_);
          pendingRefresh_[displayId] = refreshNs;
        }
        WakeControlThread();
      }
      ds->lastVsyncNs = stamp;
      if (!ds->vsyncEnabled) return;
      const int64_t minGapNs = (ds->vsyncPeriodNs * composerVsyncMinGapPct()) / 100;
      if (stamp - ds->lastSentVsyncNs < minGapNs) {
        ds->vsyncDropped++;
        ReportVsyncStatsLocked(ds, displayId, now);
        return;
      }
      ds->lastSentVsyncNs = stamp;
      ds->vsyncSent++;
      ReportVsyncStatsLocked(ds, displayId, now);
      period = ds->vsyncPeriodNs;
      cb = callback_;
    }
    if (cb) cb->onVsync(displayId, stamp, period);
  }

  // return true for a change over 0.5 percent
  static bool RefreshDiffers(int64_t a, int64_t b) {
    int64_t d = a > b ? a - b : b - a;
    return d * 200 > b;
  }

  // return the earliest refresh change time
  int64_t RefreshDueNs(int64_t id) {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindAnyRaw(id);
    if (!ds) return 0;
    const int64_t sinceConnectNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - ds->lastConnectAt).count();
    return std::max(NowNanos() + kRefreshAfterHotplugNs - sinceConnectNs, lastAnyHotplugNs_ + kQuiescenceGapNs);
  }

  // set the display refresh period
  void ApplyRefresh(int64_t id, int64_t refreshNs) {
    std::shared_ptr<IComposerCallback> cb;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLocked(id);
      if (!ds) return;
      if (ds->removing) return;
      if (!RefreshDiffers(refreshNs, ds->vsyncPeriodNs)) return;
      klogf("display %lld refresh %.3fms -> %.3fms (%.2fHz), re-hotplugging",
            static_cast<long long>(id), ds->vsyncPeriodNs / 1e6, refreshNs / 1e6, 1e9 / refreshNs);
      ds->vsyncPeriodNs = refreshNs;
      ds->timerNextNs = 0;
      ds->configGroup++;
      ds->SyncConfig();
      if (id == kPrimaryDisplayId) KeepPrimaryGeometry(*ds);
      cb = callback_;
      vsyncCv_.notify_all();
    }
    if (!cb) return;
    auto st = cb->onHotplugEvent(
        id, ::aidl::android::hardware::graphics::common::DisplayHotplugEvent::CONNECTED);
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(id)) ds->lastConnectAt = std::chrono::steady_clock::now();
      lastAnyHotplugNs_ = NowNanos();
    }
    klogf("ApplyRefresh: display %lld re-hotplug CONNECTED isOk=%d", static_cast<long long>(id),
          st.isOk());
    LifecycleKlogf(id, "hotplug CONNECTED sent");
  }

  std::mutex mutex_;
  std::map<int64_t, DisplayState> displays_;
  std::map<int64_t, DisplayState> removingDisplays_;
  // display waiting for SurfaceFlinger release
  struct AwaitingRelease {
    int32_t port = 0;
    int64_t sentNs = 0;
    int64_t deadlineNs = 0;
    int attempts = 1;
    bool released = false;
  };
  std::map<int64_t, AwaitingRelease> awaitingSfRelease_;
  std::map<int64_t, int32_t> orphanedPorts_;
  int64_t lastAnyHotplugNs_ = 0;
  std::shared_ptr<IComposerCallback> callback_;
  std::atomic<bool> vsyncThreadStarted_{false};
  rhizo::WaylandBackend wayland_;
  rhizo::StreamExportBackend stream_;
  rhizo::UinputDevices uinput_;
  std::set<int64_t> pointerDown_;
  std::map<int64_t, std::pair<int32_t, int32_t>> androidPointer_;
  std::map<int64_t, std::pair<int32_t, int32_t>> pointerRemainder_;

  std::map<int64_t, std::pair<int32_t, int32_t>> lastPointerAbs_;
  // pointer position read from cursor layer
  struct ObservedPointer {
    int32_t x = 0, y = 0, w = 0, h = 0;
  };
  // store the observed pointer position and size for a display
  void SetObservedPointer(int64_t displayId, int32_t x, int32_t y, int32_t w = 0, int32_t h = 0) {
    std::lock_guard<std::mutex> lg(observedPointerMutex_);
    observedPointer_[displayId] = {x, y, w, h};
  }
  // return and clear the pointer position
  bool TakeObservedPointer(int64_t displayId, int32_t* x, int32_t* y) {
    ObservedPointer o;
    {
      std::lock_guard<std::mutex> lg(observedPointerMutex_);
      auto it = observedPointer_.find(displayId);
      if (it == observedPointer_.end()) return false;
      o = it->second;
      observedPointer_.erase(it);
    }
    auto mit = androidPointer_.find(displayId);
    const bool haveModel = mit != androidPointer_.end();
    *x = rhizo::ReconcileObservedAxis(haveModel, haveModel ? mit->second.first : 0, o.x, o.w);
    *y = rhizo::ReconcileObservedAxis(haveModel, haveModel ? mit->second.second : 0, o.y, o.h);
    return true;
  }
  std::mutex observedPointerMutex_;
  std::map<int64_t, ObservedPointer> observedPointer_;
  // a relative move held for an accelerated display
  struct HeldPointerMove {
    int32_t dx = 0, dy = 0;
    int64_t lastSendNs = 0, dueNs = 0;
  };
  std::mutex pacerMutex_;
  std::map<int64_t, HeldPointerMove> pacer_;

  std::mutex cursorPointerMutex_;
  std::map<int64_t, std::pair<int32_t, int32_t>> cursorPointerAbs_;
  // pointer type and request count per cursor image digest (under mutex_)
  static constexpr size_t kMaxPointerTypeImages = 4096;
  std::map<uint32_t, int32_t> pointerTypeByImage_;
  std::map<uint32_t, int> pointerTypeAsks_;
  std::atomic<int64_t> nextDropSeq_{0};
  std::atomic<int64_t> nextClipSeq_{0};
  std::mutex keymapMutex_;
  uint32_t hostKeymapDigest_ = 0;
  uint32_t keymapTableDigest_ = 0;
  std::map<uint32_t, std::array<std::string, 4>> keymapTable_;
  std::set<std::string> unmappableChars_;
  std::atomic<int64_t> nextKeymapFileSeq_{0};
  // per-display keyboard translation state
  struct KeyTranslateState {
    uint32_t effectiveMods = 0;
    int32_t group = 0;
    std::set<uint32_t> heldShift;
    std::set<uint32_t> heldAltGr;
    // key emission for a host scancode
    struct Emitted {
      uint16_t androidCode = 0;
      bool forcedShiftOn = false;
      std::set<uint32_t> forcedShiftOff;
      std::set<uint32_t> forcedAltGrOff;
    };
    std::map<uint32_t, Emitted> active;
  };
  std::map<int64_t, KeyTranslateState> keyTranslate_;
  // state for injected touch input
  struct InjectedTouch {
    bool down = false;
    bool watcherRunning = false;
    int64_t lastActivityNs = 0;
  };
  std::mutex injectMutex_;
  std::map<int64_t, InjectedTouch> injectedTouch_;
  std::atomic<bool> bootPrimarySurfaceAttempted_{false};
  std::atomic<bool> waylandActive_{false};
  std::mutex waylandLifecycleMutex_;
  std::atomic<bool> controlThreadStarted_{false};
  int64_t nextDisplayId_ = 2;
  std::set<int32_t> freePorts_{1, 2, 3, 4, 5, 6, 7, 8};
  std::mutex workMutex_;
  std::vector<int64_t> pendingRemovals_;
  struct PendingResize { int32_t width; int32_t height; int32_t scale120; int64_t dueNs; };
  std::map<int64_t, PendingResize> pendingResizes_;
  std::map<int64_t, int64_t> pendingRefresh_;
  std::map<int64_t, std::pair<int64_t, int64_t>> heldRefresh_;
  int controlWakeFd_ = -1;
  // write one to the control thread's wake eventfd
  void WakeControlThread() {
    if (controlWakeFd_ < 0) return;
    uint64_t one = 1;
    write(controlWakeFd_, &one, sizeof(one));
  }
  std::condition_variable vsyncCv_;
  bool presentationClockWarned_ = false;
  std::atomic<bool> shuttingDown_{false};
  std::atomic<int> transientThreads_{0};
  std::thread controlThread_;
  std::thread vsyncThread_;
};

// IComposer HAL for Wayland display output
class RhizoComposer : public BnComposer {
 public:
  // create the RhizoComposerClient
  ScopedAStatus createClient(std::shared_ptr<IComposerClient>* out) override {
    klog("createClient() called");
    std::lock_guard<std::mutex> lg(mutex_);
    if (auto live = client_.lock()) {
      (void)live;
      return clientErr(IComposerClient::EX_NO_RESOURCES, "a client is already connected");
    }
    auto client = ndk::SharedRefBase::make<RhizoComposerClient>();
    AIBinder_setMinSchedulerPolicy(client->asBinder().get(), SCHED_FIFO, 2);
    client_ = client;
    *out = client;
    return ok();
  }
  // return the composer capabilities
  ScopedAStatus getCapabilities(std::vector<Capability>* out) override {
    klog("getCapabilities() called");
    *out = composerUnreliableFences() ? std::vector<Capability>{Capability::PRESENT_FENCE_IS_NOT_RELIABLE}
                                       : std::vector<Capability>{};
    return ok();
  }

 private:
  std::mutex mutex_;
  std::weak_ptr<RhizoComposerClient> client_;
};

}

// register the composer and join the thread pool
int main() {
  klog("main() entered");
  klogf("RHIZO_MARKER display_pool_idle_s=%d", displayPoolIdleSeconds());
  auto composer = ndk::SharedRefBase::make<RhizoComposer>();
  const std::string instance = std::string(RhizoComposer::descriptor) + "/default";
  AIBinder_setMinSchedulerPolicy(composer->asBinder().get(), SCHED_FIFO, 2);
  binder_status_t status = AServiceManager_addService(composer->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    klogf("addService FAILED status=%d", status);
    return 1;
  }
  klog("registered, joining thread pool");
  SetFifoPriority2("rhizo-composer main thread");
  ABinderProcess_setThreadPoolMaxThreadCount(4);
  ABinderProcess_joinThreadPool();
  klog("joinThreadPool RETURNED (unexpected)");
  return 0;
}

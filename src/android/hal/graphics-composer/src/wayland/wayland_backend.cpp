#include "wayland_backend.h"
#include "rhizo/memfd_buffer.h"
#include "../input/pointer_icon.h"
#include "selection_read.h"
#include "shm_present.h"

#include <poll.h>
#include <deque>
#include <unistd.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <wayland-client.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <fcntl.h>
#include <sys/eventfd.h>
#include <time.h>
#include <set>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <log/log.h>

#include "cursor-shape-v1-client-protocol.h"
#include "fractional-scale-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
#include "presentation-time-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-activation-v1-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static_assert(rhizo::kShapeDefault == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT &&
                  rhizo::kShapeContextMenu == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CONTEXT_MENU &&
                  rhizo::kShapeHelp == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_HELP &&
                  rhizo::kShapePointer == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER &&
                  rhizo::kShapeWait == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT &&
                  rhizo::kShapeCell == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CELL &&
                  rhizo::kShapeCrosshair == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR &&
                  rhizo::kShapeText == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT &&
                  rhizo::kShapeVerticalText == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_VERTICAL_TEXT &&
                  rhizo::kShapeAlias == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALIAS &&
                  rhizo::kShapeCopy == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COPY &&
                  rhizo::kShapeNotAllowed == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED &&
                  rhizo::kShapeGrab == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB &&
                  rhizo::kShapeGrabbing == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING &&
                  rhizo::kShapeEwResize == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE &&
                  rhizo::kShapeNsResize == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE &&
                  rhizo::kShapeNeswResize == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE &&
                  rhizo::kShapeNwseResize == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE &&
                  rhizo::kShapeAllScroll == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_SCROLL &&
                  rhizo::kShapeZoomIn == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_IN &&
                  rhizo::kShapeZoomOut == WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_OUT,
              "pointer_icon.h's shapes are wp_cursor_shape_device_v1's");

namespace rhizo {
namespace {

// write the message to logcat
void klog(const char* msg) {
  __android_log_print(ANDROID_LOG_INFO, "rhizo-wayland-backend", "%s", msg);
}
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

// return the RHIZO_COMPOSER_DEBUG setting
bool composerDebugEnabled() {
  static const bool on = getenv("RHIZO_COMPOSER_DEBUG") != nullptr;
  return on;
}

// return the clipboard enabled flag
bool composerClipboardEnabled() {
  static const bool on = [] {
    const char* v = getenv("RHIZO_COMPOSER_CLIPBOARD");
    return !(v && strcmp(v, "0") == 0);
  }();
  return on;
}

// return the monotonic clock in nanoseconds
int64_t MonotonicNs() {
  struct timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

// wait up to 3 s for the fence fd
void WaitFence(int fenceFd) {
  if (fenceFd < 0) return;
  struct pollfd pfd{fenceFd, POLLIN, 0};
  int pr = poll(&pfd, 1, 3000);
  if (pr <= 0) {
    klogf("WaylandBackend: acquire fence wait pr=%d errno=%d (%s) -- proceeding anyway",
          pr, errno, strerror(errno));
  }
}

// write the bytes to the file descriptor
bool WriteAllWithDeadline(int fd, const uint8_t* data, size_t len, const char* what) {
  size_t remaining = len;
  const uint8_t* p = data;
  const int64_t deadlineNs = MonotonicNs() + 5000000000LL;
  while (remaining > 0) {
    const int64_t remainingMs = (deadlineNs - MonotonicNs()) / 1000000;
    if (remainingMs <= 0) {
      klogf("WaylandBackend: %s write timed out, %zu/%zu bytes sent", what, len - remaining, len);
      return false;
    }
    struct pollfd pfd{fd, POLLOUT, 0};
    int pr = poll(&pfd, 1, static_cast<int>(remainingMs));
    if (pr < 0) {
      if (errno == EINTR) continue;
      klogf("WaylandBackend: %s send poll FAILED errno=%d (%s)", what, errno, strerror(errno));
      return false;
    }
    if (pr == 0) {
      klogf("WaylandBackend: %s write timed out, %zu/%zu bytes sent", what, len - remaining, len);
      return false;
    }
    ssize_t w = write(fd, p, remaining);
    if (w <= 0) {
      klogf("WaylandBackend: %s write FAILED errno=%d (%s), %zu/%zu bytes sent", what, errno,
            strerror(errno), len - remaining, len);
      return false;
    }
    p += w;
    remaining -= static_cast<size_t>(w);
  }
  return true;
}

// create a sized anonymous shm file
int CreateAnonShmFile(size_t size) {
  int fd = memfd_create("rhizo-cursor", MFD_CLOEXEC);
  if (fd < 0) {
    klogf("CreateAnonShmFile: memfd_create failed errno=%d (%s)", errno, strerror(errno));
    return -1;
  }
  if (ftruncate(fd, static_cast<off_t>(size)) < 0) {
    klogf("CreateAnonShmFile: ftruncate(%zu) failed errno=%d (%s)", size, errno, strerror(errno));
    close(fd);
    return -1;
  }
  return fd;
}

// cached wl_buffer for a buffer slot
struct BufferSlot {
  wl_buffer* buffer = nullptr;
  wl_shm_pool* pool = nullptr;
  dev_t dev = 0;
  ino_t ino = 0;
  bool releasedSinceAttach = true;
  // wl_shm buffer a memfd frame is copied into
  struct Copy {
    int fd = -1;
    void* map = nullptr;
    size_t size = 0;
    wl_shm_pool* pool = nullptr;
    wl_buffer* buffer = nullptr;
    int32_t width = 0;
    int32_t height = 0;
    uint32_t format = 0;
    bool released = true;
  } copy[2];
};

// listener userdata for a drag source
struct DragSourceCtx {
  WaylandBackend::Impl* impl;
  std::shared_ptr<const std::vector<uint8_t>> payload;
};

// listener userdata for a selection source
struct ClipSourceCtx {
  WaylandBackend::Impl* impl;
  std::shared_ptr<const std::vector<uint8_t>> payload;
};

// state for a Wayland display
struct DisplayState {
  int64_t id = -1;
  wl_surface* surface = nullptr;
  xdg_surface* xdgSurface = nullptr;
  xdg_toplevel* xdgToplevel = nullptr;
  wp_viewport* viewport = nullptr;
  void* toplevelCtx = nullptr;
  bool configured = false;
  int32_t proposedWidth = 0;
  int32_t proposedHeight = 0;
  int32_t reportedWidth = 0;
  int32_t reportedHeight = 0;
  int32_t startWidth = 0;
  int32_t startHeight = 0;
  int32_t boundsWidth = 0;
  int32_t boundsHeight = 0;
  std::map<int32_t, BufferSlot> bufferCache;
  std::set<wl_output*> enteredOutputs;
  wl_output* currentOutput = nullptr;
  int32_t appliedScale120 = 120;
  wp_fractional_scale_v1* fractionalScale = nullptr;
  int32_t preferredScale120 = 0;
  std::string appId;
  std::string title;
  bool maximized = false;
  bool fullscreen = false;
  bool activated = false;
  bool resizing = false;
  bool bufferCommitted = false;
  bool viewportCropped = false;
  // one-pixel background buffer shown under the app
  struct Fill {
    wl_surface* surface = nullptr;
    wl_subsurface* subsurface = nullptr;
    wp_viewport* viewport = nullptr;
    wl_shm_pool* pool = nullptr;
    wl_buffer* buffer = nullptr;
    void* map = nullptr;
    int fd = -1;
    uint32_t rgba = 0;
    bool shown = false;
  } fill;
  bool minSizeSet = false;
  // configures not yet acked, oldest first
  struct PendingAck {
    uint32_t serial;
    int32_t width;
    int32_t height;
    int64_t sinceNs;
  };
  std::vector<PendingAck> pendingAcks;
  std::string heldActivationToken;
  struct CursorContent {
    bool valid = false;
    std::vector<uint8_t> argb;
    int32_t width = 0;
    int32_t height = 0;
    int32_t hotspotX = 0;
    int32_t hotspotY = 0;
    int32_t pointerType = rhizo::kPointerTypeArrow;
  } cursor;

  zxdg_toplevel_decoration_v1* decoration = nullptr;
  WaylandDecorationMode decorationMode = WaylandDecorationMode::kNone;
  // client-side title strip
  struct CsdStrip {
    wl_surface* surface = nullptr;
    wl_subsurface* subsurface = nullptr;
    wl_shm_pool* pool = nullptr;
    void* data = nullptr;
    int32_t poolSize = 0;
    wl_buffer* buffer = nullptr;
    int32_t width = 0;
    int32_t scale = 0;
  } csd;
};

wl_output* EffectiveOutputLocked(WaylandBackend::Impl* impl, DisplayState* ds, int32_t* outScale);

void QueueResizeLocked(WaylandBackend::Impl* impl, DisplayState* ds);

void ApplyCursorNowLocked(WaylandBackend::Impl* impl, DisplayState* ds);

void RedrawCsdStripLocked(WaylandBackend::Impl* impl, DisplayState* ds);

void CreateCsdStripLocked(WaylandBackend::Impl* impl, DisplayState* ds);

void DestroyCsdStripLocked(DisplayState* ds);

void CreateSelectionSourceLocked(WaylandBackend::Impl* impl, const std::string& mime,
                                  std::shared_ptr<const std::vector<uint8_t>> payload);

void CompleteParkedSelectionLocked(WaylandBackend::Impl* impl);

// return the high 32 bits of a modifier
uint32_t ModHi(uint64_t m) { return static_cast<uint32_t>(m >> 32); }
// return the low 32 bits of a modifier
uint32_t ModLo(uint64_t m) { return static_cast<uint32_t>(m & 0xffffffffu); }

}

std::mutex g_wlLogMutex;
std::string g_wlLastLogMessage;
// format a libwayland log message and store it as the last one
void WlLogHandler(const char* fmt, va_list args) {
  char buf[320];
  vsnprintf(buf, sizeof(buf), fmt, args);
  std::lock_guard<std::mutex> lg(g_wlLogMutex);
  g_wlLastLogMessage = buf;
}

// state for the Wayland connection
struct WaylandBackend::Impl {
  std::mutex mutex_;
  std::condition_variable configureCv;

  wl_display* display = nullptr;
  wl_registry* registry = nullptr;
  wl_compositor* compositor = nullptr;
  xdg_wm_base* wmBase = nullptr;
  zwp_linux_dmabuf_v1* dmabuf = nullptr;
  wp_presentation* presentation = nullptr;
  int presentationClockId = -1;
  // state of a bound wl_output
  struct OutputState {
    std::string name;
    int32_t scale = 1;
    int32_t width = 0;
    int32_t height = 0;
    int32_t refreshMHz = 0;
  };
  std::map<wl_output*, OutputState> outputs;
  // batched wl_pointer axis events
  struct PendingAxis {
    bool haveAxis = false;
    double axisValue = 0;
    bool haveValue120 = false;
    int32_t value120 = 0;
    bool haveDiscrete = false;
    int32_t discrete = 0;
  };
  PendingAxis pendingAxis[2];
  wp_viewporter* viewporter = nullptr;
  wp_fractional_scale_manager_v1* fractionalScaleManager = nullptr;
  wp_cursor_shape_manager_v1* cursorShapeManager = nullptr;
  wp_cursor_shape_device_v1* cursorShapeDevice = nullptr;
  wl_shm* shm = nullptr;
  std::set<uint32_t> shmFormats;
  uint64_t shmCopyDrops = 0;
  uint64_t shmRefusals = 0;
  uint64_t shmUnsealed = 0;
  uint64_t dmabufRefusals = 0;
  wl_seat* seat = nullptr;
  wl_pointer* pointer = nullptr;
  wl_keyboard* keyboard = nullptr;
  wl_touch* touch = nullptr;
  wl_data_device_manager* dataDeviceManager = nullptr;
  wl_data_device* dataDevice = nullptr;
  wl_subcompositor* subcompositor = nullptr;
  zxdg_decoration_manager_v1* decorationManager = nullptr;
  xdg_activation_v1* activationManager = nullptr;
  uint32_t dmabufVersion = 0;
  uint32_t lastPointerSerial = 0;
  bool lastPointerHeld = false;
  uint32_t lastPointerEnterSerial = 0;
  uint32_t lastInputSerial = 0;
  int64_t csdPointerFocus = -1;
  std::map<wl_surface*, int64_t> csdSurfaceToDisplay;

  wl_surface* cursorSurface = nullptr;
  struct CursorShmBuffer {
    wl_shm_pool* pool = nullptr;
    void* data = nullptr;
    int32_t size = 0;
    wl_buffer* buffer = nullptr;
    int32_t width = 0;
    int32_t height = 0;
    bool released = true;
  };
  CursorShmBuffer cursorBufs[2];
  int cursorBufNext = 0;
  std::set<int64_t> cursorApplyPending;

  int64_t presentAttempts = 0;
  int64_t connectCount = 0;
  std::map<uint32_t, int64_t> paramsIdAllocatedAtAttempt;
  struct FirstErrorInfo {
    bool captured = false;
    int64_t atPresentAttempt = -1;
    int64_t displayId = -1;
    int32_t width = 0, height = 0, strideBytes = 0;
    int dmabufFd = -1;
    uint32_t drmFormat = 0;
    uint64_t modifier = 0;
    uint32_t failedParamsId = 0;
    bool failedParamsIdWasReused = false;
    int64_t failedParamsIdPriorAllocAttempt = -1;
  } firstError;

  std::map<wl_surface*, int64_t> surfaceToDisplay;
  int64_t pointerFocus = -1;
  int64_t keyboardFocus = -1;
  int64_t touchFocus = -1;
  double pointerX = 0, pointerY = 0;

  wl_data_offer* pendingOfferProxy = nullptr;
  std::vector<std::string> pendingOfferMimes;

  // drag offer over a display
  struct DndOfferState {
    wl_data_offer* offer = nullptr;
    int64_t displayId = -1;
    std::vector<std::string> mimeTypes;
    std::string acceptedMime;
    bool actionReceived = false;
    double x = 0, y = 0;
  } dndOffer;

  wl_data_source* dragSource = nullptr;
  void* dragSourceCtx = nullptr;

  wl_data_source* clipSource = nullptr;
  void* clipSourceCtx = nullptr;
  // deferred clipboard set request
  struct ParkedSelection {
    bool valid = false;
    std::string mime;
    std::shared_ptr<const std::vector<uint8_t>> payload;
  } parkedSelection;

  int64_t activeIoThreads = 0;
  std::condition_variable ioThreadsCv;

  std::map<uint32_t, std::vector<uint64_t>> modifierTable;
  std::set<std::pair<uint32_t, uint64_t>> importedPairs;

  std::map<int64_t, DisplayState> displays;

  VsyncCallback vsyncCb;
  CloseCallback closeCb;
  ResizeCallback resizeCb;
  InputCallback inputCb;
  PresentedCallback presentedCb;
  DropCallback dropCb;
  KeymapCallback keymapCb;
  SelectionCallback selectionCb;

  std::condition_variable activationCv;
  bool activationTokenReady = false;
  std::string pendingActivationTokenResult;

  // queue an input event for the display
  void QueueInput(int64_t displayId, WaylandInputEvent::Kind kind, double x, double y,
                  uint32_t code, int32_t value, uint32_t timeMsec) {
    if (displayId < 0) {
      klogf("QueueInput: dropped kind=%d x=%.0f y=%.0f code=%u value=%d, no focused display",
            static_cast<int>(kind), x, y, code, value);
    }
    if (!inputCb || displayId < 0) return;
    WaylandInputEvent ev;
    ev.displayId = displayId;
    ev.kind = kind;
    ev.x = x;
    ev.y = y;
    ev.code = code;
    ev.value = value;
    ev.timeMsec = timeMsec;
    ev.queuedNs = MonotonicNs();
    pendingInput.push_back(ev);
  }

  struct PendingVsync { int64_t displayId; int64_t timestampNs; };
  struct PendingResize { int64_t displayId; int32_t width; int32_t height; int32_t scale; };
  struct PendingPresented { int64_t displayId; int64_t presentedNs; int64_t refreshNs; bool discarded; int64_t commitNs; };
  std::vector<PendingVsync> pendingVsyncs;
  std::vector<PendingPresented> pendingPresented;
  std::vector<int64_t> pendingCloses;
  std::vector<PendingResize> pendingResizes;
  std::vector<WaylandInputEvent> pendingInput;
  std::vector<WaylandDropEvent> pendingDrops;
  std::vector<std::string> pendingKeymaps;
  std::vector<WaylandSelectionEvent> pendingSelections;
  rhizo_selection::Sequencer selections;

  static constexpr size_t kPendingDepth = 2;
  struct PendingFrame { WaylandFrame frame; int64_t queuedNs = 0; };
  std::map<int64_t, std::deque<PendingFrame>> pendingFrames;
  int wakeFd = -1;
  uint64_t asyncQueued = 0, asyncSuperseded = 0, asyncPresented = 0, asyncWaitNs = 0, asyncWaitMaxNs = 0;
  int64_t asyncReportNs = 0;
  // close a pending frame's dmabuf and acquire fence fds
  static void ClosePending(PendingFrame& pf) {
    if (pf.frame.dmabufFd >= 0) close(pf.frame.dmabufFd);
    if (pf.frame.acquireFenceFd >= 0) close(pf.frame.acquireFenceFd);
    pf.frame.dmabufFd = -1;
    pf.frame.acquireFenceFd = -1;
  }

  std::thread pumpThread;
  bool pumpRunning = false;
  bool connected = false;
  bool lastPresentWasDmabuf = false;
  bool lastPresentDropped = false;
  bool vsyncEnabled = false;

  // return the state of a display
  DisplayState* Find(int64_t displayId) {
    auto it = displays.find(displayId);
    return it == displays.end() ? nullptr : &it->second;
  }

  // stop the event pump thread
  void StopPump() {
    if (pumpRunning) {
      {
        std::lock_guard<std::mutex> lg(mutex_);
        pumpRunning = false;
      }
      if (pumpThread.joinable()) pumpThread.join();
      for (auto& kv : pendingFrames) {
        for (auto& pf : kv.second) ClosePending(pf);
      }
      pendingFrames.clear();
      if (wakeFd >= 0) { close(wakeFd); wakeFd = -1; }
    }
    std::unique_lock<std::mutex> lk(mutex_);
    bool drained = ioThreadsCv.wait_for(lk, std::chrono::seconds(6),
                                         [&] { return activeIoThreads == 0; });
    if (!drained) {
      klogf("WaylandBackend: %lld drag-and-drop I/O thread(s) still running at shutdown",
            static_cast<long long>(activeIoThreads));
    }
  }

  // stop the pump and disconnect from the wayland display
  ~Impl() {
    StopPump();
    if (display) wl_display_disconnect(display);
  }
};

// create the backend's state
WaylandBackend::WaylandBackend() : impl_(new Impl()) {}
WaylandBackend::~WaylandBackend() = default;

// stop the pump
void WaylandBackend::Shutdown() { impl_->StopPump(); }

// destroy the Wayland objects and disconnect
void WaylandBackend::Disconnect() {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  if (!impl->display) return;

  if (!impl->displays.empty()) {
    std::vector<int64_t> leftover;
    for (auto& kv : impl->displays) leftover.push_back(kv.first);
    for (int64_t id : leftover) {
      klogf("WaylandBackend::Disconnect: display %lld still had a live surface -- "
            "destroying it",
            static_cast<long long>(id));
      DestroyDisplayLocked(impl, id);
    }
  }

  if (impl->cursorShapeDevice) {
    wp_cursor_shape_device_v1_destroy(impl->cursorShapeDevice);
    impl->cursorShapeDevice = nullptr;
  }
  if (impl->pointer) { wl_pointer_release(impl->pointer); impl->pointer = nullptr; }
  if (impl->keyboard) { wl_keyboard_release(impl->keyboard); impl->keyboard = nullptr; }
  if (impl->touch) { wl_touch_release(impl->touch); impl->touch = nullptr; }
  if (impl->seat) { wl_seat_destroy(impl->seat); impl->seat = nullptr; }
  if (impl->pendingOfferProxy) {
    wl_data_offer_destroy(impl->pendingOfferProxy);
    impl->pendingOfferProxy = nullptr;
    impl->pendingOfferMimes.clear();
  }
  if (impl->dndOffer.offer) {
    wl_data_offer_destroy(impl->dndOffer.offer);
    impl->dndOffer = {};
  }
  if (impl->dragSource) {
    wl_data_source_destroy(impl->dragSource);
    delete static_cast<DragSourceCtx*>(impl->dragSourceCtx);
    impl->dragSource = nullptr;
    impl->dragSourceCtx = nullptr;
  }
  if (impl->clipSource) {
    wl_data_source_destroy(impl->clipSource);
    delete static_cast<ClipSourceCtx*>(impl->clipSourceCtx);
    impl->clipSource = nullptr;
    impl->clipSourceCtx = nullptr;
  }
  impl->parkedSelection = {};
  if (impl->dataDevice) { wl_data_device_release(impl->dataDevice); impl->dataDevice = nullptr; }
  if (impl->dataDeviceManager) {
    wl_data_device_manager_destroy(impl->dataDeviceManager);
    impl->dataDeviceManager = nullptr;
  }
  if (impl->activationManager) {
    xdg_activation_v1_destroy(impl->activationManager);
    impl->activationManager = nullptr;
  }
  if (impl->decorationManager) {
    zxdg_decoration_manager_v1_destroy(impl->decorationManager);
    impl->decorationManager = nullptr;
  }
  if (impl->subcompositor) { wl_subcompositor_destroy(impl->subcompositor); impl->subcompositor = nullptr; }
  impl->csdSurfaceToDisplay.clear();
  impl->csdPointerFocus = -1;
  impl->pendingDrops.clear();
  impl->pendingKeymaps.clear();
  impl->pendingSelections.clear();
  for (auto& slot : impl->cursorBufs) {
    if (slot.buffer) wl_buffer_destroy(slot.buffer);
    if (slot.pool) wl_shm_pool_destroy(slot.pool);
    if (slot.data) munmap(slot.data, static_cast<size_t>(slot.size));
    slot = {};
  }
  if (impl->cursorSurface) { wl_surface_destroy(impl->cursorSurface); impl->cursorSurface = nullptr; }
  if (impl->shm) { wl_shm_destroy(impl->shm); impl->shm = nullptr; }
  if (impl->viewporter) { wp_viewporter_destroy(impl->viewporter); impl->viewporter = nullptr; }
  if (impl->fractionalScaleManager) {
    wp_fractional_scale_manager_v1_destroy(impl->fractionalScaleManager);
    impl->fractionalScaleManager = nullptr;
  }
  if (impl->cursorShapeManager) {
    wp_cursor_shape_manager_v1_destroy(impl->cursorShapeManager);
    impl->cursorShapeManager = nullptr;
  }
  if (impl->presentation) { wp_presentation_destroy(impl->presentation); impl->presentation = nullptr; }
  if (impl->dmabuf) { zwp_linux_dmabuf_v1_destroy(impl->dmabuf); impl->dmabuf = nullptr; }
  if (impl->wmBase) { xdg_wm_base_destroy(impl->wmBase); impl->wmBase = nullptr; }
  if (impl->compositor) { wl_compositor_destroy(impl->compositor); impl->compositor = nullptr; }
  if (impl->registry) { wl_registry_destroy(impl->registry); impl->registry = nullptr; }

  wl_display_disconnect(impl->display);
  impl->display = nullptr;

  impl->dmabufVersion = 0;
  impl->surfaceToDisplay.clear();
  impl->pointerFocus = -1;
  impl->keyboardFocus = -1;
  impl->touchFocus = -1;
  impl->modifierTable.clear();
  impl->shmFormats.clear();
  impl->connected = false;
  impl->lastPresentWasDmabuf = false;
  klog("WaylandBackend::Disconnect: connection torn down, ready to Connect() again");
}

namespace {

// listener userdata for a display
struct DisplayCtx {
  int64_t displayId;
  WaylandBackend::Impl* impl;
  int64_t commitNs;
};

// return the entered output with the highest scale
wl_output* EffectiveOutputLocked(WaylandBackend::Impl* impl, DisplayState* ds, int32_t* outScale) {
  wl_output* best = nullptr;
  int32_t bestScale = 0;
  for (wl_output* o : ds->enteredOutputs) {
    auto it = impl->outputs.find(o);
    const int32_t s = it != impl->outputs.end() ? it->second.scale : 1;
    if (!best || s > bestScale) {
      best = o;
      bestScale = s;
    }
  }
  if (outScale) *outScale = best ? bestScale : 1;
  return best;
}

// convert surface-local units to buffer pixels
int32_t ScaledPx(int32_t surfaceLocal, int32_t scale120) {
  return (surfaceLocal * scale120 + 60) / 120;
}

// convert buffer pixels to surface-local units
int32_t SurfaceLocal(int32_t px, int32_t scale120) {
  return scale120 > 0 ? (px * 120 + scale120 / 2) / scale120 : px;
}

// check for a fractional scale
bool FractionalLocked(const DisplayState* ds) {
  return ds->fractionalScale && ds->viewport && ds->preferredScale120 > 0;
}

// queue a resize event for the display
void QueueResizeLocked(WaylandBackend::Impl* impl, DisplayState* ds) {
  if (ds->reportedWidth <= 0 || ds->reportedHeight <= 0 || !impl->resizeCb) return;
  impl->pendingResizes.push_back({ds->id, ScaledPx(ds->reportedWidth, ds->appliedScale120),
                                  ScaledPx(ds->reportedHeight, ds->appliedScale120),
                                  ds->appliedScale120});
}

// recompute the display's buffer scale
void ApplyOutputScaleLocked(WaylandBackend::Impl* impl, DisplayState* ds) {
  int32_t scale = 1;
  ds->currentOutput = EffectiveOutputLocked(impl, ds, &scale);
  const bool fractional = FractionalLocked(ds);
  const int32_t scale120 = fractional ? ds->preferredScale120 : 120 * scale;
  if (scale120 == ds->appliedScale120) return;
  ds->appliedScale120 = scale120;
  if (ds->surface) {
    wl_surface_set_buffer_scale(ds->surface, fractional ? 1 : scale);
  }
  klogf("WaylandBackend: display %lld buffer scale -> %d/120 (%s)", static_cast<long long>(ds->id),
        scale120, fractional ? "fractional, viewport" : "integer, buffer scale");
  QueueResizeLocked(impl, ds);
  if (ds->decorationMode == WaylandDecorationMode::kClientSide) RedrawCsdStripLocked(impl, ds);
}

// store the preferred fractional scale
void OnPreferredScale(void* data, wp_fractional_scale_v1*, uint32_t scale120) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  DisplayState* ds = ctx->impl->Find(ctx->displayId);
  if (!ds || scale120 == 0) return;
  ds->preferredScale120 = static_cast<int32_t>(scale120);
  klogf("WaylandBackend: display %lld preferred scale %u/120", static_cast<long long>(ds->id), scale120);
  ApplyOutputScaleLocked(ctx->impl, ds);
}
constexpr wp_fractional_scale_v1_listener kFractionalScaleListener{.preferred_scale = OnPreferredScale};

// reply to the xdg_wm_base ping
void OnWmBasePing(void*, xdg_wm_base* wmBase, uint32_t serial) {
  xdg_wm_base_pong(wmBase, serial);
}
constexpr xdg_wm_base_listener kWmBaseListener{.ping = OnWmBasePing};

// acknowledge the xdg_surface configure
void OnXdgSurfaceConfigure(void* data, xdg_surface* surface, uint32_t serial) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  DisplayState* ds = ctx->impl->Find(ctx->displayId);
  if (!ds) {
    xdg_surface_ack_configure(surface, serial);
    return;
  }
  bool first = !ds->configured;
  ds->configured = true;
  const bool sizeChange = ds->proposedWidth > 0 && ds->proposedHeight > 0 &&
      (ds->proposedWidth != ds->reportedWidth || ds->proposedHeight != ds->reportedHeight);
  if (ds->viewportCropped && (sizeChange || !ds->pendingAcks.empty())) {
    const int32_t w = sizeChange ? ds->proposedWidth : ds->pendingAcks.back().width;
    const int32_t h = sizeChange ? ds->proposedHeight : ds->pendingAcks.back().height;
    ds->pendingAcks.push_back({serial, w, h, MonotonicNs()});
  } else {
    xdg_surface_ack_configure(surface, serial);
  }
  if (sizeChange) {
    ds->reportedWidth = ds->proposedWidth;
    ds->reportedHeight = ds->proposedHeight;
    QueueResizeLocked(ctx->impl, ds);
    klogf("WaylandBackend: display %lld compositor sized it %dx%d surface-local (%dx%d px at scale %d/120)",
          static_cast<long long>(ctx->displayId), ds->reportedWidth, ds->reportedHeight,
          ScaledPx(ds->reportedWidth, ds->appliedScale120), ScaledPx(ds->reportedHeight, ds->appliedScale120),
          ds->appliedScale120);
    if (ds->decorationMode == WaylandDecorationMode::kClientSide) {
      RedrawCsdStripLocked(ctx->impl, ds);
    }
  }
  if (first) {
    klogf("WaylandBackend: display %lld xdg_surface.configure serial=%u ack'd (first)",
          static_cast<long long>(ctx->displayId), serial);
    ctx->impl->configureCv.notify_all();
  }
}
constexpr xdg_surface_listener kXdgSurfaceListener{.configure = OnXdgSurfaceConfigure};

// record the toplevel size and state
void OnToplevelConfigure(void* data, xdg_toplevel*, int32_t width, int32_t height,
                          wl_array* states) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  DisplayState* ds = ctx->impl->Find(ctx->displayId);
  if (!ds) return;
  bool maximized = false, fullscreen = false, activated = false, resizing = false;
  if (states) {
    const uint32_t* begin = static_cast<const uint32_t*>(states->data);
    const uint32_t* end = begin + states->size / sizeof(uint32_t);
    for (const uint32_t* p = begin; p < end; ++p) {
      switch (static_cast<xdg_toplevel_state>(*p)) {
        case XDG_TOPLEVEL_STATE_MAXIMIZED: maximized = true; break;
        case XDG_TOPLEVEL_STATE_FULLSCREEN: fullscreen = true; break;
        case XDG_TOPLEVEL_STATE_ACTIVATED: activated = true; break;
        case XDG_TOPLEVEL_STATE_RESIZING: resizing = true; break;
        case XDG_TOPLEVEL_STATE_TILED_LEFT:
        case XDG_TOPLEVEL_STATE_TILED_RIGHT:
        case XDG_TOPLEVEL_STATE_TILED_TOP:
        case XDG_TOPLEVEL_STATE_TILED_BOTTOM: maximized = true; break;
        default: break;
      }
    }
  }
  int32_t w = width, h = height;
  const bool ours = w <= 0 || h <= 0;
  bool fitted = false;
  if (ours && !ds->configured && ds->startWidth > 0 && ds->startHeight > 0) {
    w = SurfaceLocal(ds->startWidth, ds->appliedScale120);
    h = SurfaceLocal(ds->startHeight, ds->appliedScale120);
    if (ds->boundsWidth > 0 && ds->boundsHeight > 0) {
      const double fit = std::min({1.0, 0.7 * ds->boundsWidth / w, 0.7 * ds->boundsHeight / h});
      w = static_cast<int32_t>(w * fit);
      h = static_cast<int32_t>(h * fit);
      fitted = fit < 1.0;
    }
  }
  bool clamped = false;
  if (w > 0 && h > 0 && !fullscreen && !maximized && !resizing && ds->boundsWidth > 0 &&
      ds->boundsHeight > 0 && (w > ds->boundsWidth || h > ds->boundsHeight)) {
    klogf("WaylandBackend: display %lld at %dx%d is past the compositor's bounds %dx%d -- asking for "
          "%dx%d", static_cast<long long>(ctx->displayId), w, h, ds->boundsWidth, ds->boundsHeight,
          std::min(w, ds->boundsWidth), std::min(h, ds->boundsHeight));
    w = std::min(w, ds->boundsWidth);
    h = std::min(h, ds->boundsHeight);
    clamped = true;
  }
  if (w > 0 && h > 0 && (!ours || clamped || fitted)) {
    ds->proposedWidth = w;
    ds->proposedHeight = h;
  }
  if (maximized != ds->maximized || fullscreen != ds->fullscreen ||
      activated != ds->activated || resizing != ds->resizing) {
    klogf("WaylandBackend: display %lld toplevel state -> maximized=%d fullscreen=%d "
          "activated=%d resizing=%d",
          static_cast<long long>(ctx->displayId), maximized, fullscreen, activated, resizing);
  }
  ds->maximized = maximized;
  ds->fullscreen = fullscreen;
  ds->activated = activated;
  ds->resizing = resizing;
}
// queue the toplevel close event
void OnToplevelClose(void* data, xdg_toplevel*) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  klogf("WaylandBackend: display %lld xdg_toplevel.close from compositor",
        static_cast<long long>(ctx->displayId));
  if (ctx->impl->closeCb) ctx->impl->pendingCloses.push_back(ctx->displayId);
}
// store the compositor's size bounds
void OnToplevelConfigureBounds(void* data, xdg_toplevel*, int32_t width, int32_t height) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  DisplayState* ds = ctx->impl->Find(ctx->displayId);
  if (!ds) return;
  ds->boundsWidth = width > 0 ? width : 0;
  ds->boundsHeight = height > 0 ? height : 0;
}
// ignore the toplevel wm capabilities event
void OnToplevelWmCapabilities(void*, xdg_toplevel*, wl_array*) {}
constexpr xdg_toplevel_listener kToplevelListener{
    .configure = OnToplevelConfigure,
    .close = OnToplevelClose,
    .configure_bounds = OnToplevelConfigureBounds,
    .wm_capabilities = OnToplevelWmCapabilities,
};

// set the display's decoration mode
void OnDecorationConfigure(void* data, zxdg_toplevel_decoration_v1*, uint32_t mode) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  DisplayState* ds = ctx->impl->Find(ctx->displayId);
  if (!ds) return;
  const auto newMode = mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
                            ? WaylandDecorationMode::kServerSide
                            : WaylandDecorationMode::kClientSide;
  if (newMode == ds->decorationMode) return;
  klogf("WaylandBackend: display %lld decoration mode -> %s", static_cast<long long>(ds->id),
        newMode == WaylandDecorationMode::kServerSide ? "ssd" : "csd");
  ds->decorationMode = newMode;
  if (newMode == WaylandDecorationMode::kClientSide) {
    CreateCsdStripLocked(ctx->impl, ds);
  } else {
    if (ds->csd.surface) ctx->impl->csdSurfaceToDisplay.erase(ds->csd.surface);
    if (ctx->impl->csdPointerFocus == ds->id) ctx->impl->csdPointerFocus = -1;
    DestroyCsdStripLocked(ds);
  }
}
constexpr zxdg_toplevel_decoration_v1_listener kDecorationListener{.configure = OnDecorationConfigure};

// store the activation token
void OnActivationTokenDone(void* data, xdg_activation_token_v1*, const char* token) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->pendingActivationTokenResult = token ? token : "";
  impl->activationTokenReady = true;
  impl->activationCv.notify_all();
}
constexpr xdg_activation_token_v1_listener kActivationTokenListener{.done = OnActivationTokenDone};

// ignore the dmabuf format event
void OnDmabufFormat(void*, zwp_linux_dmabuf_v1*, uint32_t) {
}
// add an advertised dmabuf modifier to the format's list
void OnDmabufModifier(void* data, zwp_linux_dmabuf_v1*, uint32_t format,
                       uint32_t modifierHi, uint32_t modifierLo) {
  auto* table = static_cast<std::map<uint32_t, std::vector<uint64_t>>*>(data);
  uint64_t modifier = (static_cast<uint64_t>(modifierHi) << 32) | modifierLo;
  (*table)[format].push_back(modifier);
  klogf("WaylandBackend: compositor advertised format=0x%08x modifier=0x%016llx", format,
        static_cast<unsigned long long>(modifier));
}
constexpr zwp_linux_dmabuf_v1_listener kDmabufListener{
    .format = OnDmabufFormat,
    .modifier = OnDmabufModifier,
};

// set the buffer slot released flag
void OnBufferRelease(void* data, wl_buffer*) {
  auto* slot = static_cast<BufferSlot*>(data);
  slot->releasedSinceAttach = true;
}
constexpr wl_buffer_listener kBufferListener{.release = OnBufferRelease};

// set the copy buffer released flag
void OnCopyBufferRelease(void* data, wl_buffer*) {
  static_cast<BufferSlot::Copy*>(data)->released = true;
}
constexpr wl_buffer_listener kCopyBufferListener{.release = OnCopyBufferRelease};

void DestroyCopyBuffer(BufferSlot::Copy& c) {
  if (c.buffer) wl_buffer_destroy(c.buffer);
  if (c.pool) wl_shm_pool_destroy(c.pool);
  if (c.map) munmap(c.map, c.size);
  if (c.fd >= 0) close(c.fd);
  c = {};
}

void DestroySlotBuffers(BufferSlot& slot) {
  if (slot.buffer) wl_buffer_destroy(slot.buffer);
  if (slot.pool) wl_shm_pool_destroy(slot.pool);
  slot.buffer = nullptr;
  slot.pool = nullptr;
  for (auto& c : slot.copy) DestroyCopyBuffer(c);
}

// set the cursor buffer released flag
void OnCursorBufferRelease(void* data, wl_buffer*) {
  static_cast<WaylandBackend::Impl::CursorShmBuffer*>(data)->released = true;
}
constexpr wl_buffer_listener kCursorBufferListener{.release = OnCursorBufferRelease};

// attach the cursor image to the pointer
void ApplyCursorNowLocked(WaylandBackend::Impl* impl, DisplayState* ds) {
  // the host cursor theme draws all of the system pointers; only a custom icon uses Android's image
  if (impl->cursorShapeManager) {
    const uint32_t shape = rhizo::CursorShapeForPointerType(ds->cursor.pointerType);
    if (shape != rhizo::kShapeUseImage) {
      if (!impl->pointer) return;
      if (!impl->cursorShapeDevice) {
        impl->cursorShapeDevice = wp_cursor_shape_manager_v1_get_pointer(impl->cursorShapeManager, impl->pointer);
      }
      wp_cursor_shape_device_v1_set_shape(impl->cursorShapeDevice, impl->lastPointerEnterSerial, shape);
      wl_display_flush(impl->display);
      return;
    }
  }
  if (!impl->pointer || !impl->shm || !ds->cursor.valid) return;
  const auto& c = ds->cursor;
  if (!impl->cursorSurface) impl->cursorSurface = wl_compositor_create_surface(impl->compositor);

  WaylandBackend::Impl::CursorShmBuffer* slot = &impl->cursorBufs[impl->cursorBufNext];
  if (slot->buffer && slot->width == c.width && slot->height == c.height && !slot->released) {
    slot = &impl->cursorBufs[1 - impl->cursorBufNext];
  }
  impl->cursorBufNext = (slot == &impl->cursorBufs[0]) ? 1 : 0;

  const int32_t stride = c.width * 4;
  const int32_t needed = stride * c.height;
  if (!slot->buffer || slot->width != c.width || slot->height != c.height) {
    if (slot->buffer) wl_buffer_destroy(slot->buffer);
    if (slot->pool) wl_shm_pool_destroy(slot->pool);
    if (slot->data) munmap(slot->data, static_cast<size_t>(slot->size));
    slot->buffer = nullptr;
    slot->pool = nullptr;
    slot->data = nullptr;
    slot->size = 0;
    int fd = CreateAnonShmFile(static_cast<size_t>(needed));
    if (fd < 0) return;
    slot->data = mmap(nullptr, static_cast<size_t>(needed), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (slot->data == MAP_FAILED) {
      klog("ApplyCursorNowLocked: mmap failed");
      close(fd);
      slot->data = nullptr;
      return;
    }
    slot->pool = wl_shm_create_pool(impl->shm, fd, needed);
    close(fd);
    slot->buffer =
        wl_shm_pool_create_buffer(slot->pool, 0, c.width, c.height, stride, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(slot->buffer, &kCursorBufferListener, slot);
    slot->size = needed;
    slot->width = c.width;
    slot->height = c.height;
  }
  memcpy(slot->data, c.argb.data(), std::min<size_t>(c.argb.size(), static_cast<size_t>(needed)));
  slot->released = false;

  wl_surface_attach(impl->cursorSurface, slot->buffer, 0, 0);
  wl_surface_damage_buffer(impl->cursorSurface, 0, 0, c.width, c.height);
  wl_surface_commit(impl->cursorSurface);
  wl_pointer_set_cursor(impl->pointer, impl->lastPointerEnterSerial, impl->cursorSurface,
                        c.hotspotX, c.hotspotY);
  wl_display_flush(impl->display);
}

constexpr int32_t kCsdStripHeight = 32;
constexpr int32_t kCsdButtonWidth = 40;

void DestroyCsdStripLocked(DisplayState* ds) {
  auto& csd = ds->csd;
  if (csd.subsurface) { wl_subsurface_destroy(csd.subsurface); csd.subsurface = nullptr; }
  if (csd.buffer) { wl_buffer_destroy(csd.buffer); csd.buffer = nullptr; }
  if (csd.pool) { wl_shm_pool_destroy(csd.pool); csd.pool = nullptr; }
  if (csd.data) { munmap(csd.data, static_cast<size_t>(csd.poolSize)); csd.data = nullptr; }
  if (csd.surface) { wl_surface_destroy(csd.surface); csd.surface = nullptr; }
  csd.poolSize = 0;
  csd.width = 0;
  csd.scale = 0;
}

// destroy the fill subsurface and its buffer
void DestroyFillLocked(DisplayState* ds) {
  auto& f = ds->fill;
  if (f.viewport) { wp_viewport_destroy(f.viewport); f.viewport = nullptr; }
  if (f.subsurface) { wl_subsurface_destroy(f.subsurface); f.subsurface = nullptr; }
  if (f.surface) { wl_surface_destroy(f.surface); f.surface = nullptr; }
  if (f.buffer) { wl_buffer_destroy(f.buffer); f.buffer = nullptr; }
  if (f.pool) { wl_shm_pool_destroy(f.pool); f.pool = nullptr; }
  if (f.map) { munmap(f.map, 4); f.map = nullptr; }
  if (f.fd >= 0) { close(f.fd); f.fd = -1; }
  f.shown = false;
}

// show a one-pixel fill buffer under the display's surface
void ShowFillLocked(WaylandBackend::Impl* impl, DisplayState* ds, int32_t w, int32_t h, uint32_t rgba) {
  auto& f = ds->fill;
  if (!impl->subcompositor || !impl->viewporter || !impl->shm) return;
  if (!f.surface) {
    f.fd = CreateAnonShmFile(4);
    if (f.fd < 0) return;
    f.map = mmap(nullptr, 4, PROT_READ | PROT_WRITE, MAP_SHARED, f.fd, 0);
    if (f.map == MAP_FAILED) {
      f.map = nullptr;
      DestroyFillLocked(ds);
      return;
    }
    f.pool = wl_shm_create_pool(impl->shm, f.fd, 4);
    f.buffer = wl_shm_pool_create_buffer(f.pool, 0, 1, 1, 4, WL_SHM_FORMAT_ARGB8888);
    f.surface = wl_compositor_create_surface(impl->compositor);
    f.subsurface = wl_subcompositor_get_subsurface(impl->subcompositor, f.surface, ds->surface);
    wl_subsurface_place_below(f.subsurface, ds->surface);
    wl_subsurface_set_position(f.subsurface, 0, 0);
    f.viewport = wp_viewporter_get_viewport(impl->viewporter, f.surface);
    f.rgba = 0;
  }
  if (rgba != f.rgba || !f.shown) {
    const uint8_t px[4] = {static_cast<uint8_t>(rgba >> 8), static_cast<uint8_t>(rgba >> 16),
                           static_cast<uint8_t>(rgba >> 24), 0xff};
    memcpy(f.map, px, 4);
    f.rgba = rgba;
    wl_surface_attach(f.surface, f.buffer, 0, 0);
    wl_surface_damage_buffer(f.surface, 0, 0, 1, 1);
  }
  wp_viewport_set_destination(f.viewport, w, h);
  wl_surface_commit(f.surface);
  if (getenv("RHIZO_RESIZE_TRACE")) {
    klogf("FILL_TRACE display %lld fill %dx%d rgba=0x%08x surface=%p", static_cast<long long>(ds->id), w, h, rgba,
          static_cast<void*>(f.surface));
  }
  f.shown = true;
}

// hide the fill under the display's surface
void HideFillLocked(DisplayState* ds) {
  auto& f = ds->fill;
  if (!f.surface || !f.shown) return;
  wl_surface_attach(f.surface, nullptr, 0, 0);
  wl_surface_commit(f.surface);
  f.shown = false;
}


// write a pixel to the ARGB buffer
void SetArgbPixel(uint8_t* argb, int32_t widthPx, int32_t heightPx, int32_t x, int32_t y,
                   uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  if (x < 0 || y < 0 || x >= widthPx || y >= heightPx) return;
  uint8_t* p = argb + (static_cast<size_t>(y) * widthPx + x) * 4;
  p[0] = b; p[1] = g; p[2] = r; p[3] = a;
}

// draw a line into the ARGB buffer
void DrawLine(uint8_t* argb, int32_t widthPx, int32_t heightPx, int32_t x0, int32_t y0,
              int32_t x1, int32_t y1, int32_t thickness, uint8_t r, uint8_t g, uint8_t b) {
  int32_t dx = std::abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
  int32_t dy = -std::abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
  int32_t err = dx + dy;
  int32_t x = x0, y = y0;
  const int32_t half = thickness / 2;
  for (;;) {
    for (int32_t oy = -half; oy <= half; oy++) {
      for (int32_t ox = -half; ox <= half; ox++) {
        SetArgbPixel(argb, widthPx, heightPx, x + ox, y + oy, r, g, b, 0xff);
      }
    }
    if (x == x1 && y == y1) break;
    int32_t e2 = 2 * err;
    if (e2 >= dy) { err += dy; x += sx; }
    if (e2 <= dx) { err += dx; y += sy; }
  }
}

// paint the client-side title strip
void PaintCsdStrip(uint8_t* argb, int32_t widthPx, int32_t heightPx, int32_t scale) {
  constexpr uint8_t kBg[3] = {0x2d, 0x2d, 0x30};
  constexpr uint8_t kFg[3] = {0xd8, 0xd8, 0xdc};
  for (int32_t y = 0; y < heightPx; y++) {
    for (int32_t x = 0; x < widthPx; x++) SetArgbPixel(argb, widthPx, heightPx, x, y, kBg[0], kBg[1], kBg[2], 0xff);
  }
  const int32_t bw = kCsdButtonWidth * scale;
  const int32_t thick = std::max(1, scale);
  const int32_t margin = bw / 3;
  const int32_t closeX0 = widthPx - bw;
  const int32_t maxX0 = widthPx - bw * 2;
  const int32_t minX0 = widthPx - bw * 3;
  DrawLine(argb, widthPx, heightPx, closeX0 + margin, margin, closeX0 + bw - margin, heightPx - margin,
           thick, kFg[0], kFg[1], kFg[2]);
  DrawLine(argb, widthPx, heightPx, closeX0 + bw - margin, margin, closeX0 + margin, heightPx - margin,
           thick, kFg[0], kFg[1], kFg[2]);
  DrawLine(argb, widthPx, heightPx, maxX0 + margin, margin, maxX0 + bw - margin, margin, thick,
           kFg[0], kFg[1], kFg[2]);
  DrawLine(argb, widthPx, heightPx, maxX0 + bw - margin, margin, maxX0 + bw - margin, heightPx - margin,
           thick, kFg[0], kFg[1], kFg[2]);
  DrawLine(argb, widthPx, heightPx, maxX0 + bw - margin, heightPx - margin, maxX0 + margin, heightPx - margin,
           thick, kFg[0], kFg[1], kFg[2]);
  DrawLine(argb, widthPx, heightPx, maxX0 + margin, heightPx - margin, maxX0 + margin, margin, thick,
           kFg[0], kFg[1], kFg[2]);
  DrawLine(argb, widthPx, heightPx, minX0 + margin, heightPx - margin, minX0 + bw - margin,
           heightPx - margin, thick, kFg[0], kFg[1], kFg[2]);
}

// redraw the client-side title strip
void RedrawCsdStripLocked(WaylandBackend::Impl* impl, DisplayState* ds) {
  auto& csd = ds->csd;
  if (!csd.surface) return;
  const int32_t widthSurf = ds->reportedWidth > 0 ? ds->reportedWidth : 1;
  const int32_t scale = (ds->appliedScale120 + 119) / 120;
  const int32_t widthPx = widthSurf * scale;
  const int32_t heightPx = kCsdStripHeight * scale;
  const size_t needed = static_cast<size_t>(widthPx) * heightPx * 4;
  if (csd.width != widthSurf || csd.scale != scale || static_cast<size_t>(csd.poolSize) < needed) {
    if (csd.buffer) { wl_buffer_destroy(csd.buffer); csd.buffer = nullptr; }
    if (csd.pool) { wl_shm_pool_destroy(csd.pool); csd.pool = nullptr; }
    if (csd.data) { munmap(csd.data, static_cast<size_t>(csd.poolSize)); csd.data = nullptr; }
    int fd = CreateAnonShmFile(needed);
    if (fd < 0) return;
    csd.data = mmap(nullptr, needed, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (csd.data == MAP_FAILED) {
      klog("RedrawCsdStripLocked: mmap failed");
      close(fd);
      csd.data = nullptr;
      return;
    }
    csd.pool = wl_shm_create_pool(impl->shm, fd, static_cast<int32_t>(needed));
    close(fd);
    csd.buffer = wl_shm_pool_create_buffer(csd.pool, 0, widthPx, heightPx, widthPx * 4,
                                            WL_SHM_FORMAT_ARGB8888);
    csd.poolSize = static_cast<int32_t>(needed);
    csd.width = widthSurf;
    csd.scale = scale;
  }
  PaintCsdStrip(static_cast<uint8_t*>(csd.data), widthPx, heightPx, scale);
  wl_surface_attach(csd.surface, csd.buffer, 0, 0);
  wl_surface_set_buffer_scale(csd.surface, scale);
  wl_surface_damage_buffer(csd.surface, 0, 0, widthPx, heightPx);
  wl_subsurface_set_position(csd.subsurface, 0, -kCsdStripHeight);
  wl_surface_commit(csd.surface);
}

// create the client-side title strip
void CreateCsdStripLocked(WaylandBackend::Impl* impl, DisplayState* ds) {
  if (ds->csd.surface) return;
  if (!impl->compositor || !impl->shm || !impl->subcompositor) {
    klog("WaylandBackend: cannot build a CSD strip, missing wl_compositor/wl_shm/wl_subcompositor");
    return;
  }
  ds->csd.surface = wl_compositor_create_surface(impl->compositor);
  impl->csdSurfaceToDisplay[ds->csd.surface] = ds->id;
  ds->csd.subsurface = wl_subcompositor_get_subsurface(impl->subcompositor, ds->csd.surface, ds->surface);
  wl_subsurface_set_desync(ds->csd.subsurface);
  RedrawCsdStripLocked(impl, ds);
}

// run the action for a title strip click
void HandleCsdClickLocked(WaylandBackend::Impl* impl, int64_t displayId, double x, uint32_t serial) {
  DisplayState* ds = impl->Find(displayId);
  if (!ds || !ds->xdgToplevel) return;
  const int32_t w = ds->reportedWidth > 0 ? ds->reportedWidth : 1;
  const int32_t closeX0 = w - kCsdButtonWidth;
  const int32_t maxX0 = w - kCsdButtonWidth * 2;
  const int32_t minX0 = w - kCsdButtonWidth * 3;
  if (x >= closeX0) {
    klogf("WaylandBackend: display %lld CSD close clicked", static_cast<long long>(displayId));
    if (impl->closeCb) impl->pendingCloses.push_back(displayId);
  } else if (x >= maxX0) {
    if (ds->maximized) xdg_toplevel_unset_maximized(ds->xdgToplevel);
    else xdg_toplevel_set_maximized(ds->xdgToplevel);
  } else if (x >= minX0) {
    xdg_toplevel_set_minimized(ds->xdgToplevel);
  } else if (impl->seat) {
    xdg_toplevel_move(ds->xdgToplevel, impl->seat, serial);
  }
  wl_display_flush(impl->display);
}

void OnFrameDone(void* data, wl_callback* cb, uint32_t callbackDataMs);
constexpr wl_callback_listener kFrameListener{.done = OnFrameDone};

// ignore the presentation feedback sync output event
void OnFeedbackSyncOutput(void*, struct wp_presentation_feedback*, wl_output*) {}
// queue the presented time and refresh for the frame's display
void OnFeedbackPresented(void* data, struct wp_presentation_feedback* fb, uint32_t tv_sec_hi,
                         uint32_t tv_sec_lo, uint32_t tv_nsec, uint32_t refresh, uint32_t,
                         uint32_t, uint32_t) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  wp_presentation_feedback_destroy(fb);
  WaylandBackend::Impl* impl = ctx->impl;
  int64_t displayId = ctx->displayId;
  int64_t commitNs = ctx->commitNs;
  delete ctx;
  int64_t sec = (static_cast<int64_t>(tv_sec_hi) << 32) | tv_sec_lo;
  int64_t presentedNs = sec * 1000000000LL + tv_nsec;
  impl->pendingPresented.push_back({displayId, presentedNs, static_cast<int64_t>(refresh), false, commitNs});
}
// queue a discarded presentation for the frame's display
void OnFeedbackDiscarded(void* data, struct wp_presentation_feedback* fb) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  wp_presentation_feedback_destroy(fb);
  WaylandBackend::Impl* impl = ctx->impl;
  int64_t displayId = ctx->displayId;
  int64_t commitNs = ctx->commitNs;
  delete ctx;
  impl->pendingPresented.push_back({displayId, 0, 0, true, commitNs});
}
constexpr wp_presentation_feedback_listener kFeedbackListener{
    .sync_output = OnFeedbackSyncOutput,
    .presented = OnFeedbackPresented,
    .discarded = OnFeedbackDiscarded,
};

// request presentation feedback or a frame callback
void RequestCompletionLocked(WaylandBackend::Impl* impl, DisplayState* ds, int64_t commitNs) {
  auto* ctx = new DisplayCtx{ds->id, impl, commitNs};
  if (impl->presentation) {
    struct wp_presentation_feedback* fb = wp_presentation_feedback(impl->presentation, ds->surface);
    wp_presentation_feedback_add_listener(fb, &kFeedbackListener, ctx);
    return;
  }
  wl_callback* cb = wl_surface_frame(ds->surface);
  wl_callback_add_listener(cb, &kFrameListener, ctx);
}

// request a completion on an empty commit
void KickLocked(WaylandBackend::Impl* impl, DisplayState* ds) {
  RequestCompletionLocked(impl, ds, 0);
  wl_surface_commit(ds->surface);
}

// queue a vsync event for the display
void OnFrameDone(void* data, wl_callback* cb, uint32_t callbackDataMs) {
  auto* ctx = static_cast<DisplayCtx*>(data);
  wl_callback_destroy(cb);
  WaylandBackend::Impl* impl = ctx->impl;
  int64_t displayId = ctx->displayId;
  delete ctx;
  DisplayState* ds = impl->Find(displayId);
  if (!ds) return;
  if (impl->vsyncCb) {
    impl->pendingVsyncs.push_back(
        {displayId, static_cast<int64_t>(callbackDataMs) * 1000000LL});
  }
}


// record the pointer position and focus
void OnPointerEnter(void* data, wl_pointer*, uint32_t serial, wl_surface* surface, wl_fixed_t sx,
                     wl_fixed_t sy) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->lastPointerEnterSerial = serial;
  impl->pointerX = wl_fixed_to_double(sx);
  impl->pointerY = wl_fixed_to_double(sy);
  auto csdIt = impl->csdSurfaceToDisplay.find(surface);
  if (csdIt != impl->csdSurfaceToDisplay.end()) {
    impl->csdPointerFocus = csdIt->second;
    impl->pointerFocus = -1;
    return;
  }
  impl->csdPointerFocus = -1;
  auto it = impl->surfaceToDisplay.find(surface);
  impl->pointerFocus = it == impl->surfaceToDisplay.end() ? -1 : it->second;
  klogf("WaylandBackend: pointer entered display %lld at %.0f,%.0f",
        static_cast<long long>(impl->pointerFocus), impl->pointerX, impl->pointerY);
  impl->QueueInput(impl->pointerFocus, WaylandInputEvent::Kind::PointerEnter, impl->pointerX,
                   impl->pointerY, 0, 0, 0);
  if (impl->cursorShapeManager && impl->pointer) {
    DisplayState* ds = impl->pointerFocus >= 0 ? impl->Find(impl->pointerFocus) : nullptr;
    const uint32_t shape =
        ds ? rhizo::CursorShapeForPointerType(ds->cursor.pointerType) : rhizo::kShapeDefault;
    if (shape != rhizo::kShapeUseImage) {
      if (!impl->cursorShapeDevice) {
        impl->cursorShapeDevice = wp_cursor_shape_manager_v1_get_pointer(impl->cursorShapeManager, impl->pointer);
      }
      wp_cursor_shape_device_v1_set_shape(impl->cursorShapeDevice, serial, shape);
      return;
    }
  }
  if (impl->pointerFocus >= 0) impl->cursorApplyPending.insert(impl->pointerFocus);
}
// clear the pointer and decoration pointer focus
void OnPointerLeave(void* data, wl_pointer*, uint32_t, wl_surface*) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->pointerFocus = -1;
  impl->csdPointerFocus = -1;
}
// queue a pointer motion event
void OnPointerMotion(void* data, wl_pointer*, uint32_t time, wl_fixed_t sx, wl_fixed_t sy) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->pointerX = wl_fixed_to_double(sx);
  impl->pointerY = wl_fixed_to_double(sy);
  if (impl->csdPointerFocus >= 0) return;
  impl->QueueInput(impl->pointerFocus, WaylandInputEvent::Kind::PointerMotion, impl->pointerX,
                   impl->pointerY, 0, 0, time);
}
// queue the pointer button event
void OnPointerButton(void* data, wl_pointer*, uint32_t serial, uint32_t time, uint32_t button,
                      uint32_t state) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
    impl->lastPointerSerial = serial;
    impl->lastPointerHeld = true;
    impl->lastInputSerial = serial;
    CompleteParkedSelectionLocked(impl);
  } else {
    impl->lastPointerHeld = false;
  }
  if (impl->csdPointerFocus >= 0) {
    if (button == 0x110 && state == WL_POINTER_BUTTON_STATE_PRESSED) {
      HandleCsdClickLocked(impl, impl->csdPointerFocus, impl->pointerX, serial);
    }
    return;
  }
  impl->QueueInput(impl->pointerFocus, WaylandInputEvent::Kind::PointerButton, impl->pointerX,
                   impl->pointerY, button, state == WL_POINTER_BUTTON_STATE_PRESSED ? 1 : 0, time);
}
// add the scroll value to the pending axis
void OnPointerAxis(void* data, wl_pointer*, uint32_t, uint32_t axis, wl_fixed_t value) {
  if (axis > WL_POINTER_AXIS_HORIZONTAL_SCROLL) return;
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  auto& p = impl->pendingAxis[axis];
  p.haveAxis = true;
  p.axisValue += wl_fixed_to_double(value);
}
// add a high-resolution scroll value to the pending axis
void OnPointerAxisValue120(void* data, wl_pointer*, uint32_t axis, int32_t value120) {
  if (axis > WL_POINTER_AXIS_HORIZONTAL_SCROLL) return;
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  auto& p = impl->pendingAxis[axis];
  p.haveValue120 = true;
  p.value120 += value120;
}
// add a discrete scroll step to the pending axis
void OnPointerAxisDiscrete(void* data, wl_pointer*, uint32_t axis, int32_t discrete) {
  if (axis > WL_POINTER_AXIS_HORIZONTAL_SCROLL) return;
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  auto& p = impl->pendingAxis[axis];
  p.haveDiscrete = true;
  p.discrete += discrete;
}
// queue the pending pointer axis values
void FlushPointerAxisLocked(WaylandBackend::Impl* impl) {
  for (uint32_t axis = 0; axis < 2; ++axis) {
    WaylandBackend::Impl::PendingAxis& p = impl->pendingAxis[axis];
    if (p.haveAxis) {
      int32_t value120;
      if (p.haveValue120) {
        value120 = p.value120;
      } else if (p.haveDiscrete) {
        value120 = p.discrete * 120;
      } else {
        value120 = static_cast<int32_t>(std::lround(p.axisValue / 10.0 * 120.0));
      }
      if (value120 != 0) {
        const bool vertical = axis == WL_POINTER_AXIS_VERTICAL_SCROLL;
        impl->QueueInput(impl->pointerFocus, WaylandInputEvent::Kind::PointerAxis, impl->pointerX,
                         impl->pointerY, axis, vertical ? -value120 : value120, 0);
      }
    }
    p = WaylandBackend::Impl::PendingAxis{};
  }
}
// send the pending scroll axes
void OnPointerFrame(void* data, wl_pointer*) {
  FlushPointerAxisLocked(static_cast<WaylandBackend::Impl*>(data));
}
// ignore the pointer axis source event
void OnPointerAxisSource(void*, wl_pointer*, uint32_t) {}
// ignore the pointer axis stop event
void OnPointerAxisStop(void*, wl_pointer*, uint32_t, uint32_t) {}
// ignore the pointer axis relative direction event
void OnPointerAxisRelativeDirection(void*, wl_pointer*, uint32_t, uint32_t) {}
constexpr wl_pointer_listener kPointerListener{
    .enter = OnPointerEnter,
    .leave = OnPointerLeave,
    .motion = OnPointerMotion,
    .button = OnPointerButton,
    .axis = OnPointerAxis,
    .frame = OnPointerFrame,
    .axis_source = OnPointerAxisSource,
    .axis_stop = OnPointerAxisStop,
    .axis_discrete = OnPointerAxisDiscrete,
    .axis_value120 = OnPointerAxisValue120,
    .axis_relative_direction = OnPointerAxisRelativeDirection,
};

// queue the keymap text
void OnKeyboardKeymap(void* data, wl_keyboard*, uint32_t format, int32_t fd, uint32_t size) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  if (format != 1 || fd < 0 || size == 0) {
    if (fd >= 0) close(fd);
    return;
  }
  void* map = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (map == MAP_FAILED) {
    klogf("OnKeyboardKeymap: mmap FAILED errno=%d (%s)", errno, strerror(errno));
    return;
  }
  const char* text = static_cast<const char*>(map);
  impl->pendingKeymaps.emplace_back(text, strnlen(text, size));
  munmap(map, size);
}
// set the keyboard focus and complete a parked selection
void OnKeyboardEnter(void* data, wl_keyboard*, uint32_t serial, wl_surface* surface, wl_array*) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->lastInputSerial = serial;
  CompleteParkedSelectionLocked(impl);
  auto it = impl->surfaceToDisplay.find(surface);
  impl->keyboardFocus = it == impl->surfaceToDisplay.end() ? -1 : it->second;
  klogf("WaylandBackend: keyboard focus -> display %lld",
        static_cast<long long>(impl->keyboardFocus));
}
// clear the keyboard focus
void OnKeyboardLeave(void* data, wl_keyboard*, uint32_t, wl_surface*) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->keyboardFocus = -1;
}
// queue a key event and complete a parked selection
void OnKeyboardKey(void* data, wl_keyboard*, uint32_t serial, uint32_t time, uint32_t key,
                    uint32_t state) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->lastInputSerial = serial;
  CompleteParkedSelectionLocked(impl);
  impl->QueueInput(impl->keyboardFocus, WaylandInputEvent::Kind::KeyboardKey, 0, 0, key,
                   state == WL_KEYBOARD_KEY_STATE_PRESSED ? 1 : 0, time);
}
// queue a keyboard modifiers event
void OnKeyboardModifiers(void* data, wl_keyboard*, uint32_t, uint32_t modsDepressed,
                          uint32_t modsLatched, uint32_t modsLocked, uint32_t group) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->QueueInput(impl->keyboardFocus, WaylandInputEvent::Kind::KeyboardModifiers, 0, 0,
                   modsDepressed | modsLatched | modsLocked, static_cast<int32_t>(group), 0);
}
// ignore the keyboard repeat info event
void OnKeyboardRepeatInfo(void*, wl_keyboard*, int32_t, int32_t) {}
constexpr wl_keyboard_listener kKeyboardListener{
    .keymap = OnKeyboardKeymap,
    .enter = OnKeyboardEnter,
    .leave = OnKeyboardLeave,
    .key = OnKeyboardKey,
    .modifiers = OnKeyboardModifiers,
    .repeat_info = OnKeyboardRepeatInfo,
};

// set the touch focus display and queue a touch down
void OnTouchDown(void* data, wl_touch*, uint32_t, uint32_t time, wl_surface* surface, int32_t id,
                  wl_fixed_t x, wl_fixed_t y) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  auto it = impl->surfaceToDisplay.find(surface);
  impl->touchFocus = it == impl->surfaceToDisplay.end() ? -1 : it->second;
  impl->QueueInput(impl->touchFocus, WaylandInputEvent::Kind::TouchDown, wl_fixed_to_double(x),
                   wl_fixed_to_double(y), static_cast<uint32_t>(id), 1, time);
}
// queue a touch up
void OnTouchUp(void* data, wl_touch*, uint32_t, uint32_t time, int32_t id) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->QueueInput(impl->touchFocus, WaylandInputEvent::Kind::TouchUp, 0, 0,
                   static_cast<uint32_t>(id), 0, time);
}
// queue a touch motion
void OnTouchMotion(void* data, wl_touch*, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->QueueInput(impl->touchFocus, WaylandInputEvent::Kind::TouchMotion, wl_fixed_to_double(x),
                   wl_fixed_to_double(y), static_cast<uint32_t>(id), 1, time);
}
// ignore the touch frame event
void OnTouchFrame(void*, wl_touch*) {}
// ignore the touch cancel event
void OnTouchCancel(void*, wl_touch*) {}
// ignore the touch shape event
void OnTouchShape(void*, wl_touch*, int32_t, wl_fixed_t, wl_fixed_t) {}
// ignore the touch orientation event
void OnTouchOrientation(void*, wl_touch*, int32_t, wl_fixed_t) {}
constexpr wl_touch_listener kTouchListener{
    .down = OnTouchDown,
    .up = OnTouchUp,
    .motion = OnTouchMotion,
    .frame = OnTouchFrame,
    .cancel = OnTouchCancel,
    .shape = OnTouchShape,
    .orientation = OnTouchOrientation,
};

// get or release the input devices to match the seat
void OnSeatCapabilities(void* data, wl_seat* seat, uint32_t caps) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  klogf("WaylandBackend: seat capabilities=0x%x", caps);
  if ((caps & WL_SEAT_CAPABILITY_POINTER) && !impl->pointer) {
    impl->pointer = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(impl->pointer, &kPointerListener, impl);
  } else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && impl->pointer) {
    if (impl->cursorShapeDevice) {
      wp_cursor_shape_device_v1_destroy(impl->cursorShapeDevice);
      impl->cursorShapeDevice = nullptr;
    }
    wl_pointer_release(impl->pointer);
    impl->pointer = nullptr;
    impl->pointerFocus = -1;
  }
  if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !impl->keyboard) {
    impl->keyboard = wl_seat_get_keyboard(seat);
    wl_keyboard_add_listener(impl->keyboard, &kKeyboardListener, impl);
  } else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && impl->keyboard) {
    wl_keyboard_release(impl->keyboard);
    impl->keyboard = nullptr;
    impl->keyboardFocus = -1;
  }
  if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !impl->touch) {
    impl->touch = wl_seat_get_touch(seat);
    wl_touch_add_listener(impl->touch, &kTouchListener, impl);
  } else if (!(caps & WL_SEAT_CAPABILITY_TOUCH) && impl->touch) {
    wl_touch_release(impl->touch);
    impl->touch = nullptr;
    impl->touchFocus = -1;
  }
}
// ignore the seat name event
void OnSeatName(void*, wl_seat*, const char*) {}
constexpr wl_seat_listener kSeatListener{
    .capabilities = OnSeatCapabilities,
    .name = OnSeatName,
};

// record a mime type of the data offer
void OnDataOfferOffer(void* data, wl_data_offer* offer, const char* mimeType) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  if (impl->pendingOfferProxy == offer) {
    impl->pendingOfferMimes.push_back(mimeType);
  } else if (impl->dndOffer.offer == offer) {
    impl->dndOffer.mimeTypes.push_back(mimeType);
  }
}
// ignore the data offer source actions event
void OnDataOfferSourceActions(void*, wl_data_offer*, uint32_t) {}
// mark the drag offer's action as received
void OnDataOfferAction(void* data, wl_data_offer* offer, uint32_t) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  if (impl->dndOffer.offer == offer) impl->dndOffer.actionReceived = true;
}
constexpr wl_data_offer_listener kDataOfferListener{
    .offer = OnDataOfferOffer,
    .source_actions = OnDataOfferSourceActions,
    .action = OnDataOfferAction,
};

// set the pending data offer and listener
void OnDataDeviceDataOffer(void* data, wl_data_device*, wl_data_offer* id) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->pendingOfferProxy = id;
  impl->pendingOfferMimes.clear();
  wl_data_offer_add_listener(id, &kDataOfferListener, impl);
}
// accept the dragged offer
void OnDataDeviceEnter(void* data, wl_data_device*, uint32_t serial, wl_surface* surface,
                        wl_fixed_t x, wl_fixed_t y, wl_data_offer* id) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  auto it = impl->surfaceToDisplay.find(surface);
  int64_t displayId = it == impl->surfaceToDisplay.end() ? -1 : it->second;

  impl->dndOffer.offer = id;
  impl->dndOffer.displayId = displayId;
  impl->dndOffer.mimeTypes =
      impl->pendingOfferProxy == id ? impl->pendingOfferMimes : std::vector<std::string>{};
  impl->dndOffer.x = wl_fixed_to_double(x);
  impl->dndOffer.y = wl_fixed_to_double(y);
  impl->dndOffer.actionReceived = false;
  impl->dndOffer.acceptedMime.clear();
  impl->pendingOfferProxy = nullptr;
  impl->pendingOfferMimes.clear();

  if (displayId < 0 || impl->dndOffer.mimeTypes.empty()) {
    klogf("WaylandBackend: drag entered with no display/mime (display=%lld mimes=%zu), refusing",
          static_cast<long long>(displayId), impl->dndOffer.mimeTypes.size());
    wl_data_offer_accept(id, serial, nullptr);
    wl_display_flush(impl->display);
    return;
  }
  impl->dndOffer.acceptedMime = impl->dndOffer.mimeTypes.front();
  wl_data_offer_accept(id, serial, impl->dndOffer.acceptedMime.c_str());
  wl_display_flush(impl->display);
  klogf("WaylandBackend: accepted offer %p serial=%u version=%d", static_cast<void*>(id), serial,
        wl_data_offer_get_version(id));
  if (wl_data_offer_get_version(id) >= WL_DATA_OFFER_SET_ACTIONS_SINCE_VERSION) {
    wl_data_offer_set_actions(id, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY,
                               WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
  }
  klogf("WaylandBackend: drag entered display %lld mime=%s", static_cast<long long>(displayId),
        impl->dndOffer.acceptedMime.c_str());
}
// store the drag position
void OnDataDeviceMotion(void* data, wl_data_device*, uint32_t, wl_fixed_t x, wl_fixed_t y) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  if (!impl->dndOffer.offer) return;
  impl->dndOffer.x = wl_fixed_to_double(x);
  impl->dndOffer.y = wl_fixed_to_double(y);
}
// destroy the drag offer and clear it
void OnDataDeviceLeave(void* data, wl_data_device*) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  klogf("WaylandBackend: drag left (offer=%p)", static_cast<void*>(impl->dndOffer.offer));
  if (impl->dndOffer.offer) {
    wl_data_offer_destroy(impl->dndOffer.offer);
    impl->dndOffer = {};
  }
}
// read the dropped data on a new thread
void OnDataDeviceDrop(void* data, wl_data_device*) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  klogf("WaylandBackend: drop event received");
  if (!impl->dndOffer.offer || impl->dndOffer.acceptedMime.empty()) {
    klog("WaylandBackend: drop with nothing accepted, ignoring");
    if (impl->dndOffer.offer) wl_data_offer_destroy(impl->dndOffer.offer);
    impl->dndOffer = {};
    return;
  }
  int pipeFds[2];
  if (pipe2(pipeFds, O_CLOEXEC) != 0) {
    klogf("WaylandBackend: drop pipe2 FAILED errno=%d (%s)", errno, strerror(errno));
    wl_data_offer_destroy(impl->dndOffer.offer);
    impl->dndOffer = {};
    return;
  }
  wl_data_offer_receive(impl->dndOffer.offer, impl->dndOffer.acceptedMime.c_str(), pipeFds[1]);
  wl_display_flush(impl->display);
  close(pipeFds[1]);

  const int64_t displayId = impl->dndOffer.displayId;
  const std::string mime = impl->dndOffer.acceptedMime;
  const double x = impl->dndOffer.x, y = impl->dndOffer.y;
  const bool finishOffer = impl->dndOffer.actionReceived &&
      wl_data_offer_get_version(impl->dndOffer.offer) >= WL_DATA_OFFER_FINISH_SINCE_VERSION;
  wl_data_offer* offer = impl->dndOffer.offer;
  impl->dndOffer = {};

  const int readFd = pipeFds[0];
  impl->activeIoThreads++;
  std::thread([impl, readFd, displayId, mime, x, y, offer, finishOffer] {
    std::vector<uint8_t> bytes;
    uint8_t buf[65536];
    const int64_t deadlineNs = MonotonicNs() + 5000000000LL;
    while (true) {
      const int64_t remainingMs = (deadlineNs - MonotonicNs()) / 1000000;
      if (remainingMs <= 0) {
        klog("WaylandBackend: drop read timed out, discarding partial data");
        break;
      }
      struct pollfd pfd{readFd, POLLIN, 0};
      int pr = poll(&pfd, 1, static_cast<int>(remainingMs));
      if (pr < 0) {
        if (errno == EINTR) continue;
        klogf("WaylandBackend: drop poll FAILED errno=%d (%s)", errno, strerror(errno));
        break;
      }
      if (pr == 0) {
        klog("WaylandBackend: drop read timed out, discarding partial data");
        break;
      }
      ssize_t r = read(readFd, buf, sizeof buf);
      if (r < 0) {
        if (errno == EINTR) continue;
        klogf("WaylandBackend: drop read FAILED errno=%d (%s)", errno, strerror(errno));
        break;
      }
      if (r == 0) break;
      bytes.insert(bytes.end(), buf, buf + r);
    }
    close(readFd);
    std::lock_guard<std::mutex> lg(impl->mutex_);
    if (finishOffer) wl_data_offer_finish(offer);
    wl_data_offer_destroy(offer);
    if (impl->display) wl_display_flush(impl->display);
    impl->pendingDrops.push_back({displayId, mime, std::move(bytes), x, y});
    impl->activeIoThreads--;
    impl->ioThreadsCv.notify_all();
  }).detach();
}
constexpr const char* kSelectionMimePreference[] = {"text/plain;charset=utf-8", "text/plain",
                                                     "image/png"};
constexpr const char* kPasswordHintMime = "x-kde-passwordManagerHint";

// queue an empty clipboard selection
void PushUncarriedSelection(WaylandBackend::Impl* impl) {
  impl->pendingSelections.push_back({std::string(), {}, false});
}

// read the host clipboard selection
void OnDataDeviceSelection(void* data, wl_data_device*, wl_data_offer* id) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  const uint64_t seq = impl->selections.Begin();
  std::vector<std::string> mimes;
  if (impl->pendingOfferProxy == id) {
    mimes = impl->pendingOfferMimes;
    impl->pendingOfferProxy = nullptr;
    impl->pendingOfferMimes.clear();
  }
  klogf("WaylandBackend: selection event seq=%llu offer=%s mimes=%zu", static_cast<unsigned long long>(seq),
        id ? "yes" : "none", mimes.size());

  if (!composerClipboardEnabled()) {
    if (id) wl_data_offer_destroy(id);
    return;
  }
  if (!id) {
    PushUncarriedSelection(impl);
    return;
  }
  if (std::find(mimes.begin(), mimes.end(), kPasswordHintMime) != mimes.end()) {
    klog("WaylandBackend: selection carries a password-manager hint, not syncing");
    wl_data_offer_destroy(id);
    PushUncarriedSelection(impl);
    return;
  }
  std::string chosen;
  for (const char* pref : kSelectionMimePreference) {
    if (std::find(mimes.begin(), mimes.end(), pref) != mimes.end()) { chosen = pref; break; }
  }
  if (chosen.empty()) {
    klogf("WaylandBackend: selection offers nothing this composer syncs (%zu mime(s))", mimes.size());
    wl_data_offer_destroy(id);
    PushUncarriedSelection(impl);
    return;
  }

  int pipeFds[2];
  if (pipe2(pipeFds, O_CLOEXEC) != 0) {
    klogf("WaylandBackend: selection pipe2 FAILED errno=%d (%s)", errno, strerror(errno));
    wl_data_offer_destroy(id);
    PushUncarriedSelection(impl);
    return;
  }
  wl_data_offer_receive(id, chosen.c_str(), pipeFds[1]);
  wl_display_flush(impl->display);
  close(pipeFds[1]);

  const std::string mime = chosen;
  impl->activeIoThreads++;
  rhizo_selection::ReadInThread(
      impl->selections, impl->mutex_, pipeFds[0], seq, 5000,
      [impl, mime, id, seq](rhizo_selection::Verdict verdict, rhizo_selection::Read outcome, int err,
                            std::vector<uint8_t>&& bytes) {
        klogf("WaylandBackend: selection read seq=%llu mime=%s bytes=%zu verdict=%s",
              static_cast<unsigned long long>(seq), mime.c_str(), bytes.size(),
              verdict == rhizo_selection::Verdict::kReport      ? "report"
              : verdict == rhizo_selection::Verdict::kUncarried ? "uncarried"
                                                                : "superseded");
        if (outcome == rhizo_selection::Read::kTimedOut) {
          klogf("WaylandBackend: selection read timed out after %zu byte(s), not carried", bytes.size());
        } else if (outcome == rhizo_selection::Read::kFailed) {
          klogf("WaylandBackend: selection read FAILED errno=%d (%s), not carried", err, strerror(err));
        }
        wl_data_offer_destroy(id);
        if (impl->display) wl_display_flush(impl->display);
        if (verdict == rhizo_selection::Verdict::kReport) {
          impl->pendingSelections.push_back({mime, std::move(bytes), true});
        } else if (verdict == rhizo_selection::Verdict::kUncarried) {
          PushUncarriedSelection(impl);
        } else {
          klog("WaylandBackend: selection read superseded by a newer selection, not reported");
        }
        impl->activeIoThreads--;
        impl->ioThreadsCv.notify_all();
      });
}
constexpr wl_data_device_listener kDataDeviceListener{
    .data_offer = OnDataDeviceDataOffer,
    .enter = OnDataDeviceEnter,
    .leave = OnDataDeviceLeave,
    .motion = OnDataDeviceMotion,
    .drop = OnDataDeviceDrop,
    .selection = OnDataDeviceSelection,
};

// ignore the data source target event
void OnDataSourceTarget(void*, wl_data_source*, const char*) {}
// write the drag payload on a new thread
void OnDataSourceSend(void* data, wl_data_source*, const char*, int32_t fd) {
  auto* ctx = static_cast<DragSourceCtx*>(data);
  WaylandBackend::Impl* impl = ctx->impl;
  std::shared_ptr<const std::vector<uint8_t>> payload = ctx->payload;
  impl->activeIoThreads++;
  std::thread([impl, payload, fd] {
    WriteAllWithDeadline(fd, payload->data(), payload->size(), "drag");
    close(fd);
    std::lock_guard<std::mutex> lg(impl->mutex_);
    impl->activeIoThreads--;
    impl->ioThreadsCv.notify_all();
  }).detach();
}
// destroy the drag data source
void DropDragSourceLocked(WaylandBackend::Impl* impl, wl_data_source* source) {
  if (impl->dragSource != source) return;
  wl_data_source_destroy(source);
  delete static_cast<DragSourceCtx*>(impl->dragSourceCtx);
  impl->dragSource = nullptr;
  impl->dragSourceCtx = nullptr;
}
// log the canceled drag and drop its source
void OnDataSourceCanceled(void* data, wl_data_source* source) {
  auto* ctx = static_cast<DragSourceCtx*>(data);
  klog("WaylandBackend: drag canceled");
  DropDragSourceLocked(ctx->impl, source);
}
// ignore the drag source drop performed event
void OnDataSourceDndDropPerformed(void*, wl_data_source*) {}
// log the finished drag and drop its source
void OnDataSourceDndFinished(void* data, wl_data_source* source) {
  auto* ctx = static_cast<DragSourceCtx*>(data);
  klog("WaylandBackend: drag finished");
  DropDragSourceLocked(ctx->impl, source);
}
// ignore the drag source action event
void OnDataSourceAction(void*, wl_data_source*, uint32_t) {}
constexpr wl_data_source_listener kDataSourceListener{
    .target = OnDataSourceTarget,
    .send = OnDataSourceSend,
    .cancelled = OnDataSourceCanceled,
    .dnd_drop_performed = OnDataSourceDndDropPerformed,
    .dnd_finished = OnDataSourceDndFinished,
    .action = OnDataSourceAction,
};

// ignore the clipboard source target event
void OnClipSourceTarget(void*, wl_data_source*, const char*) {}
// write the clipboard payload on a new thread
void OnClipSourceSend(void* data, wl_data_source*, const char*, int32_t fd) {
  auto* ctx = static_cast<ClipSourceCtx*>(data);
  WaylandBackend::Impl* impl = ctx->impl;
  std::shared_ptr<const std::vector<uint8_t>> payload = ctx->payload;
  impl->activeIoThreads++;
  std::thread([impl, payload, fd] {
    WriteAllWithDeadline(fd, payload->data(), payload->size(), "clip");
    close(fd);
    std::lock_guard<std::mutex> lg(impl->mutex_);
    impl->activeIoThreads--;
    impl->ioThreadsCv.notify_all();
  }).detach();
}
// destroy the clipboard data source
void DropClipSourceLocked(WaylandBackend::Impl* impl, wl_data_source* source) {
  if (impl->clipSource != source) return;
  wl_data_source_destroy(source);
  delete static_cast<ClipSourceCtx*>(impl->clipSourceCtx);
  impl->clipSource = nullptr;
  impl->clipSourceCtx = nullptr;
}
// log the replaced host selection and drop the clipboard source
void OnClipSourceCanceled(void* data, wl_data_source* source) {
  auto* ctx = static_cast<ClipSourceCtx*>(data);
  klog("WaylandBackend: host selection replaced or cleared");
  DropClipSourceLocked(ctx->impl, source);
}
// ignore the clipboard source drop performed event
void OnClipSourceDndDropPerformed(void*, wl_data_source*) {}
// ignore the clipboard source drag finished event
void OnClipSourceDndFinished(void*, wl_data_source*) {}
// ignore the clipboard source action event
void OnClipSourceAction(void*, wl_data_source*, uint32_t) {}
constexpr wl_data_source_listener kClipSourceListener{
    .target = OnClipSourceTarget,
    .send = OnClipSourceSend,
    .cancelled = OnClipSourceCanceled,
    .dnd_drop_performed = OnClipSourceDndDropPerformed,
    .dnd_finished = OnClipSourceDndFinished,
    .action = OnClipSourceAction,
};

// set a new clipboard source offering the payload
void CreateSelectionSourceLocked(WaylandBackend::Impl* impl, const std::string& mime,
                                  std::shared_ptr<const std::vector<uint8_t>> payload) {
  if (impl->clipSource) DropClipSourceLocked(impl, impl->clipSource);
  wl_data_source* source = wl_data_device_manager_create_data_source(impl->dataDeviceManager);
  wl_data_source_offer(source, mime.c_str());
  auto* ctx = new ClipSourceCtx{impl, payload};
  wl_data_source_add_listener(source, &kClipSourceListener, ctx);
  impl->clipSource = source;
  impl->clipSourceCtx = ctx;
  wl_data_device_set_selection(impl->dataDevice, source, impl->lastInputSerial);
  wl_display_flush(impl->display);
  klogf("WaylandBackend: clipboard set_selection mime=%s bytes=%zu serial=%u", mime.c_str(),
        payload->size(), impl->lastInputSerial);
}

// set the parked clipboard selection
void CompleteParkedSelectionLocked(WaylandBackend::Impl* impl) {
  if (!impl->parkedSelection.valid) return;
  const std::string mime = impl->parkedSelection.mime;
  auto payload = impl->parkedSelection.payload;
  impl->parkedSelection = {};
  klogf("WaylandBackend: completing parked clipboard set, mime=%s, on a new serial",
        mime.c_str());
  CreateSelectionSourceLocked(impl, mime, payload);
}

// ignore the output geometry event
void OnOutputGeometry(void*, wl_output*, int32_t, int32_t, int32_t, int32_t, int32_t,
                      const char*, const char*, int32_t) {}
// store the current mode's size and refresh for the output
void OnOutputMode(void* data, wl_output* output, uint32_t flags, int32_t width, int32_t height,
                  int32_t refresh) {
  if (!(flags & WL_OUTPUT_MODE_CURRENT)) return;
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  auto& st = impl->outputs[output];
  st.width = width;
  st.height = height;
  st.refreshMHz = refresh;
}
// reapply the scale of displays on the output
void OnOutputDone(void* data, wl_output* output) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  for (auto& [id, ds] : impl->displays) {
    if (ds.enteredOutputs.count(output)) ApplyOutputScaleLocked(impl, &ds);
  }
}
// record the scale factor of the output
void OnOutputScale(void* data, wl_output* output, int32_t factor) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->outputs[output].scale = factor;
}
// store the output's name
void OnOutputName(void* data, wl_output* output, const char* name) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  impl->outputs[output].name = name ? name : "";
}
// ignore the output description event
void OnOutputDescription(void*, wl_output*, const char*) {}
constexpr wl_output_listener kOutputListener{
    .geometry = OnOutputGeometry,
    .mode = OnOutputMode,
    .done = OnOutputDone,
    .scale = OnOutputScale,
    .name = OnOutputName,
    .description = OnOutputDescription,
};

// record the output a display entered
void OnSurfaceEnter(void* data, wl_surface* surface, wl_output* output) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  auto it = impl->surfaceToDisplay.find(surface);
  if (it == impl->surfaceToDisplay.end()) return;
  if (DisplayState* ds = impl->Find(it->second)) {
    ds->enteredOutputs.insert(output);
    klogf("WaylandBackend: display %lld entered output %s", static_cast<long long>(ds->id),
          impl->outputs.count(output) ? impl->outputs[output].name.c_str() : "(unknown)");
    ApplyOutputScaleLocked(impl, ds);
  }
}
// remove the output from the display's entered outputs
void OnSurfaceLeave(void* data, wl_surface* surface, wl_output* output) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  auto it = impl->surfaceToDisplay.find(surface);
  if (it == impl->surfaceToDisplay.end()) return;
  if (DisplayState* ds = impl->Find(it->second)) {
    ds->enteredOutputs.erase(output);
    klogf("WaylandBackend: display %lld left output %s", static_cast<long long>(ds->id),
          impl->outputs.count(output) ? impl->outputs[output].name.c_str() : "(unknown)");
    ApplyOutputScaleLocked(impl, ds);
  }
}
constexpr wl_surface_listener kSurfaceListener{
    .enter = OnSurfaceEnter,
    .leave = OnSurfaceLeave,
};

// store the presentation clock id
void OnPresentationClockId(void* data, wp_presentation*, uint32_t clkId) {
  static_cast<WaylandBackend::Impl*>(data)->presentationClockId = static_cast<int>(clkId);
}
constexpr wp_presentation_listener kPresentationListener{.clock_id = OnPresentationClockId};

// record a wl_shm format the compositor advertises
void OnShmFormat(void* data, wl_shm*, uint32_t format) {
  static_cast<WaylandBackend::Impl*>(data)->shmFormats.insert(format);
}
constexpr wl_shm_listener kShmListener{.format = OnShmFormat};

// bind a Wayland global object
void OnRegistryGlobal(void* data, wl_registry* registry, uint32_t name, const char* interface,
                       uint32_t version) {
  auto* impl = static_cast<WaylandBackend::Impl*>(data);
  std::string iface(interface);
  if (iface == wl_compositor_interface.name) {
    impl->compositor = static_cast<wl_compositor*>(
        wl_registry_bind(registry, name, &wl_compositor_interface, 4));
  } else if (iface == xdg_wm_base_interface.name) {
    impl->wmBase = static_cast<xdg_wm_base*>(
        wl_registry_bind(registry, name, &xdg_wm_base_interface, std::min<uint32_t>(version, 4)));
    xdg_wm_base_add_listener(impl->wmBase, &kWmBaseListener, nullptr);
  } else if (iface == zwp_linux_dmabuf_v1_interface.name) {
    uint32_t bindVersion = version < 3 ? version : 3;
    impl->dmabuf = static_cast<zwp_linux_dmabuf_v1*>(
        wl_registry_bind(registry, name, &zwp_linux_dmabuf_v1_interface, bindVersion));
    impl->dmabufVersion = bindVersion;
    if (bindVersion >= 3) {
      zwp_linux_dmabuf_v1_add_listener(impl->dmabuf, &kDmabufListener, &impl->modifierTable);
    }
  } else if (iface == wp_presentation_interface.name) {
    impl->presentation = static_cast<wp_presentation*>(
        wl_registry_bind(registry, name, &wp_presentation_interface, 1));
    wp_presentation_add_listener(impl->presentation, &kPresentationListener, impl);
  } else if (iface == wl_output_interface.name) {
    uint32_t bindVersion = version < 4 ? version : 4;
    auto* output = static_cast<wl_output*>(
        wl_registry_bind(registry, name, &wl_output_interface, bindVersion));
    impl->outputs[output] = {};
    wl_output_add_listener(output, &kOutputListener, impl);
  } else if (iface == wl_seat_interface.name) {
    uint32_t bindVersion = version < 8 ? version : 8;
    impl->seat = static_cast<wl_seat*>(
        wl_registry_bind(registry, name, &wl_seat_interface, bindVersion));
    wl_seat_add_listener(impl->seat, &kSeatListener, impl);
  } else if (iface == wp_viewporter_interface.name) {
    impl->viewporter = static_cast<wp_viewporter*>(
        wl_registry_bind(registry, name, &wp_viewporter_interface, 1));
  } else if (iface == wp_fractional_scale_manager_v1_interface.name) {
    impl->fractionalScaleManager = static_cast<wp_fractional_scale_manager_v1*>(
        wl_registry_bind(registry, name, &wp_fractional_scale_manager_v1_interface, 1));
  } else if (iface == wp_cursor_shape_manager_v1_interface.name) {
    impl->cursorShapeManager = static_cast<wp_cursor_shape_manager_v1*>(
        wl_registry_bind(registry, name, &wp_cursor_shape_manager_v1_interface, 1));
  } else if (iface == wl_shm_interface.name) {
    impl->shm = static_cast<wl_shm*>(wl_registry_bind(registry, name, &wl_shm_interface, 1));
    wl_shm_add_listener(impl->shm, &kShmListener, impl);
  } else if (iface == wl_data_device_manager_interface.name) {
    uint32_t bindVersion = version < 3 ? version : 3;
    impl->dataDeviceManager = static_cast<wl_data_device_manager*>(
        wl_registry_bind(registry, name, &wl_data_device_manager_interface, bindVersion));
  } else if (iface == wl_subcompositor_interface.name) {
    impl->subcompositor = static_cast<wl_subcompositor*>(
        wl_registry_bind(registry, name, &wl_subcompositor_interface, 1));
  } else if (iface == zxdg_decoration_manager_v1_interface.name) {
    impl->decorationManager = static_cast<zxdg_decoration_manager_v1*>(
        wl_registry_bind(registry, name, &zxdg_decoration_manager_v1_interface, 1));
  } else if (iface == xdg_activation_v1_interface.name) {
    impl->activationManager = static_cast<xdg_activation_v1*>(
        wl_registry_bind(registry, name, &xdg_activation_v1_interface, 1));
  }
}
// ignore the registry global remove event
void OnRegistryGlobalRemove(void*, wl_registry*, uint32_t) {}
constexpr wl_registry_listener kRegistryListener{
    .global = OnRegistryGlobal,
    .global_remove = OnRegistryGlobalRemove,
};

}

// connect to the Wayland display
bool WaylandBackend::Connect() {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);

  wl_log_set_handler_client(WlLogHandler);

  const char* waylandDisplay = getenv("WAYLAND_DISPLAY");
  klogf("WaylandBackend::Connect: WAYLAND_DISPLAY=%s XDG_RUNTIME_DIR=%s",
        waylandDisplay ? waylandDisplay : "(unset)",
        getenv("XDG_RUNTIME_DIR") ? getenv("XDG_RUNTIME_DIR") : "(unset)");

  impl->display = wl_display_connect(nullptr);
  if (!impl->display) {
    klogf("WaylandBackend::Connect: wl_display_connect FAILED errno=%d (%s)", errno,
          strerror(errno));
    return false;
  }

  impl->registry = wl_display_get_registry(impl->display);
  wl_registry_add_listener(impl->registry, &kRegistryListener, impl);

  if (wl_display_roundtrip(impl->display) < 0 || wl_display_roundtrip(impl->display) < 0) {
    klog("WaylandBackend::Connect: roundtrip FAILED");
    return false;
  }

  if (!impl->compositor || !impl->wmBase || !(impl->dmabuf || impl->shm)) {
    klogf(
        "WaylandBackend::Connect: missing required global(s): compositor=%p wmBase=%p dmabuf=%p shm=%p",
        static_cast<void*>(impl->compositor), static_cast<void*>(impl->wmBase),
        static_cast<void*>(impl->dmabuf), static_cast<void*>(impl->shm));
    return false;
  }
  klogf("WaylandBackend::Connect: present paths dmabuf=%d shm=%d", impl->dmabuf != nullptr, impl->shm != nullptr);
  if (!impl->presentation) klog("WaylandBackend::Connect: wp_presentation absent (soft, v1 doesn't need it)");
  if (!impl->viewporter) klog("WaylandBackend::Connect: wp_viewporter absent (soft, v1 doesn't need it)");
  if (!impl->dataDeviceManager) {
    klog("WaylandBackend::Connect: wl_data_device_manager absent (soft, drag-and-drop stays off)");
  } else if (impl->seat) {
    impl->dataDevice = wl_data_device_manager_get_data_device(impl->dataDeviceManager, impl->seat);
    wl_data_device_add_listener(impl->dataDevice, &kDataDeviceListener, impl);
  } else {
    klog("WaylandBackend::Connect: wl_data_device_manager present but no wl_seat, drag-and-drop stays off");
  }

  impl->connected = true;
  impl->connectCount++;
  klogf("WaylandBackend::Connect: OK (connectCount=%lld), dmabuf protocol version=%u, %zu formats "
        "with modifiers",
        static_cast<long long>(impl->connectCount), impl->dmabufVersion, impl->modifierTable.size());
  return true;
}

bool WaylandBackend::Connected() const { return impl_->connected; }

// read the compositor's size during an edge drag
bool WaylandBackend::DraggedSize(int64_t displayId, int32_t* width, int32_t* height) const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  const DisplayState* ds = impl_->Find(displayId);
  if (!ds || !ds->resizing || ds->reportedWidth <= 0 || ds->reportedHeight <= 0) return false;
  if (width) *width = ScaledPx(ds->reportedWidth, ds->appliedScale120);
  if (height) *height = ScaledPx(ds->reportedHeight, ds->appliedScale120);
  return true;
}

// read the compositor's maximum window size for the display
bool WaylandBackend::DisplayBounds(int64_t displayId, int32_t* width, int32_t* height) const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  const DisplayState* ds = impl_->Find(displayId);
  if (!ds || ds->boundsWidth <= 0 || ds->boundsHeight <= 0) return false;
  *width = ds->boundsWidth;
  *height = ds->boundsHeight;
  return true;
}

// create a toplevel window for the display
bool WaylandBackend::CreateDisplay(int64_t displayId, const std::string& title, int32_t width,
                                   int32_t height) {
  Impl* impl = impl_.get();
  std::unique_lock<std::mutex> lk(impl->mutex_);
  if (!impl->connected) {
    klog("WaylandBackend::CreateDisplay: not connected");
    return false;
  }
  if (impl->displays.count(displayId)) {
    klogf("WaylandBackend::CreateDisplay: display %lld already exists",
          static_cast<long long>(displayId));
    return false;
  }

  DisplayState& ds = impl->displays[displayId];
  ds.id = displayId;
  ds.startWidth = width > 0 ? width : 0;
  ds.startHeight = height > 0 ? height : 0;
  ds.surface = wl_compositor_create_surface(impl->compositor);
  wl_surface_add_listener(ds.surface, &kSurfaceListener, impl);
  ds.xdgSurface = xdg_wm_base_get_xdg_surface(impl->wmBase, ds.surface);
  auto* ctx = new DisplayCtx{displayId, impl};
  ds.toplevelCtx = ctx;
  xdg_surface_add_listener(ds.xdgSurface, &kXdgSurfaceListener, ctx);
  impl->surfaceToDisplay[ds.surface] = displayId;
  ds.xdgToplevel = xdg_surface_get_toplevel(ds.xdgSurface);
  xdg_toplevel_add_listener(ds.xdgToplevel, &kToplevelListener, ctx);
  xdg_toplevel_set_title(ds.xdgToplevel, title.c_str());
  xdg_toplevel_set_app_id(ds.xdgToplevel, "rhizo");
  ds.appId = "rhizo";
  ds.title = title;
  if (impl->viewporter) {
    ds.viewport = wp_viewporter_get_viewport(impl->viewporter, ds.surface);
    if (impl->fractionalScaleManager) {
      ds.fractionalScale =
          wp_fractional_scale_manager_v1_get_fractional_scale(impl->fractionalScaleManager, ds.surface);
      wp_fractional_scale_v1_add_listener(ds.fractionalScale, &kFractionalScaleListener, ctx);
    }
  }

  if (impl->decorationManager) {
    ds.decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(impl->decorationManager,
                                                                        ds.xdgToplevel);
    zxdg_toplevel_decoration_v1_add_listener(ds.decoration, &kDecorationListener, ctx);
    zxdg_toplevel_decoration_v1_set_mode(ds.decoration,
                                          ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
  } else {
    ds.decorationMode = WaylandDecorationMode::kClientSide;
    CreateCsdStripLocked(impl, &ds);
  }

  wl_surface_commit(ds.surface);
  wl_display_flush(impl->display);

  bool ok;
  if (!impl->pumpRunning) {
    for (int i = 0; i < 200; ++i) {
      DisplayState* cur = impl->Find(displayId);
      if (!cur || cur->configured) break;
      if (wl_display_dispatch(impl->display) < 0) {
        klog("WaylandBackend::CreateDisplay: wl_display_dispatch FAILED waiting for configure");
        DestroyDisplayLocked(impl, displayId);
        return false;
      }
    }
    DisplayState* cur = impl->Find(displayId);
    ok = cur && cur->configured;
  } else {
    ok = impl->configureCv.wait_for(lk, std::chrono::seconds(5), [&] {
      DisplayState* cur = impl->Find(displayId);
      return !cur || cur->configured || !impl->pumpRunning;
    });
    DisplayState* cur = impl->Find(displayId);
    ok = ok && cur && cur->configured;
  }

  if (!ok) {
    klogf("WaylandBackend::CreateDisplay: display %lld never configured (timeout)",
          static_cast<long long>(displayId));
    DestroyDisplayLocked(impl, displayId);
    return false;
  }
  klogf("WaylandBackend::CreateDisplay: display %lld ready, title=\"%s\"",
        static_cast<long long>(displayId), title.c_str());
  return true;
}

// destroy the display's Wayland objects
void WaylandBackend::DestroyDisplayLocked(Impl* impl, int64_t displayId) {
  auto pit = impl->pendingFrames.find(displayId);
  if (pit != impl->pendingFrames.end()) {
    for (auto& pf : pit->second) Impl::ClosePending(pf);
    impl->pendingFrames.erase(pit);
  }
  DisplayState* ds = impl->Find(displayId);
  if (!ds) return;
  for (auto& kv : ds->bufferCache) DestroySlotBuffers(kv.second);
  if (ds->csd.surface) {
    impl->csdSurfaceToDisplay.erase(ds->csd.surface);
    DestroyCsdStripLocked(ds);
  }
  DestroyFillLocked(ds);
  if (ds->decoration) { zxdg_toplevel_decoration_v1_destroy(ds->decoration); ds->decoration = nullptr; }
  if (ds->fractionalScale) wp_fractional_scale_v1_destroy(ds->fractionalScale);
  if (ds->viewport) wp_viewport_destroy(ds->viewport);
  if (ds->xdgToplevel) xdg_toplevel_destroy(ds->xdgToplevel);
  if (ds->xdgSurface) xdg_surface_destroy(ds->xdgSurface);
  if (ds->surface) {
    impl->surfaceToDisplay.erase(ds->surface);
    wl_surface_destroy(ds->surface);
  }
  if (impl->pointerFocus == displayId) impl->pointerFocus = -1;
  if (impl->keyboardFocus == displayId) impl->keyboardFocus = -1;
  if (impl->touchFocus == displayId) impl->touchFocus = -1;
  if (impl->csdPointerFocus == displayId) impl->csdPointerFocus = -1;
  delete static_cast<DisplayCtx*>(ds->toplevelCtx);
  impl->displays.erase(displayId);
  if (impl->display) wl_display_flush(impl->display);
  klogf("WaylandBackend: display %lld destroyed", static_cast<long long>(displayId));
}

// destroy a display under the backend lock
void WaylandBackend::DestroyDisplay(int64_t displayId) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  DestroyDisplayLocked(impl, displayId);
}

// queue the frame for the event pump
bool WaylandBackend::PresentFrameWhenSignaled(int64_t displayId, const WaylandFrame& frame) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  if (!impl->Find(displayId)) return false;
  if (impl->wakeFd < 0) {
    impl->wakeFd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (impl->wakeFd < 0) klogf("WaylandBackend: eventfd FAILED errno=%d (%s)", errno, strerror(errno));
  }
  Impl::PendingFrame pf;
  pf.frame = frame;
  pf.frame.dmabufFd = fcntl(frame.dmabufFd, F_DUPFD_CLOEXEC, 0);
  pf.frame.acquireFenceFd = frame.acquireFenceFd >= 0 ? fcntl(frame.acquireFenceFd, F_DUPFD_CLOEXEC, 0) : -1;
  if (pf.frame.dmabufFd < 0) {
    klogf("WaylandBackend::PresentFrameWhenSignaled: dup of dmabuf fd %d FAILED errno=%d", frame.dmabufFd, errno);
    Impl::ClosePending(pf);
    return false;
  }
  pf.queuedNs = MonotonicNs();
  auto& queue = impl->pendingFrames[displayId];
  if (queue.size() >= Impl::kPendingDepth) {
    Impl::ClosePending(queue.back());
    queue.pop_back();
    impl->asyncSuperseded++;
  }
  queue.push_back(pf);
  impl->asyncQueued++;
  if (impl->wakeFd >= 0) {
    uint64_t one = 1;
    if (write(impl->wakeFd, &one, sizeof one) < 0 && errno != EAGAIN) {
      klogf("WaylandBackend: eventfd write FAILED errno=%d", errno);
    }
  }
  return true;
}

namespace {

// return the wl_shm buffer for a size-sealed shmem frame
wl_buffer* ShmFrameBufferLocked(WaylandBackend::Impl* impl, const DisplayState& ds, BufferSlot& slot,
                                const WaylandFrame& frame, const struct stat& st, int seals) {
  if (!impl->shm) {
    impl->lastPresentDropped = true;
    if (impl->shmRefusals++ % 300 == 0) {
      klogf("WaylandBackend::PresentFrame: refused a memfd frame: the compositor has no wl_shm (%llu refused)",
            static_cast<unsigned long long>(impl->shmRefusals));
    }
    return nullptr;
  }
  const int64_t frameBytes = static_cast<int64_t>(frame.strideBytes) * frame.height;
  if (frame.width <= 0 || frame.height <= 0 || frame.strideBytes <= 0 || frameBytes > st.st_size ||
      st.st_size > INT32_MAX) {
    impl->lastPresentDropped = true;
    if (impl->shmRefusals++ % 300 == 0) {
      klogf("WaylandBackend::PresentFrame: refused a shmem frame %dx%d stride %d in a %lld-byte file (%llu refused)",
            frame.width, frame.height, frame.strideBytes, static_cast<long long>(st.st_size),
            static_cast<unsigned long long>(impl->shmRefusals));
    }
    return nullptr;
  }
  const uint32_t shmFormat = ShmFormatOf(frame.drmFormat);
  if (impl->shmFormats.count(shmFormat) && ShmSealsAllowZeroCopy(seals) &&
      ShmZeroCopyFits(frame.drmFormat, frame.width, frame.height, frame.strideBytes, st.st_size)) {
    bool needNewBuffer = composerDebugEnabled()
                              ? true
                              : (slot.buffer == nullptr) || (slot.dev != st.st_dev) || (slot.ino != st.st_ino);
    if (needNewBuffer) {
      if (slot.buffer) wl_buffer_destroy(slot.buffer);
      if (slot.pool) wl_shm_pool_destroy(slot.pool);
      slot.pool = wl_shm_create_pool(impl->shm, frame.dmabufFd, static_cast<int32_t>(st.st_size));
      slot.buffer = slot.pool ? wl_shm_pool_create_buffer(slot.pool, 0, frame.width, frame.height, frame.strideBytes,
                                                          shmFormat)
                              : nullptr;
      if (!slot.buffer) {
        if (slot.pool) wl_shm_pool_destroy(slot.pool);
        slot.pool = nullptr;
        klogf("WaylandBackend::PresentFrame: wl_shm buffer FAILED slot=%d %dx%d format=0x%08x", frame.slot,
              frame.width, frame.height, frame.drmFormat);
        return nullptr;
      }
      slot.dev = st.st_dev;
      slot.ino = st.st_ino;
      klogf("WaylandBackend::PresentFrame: display %lld slot %d wl_shm buffer created %dx%d format=0x%08x over the "
            "frame's memfd",
            static_cast<long long>(ds.id), frame.slot, frame.width, frame.height, frame.drmFormat);
      wl_buffer_add_listener(slot.buffer, &kBufferListener, &slot);
    }
    slot.releasedSinceAttach = false;
    return slot.buffer;
  }

  const uint32_t to = ShmCopyFormat(frame.drmFormat);
  if (to == 0xffffffffu) {
    impl->lastPresentDropped = true;
    if (impl->shmRefusals++ % 300 == 0) {
      klogf("WaylandBackend::PresentFrame: refused a memfd frame of format 0x%08x: the compositor's wl_shm lacks it "
            "and it has no copy format (%llu refused)",
            frame.drmFormat, static_cast<unsigned long long>(impl->shmRefusals));
    }
    return nullptr;
  }
  if (!ShmCopyFits(frame.width, frame.height, frame.strideBytes, st.st_size)) {
    impl->lastPresentDropped = true;
    if (impl->shmRefusals++ % 300 == 0) {
      klogf("WaylandBackend::PresentFrame: refused to copy a shmem frame %dx%d of format 0x%08x: stride %d is under 4 "
            "bytes a pixel or the %lld-byte file is short of its rows (%llu refused)",
            frame.width, frame.height, frame.drmFormat, frame.strideBytes, static_cast<long long>(st.st_size),
            static_cast<unsigned long long>(impl->shmRefusals));
    }
    return nullptr;
  }
  BufferSlot::Copy* c = slot.copy[0].released ? &slot.copy[0] : slot.copy[1].released ? &slot.copy[1] : nullptr;
  if (!c) {
    impl->lastPresentDropped = true;
    if (impl->shmCopyDrops++ % 300 == 0) {
      klogf("WaylandBackend::PresentFrame: display %lld slot %d dropped a frame: the compositor holds both copy "
            "buffers (%llu dropped)",
            static_cast<long long>(ds.id), frame.slot, static_cast<unsigned long long>(impl->shmCopyDrops));
    }
    return nullptr;
  }
  const int32_t stride = frame.width * 4;
  const size_t size = static_cast<size_t>(stride) * static_cast<size_t>(frame.height);
  if (!c->buffer || c->width != frame.width || c->height != frame.height || c->format != to) {
    DestroyCopyBuffer(*c);
    c->fd = CreateBufferMemfd("rhizo-shm-copy", size);
    if (c->fd < 0) {
      klogf("WaylandBackend::PresentFrame: copy buffer memfd of %zu bytes FAILED errno=%d (%s)", size, errno,
            strerror(errno));
      return nullptr;
    }
    void* map = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, c->fd, 0);
    if (map == MAP_FAILED) {
      klogf("WaylandBackend::PresentFrame: copy buffer mmap of %zu bytes FAILED errno=%d (%s)", size, errno,
            strerror(errno));
      DestroyCopyBuffer(*c);
      return nullptr;
    }
    c->map = map;
    c->size = size;
    c->pool = wl_shm_create_pool(impl->shm, c->fd, static_cast<int32_t>(size));
    c->buffer = c->pool ? wl_shm_pool_create_buffer(c->pool, 0, frame.width, frame.height, stride, to) : nullptr;
    if (!c->buffer) {
      klogf("WaylandBackend::PresentFrame: copy wl_shm buffer FAILED slot=%d %dx%d wl_shm format %u", frame.slot,
            frame.width, frame.height, to);
      DestroyCopyBuffer(*c);
      return nullptr;
    }
    c->width = frame.width;
    c->height = frame.height;
    c->format = to;
    klogf("WaylandBackend::PresentFrame: display %lld slot %d copy buffer %d created %dx%d wl_shm format %u for "
          "format=0x%08x",
          static_cast<long long>(ds.id), frame.slot, static_cast<int>(c - slot.copy), frame.width, frame.height, to,
          frame.drmFormat);
    wl_buffer_add_listener(c->buffer, &kCopyBufferListener, c);
  }
  const size_t frameSize = static_cast<size_t>(frameBytes);
  void* src = mmap(nullptr, frameSize, PROT_READ, MAP_SHARED, frame.dmabufFd, 0);
  if (src == MAP_FAILED) {
    klogf("WaylandBackend::PresentFrame: mmap of the memfd frame (%zu bytes) FAILED errno=%d (%s)", frameSize, errno,
          strerror(errno));
    return nullptr;
  }
  const auto* s = static_cast<const uint8_t*>(src);
  auto* d = static_cast<uint8_t*>(c->map);
  if (frame.drmFormat == 0x34324241 || frame.drmFormat == 0x34324258) {
    SwapRedBlue(s, frame.strideBytes, d, stride, frame.width, frame.height);
  } else {
    for (int32_t y = 0; y < frame.height; y++) {
      memcpy(d + static_cast<size_t>(y) * stride, s + static_cast<size_t>(y) * frame.strideBytes,
             static_cast<size_t>(stride));
    }
  }
  munmap(src, frameSize);
  c->released = false;
  return c->buffer;
}

}

// present the frame on the display
bool WaylandBackend::PresentFrame(int64_t displayId, const WaylandFrame& frame) {
  Impl* impl = impl_.get();
  WaitFence(frame.acquireFenceFd);

  std::lock_guard<std::mutex> lg(impl->mutex_);
  impl->lastPresentWasDmabuf = false;
  impl->lastPresentDropped = false;

  if (impl->display && wl_display_get_error(impl->display) != 0) {
    if (!impl->firstError.captured) {
      impl->firstError.captured = true;
      impl->firstError.atPresentAttempt = impl->presentAttempts;
      impl->firstError.displayId = displayId;
      impl->firstError.width = frame.width;
      impl->firstError.height = frame.height;
      impl->firstError.strideBytes = frame.strideBytes;
      impl->firstError.dmabufFd = frame.dmabufFd;
      impl->firstError.drmFormat = frame.drmFormat;
      impl->firstError.modifier = frame.modifier;
      std::string logMsg;
      {
        std::lock_guard<std::mutex> lgLog(g_wlLogMutex);
        logMsg = g_wlLastLogMessage;
      }
      const std::string kNeedle = "zwp_linux_buffer_params_v1@";
      size_t pos = logMsg.find(kNeedle);
      if (pos != std::string::npos) {
        size_t idStart = pos + kNeedle.size();
        size_t idEnd = idStart;
        while (idEnd < logMsg.size() && isdigit(static_cast<unsigned char>(logMsg[idEnd]))) idEnd++;
        if (idEnd > idStart) {
          impl->firstError.failedParamsId = static_cast<uint32_t>(
              strtoul(logMsg.substr(idStart, idEnd - idStart).c_str(), nullptr, 10));
          auto it = impl->paramsIdAllocatedAtAttempt.find(impl->firstError.failedParamsId);
          if (it != impl->paramsIdAllocatedAtAttempt.end()) {
            impl->firstError.failedParamsIdWasReused = true;
            impl->firstError.failedParamsIdPriorAllocAttempt = it->second;
          }
        }
      }
    }
    impl->presentAttempts++;
    return false;
  }
  impl->presentAttempts++;

  DisplayState* dsp = impl->Find(displayId);
  if (!dsp) {
    klogf("WaylandBackend::PresentFrame: unknown display %lld", static_cast<long long>(displayId));
    return false;
  }
  DisplayState& ds = *dsp;

  const int seals = fcntl(frame.dmabufFd, F_GET_SEALS);
  const bool shmem = seals >= 0;
  if (shmem && !SealsHoldSize(seals)) {
    impl->lastPresentDropped = true;
    if (impl->shmUnsealed++ % 300 == 0) {
      klogf("WaylandBackend::PresentFrame: refused a shmem frame not sealed against shrinking: its owner could "
            "truncate it under this composer's and the compositor's maps (%llu refused)",
            static_cast<unsigned long long>(impl->shmUnsealed));
    }
    return false;
  }

  struct stat st{};
  if (fstat(frame.dmabufFd, &st) != 0) {
    klogf("WaylandBackend::PresentFrame: fstat(dmabufFd=%d) FAILED errno=%d (%s)", frame.dmabufFd,
          errno, strerror(errno));
    return false;
  }

  if (!shmem && !impl->dmabuf) {
    impl->lastPresentDropped = true;
    if (impl->dmabufRefusals++ % 300 == 0) {
      klogf("WaylandBackend::PresentFrame: refused a dmabuf frame: the compositor has no zwp_linux_dmabuf_v1 "
            "(%llu refused)",
            static_cast<unsigned long long>(impl->dmabufRefusals));
    }
    return false;
  }
  BufferSlot& slot = ds.bufferCache[frame.slot];
  wl_buffer* attach = nullptr;
  if (shmem) {
    attach = ShmFrameBufferLocked(impl, ds, slot, frame, st, seals);
    if (!attach) return false;
  } else {
    bool needNewBuffer = composerDebugEnabled()
                              ? true
                              : (slot.buffer == nullptr) || (slot.dev != st.st_dev) || (slot.ino != st.st_ino);
    if (needNewBuffer) {
      if (slot.buffer) wl_buffer_destroy(slot.buffer);

      zwp_linux_buffer_params_v1* params = zwp_linux_dmabuf_v1_create_params(impl->dmabuf);
      impl->paramsIdAllocatedAtAttempt[wl_proxy_get_id(reinterpret_cast<wl_proxy*>(params))] =
          impl->presentAttempts;
      zwp_linux_buffer_params_v1_add(params, frame.dmabufFd,  0,  0,
                                      static_cast<uint32_t>(frame.strideBytes), ModHi(frame.modifier),
                                      ModLo(frame.modifier));
      wl_buffer* buffer = zwp_linux_buffer_params_v1_create_immed(
          params, frame.width, frame.height, frame.drmFormat,  0);
      zwp_linux_buffer_params_v1_destroy(params);
      if (!buffer) {
        klogf(
            "WaylandBackend::PresentFrame: create_immed FAILED slot=%d %dx%d format=0x%08x "
            "mod=0x%016llx",
            frame.slot, frame.width, frame.height, frame.drmFormat,
            static_cast<unsigned long long>(frame.modifier));
        return false;
      }
      slot.buffer = buffer;
      slot.dev = st.st_dev;
      slot.ino = st.st_ino;
      klogf("WaylandBackend::PresentFrame: display %lld slot %d wl_buffer created %dx%d format=0x%08x modifier=0x%llx",
           static_cast<long long>(displayId), frame.slot, frame.width, frame.height, frame.drmFormat,
           static_cast<unsigned long long>(frame.modifier));
      wl_buffer_add_listener(buffer, &kBufferListener, &slot);
      impl->importedPairs.insert({frame.drmFormat, frame.modifier});
    }

    slot.releasedSinceAttach = false;
    attach = slot.buffer;
  }
  wl_surface_attach(ds.surface, attach, 0, 0);
  wl_surface_damage_buffer(ds.surface, 0, 0, frame.width, frame.height);
  const bool cropped = ds.viewport && frame.srcWidth > 0 && frame.srcHeight > 0;
  if (cropped) {
    const int32_t lw = SurfaceLocal(frame.srcWidth, ds.appliedScale120);
    const int32_t lh = SurfaceLocal(frame.srcHeight, ds.appliedScale120);
    const bool filled = frame.fillWidth > 0 && frame.fillHeight > 0;
    const int32_t gw = filled ? SurfaceLocal(frame.fillWidth, ds.appliedScale120) : lw;
    const int32_t gh = filled ? SurfaceLocal(frame.fillHeight, ds.appliedScale120) : lh;
    if (filled) {
      ShowFillLocked(impl, &ds, gw, gh, frame.fillRgba);
    } else {
      HideFillLocked(&ds);
    }
    if (!ds.minSizeSet && ds.xdgToplevel) {
      xdg_toplevel_set_min_size(ds.xdgToplevel, 220, 220 - 42);
      ds.minSizeSet = true;
    }
    if (!ds.pendingAcks.empty()) {
      int match = -1;
      for (int i = static_cast<int>(ds.pendingAcks.size()) - 1; i >= 0; --i) {
        const auto& a = ds.pendingAcks[i];
        if (std::abs(gw - a.width) <= 1 && std::abs(gh - a.height) <= 1) {
          match = i;
          break;
        }
      }
      if (match < 0 && MonotonicNs() - ds.pendingAcks.front().sinceNs > 300000000) {
        match = static_cast<int>(ds.pendingAcks.size()) - 1;
      }
      if (match >= 0) {
        xdg_surface_ack_configure(ds.xdgSurface, ds.pendingAcks[match].serial);
        ds.pendingAcks.erase(ds.pendingAcks.begin(), ds.pendingAcks.begin() + match + 1);
      }
    }
    wp_viewport_set_source(ds.viewport, wl_fixed_from_int(frame.srcX), wl_fixed_from_int(frame.srcY),
                           wl_fixed_from_int(frame.srcWidth), wl_fixed_from_int(frame.srcHeight));
    wp_viewport_set_destination(ds.viewport, lw, lh);
    xdg_surface_set_window_geometry(ds.xdgSurface, 0, 0, gw, gh);
    ds.viewportCropped = true;
  } else if (ds.viewportCropped) {
    if (!ds.pendingAcks.empty()) {
      xdg_surface_ack_configure(ds.xdgSurface, ds.pendingAcks.back().serial);
      ds.pendingAcks.clear();
    }
    wp_viewport_set_source(ds.viewport, wl_fixed_from_int(-1), wl_fixed_from_int(-1), wl_fixed_from_int(-1),
                           wl_fixed_from_int(-1));
    if (!FractionalLocked(&ds)) wp_viewport_set_destination(ds.viewport, -1, -1);
    ds.viewportCropped = false;
  }
  if (cropped) {
  } else if (FractionalLocked(&ds)) {
    const int32_t lw = ds.reportedWidth > 0 ? ds.reportedWidth : SurfaceLocal(frame.width, ds.appliedScale120);
    const int32_t lh = ds.reportedHeight > 0 ? ds.reportedHeight : SurfaceLocal(frame.height, ds.appliedScale120);
    wp_viewport_set_destination(ds.viewport, lw, lh);
    xdg_surface_set_window_geometry(ds.xdgSurface, 0, 0, lw, lh);
  } else {
    xdg_surface_set_window_geometry(ds.xdgSurface, 0, 0, frame.width, frame.height);
  }
  RequestCompletionLocked(impl, &ds, MonotonicNs());
  wl_surface_commit(ds.surface);
  if (!ds.bufferCommitted) {
    ds.bufferCommitted = true;
    if (!ds.heldActivationToken.empty() && impl->activationManager) {
      xdg_activation_v1_activate(impl->activationManager, ds.heldActivationToken.c_str(), ds.surface);
      klogf("WaylandBackend::PresentFrame: display %lld mapped, activated with its held token=%s",
            static_cast<long long>(displayId), ds.heldActivationToken.c_str());
      ds.heldActivationToken.clear();
    }
  }
  wl_display_flush(impl->display);

  impl->lastPresentWasDmabuf = !shmem;
  return true;
}

// start the Wayland event pump thread
void WaylandBackend::StartEventPump(VsyncCallback vsyncCb, CloseCallback closeCb,
                                     ResizeCallback resizeCb, InputCallback inputCb,
                                     PresentedCallback presentedCb, DropCallback dropCb,
                                     KeymapCallback keymapCb, SelectionCallback selectionCb) {
  Impl* impl = impl_.get();
  impl->presentedCb = std::move(presentedCb);
  {
    std::lock_guard<std::mutex> lg(impl->mutex_);
    impl->vsyncCb = std::move(vsyncCb);
    impl->closeCb = std::move(closeCb);
    impl->resizeCb = std::move(resizeCb);
    impl->inputCb = std::move(inputCb);
    impl->dropCb = std::move(dropCb);
    impl->keymapCb = std::move(keymapCb);
    impl->selectionCb = std::move(selectionCb);
    impl->pumpRunning = true;
  }
  impl->pumpThread = std::thread([this, impl] {
    prctl(PR_SET_NAME, "rhizo-wl-pump");
    SetFifoPriority2("rhizo-wl-pump");
    klog("WaylandBackend: event pump thread started");
    while (true) {
      {
        std::lock_guard<std::mutex> lg(impl->mutex_);
        if (!impl->pumpRunning) return;
      }
      int fd;
      {
        std::lock_guard<std::mutex> lg(impl->mutex_);
        while (wl_display_prepare_read(impl->display) != 0) {
          wl_display_dispatch_pending(impl->display);
        }
        wl_display_flush(impl->display);
        fd = wl_display_get_fd(impl->display);
      }
      std::vector<struct pollfd> pfds;
      std::vector<int64_t> pfdDisplay;
      int pollMs = 200;
      pfds.push_back({fd, POLLIN, 0});
      {
        std::lock_guard<std::mutex> lg(impl->mutex_);
        pfds.push_back({impl->wakeFd >= 0 ? impl->wakeFd : -1, POLLIN, 0});
        for (const auto& kv : impl->pendingFrames) {
          if (kv.second.empty()) continue;
          const Impl::PendingFrame& head = kv.second.front();
          if (head.frame.acquireFenceFd < 0) { pollMs = 0; continue; }
          pfds.push_back({head.frame.acquireFenceFd, POLLIN, 0});
          pfdDisplay.push_back(kv.first);
        }
      }
      int pr = poll(pfds.data(), pfds.size(), pollMs);
      struct pollfd pfd = pfds[0];
      if (pfds[1].revents & POLLIN) {
        uint64_t drained;
        while (read(pfds[1].fd, &drained, sizeof drained) > 0) {}
      }
      std::vector<std::pair<int64_t, Impl::PendingFrame>> ready;
      {
        std::lock_guard<std::mutex> lg(impl->mutex_);
        std::vector<int64_t> readyIds;
        for (size_t i = 2; i < pfds.size(); i++) {
          if (pfds[i].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL)) readyIds.push_back(pfdDisplay[i - 2]);
        }
        for (const auto& kv : impl->pendingFrames) {
          if (!kv.second.empty() && kv.second.front().frame.acquireFenceFd < 0) readyIds.push_back(kv.first);
        }
        for (int64_t id : readyIds) {
          auto it = impl->pendingFrames.find(id);
          if (it == impl->pendingFrames.end() || it->second.empty()) continue;
          ready.emplace_back(id, it->second.front());
          it->second.pop_front();
          if (it->second.empty()) impl->pendingFrames.erase(it);
        }
      }
      for (auto& rp : ready) {
        const int64_t waited = MonotonicNs() - rp.second.queuedNs;
        WaylandFrame f = rp.second.frame;
        const bool presented = PresentFrame(rp.first, f);
        Impl::ClosePending(rp.second);
        std::lock_guard<std::mutex> lg(impl->mutex_);
        if (!presented && !impl->lastPresentDropped) {
          klogf("WaylandBackend: deferred present FAILED for display %lld", static_cast<long long>(rp.first));
        }
        impl->asyncPresented++;
        impl->asyncWaitNs += waited;
        if (static_cast<uint64_t>(waited) > impl->asyncWaitMaxNs) impl->asyncWaitMaxNs = waited;
        const int64_t now = MonotonicNs();
        if (impl->asyncReportNs == 0) impl->asyncReportNs = now;
        if (now - impl->asyncReportNs >= 5000000000LL) {
          klogf("deferred present: presented=%llu queued=%llu superseded=%llu fence wait us mean/max=%.0f/%llu over %lldms",
                (unsigned long long)impl->asyncPresented, (unsigned long long)impl->asyncQueued,
                (unsigned long long)impl->asyncSuperseded,
                impl->asyncPresented ? impl->asyncWaitNs / 1000.0 / impl->asyncPresented : 0.0,
                (unsigned long long)(impl->asyncWaitMaxNs / 1000), (long long)((now - impl->asyncReportNs) / 1000000));
          impl->asyncPresented = 0; impl->asyncQueued = 0; impl->asyncSuperseded = 0;
          impl->asyncWaitNs = 0; impl->asyncWaitMaxNs = 0; impl->asyncReportNs = now;
        }
      }
      std::vector<Impl::PendingVsync> vsyncs;
      std::vector<Impl::PendingPresented> presented;
      std::vector<int64_t> closes;
      std::vector<Impl::PendingResize> resizes;
      std::vector<WaylandInputEvent> input;
      std::vector<WaylandDropEvent> drops;
      std::vector<std::string> keymaps;
      std::vector<WaylandSelectionEvent> selections;
      {
        std::lock_guard<std::mutex> lg(impl->mutex_);
        if (pr > 0 && (pfd.revents & POLLIN)) {
          if (wl_display_read_events(impl->display) < 0) {
            const int err = errno;
            const wl_interface* iface = nullptr;
            uint32_t objectId = 0;
            uint32_t code = 0;
            if (err == EPROTO) code = wl_display_get_protocol_error(impl->display, &iface, &objectId);
            std::string wlLog;
            {
              std::lock_guard<std::mutex> lgLog(g_wlLogMutex);
              wlLog = g_wlLastLogMessage;
            }
            while (!wlLog.empty() && (wlLog.back() == '\n' || wlLog.back() == '\r')) wlLog.pop_back();
            char head[160];
            snprintf(head, sizeof(head),
                     "WaylandBackend: wl_display_read_events FAILED errno=%d (%s) iface=%s id=%u code=%u", err,
                     strerror(err), iface ? iface->name : "(none)", objectId, code);
            klog((std::string(head) + " wl_log=\"" + wlLog + "\"").c_str());
            return;
          }
          wl_display_dispatch_pending(impl->display);
        } else {
          wl_display_cancel_read(impl->display);
          if (pr < 0 && errno != EINTR) {
            klogf("WaylandBackend: poll FAILED errno=%d (%s)", errno, strerror(errno));
          }
        }
        vsyncs.swap(impl->pendingVsyncs);
        presented.swap(impl->pendingPresented);
        closes.swap(impl->pendingCloses);
        resizes.swap(impl->pendingResizes);
        input.swap(impl->pendingInput);
        drops.swap(impl->pendingDrops);
        keymaps.swap(impl->pendingKeymaps);
        selections.swap(impl->pendingSelections);
      }

      {
        std::lock_guard<std::mutex> lg(impl->mutex_);
        std::set<int64_t> apply;
        apply.swap(impl->cursorApplyPending);
        for (int64_t id : apply) {
          if (id != impl->pointerFocus) continue;
          if (DisplayState* ds = impl->Find(id)) ApplyCursorNowLocked(impl, ds);
        }
        if (!apply.empty()) {
          const int werr = wl_display_get_error(impl->display);
          if (werr != 0) {
            klogf("WaylandBackend: wl_display error %d after a cursor upload -- connection lost", werr);
          }
        }
      }
      for (const auto& ev : input) {
        if (impl->inputCb) impl->inputCb(ev);
      }
      for (const auto& d : drops) {
        if (impl->dropCb) impl->dropCb(d);
      }
      for (const auto& km : keymaps) {
        if (impl->keymapCb) impl->keymapCb(km);
      }
      for (const auto& sel : selections) {
        if (impl->selectionCb) impl->selectionCb(sel);
      }
      for (const auto& v : vsyncs) {
        if (impl->vsyncCb) impl->vsyncCb(v.displayId, v.timestampNs);
      }
      for (const auto& p : presented) {
        if (impl->presentedCb) impl->presentedCb(p.displayId, p.presentedNs, p.refreshNs, p.discarded, p.commitNs);
      }
      for (const auto& r : resizes) {
        if (impl->resizeCb) impl->resizeCb(r.displayId, r.width, r.height, r.scale);
      }
      for (int64_t id : closes) {
        if (impl->closeCb) impl->closeCb(id);
      }
    }
  });
}

// start dragging a payload from the display
bool WaylandBackend::StartDrag(int64_t displayId, const std::string& mimeType,
                                std::vector<uint8_t> payload) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  if (!impl->connected || !impl->dataDeviceManager || !impl->dataDevice) {
    klog("WaylandBackend::StartDrag: no data device bound, refusing");
    return false;
  }
  DisplayState* ds = impl->Find(displayId);
  if (!ds) {
    klogf("WaylandBackend::StartDrag: unknown display %lld", static_cast<long long>(displayId));
    return false;
  }
  if (impl->dragSource) {
    klog("WaylandBackend::StartDrag: a drag is already in flight, refusing");
    return false;
  }
  wl_data_source* source = wl_data_device_manager_create_data_source(impl->dataDeviceManager);
  wl_data_source_offer(source, mimeType.c_str());
  if (wl_proxy_get_version(reinterpret_cast<wl_proxy*>(source)) >= WL_DATA_SOURCE_SET_ACTIONS_SINCE_VERSION) {
    wl_data_source_set_actions(source, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
  }
  auto* ctx = new DragSourceCtx{impl, std::make_shared<const std::vector<uint8_t>>(std::move(payload))};
  wl_data_source_add_listener(source, &kDataSourceListener, ctx);
  impl->dragSource = source;
  impl->dragSourceCtx = ctx;
  wl_data_device_start_drag(impl->dataDevice, source, ds->surface,  nullptr,
                             impl->lastPointerSerial);
  wl_display_flush(impl->display);
  klogf("WaylandBackend::StartDrag: display %lld mime=%s bytes=%zu serial=%u held=%d",
        static_cast<long long>(displayId), mimeType.c_str(), ctx->payload->size(),
        impl->lastPointerSerial, impl->lastPointerHeld ? 1 : 0);
  return true;
}

// set the host clipboard selection
bool WaylandBackend::SetSelection(const std::string& mimeType, std::vector<uint8_t> payload) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  if (!composerClipboardEnabled()) {
    klog("WaylandBackend::SetSelection: desktop.clipboard is off, refusing");
    return false;
  }
  if (!impl->connected || !impl->dataDeviceManager || !impl->dataDevice) {
    klog("WaylandBackend::SetSelection: no data device bound, refusing");
    return false;
  }
  auto shared = std::make_shared<const std::vector<uint8_t>>(std::move(payload));
  if (impl->lastInputSerial == 0) {
    impl->parkedSelection = {true, mimeType, shared};
    klogf("WaylandBackend::SetSelection: parked mime=%s bytes=%zu, no new serial yet",
          mimeType.c_str(), shared->size());
    return true;
  }
  CreateSelectionSourceLocked(impl, mimeType, shared);
  return true;
}

// clear the host clipboard selection
void WaylandBackend::ClearSelection() {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  impl->parkedSelection = {};
  if (!impl->dataDevice) return;
  wl_data_device_set_selection(impl->dataDevice, nullptr, impl->lastInputSerial);
  wl_display_flush(impl->display);
  if (impl->clipSource) DropClipSourceLocked(impl, impl->clipSource);
  klog("WaylandBackend::ClearSelection: selection unset");
}

// return whether the clipboard is enabled and a data device is bound
bool WaylandBackend::ClipboardBound() const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  return composerClipboardEnabled() && impl_->dataDevice != nullptr;
}

// return the display's decoration mode
WaylandDecorationMode WaylandBackend::GetDecorationMode(int64_t displayId) const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  DisplayState* ds = impl_->Find(displayId);
  return ds ? ds->decorationMode : WaylandDecorationMode::kNone;
}

// activate the display with a token
bool WaylandBackend::ActivateDisplay(int64_t displayId, const std::string& token, bool* held) {
  Impl* impl = impl_.get();
  std::unique_lock<std::mutex> lk(impl->mutex_);
  if (!impl->activationManager) {
    klog("WaylandBackend::ActivateDisplay: xdg_activation_v1 not bound, refusing");
    return false;
  }
  DisplayState* ds = impl->Find(displayId);
  if (!ds) {
    klogf("WaylandBackend::ActivateDisplay: unknown display %lld", static_cast<long long>(displayId));
    return false;
  }
  if (held) *held = false;
  if (!token.empty() && !ds->bufferCommitted) {
    ds->heldActivationToken = token;
    if (held) *held = true;
    klogf("WaylandBackend::ActivateDisplay: display %lld not mapped yet, token=%s held until its first buffer",
          static_cast<long long>(displayId), token.c_str());
    return true;
  }
  std::string useToken = token;
  if (useToken.empty()) {
    if (!impl->pumpRunning) {
      klog("WaylandBackend::ActivateDisplay: no token given and the pump is not running, refusing");
      return false;
    }
    xdg_activation_token_v1* req = xdg_activation_v1_get_activation_token(impl->activationManager);
    impl->activationTokenReady = false;
    impl->pendingActivationTokenResult.clear();
    xdg_activation_token_v1_add_listener(req, &kActivationTokenListener, impl);
    if (impl->seat) xdg_activation_token_v1_set_serial(req, impl->lastInputSerial, impl->seat);
    xdg_activation_token_v1_set_surface(req, ds->surface);
    xdg_activation_token_v1_commit(req);
    wl_display_flush(impl->display);
    const bool ok = impl->activationCv.wait_for(lk, std::chrono::seconds(5), [&] {
      return impl->activationTokenReady || !impl->pumpRunning;
    });
    xdg_activation_token_v1_destroy(req);
    if (!ok || impl->pendingActivationTokenResult.empty()) {
      klog("WaylandBackend::ActivateDisplay: token request timed out or was refused");
      return false;
    }
    useToken = impl->pendingActivationTokenResult;
  }
  xdg_activation_v1_activate(impl->activationManager, useToken.c_str(), ds->surface);
  wl_display_flush(impl->display);
  klogf("WaylandBackend::ActivateDisplay: display %lld token=%s", static_cast<long long>(displayId),
        useToken.c_str());
  return true;
}

// minimize the display's window if it is mapped
bool WaylandBackend::MinimizeDisplay(int64_t displayId) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  DisplayState* ds = impl->Find(displayId);
  if (!ds || !ds->xdgToplevel || !ds->bufferCommitted) return false;
  xdg_toplevel_set_minimized(ds->xdgToplevel);
  wl_display_flush(impl->display);
  return true;
}

// enable or disable vsync events
void WaylandBackend::SetVsyncEnabled(bool enabled) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  bool wasEnabled = impl->vsyncEnabled;
  impl->vsyncEnabled = enabled;
  if (enabled && !wasEnabled) {
    for (auto& kv : impl->displays) KickLocked(impl, &kv.second);
    if (impl->display) wl_display_flush(impl->display);
  }
}

// kick the display's vsync
void WaylandBackend::KickVsync(int64_t displayId) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  if (!impl->vsyncEnabled) return;
  if (DisplayState* ds = impl->Find(displayId)) {
    KickLocked(impl, ds);
    if (impl->display) wl_display_flush(impl->display);
  }
}

// store the cursor image for the display
bool WaylandBackend::SetCursorSurface(int64_t displayId, const uint8_t* pixelsArgb8888,
                                       int32_t width, int32_t height, int32_t strideBytes,
                                       int32_t hotspotX, int32_t hotspotY) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  DisplayState* ds = impl->Find(displayId);
  if (!ds || !pixelsArgb8888 || width <= 0 || height <= 0) return false;
  klogf("WaylandBackend: display %lld cursor %dx%d hotspot %d,%d",
        static_cast<long long>(displayId), width, height, hotspotX, hotspotY);
  auto& c = ds->cursor;
  c.width = width;
  c.height = height;
  c.hotspotX = hotspotX;
  c.hotspotY = hotspotY;
  c.argb.resize(static_cast<size_t>(width) * height * 4);
  const size_t rowBytes = static_cast<size_t>(width) * 4;
  for (int32_t row = 0; row < height; row++) {
    memcpy(c.argb.data() + static_cast<size_t>(row) * rowBytes,
           pixelsArgb8888 + static_cast<size_t>(row) * strideBytes, rowBytes);
  }
  c.valid = true;
  if (impl->pointerFocus == displayId) {
    impl->cursorApplyPending.insert(displayId);
    if (impl->wakeFd >= 0) {
      uint64_t one = 1;
      if (write(impl->wakeFd, &one, sizeof one) < 0 && errno != EAGAIN) {
        klogf("WaylandBackend: eventfd write FAILED errno=%d", errno);
      }
    }
  }
  return true;
}

// store Android's pointer type for the display and show its host cursor shape
bool WaylandBackend::SetCursorType(int64_t displayId, int32_t pointerType) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  DisplayState* ds = impl->Find(displayId);
  if (!ds) return false;
  if (ds->cursor.pointerType == pointerType) return true;
  klogf("WaylandBackend: display %lld pointer type %d -> %d (shape %u)", static_cast<long long>(displayId),
        ds->cursor.pointerType, pointerType, rhizo::CursorShapeForPointerType(pointerType));
  ds->cursor.pointerType = pointerType;
  if (impl->pointerFocus == displayId) {
    impl->cursorApplyPending.insert(displayId);
    if (impl->wakeFd >= 0) {
      uint64_t one = 1;
      if (write(impl->wakeFd, &one, sizeof one) < 0 && errno != EAGAIN) {
        klogf("WaylandBackend: eventfd write FAILED errno=%d", errno);
      }
    }
  }
  return true;
}

// return whether wp_presentation is bound
bool WaylandBackend::HasPresentation() const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  return impl_->presentation != nullptr;
}

// name the present paths the bound globals give this connection
const char* WaylandBackend::PresentPaths() const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  return PresentPathsName(impl_->dmabuf != nullptr, impl_->shm != nullptr);
}

int WaylandBackend::PresentationClockId() const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  return impl_->presentationClockId;
}

// return whether a format and modifier pair is accepted
bool WaylandBackend::AcceptsBuffer(uint32_t drmFormat, uint64_t modifier) const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  if (impl_->importedPairs.count({drmFormat, modifier})) return true;
  auto it = impl_->modifierTable.find(drmFormat);
  if (it == impl_->modifierTable.end()) return false;
  for (uint64_t m : it->second) {
    if (m == modifier) return true;
  }
  return false;
}

// tell whether wl_shm can present a memfd buffer format
bool WaylandBackend::AcceptsShmFormat(uint32_t drmFormat) const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  return impl_->shm != nullptr && ShmPresentable(impl_->shmFormats, drmFormat);
}

// destroy the buffers cached in the slot
int WaylandBackend::ReleaseSlot(int64_t displayId, int32_t slot) {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  DisplayState* ds = impl_->Find(displayId);
  if (!ds) return 0;
  auto it = ds->bufferCache.find(slot);
  if (it == ds->bufferCache.end()) return 0;
  const bool had = it->second.buffer || it->second.copy[0].buffer || it->second.copy[1].buffer;
  DestroySlotBuffers(it->second);
  const dev_t dev = it->second.dev;
  const ino_t ino = it->second.ino;
  ds->bufferCache.erase(it);
  if (had && composerDebugEnabled()) {
    klogf("WaylandBackend::ReleaseSlot: display %lld slot %d dropped wl_buffer for %u:%llu",
          static_cast<long long>(displayId), slot, static_cast<unsigned>(dev),
          static_cast<unsigned long long>(ino));
  }
  return had ? 1 : 0;
}

// return whether a cached slot was released
bool WaylandBackend::SlotReleased(int64_t displayId, int32_t slot) const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  const DisplayState* ds = impl_->Find(displayId);
  if (!ds) return true;
  auto it = ds->bufferCache.find(slot);
  if (it == ds->bufferCache.end()) return true;
  return it->second.releasedSinceAttach;
}

// list the display's cached slots
std::vector<WaylandSlotInfo> WaylandBackend::DescribeSlots(int64_t displayId) const {
  std::vector<WaylandSlotInfo> out;
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  const DisplayState* ds = impl_->Find(displayId);
  if (!ds) return out;
  for (const auto& kv : ds->bufferCache) {
    WaylandSlotInfo info;
    info.slot = kv.first;
    info.dev = static_cast<uint64_t>(kv.second.dev);
    info.ino = static_cast<uint64_t>(kv.second.ino);
    info.released = kv.second.releasedSinceAttach;
    out.push_back(info);
  }
  return out;
}

// return the refresh interval of the display's output
int64_t WaylandBackend::OutputRefreshNs(int64_t displayId) const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  const DisplayState* ds = impl_->Find(displayId);
  if (!ds || !ds->currentOutput) return 0;
  auto it = impl_->outputs.find(ds->currentOutput);
  if (it == impl_->outputs.end() || it->second.refreshMHz <= 0) return 0;
  return 1000000000000LL / it->second.refreshMHz;
}

// return the modifiers for the DRM format
std::vector<uint64_t> WaylandBackend::NegotiatedModifiers(uint32_t drmFormat) const {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  auto it = impl_->modifierTable.find(drmFormat);
  if (it == impl_->modifierTable.end() || it->second.empty()) {
    return {0 };
  }
  return it->second;
}

// return whether the last present used a dmabuf
bool WaylandBackend::LastPresentWasDmabuf() const { return impl_->lastPresentWasDmabuf; }

// set the toplevel's app id and title and store them
bool WaylandBackend::SetToplevelIdentity(int64_t displayId, const std::string& appId,
                                          const std::string& title) {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  DisplayState* ds = impl->Find(displayId);
  if (!ds || !ds->xdgToplevel) return false;
  xdg_toplevel_set_app_id(ds->xdgToplevel, appId.c_str());
  xdg_toplevel_set_title(ds->xdgToplevel, title.c_str());
  ds->appId = appId;
  ds->title = title;
  wl_display_flush(impl->display);
  klogf("WaylandBackend: display %lld identity set app_id=\"%s\" title=\"%s\"",
        static_cast<long long>(displayId), appId.c_str(), title.c_str());
  return true;
}

// return the display's toplevel info
WaylandToplevelInfo WaylandBackend::GetToplevelInfo(int64_t displayId) const {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  WaylandToplevelInfo info;
  const DisplayState* ds = impl->Find(displayId);
  if (!ds) return info;
  info.found = true;
  info.appId = ds->appId;
  info.title = ds->title;
  info.maximized = ds->maximized;
  info.fullscreen = ds->fullscreen;
  info.activated = ds->activated;
  info.resizing = ds->resizing;
  info.scale120 = ds->appliedScale120;
  if (ds->currentOutput) {
    auto it = impl->outputs.find(ds->currentOutput);
    if (it != impl->outputs.end()) info.outputName = it->second.name;
  }
  return info;
}

// list the outputs with name, scale and size
std::vector<WaylandOutputInfo> WaylandBackend::ListOutputs() const {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  std::vector<WaylandOutputInfo> out;
  out.reserve(impl->outputs.size());
  for (auto& kv : impl->outputs) {
    WaylandOutputInfo info;
    info.name = kv.second.name;
    info.scale = kv.second.scale;
    info.width = kv.second.width;
    info.height = kv.second.height;
    out.push_back(std::move(info));
  }
  return out;
}

// return a snapshot of the connection state
WaylandDebugSnapshot WaylandBackend::DebugSnapshot() const {
  Impl* impl = impl_.get();
  std::lock_guard<std::mutex> lg(impl->mutex_);
  WaylandDebugSnapshot snap;
  snap.connected = impl->connected;
  snap.pumpRunning = impl->pumpRunning;
  snap.connectCount = impl->connectCount;
  snap.presentAttempts = impl->presentAttempts;
  if (impl->display) {
    snap.wlError = wl_display_get_error(impl->display);
    if (snap.wlError == EPROTO) {
      const wl_interface* iface = nullptr;
      snap.protoErrorCode = wl_display_get_protocol_error(impl->display, &iface, nullptr);
      snap.protoErrorInterface = iface ? iface->name : "(unknown)";
    }
  }
  {
    std::lock_guard<std::mutex> lgLog(g_wlLogMutex);
    snap.lastLogMessage = g_wlLastLogMessage;
  }
  snap.failedParamsId = impl->firstError.failedParamsId;
  snap.failedParamsIdWasReused = impl->firstError.failedParamsIdWasReused;
  snap.failedParamsIdPriorAllocAttempt = impl->firstError.failedParamsIdPriorAllocAttempt;
  snap.firstErrorCaptured = impl->firstError.captured;
  snap.firstErrorAtAttempt = impl->firstError.atPresentAttempt;
  snap.firstErrorDisplayId = impl->firstError.displayId;
  snap.firstErrorWidth = impl->firstError.width;
  snap.firstErrorHeight = impl->firstError.height;
  snap.firstErrorStride = impl->firstError.strideBytes;
  snap.firstErrorFd = impl->firstError.dmabufFd;
  snap.firstErrorFormat = impl->firstError.drmFormat;
  snap.firstErrorModifier = impl->firstError.modifier;
  for (auto& kv : impl->displays) {
    WaylandDebugDisplay d;
    d.id = kv.first;
    d.hasSurface = kv.second.surface != nullptr;
    d.hasToplevel = kv.second.xdgToplevel != nullptr;
    d.configured = kv.second.configured;
    snap.displays.push_back(d);
  }
  return snap;
}

}

#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace rhizo {

// dmabuf frame to present
struct WaylandFrame {
  int32_t slot = -1;
  int dmabufFd = -1;
  int32_t width = 0;
  int32_t height = 0;
  int32_t strideBytes = 0;
  uint32_t drmFormat = 0;
  uint64_t modifier = 0;
  int acquireFenceFd = -1;
  int32_t srcX = 0;
  int32_t srcY = 0;
  int32_t srcWidth = 0;
  int32_t srcHeight = 0;
  int32_t fillWidth = 0;
  int32_t fillHeight = 0;
  uint32_t fillRgba = 0;
};

// cached wl_buffer identity of a slot
struct WaylandSlotInfo {
  int32_t slot = -1;
  uint64_t dev = 0;
  uint64_t ino = 0;
  bool released = true;
};

using VsyncCallback = std::function<void(int64_t displayId, int64_t timestampNs)>;

using PresentedCallback = std::function<void(int64_t displayId, int64_t presentedNs,
                                             int64_t refreshNs, bool discarded, int64_t commitNs)>;

using CloseCallback = std::function<void(int64_t displayId)>;

using ResizeCallback =
    std::function<void(int64_t displayId, int32_t width, int32_t height, int32_t scale120)>;

using KeymapCallback = std::function<void(const std::string& keymapText)>;

// input event from the Wayland seat
struct WaylandInputEvent {
  enum class Kind {
    PointerEnter,
    PointerMotion,
    PointerButton,
    PointerAxis,
    KeyboardKey,
    KeyboardModifiers,
    TouchDown,
    TouchMotion,
    TouchUp,
  };
  int64_t displayId = -1;
  Kind kind = Kind::PointerMotion;
  double x = 0;
  double y = 0;
  uint32_t code = 0;
  int32_t value = 0;
  uint32_t timeMsec = 0;
  int64_t queuedNs = 0;
};
using InputCallback = std::function<void(const WaylandInputEvent&)>;

// drag-and-drop payload from the host
struct WaylandDropEvent {
  int64_t displayId = -1;
  std::string mime;
  std::vector<uint8_t> bytes;
  double x = 0;
  double y = 0;
};
using DropCallback = std::function<void(const WaylandDropEvent&)>;

// host selection synced into Android
struct WaylandSelectionEvent {
  std::string mime;
  std::vector<uint8_t> bytes;
  bool carried = true;
};
using SelectionCallback = std::function<void(const WaylandSelectionEvent&)>;

enum class WaylandDecorationMode { kNone, kServerSide, kClientSide };

struct WaylandDebugDisplay {
  int64_t id = -1;
  bool hasSurface = false;
  bool hasToplevel = false;
  bool configured = false;
};

// toplevel state of a display
struct WaylandToplevelInfo {
  bool found = false;
  std::string appId;
  std::string title;
  bool maximized = false;
  bool fullscreen = false;
  bool activated = false;
  bool resizing = false;
  std::string outputName;
  int32_t scale120 = 120;
};

// properties of a wl_output
struct WaylandOutputInfo {
  std::string name;
  int32_t scale = 1;
  int32_t width = 0;
  int32_t height = 0;
};

struct WaylandDebugSnapshot {
  bool connected = false;
  bool pumpRunning = false;
  int64_t connectCount = 0;
  int64_t presentAttempts = 0;
  int wlError = 0;
  int protoErrorCode = 0;
  std::string protoErrorInterface;
  std::string lastLogMessage;
  uint32_t failedParamsId = 0;
  bool failedParamsIdWasReused = false;
  int64_t failedParamsIdPriorAllocAttempt = -1;
  bool firstErrorCaptured = false;
  int64_t firstErrorAtAttempt = -1;
  int64_t firstErrorDisplayId = -1;
  int32_t firstErrorWidth = 0, firstErrorHeight = 0, firstErrorStride = 0;
  int firstErrorFd = -1;
  uint32_t firstErrorFormat = 0;
  uint64_t firstErrorModifier = 0;
  std::vector<WaylandDebugDisplay> displays;
};

// Wayland output backend for composer3
class WaylandBackend {
 public:
  WaylandBackend();
  ~WaylandBackend();

  WaylandBackend(const WaylandBackend&) = delete;
  WaylandBackend& operator=(const WaylandBackend&) = delete;

  void Shutdown();

  void Disconnect();

  bool Connect();

  bool Connected() const;

  bool CreateDisplay(int64_t displayId, const std::string& title, int32_t width = 0,
                     int32_t height = 0);

  void DestroyDisplay(int64_t displayId);

  bool PresentFrame(int64_t displayId, const WaylandFrame& frame);

  bool PresentFrameWhenSignaled(int64_t displayId, const WaylandFrame& frame);
  // read the compositor's maximum window size for the display
  bool DisplayBounds(int64_t displayId, int32_t* width, int32_t* height) const;
  // read the size the compositor asked for during an edge drag
  bool DraggedSize(int64_t displayId, int32_t* width, int32_t* height) const;

  void SetVsyncEnabled(bool enabled);

  void StartEventPump(VsyncCallback vsyncCb, CloseCallback closeCb, ResizeCallback resizeCb,
                       InputCallback inputCb, PresentedCallback presentedCb = nullptr,
                       DropCallback dropCb = nullptr, KeymapCallback keymapCb = nullptr,
                       SelectionCallback selectionCb = nullptr);

  bool StartDrag(int64_t displayId, const std::string& mimeType, std::vector<uint8_t> payload);

  bool HasPresentation() const;
  int PresentationClockId() const;
  const char* PresentPaths() const;

  bool SetSelection(const std::string& mimeType, std::vector<uint8_t> payload);

  void ClearSelection();

  bool ClipboardBound() const;

  WaylandDecorationMode GetDecorationMode(int64_t displayId) const;

  bool ActivateDisplay(int64_t displayId, const std::string& token, bool* held = nullptr);

  bool MinimizeDisplay(int64_t displayId);

  bool AcceptsBuffer(uint32_t drmFormat, uint64_t modifier) const;

  bool AcceptsShmFormat(uint32_t drmFormat) const;

  bool SlotReleased(int64_t displayId, int32_t slot) const;

  int ReleaseSlot(int64_t displayId, int32_t slot);

  std::vector<WaylandSlotInfo> DescribeSlots(int64_t displayId) const;

  int64_t OutputRefreshNs(int64_t displayId) const;

  bool SetToplevelIdentity(int64_t displayId, const std::string& appId,
                            const std::string& title);

  WaylandToplevelInfo GetToplevelInfo(int64_t displayId) const;

  std::vector<WaylandOutputInfo> ListOutputs() const;

  void KickVsync(int64_t displayId);

  bool SetCursorSurface(int64_t displayId, const uint8_t* pixelsArgb8888, int32_t width,
                        int32_t height, int32_t strideBytes, int32_t hotspotX, int32_t hotspotY);

  bool SetCursorType(int64_t displayId, int32_t pointerType);

  std::vector<uint64_t> NegotiatedModifiers(uint32_t drmFormat) const;

  bool LastPresentWasDmabuf() const;

  WaylandDebugSnapshot DebugSnapshot() const;

 public:
  struct Impl;

 private:
  static void DestroyDisplayLocked(Impl* impl, int64_t displayId);

  std::unique_ptr<Impl> impl_;
};

}

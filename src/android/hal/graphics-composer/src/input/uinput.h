#pragma once

#include <cstdint>
#include <map>
#include <mutex>
#include <string>

namespace rhizo {

// virtual uinput devices per display
class UinputDevices {
 public:
  UinputDevices() = default;
  ~UinputDevices();

  UinputDevices(const UinputDevices&) = delete;
  UinputDevices& operator=(const UinputDevices&) = delete;

  void PreCreatePool();

  bool Create(int64_t displayId, int32_t port, int32_t width, int32_t height);

  void Destroy(int64_t displayId);

  bool Resize(int64_t displayId, int32_t port, int32_t width, int32_t height);

  bool Touch(int64_t displayId, int32_t x, int32_t y, bool down);

  bool Scroll(int64_t displayId, bool horizontal, int32_t value120);

  bool Move(int64_t displayId, int32_t dx, int32_t dy);

  bool MoveTo(int64_t displayId, int32_t x, int32_t y);

  bool MoveHome(int64_t displayId);

  bool Key(int64_t displayId, uint32_t evdevCode, bool pressed);

  void PublishMouse(int64_t displayId);

  bool Has(int64_t displayId);

 private:
  static constexpr int32_t kAxisMax = 32767;

  // a uinput device
  struct Device {
    int fd = -1;
    std::string node;
    bool created = false;
    bool touching = false;
  };
  struct PortDevices {
    Device touch;
    Device keyboard;
    Device mouse;
    int64_t boundDisplayId = -1;
    int32_t width = 0;
    int32_t height = 0;
  };

  bool CreatePoolDeviceLocked(int32_t port);
  bool BindLocked(int64_t displayId, int32_t port, int32_t width, int32_t height);

  std::mutex mutex_;
  std::map<int32_t, PortDevices> pool_;
  std::map<int64_t, int32_t> displayToPort_;
  int32_t nextTrackingId_ = 1;
};

}

#include "uinput.h"

#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <utility>

#include <log/log.h>

namespace rhizo {
namespace {

// format a message and write it to the Android log
void klogf(const char* fmt, ...) {
  char buf[320];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  __android_log_print(ANDROID_LOG_INFO, "rhizo-uinput", "%s", buf);
}

constexpr const char* kUinputPath = "/dev/uinput";
constexpr const char* kInputDir = "/dev/input";

constexpr int32_t kMinPort = 0;
constexpr int32_t kMaxPort = 8;

// return the evdev phys string for a port
std::string PortPhys(int32_t port) {
  static const std::string prefix = [] {
    const char* v = getenv("RHIZO_INPUT_PHYS_PREFIX");
    return std::string(v && *v ? v : "rhizo-port-");
  }();
  return prefix + std::to_string(port);
}

// write an input event to the device
bool Emit(int fd, uint16_t type, uint16_t code, int32_t value) {
  struct input_event ev {};
  ev.type = type;
  ev.code = code;
  ev.value = value;
  ssize_t n = write(fd, &ev, sizeof(ev));
  if (n != sizeof(ev)) {
    klogf("Emit(type=%u code=%u value=%d) write FAILED n=%zd errno=%d (%s)", type, code, value, n,
          errno, strerror(errno));
    return false;
  }
  return true;
}

// write a SYN_REPORT event to a device
bool Sync(int fd) { return Emit(fd, EV_SYN, SYN_REPORT, 0); }

// wait for present() to return true
bool WaitInDir(const std::string& dir, const std::function<bool()>& present, int timeout_ms) {
  int in = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
  if (in < 0) return present();
  bool watched = inotify_add_watch(in, dir.c_str(), IN_CREATE | IN_ATTRIB | IN_MOVED_TO) >= 0;
  bool ok = present();
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (!ok && watched) {
    auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                    deadline - std::chrono::steady_clock::now()).count();
    if (left <= 0) break;
    struct pollfd p {in, POLLIN, 0};
    if (poll(&p, 1, static_cast<int>(left)) <= 0) break;
    char buf[4096];
    while (read(in, buf, sizeof(buf)) > 0) {
    }
    ok = present();
  }
  close(in);
  return ok;
}

// wait for the input device node
std::string PublishNode(int fd) {
  char sysname[64] = {0};
  if (ioctl(fd, UI_GET_SYSNAME(sizeof(sysname) - 1), sysname) < 0) {
    klogf("UI_GET_SYSNAME FAILED errno=%d (%s)", errno, strerror(errno));
    return {};
  }
  char classDir[128];
  snprintf(classDir, sizeof(classDir), "/sys/class/input/%s", sysname);
  DIR* d = opendir(classDir);
  if (!d) {
    klogf("opendir(%s) FAILED errno=%d (%s)", classDir, errno, strerror(errno));
    return {};
  }
  std::string eventName;
  while (struct dirent* e = readdir(d)) {
    if (!strncmp(e->d_name, "event", 5)) {
      eventName = e->d_name;
      break;
    }
  }
  closedir(d);
  if (eventName.empty()) {
    klogf("no eventN under %s", classDir);
    return {};
  }

  char devAttr[192];
  snprintf(devAttr, sizeof(devAttr), "%s/%s/dev", classDir, eventName.c_str());
  int af = open(devAttr, O_RDONLY | O_CLOEXEC);
  if (af < 0) {
    klogf("open(%s) FAILED errno=%d (%s)", devAttr, errno, strerror(errno));
    return {};
  }
  char devbuf[32] = {0};
  ssize_t got = read(af, devbuf, sizeof(devbuf) - 1);
  close(af);
  unsigned major = 0, minor = 0;
  if (got <= 0 || sscanf(devbuf, "%u:%u", &major, &minor) != 2) {
    klogf("unparseable %s contents '%s'", devAttr, devbuf);
    return {};
  }

  std::string node = std::string(kInputDir) + "/" + eventName;
  auto published = [&] {
    struct stat st {};
    return lstat(node.c_str(), &st) == 0 && S_ISCHR(st.st_mode) &&
           st.st_rdev == makedev(major, minor);
  };
  static bool fence_missed = false;
  bool arrived = WaitInDir(kInputDir, published, fence_missed ? 0 : 1000);
  fence_missed = !arrived;
  if (!arrived) {
    klogf("no node %s (%u:%u) for sysfs %s: the input fence did not publish it", node.c_str(), major,
          minor, sysname);
    return {};
  }
  klogf("published %s (%u:%u) for sysfs %s", node.c_str(), major, minor, sysname);
  return node;
}

// open the uinput node for writing
int OpenUinput() {
  int fd = open(kUinputPath, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    klogf("open(%s) FAILED errno=%d (%s)", kUinputPath, errno, strerror(errno));
  }
  return fd;
}

// set the phys string and device identity
bool SetupCommon(int fd, const std::string& name, const std::string& phys, uint16_t product) {
  if (ioctl(fd, UI_SET_PHYS, phys.c_str()) < 0) {
    klogf("UI_SET_PHYS(%s) FAILED errno=%d (%s)", phys.c_str(), errno, strerror(errno));
    return false;
  }
  struct uinput_setup us {};
  us.id.bustype = BUS_VIRTUAL;
  us.id.vendor = 0x1209;
  us.id.product = product;
  us.id.version = 1;
  snprintf(us.name, sizeof(us.name), "%s", name.c_str());
  if (ioctl(fd, UI_DEV_SETUP, &us) < 0) {
    klogf("UI_DEV_SETUP(%s) FAILED errno=%d (%s)", name.c_str(), errno, strerror(errno));
    return false;
  }
  return true;
}

// set the range of an absolute axis on a uinput device
bool SetAbs(int fd, uint16_t code, int32_t min, int32_t max) {
  struct uinput_abs_setup as {};
  as.code = code;
  as.absinfo.minimum = min;
  as.absinfo.maximum = max;
  if (ioctl(fd, UI_ABS_SETUP, &as) < 0) {
    klogf("UI_ABS_SETUP(code=%u) FAILED errno=%d (%s)", code, errno, strerror(errno));
    return false;
  }
  return true;
}

// set the mouse event bits and identity
bool SetupMouse(int fd, int32_t port) {
  const std::pair<unsigned long, int> bits[] = {
      {UI_SET_EVBIT, EV_SYN},           {UI_SET_EVBIT, EV_KEY},
      {UI_SET_EVBIT, EV_REL},           {UI_SET_KEYBIT, BTN_LEFT},
      {UI_SET_KEYBIT, BTN_RIGHT},       {UI_SET_KEYBIT, BTN_MIDDLE},
      {UI_SET_RELBIT, REL_X},           {UI_SET_RELBIT, REL_Y},
      {UI_SET_RELBIT, REL_WHEEL},       {UI_SET_RELBIT, REL_HWHEEL},
      {UI_SET_RELBIT, REL_WHEEL_HI_RES}, {UI_SET_RELBIT, REL_HWHEEL_HI_RES},
  };
  for (const auto& [request, bit] : bits) {
    if (ioctl(fd, request, bit) < 0) {
      klogf("mouse setup, port %d: ioctl(0x%lx, %d) FAILED errno=%d (%s)", port, request, bit, errno,
            strerror(errno));
      return false;
    }
  }
  return SetupCommon(fd, "rhizo-mouse-" + std::to_string(port), PortPhys(port),
                     static_cast<uint16_t>(0x0300 + port));
}

}

// destroy and close all of the pool devices and unlink their nodes
UinputDevices::~UinputDevices() {
  std::lock_guard<std::mutex> lg(mutex_);
  for (auto& kv : pool_) {
    for (Device* d : {&kv.second.touch, &kv.second.keyboard, &kv.second.mouse}) {
      if (d->fd >= 0) {
        ioctl(d->fd, UI_DEV_DESTROY);
        close(d->fd);
      }
      if (!d->node.empty()) unlink(d->node.c_str());
    }
  }
  pool_.clear();
}

// create the input devices of all of the ports
void UinputDevices::PreCreatePool() {
  std::lock_guard<std::mutex> lg(mutex_);
  for (int32_t port = kMinPort; port <= kMaxPort; ++port) {
    if (!CreatePoolDeviceLocked(port)) {
      klogf("PreCreatePool: port %d never got a working input device", port);
    }
  }
}

// create the devices for an input port
bool UinputDevices::CreatePoolDeviceLocked(int32_t port) {
  if (pool_.count(port)) return true;

  PortDevices pd;
  const std::string phys = PortPhys(port);

  pd.touch.fd = OpenUinput();
  if (pd.touch.fd < 0) return false;
  int t = pd.touch.fd;
  ioctl(t, UI_SET_EVBIT, EV_SYN);
  ioctl(t, UI_SET_EVBIT, EV_KEY);
  ioctl(t, UI_SET_EVBIT, EV_ABS);
  ioctl(t, UI_SET_KEYBIT, BTN_TOUCH);
  ioctl(t, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
  ioctl(t, UI_SET_ABSBIT, ABS_MT_SLOT);
  ioctl(t, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
  ioctl(t, UI_SET_ABSBIT, ABS_MT_POSITION_X);
  ioctl(t, UI_SET_ABSBIT, ABS_MT_POSITION_Y);
  ioctl(t, UI_SET_ABSBIT, ABS_X);
  ioctl(t, UI_SET_ABSBIT, ABS_Y);
  if (!SetupCommon(t, "rhizo-touch-" + std::to_string(port), phys,
                   static_cast<uint16_t>(0x0100 + port))) {
    close(t);
    return false;
  }
  SetAbs(t, ABS_MT_SLOT, 0, 9);
  SetAbs(t, ABS_MT_TRACKING_ID, 0, 0xffff);
  SetAbs(t, ABS_MT_POSITION_X, 0, kAxisMax);
  SetAbs(t, ABS_MT_POSITION_Y, 0, kAxisMax);
  SetAbs(t, ABS_X, 0, kAxisMax);
  SetAbs(t, ABS_Y, 0, kAxisMax);
  if (ioctl(t, UI_DEV_CREATE) < 0) {
    klogf("UI_DEV_CREATE (touch, port %d) FAILED errno=%d (%s)", port, errno, strerror(errno));
    close(t);
    return false;
  }
  pd.touch.node = PublishNode(t);

  pd.keyboard.fd = OpenUinput();
  if (pd.keyboard.fd >= 0) {
    int k = pd.keyboard.fd;
    ioctl(k, UI_SET_EVBIT, EV_SYN);
    ioctl(k, UI_SET_EVBIT, EV_KEY);
    for (int code = KEY_ESC; code <= KEY_MICMUTE; ++code) ioctl(k, UI_SET_KEYBIT, code);
    if (SetupCommon(k, "rhizo-keyboard-" + std::to_string(port), phys,
                    static_cast<uint16_t>(0x0200 + port)) &&
        ioctl(k, UI_DEV_CREATE) == 0) {
      pd.keyboard.node = PublishNode(k);
    } else {
      klogf("UI_DEV_CREATE (keyboard, port %d) FAILED errno=%d (%s)", port, errno, strerror(errno));
      close(k);
      pd.keyboard.fd = -1;
    }
  }

  pd.mouse.fd = OpenUinput();
  if (pd.mouse.fd >= 0) {
    if (!SetupMouse(pd.mouse.fd, port)) {
      close(pd.mouse.fd);
      pd.mouse.fd = -1;
    } else if (port == kMinPort) {
      if (ioctl(pd.mouse.fd, UI_DEV_CREATE) == 0) {
        pd.mouse.created = true;
        pd.mouse.node = PublishNode(pd.mouse.fd);
      } else {
        klogf("UI_DEV_CREATE (mouse, port %d) FAILED errno=%d (%s)", port, errno, strerror(errno));
        close(pd.mouse.fd);
        pd.mouse.fd = -1;
      }
    }
  }

  klogf("port %d: touch=%s keyboard=%s mouse=%s phys=%s", port,
        pd.touch.node.empty() ? "(unpublished)" : pd.touch.node.c_str(),
        pd.keyboard.node.empty() ? "(unpublished)" : pd.keyboard.node.c_str(),
        !pd.mouse.node.empty() ? pd.mouse.node.c_str()
        : pd.mouse.fd >= 0     ? "(created with its display)"
                               : "(unpublished)",
        phys.c_str());
  pool_[port] = std::move(pd);
  return true;
}

// bind a display to a port's pool devices with its size
bool UinputDevices::BindLocked(int64_t displayId, int32_t port, int32_t width, int32_t height) {
  if (width <= 0 || height <= 0) return false;
  auto it = pool_.find(port);
  if (it == pool_.end()) {
    klogf("bind display %lld -> port %d FAILED: no pool device for that port",
          static_cast<long long>(displayId), port);
    return false;
  }
  it->second.boundDisplayId = displayId;
  it->second.width = width;
  it->second.height = height;
  displayToPort_[displayId] = port;
  return true;
}

// bind a display to a port's pool devices under the lock
bool UinputDevices::Create(int64_t displayId, int32_t port, int32_t width, int32_t height) {
  std::lock_guard<std::mutex> lg(mutex_);
  return BindLocked(displayId, port, width, height);
}

// unbind the display from its input port
void UinputDevices::Destroy(int64_t displayId) {
  std::lock_guard<std::mutex> lg(mutex_);
  auto dit = displayToPort_.find(displayId);
  if (dit == displayToPort_.end()) return;
  if (auto pit = pool_.find(dit->second); pit != pool_.end() && pit->second.boundDisplayId == displayId) {
    pit->second.boundDisplayId = -1;
    Device& mouse = pit->second.mouse;
    if (dit->second != kMinPort && mouse.created) {
      if (ioctl(mouse.fd, UI_DEV_DESTROY) != 0) {
        klogf("UI_DEV_DESTROY (mouse, port %d) FAILED errno=%d (%s)", dit->second, errno, strerror(errno));
      } else {
        mouse.created = false;
        if (!SetupMouse(mouse.fd, dit->second)) {
          close(mouse.fd);
          mouse.fd = -1;
        }
      }
    }
  }
  displayToPort_.erase(dit);
  klogf("display %lld: unbound from its input port", static_cast<long long>(displayId));
}

// create the mouse device of a display's port
void UinputDevices::PublishMouse(int64_t displayId) {
  std::lock_guard<std::mutex> lg(mutex_);
  auto dit = displayToPort_.find(displayId);
  if (dit == displayToPort_.end()) return;
  auto pit = pool_.find(dit->second);
  if (pit == pool_.end()) return;
  Device& mouse = pit->second.mouse;
  if (mouse.fd < 0 || mouse.created) return;
  if (ioctl(mouse.fd, UI_DEV_CREATE) != 0) {
    klogf("display %lld: UI_DEV_CREATE (mouse, port %d) FAILED errno=%d (%s)",
          static_cast<long long>(displayId), dit->second, errno, strerror(errno));
    return;
  }
  mouse.created = true;
  klogf("display %lld: created mouse for port %d", static_cast<long long>(displayId), dit->second);
}

// rebind a display to its port with a new size under the lock
bool UinputDevices::Resize(int64_t displayId, int32_t port, int32_t width, int32_t height) {
  std::lock_guard<std::mutex> lg(mutex_);
  return BindLocked(displayId, port, width, height);
}

// return whether a display is bound to a port
bool UinputDevices::Has(int64_t displayId) {
  std::lock_guard<std::mutex> lg(mutex_);
  return displayToPort_.count(displayId) != 0;
}

namespace {
// scale a value to the axis range
int32_t ScaleToAxis(int32_t v, int32_t extentMinusOne, int32_t axisMax) {
  if (extentMinusOne <= 0) return 0;
  return static_cast<int32_t>((static_cast<int64_t>(v) * axisMax + extentMinusOne / 2) /
                              extentMinusOne);
}
}

// send a touch event to the display
bool UinputDevices::Touch(int64_t displayId, int32_t x, int32_t y, bool down) {
  std::lock_guard<std::mutex> lg(mutex_);
  auto dit = displayToPort_.find(displayId);
  if (dit == displayToPort_.end()) return false;
  PortDevices& pd = pool_[dit->second];
  if (pd.touch.fd < 0) return false;
  int fd = pd.touch.fd;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x > pd.width - 1) x = pd.width - 1;
  if (y > pd.height - 1) y = pd.height - 1;
  const int32_t ax = ScaleToAxis(x, pd.width - 1, kAxisMax);
  const int32_t ay = ScaleToAxis(y, pd.height - 1, kAxisMax);

  Emit(fd, EV_ABS, ABS_MT_SLOT, 0);
  if (down) {
    if (!pd.touch.touching) {
      Emit(fd, EV_ABS, ABS_MT_TRACKING_ID, nextTrackingId_++);
      Emit(fd, EV_KEY, BTN_TOUCH, 1);
      pd.touch.touching = true;
    }
    Emit(fd, EV_ABS, ABS_MT_POSITION_X, ax);
    Emit(fd, EV_ABS, ABS_MT_POSITION_Y, ay);
    Emit(fd, EV_ABS, ABS_X, ax);
    Emit(fd, EV_ABS, ABS_Y, ay);
  } else {
    if (!pd.touch.touching) return true;
    Emit(fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
    Emit(fd, EV_KEY, BTN_TOUCH, 0);
    pd.touch.touching = false;
  }
  return Sync(fd);
}

// send a scroll event to the display
bool UinputDevices::Scroll(int64_t displayId, bool horizontal, int32_t value120) {
  std::lock_guard<std::mutex> lg(mutex_);
  auto dit = displayToPort_.find(displayId);
  if (dit == displayToPort_.end() || value120 == 0) return false;
  const Device& mouse = pool_[dit->second].mouse;
  if (mouse.fd < 0 || !mouse.created) return false;
  const int fd = mouse.fd;
  const int32_t detents = value120 / 120;
  if (horizontal) {
    if (detents != 0) Emit(fd, EV_REL, REL_HWHEEL, detents);
    Emit(fd, EV_REL, REL_HWHEEL_HI_RES, value120);
  } else {
    if (detents != 0) Emit(fd, EV_REL, REL_WHEEL, detents);
    Emit(fd, EV_REL, REL_WHEEL_HI_RES, value120);
  }
  return Sync(fd);
}

// send a relative mouse motion to a display's mouse
bool UinputDevices::Move(int64_t displayId, int32_t dx, int32_t dy) {
  std::lock_guard<std::mutex> lg(mutex_);
  auto dit = displayToPort_.find(displayId);
  if (dit == displayToPort_.end() || (dx == 0 && dy == 0)) return false;
  const Device& mouse = pool_[dit->second].mouse;
  if (mouse.fd < 0 || !mouse.created) return false;
  const int fd = mouse.fd;
  if (dx != 0) Emit(fd, EV_REL, REL_X, dx);
  if (dy != 0) Emit(fd, EV_REL, REL_Y, dy);
  return Sync(fd);
}

// move a display's mouse to its top-left corner
bool UinputDevices::MoveHome(int64_t displayId) {
  std::lock_guard<std::mutex> lg(mutex_);
  auto dit = displayToPort_.find(displayId);
  if (dit == displayToPort_.end()) return false;
  PortDevices& pd = pool_[dit->second];
  if (pd.mouse.fd < 0 || !pd.mouse.created) return false;
  const int32_t slam = -(pd.width + pd.height + 1);
  Emit(pd.mouse.fd, EV_REL, REL_X, slam);
  Emit(pd.mouse.fd, EV_REL, REL_Y, slam);
  return Sync(pd.mouse.fd);
}

// move the mouse pointer on the display
bool UinputDevices::MoveTo(int64_t displayId, int32_t x, int32_t y) {
  std::lock_guard<std::mutex> lg(mutex_);
  auto dit = displayToPort_.find(displayId);
  if (dit == displayToPort_.end()) return false;
  PortDevices& pd = pool_[dit->second];
  if (pd.mouse.fd < 0 || !pd.mouse.created) return false;
  const int fd = pd.mouse.fd;
  const int32_t slam = -(pd.width + pd.height + 1);
  Emit(fd, EV_REL, REL_X, slam);
  Emit(fd, EV_REL, REL_Y, slam);
  Sync(fd);
  if (x != 0) Emit(fd, EV_REL, REL_X, x);
  if (y != 0) Emit(fd, EV_REL, REL_Y, y);
  return Sync(fd);
}

// send a key press or release to a display's keyboard
bool UinputDevices::Key(int64_t displayId, uint32_t evdevCode, bool pressed) {
  std::lock_guard<std::mutex> lg(mutex_);
  auto dit = displayToPort_.find(displayId);
  if (dit == displayToPort_.end()) return false;
  int fd = pool_[dit->second].keyboard.fd;
  if (fd < 0) return false;
  Emit(fd, EV_KEY, static_cast<uint16_t>(evdevCode), pressed ? 1 : 0);
  return Sync(fd);
}

}

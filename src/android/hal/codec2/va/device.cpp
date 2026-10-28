#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <atomic>
#include <mutex>

#include <va/va_drm.h>

#include "va/log.h"
#include "va/runtime.h"
#include "va/vendor.h"

namespace rhizo::c2va {

bool IsVirgl(VADisplay display) { return display && IsVirglVendor(vaQueryVendorString(display)); }

namespace {

// return the mutex serializing display opens and vaTerminate
std::recursive_mutex& LifecycleMutex() {
  static std::recursive_mutex* m = new std::recursive_mutex();
  return *m;
}

std::atomic<int> g_open_count{0};

}

Display::~Display() {
  std::lock_guard<std::recursive_mutex> lifecycle(LifecycleMutex());
  bool opened = major_ != 0;
  if (va_) ForgetComponents(va_);
  if (va_) vaTerminate(va_);
  if (fd_ >= 0) close(fd_);
  if (opened) {
    int left = --g_open_count;
    Logf("VA display closed (%d open)", left);
  }
}

VaDevice& VaDevice::Get() {
  static VaDevice* device = new VaDevice();
  return *device;
}

void VaDevice::SetNode(const std::string& path) {
  std::lock_guard<std::mutex> lock(mutex_);
  node_ = path;
  inherited_fd_ = -1;
}

void VaDevice::SetFd(int fd) {
  std::lock_guard<std::mutex> lock(mutex_);
  inherited_fd_ = fd;
}

int VaDevice::OpenCount() { return g_open_count.load(); }

bool VaDevice::IsOpen() { return OpenCount() > 0; }

// open a display with mutex_ held
std::shared_ptr<Display> VaDevice::OpenLocked(Status* status) {
  std::lock_guard<std::recursive_mutex> lifecycle(LifecycleMutex());
  std::shared_ptr<Display> d(new Display());
  if (inherited_fd_ >= 0) {
    // a new file description gets a separate virgl host context
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", inherited_fd_);
    d->fd_ = open(path, O_RDWR | O_CLOEXEC);
    if (d->fd_ < 0) {
      static std::atomic<bool> told{false};
      if (!told.exchange(true)) {
        LogErrorf("reopen of inherited render node fd %d: %s; displays share its description (one host context)",
                  inherited_fd_, strerror(errno));
      }
      d->fd_ = fcntl(inherited_fd_, F_DUPFD_CLOEXEC, 3);
    }
    if (d->fd_ < 0) {
      LogErrorf("dup of inherited render node fd %d: %s", inherited_fd_, strerror(errno));
      if (status) *status = Status::kVaError;
      return nullptr;
    }
  } else {
    d->fd_ = open(node_.c_str(), O_RDWR | O_CLOEXEC);
    if (d->fd_ < 0) {
      LogErrorf("open %s: %s", node_.c_str(), strerror(errno));
      if (status) *status = Status::kVaError;
      return nullptr;
    }
  }
  d->va_ = vaGetDisplayDRM(d->fd_);
  if (!d->va_) {
    LogErrorf("vaGetDisplayDRM refused the render node");
    if (status) *status = Status::kVaError;
    return nullptr;
  }
  RouteVaMessages(d->va_);
  VAStatus st = vaInitialize(d->va_, &d->major_, &d->minor_);
  if (st != VA_STATUS_SUCCESS) {
    LogErrorf("vaInitialize: %s", vaErrorStr(st));
    vaTerminate(d->va_);
    d->va_ = nullptr;
    d->major_ = 0;
    if (status) *status = Status::kVaError;
    return nullptr;
  }
  const char* vendor = vaQueryVendorString(d->va_);
  d->vendor_ = vendor ? vendor : "";
  int now = ++g_open_count;
  Logf("VA display open: VA-API %d.%d, %s (%d open)", d->major_, d->minor_, d->vendor_.c_str(), now);
  if (status) *status = Status::kOk;
  return d;
}

std::shared_ptr<Display> VaDevice::Open(Status* status) {
  std::lock_guard<std::mutex> lock(mutex_);
  return OpenLocked(status);
}

std::shared_ptr<Display> VaDevice::Acquire(Status* status) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (auto held = shared_.lock()) {
    if (status) *status = Status::kOk;
    return held;
  }
  std::shared_ptr<Display> d = OpenLocked(status);
  if (d) shared_ = d;
  return d;
}

}

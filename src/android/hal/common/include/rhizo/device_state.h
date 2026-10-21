#pragma once
#include <fcntl.h>
#include <sys/inotify.h>
#include <unistd.h>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <fstream>
#include <functional>
#include <map>
#include <string>
#include <thread>
#include <utility>

namespace rhizo_device {

inline constexpr char kStateDir[] = "/vendor/etc/rhizo-device-state";
inline constexpr char kStatePath[] = "/vendor/etc/rhizo-device-state/device-state.conf";

// write a message to the kernel log under a tag
inline void Klog(const char* tag, const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    dprintf(fd, "<5>%s: %s\n", tag, msg);
    close(fd);
  }
}

// read key=value lines from the state file
inline bool ReadState(std::map<std::string, std::string>* out) {
  std::ifstream f(kStatePath);
  if (!f.is_open()) return false;
  std::string line;
  while (std::getline(f, line)) {
    auto eq = line.find('=');
    if (eq == std::string::npos) continue;
    (*out)[line.substr(0, eq)] = line.substr(eq + 1);
  }
  return true;
}

// inotify watch of device state directory
class Watcher {
 public:
  // watch the state directory and start the watcher thread
  explicit Watcher(const char* tag, std::function<void()> on_change)
      : tag_(tag), on_change_(std::move(on_change)) {
    fd_ = inotify_init1(IN_CLOEXEC);
    if (fd_ < 0) {
      LogFailure("inotify_init1");
      return;
    }
    wd_ = inotify_add_watch(fd_, kStateDir,
                             IN_CREATE | IN_CLOSE_WRITE | IN_MOVED_TO | IN_DELETE);
    if (wd_ < 0) {
      LogFailure("inotify_add_watch");
      close(fd_);
      fd_ = -1;
      return;
    }
    running_ = true;
    thread_ = std::thread([this] { Loop(); });
  }

  // stop the thread and close the fd
  ~Watcher() {
    running_ = false;
    if (fd_ >= 0) {
      close(fd_);
    }
    if (thread_.joinable()) thread_.join();
  }

  Watcher(const Watcher&) = delete;
  Watcher& operator=(const Watcher&) = delete;

 private:
  // call on_change_ for each inotify read
  void Loop() {
    alignas(struct inotify_event) char buf[4096];
    while (running_) {
      ssize_t n = read(fd_, buf, sizeof(buf));
      if (n <= 0) break;
      if (running_) on_change_();
    }
  }
  // log a failed call and that watching is disabled
  void LogFailure(const char* what) {
    char msg[160];
    snprintf(msg, sizeof(msg), "%s failed (errno=%d) -- watching disabled", what, errno);
    Klog(tag_, msg);
  }

  const char* tag_;
  std::function<void()> on_change_;
  int fd_ = -1;
  int wd_ = -1;
  std::atomic<bool> running_{false};
  std::thread thread_;
};

}

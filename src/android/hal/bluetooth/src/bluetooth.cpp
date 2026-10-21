#include "aidl/android/hardware/bluetooth/BnBluetoothHci.h"
#include "rhizo/device_state.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace aidl::android::hardware::bluetooth;
using ndk::ScopedAStatus;

namespace {

constexpr char kBtdSocket[] = "/dev/socket/rhizo_bluetooth/btd";
constexpr uint8_t kCommand = 1, kAcl = 2, kSco = 3, kEvent = 4, kIso = 5;

// write a message to the kernel log
void klog(const char* msg) { rhizo_device::Klog("rhizo-bluetooth", msg); }

// write a formatted message to the kernel log
template <typename... Args>
void klogf(const char* fmt, Args... args) {
  char buf[256];
  snprintf(buf, sizeof(buf), fmt, args...);
  klog(buf);
}

// request the controller's user-channel fd from rhizo-btd
int RequestController(int* conn, std::string* why) {
  *conn = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  if (*conn < 0) {
    *why = std::string("socket: ") + strerror(errno);
    return -1;
  }
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, kBtdSocket, sizeof(addr.sun_path) - 1);
  if (connect(*conn, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    *why = std::string("connect ") + kBtdSocket + ": " + strerror(errno);
    return -1;
  }
  if (send(*conn, "open", 4, 0) != 4) {
    *why = std::string("send: ") + strerror(errno);
    return -1;
  }
  char reply[128] = {};
  char ctrl[CMSG_SPACE(sizeof(int))] = {};
  iovec iov{reply, sizeof(reply) - 1};
  msghdr msg{};
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = ctrl;
  msg.msg_controllen = sizeof(ctrl);
  if (recvmsg(*conn, &msg, MSG_CMSG_CLOEXEC) <= 0) {
    *why = std::string("recvmsg: ") + strerror(errno);
    return -1;
  }
  if (strncmp(reply, "ok", 2) != 0) {
    *why = reply;
    return -1;
  }
  for (cmsghdr* c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
    if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
      int fd;
      memcpy(&fd, CMSG_DATA(c), sizeof(fd));
      return fd;
    }
  }
  *why = "reply carried no fd";
  return -1;
}

// HAL for the host's Bluetooth controller
class RhizoBluetoothHci : public BnBluetoothHci {
 public:
  RhizoBluetoothHci()
      : wake_(eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK)), death_(AIBinder_DeathRecipient_new(OnClientDied)) {}

  ScopedAStatus initialize(const std::shared_ptr<IBluetoothHciCallbacks>& callback) override {
    bool stale;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      stale = fd_ >= 0 && callback_ && !AIBinder_isAlive(callback_->asBinder().get());
    }
    if (stale) {
      klog("previous client is gone, closing its controller");
      Shutdown();
    }
    std::lock_guard<std::mutex> lg(mutex_);
    if (fd_ >= 0) {
      callback->initializationComplete(Status::ALREADY_INITIALIZED);
      return ScopedAStatus::ok();
    }
    std::string why;
    fd_ = RequestController(&conn_, &why);
    if (fd_ < 0) {
      klogf("no controller: %s", why.c_str());
      CloseLocked();
      callback->initializationComplete(Status::UNABLE_TO_OPEN_INTERFACE);
      return ScopedAStatus::ok();
    }
    callback_ = callback;
    AIBinder_linkToDeath(callback->asBinder().get(), death_.get(), this);
    running_ = true;
    reader_ = std::thread([this] { ReadLoop(); });
    klogf("controller open on fd %d", fd_);
    callback->initializationComplete(Status::SUCCESS);
    return ScopedAStatus::ok();
  }

  ScopedAStatus close() override {
    Shutdown();
    return ScopedAStatus::ok();
  }

  ScopedAStatus sendHciCommand(const std::vector<uint8_t>& packet) override { return Send(kCommand, packet); }
  ScopedAStatus sendAclData(const std::vector<uint8_t>& packet) override { return Send(kAcl, packet); }
  ScopedAStatus sendScoData(const std::vector<uint8_t>& packet) override { return Send(kSco, packet); }
  ScopedAStatus sendIsoData(const std::vector<uint8_t>& packet) override { return Send(kIso, packet); }

 private:
  // close the controller when its client binder dies
  static void OnClientDied(void* cookie) {
    auto* self = static_cast<RhizoBluetoothHci*>(cookie);
    {
      std::lock_guard<std::mutex> lg(self->mutex_);
      if (self->fd_ < 0 || (self->callback_ && AIBinder_isAlive(self->callback_->asBinder().get()))) return;
    }
    klog("client died, closing controller");
    self->Shutdown();
  }

  // stop the reader and return the controller to rhizo-btd
  void Shutdown() {
    std::thread reader;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      running_ = false;
      const uint64_t one = 1;
      if (write(wake_, &one, sizeof(one)) < 0) klogf("wake write FAILED: %s", strerror(errno));
      reader = std::move(reader_);
    }
    if (reader.joinable()) reader.join();
    uint64_t drained;
    while (read(wake_, &drained, sizeof(drained)) > 0) {}
    std::lock_guard<std::mutex> lg(mutex_);
    CloseLocked();
    klog("controller closed");
  }

  // write an H4 packet
  ScopedAStatus Send(uint8_t type, const std::vector<uint8_t>& packet) {
    std::lock_guard<std::mutex> lg(mutex_);
    if (fd_ < 0) return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    std::vector<uint8_t> out(packet.size() + 1);
    out[0] = type;
    memcpy(out.data() + 1, packet.data(), packet.size());
    if (write(fd_, out.data(), out.size()) != static_cast<ssize_t>(out.size())) {
      klogf("write of type %u, %zu bytes FAILED: %s", type, packet.size(), strerror(errno));
    }
    return ScopedAStatus::ok();
  }

  // read H4 packets into the Bluetooth stack
  void ReadLoop() {
    std::vector<uint8_t> buf(65536);
    while (running_) {
      pollfd fds[2] = {{fd_, POLLIN, 0}, {wake_, POLLIN, 0}};
      if (poll(fds, 2, -1) < 0) {
        if (errno == EINTR) continue;
        klogf("controller poll FAILED: %s", strerror(errno));
        return;
      }
      if (fds[1].revents) return;
      const ssize_t n = read(fd_, buf.data(), buf.size());
      if (n <= 0) {
        if (running_) klogf("controller read ended: %s", n < 0 ? strerror(errno) : "eof");
        return;
      }
      std::vector<uint8_t> packet(buf.begin() + 1, buf.begin() + n);
      switch (buf[0]) {
        case kEvent: callback_->hciEventReceived(packet); break;
        case kAcl: callback_->aclDataReceived(packet); break;
        case kSco: callback_->scoDataReceived(packet); break;
        case kIso: callback_->isoDataReceived(packet); break;
        default: klogf("packet of unknown type %u, %zd bytes", buf[0], n);
      }
    }
  }

  // close the controller fd and the connection
  void CloseLocked() {
    if (fd_ >= 0) ::close(fd_);
    if (conn_ >= 0) ::close(conn_);
    fd_ = -1;
    conn_ = -1;
    if (callback_) AIBinder_unlinkToDeath(callback_->asBinder().get(), death_.get(), this);
    callback_.reset();
  }

  std::mutex mutex_;
  int fd_ = -1;
  int conn_ = -1;
  int wake_;
  std::atomic<bool> running_{false};
  std::thread reader_;
  std::shared_ptr<IBluetoothHciCallbacks> callback_;
  ndk::ScopedAIBinder_DeathRecipient death_;
};

}

int main() {
  klog("main() entered");
  auto hci = ndk::SharedRefBase::make<RhizoBluetoothHci>();
  const std::string instance = std::string(RhizoBluetoothHci::descriptor) + "/default";
  binder_status_t status = AServiceManager_addService(hci->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    klogf("addService FAILED status=%d", status);
    return 1;
  }
  klog("registered, joining thread pool");
  ABinderProcess_setThreadPoolMaxThreadCount(4);
  ABinderProcess_startThreadPool();
  ABinderProcess_joinThreadPool();
  klog("joinThreadPool RETURNED (unexpected)");
  return 0;
}

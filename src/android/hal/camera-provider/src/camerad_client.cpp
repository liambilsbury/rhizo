#include "camerad_client.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>

#include "log.h"

namespace rhizo::camera {

namespace {

constexpr int kBackoffFirstMs = 100;
constexpr int kBackoffMaxMs = 2000;
constexpr uint32_t kMaxDimension = 4096;
constexpr char kDefaultSocket[] = "/dev/socket/rhizo_camera/" RHIZO_CAMERA_SOCKET_NAME;

// read all n bytes from fd
bool ReadFull(int fd, void* buf, size_t n) {
  auto* p = static_cast<uint8_t*>(buf);
  while (n > 0) {
    ssize_t r = recv(fd, p, n, 0);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) return false;
    p += r;
    n -= static_cast<size_t>(r);
  }
  return true;
}

// read and drop n bytes
bool Discard(int fd, uint64_t n) {
  uint8_t sink[16384];
  while (n > 0) {
    size_t chunk = static_cast<size_t>(std::min<uint64_t>(n, sizeof(sink)));
    if (!ReadFull(fd, sink, chunk)) return false;
    n -= chunk;
  }
  return true;
}

// write all n bytes to fd
bool WriteFull(int fd, const void* buf, size_t n) {
  const auto* p = static_cast<const uint8_t*>(buf);
  while (n > 0) {
    ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) return false;
    p += w;
    n -= static_cast<size_t>(w);
  }
  return true;
}

// write a whole message on fd
bool WriteMessage(int fd, uint32_t type, const void* payload, uint32_t length) {
  rhizo_camera_msg_header h{};
  h.magic = RHIZO_CAMERA_MAGIC;
  h.type = type;
  h.length = length;
  std::vector<uint8_t> msg(sizeof(h) + length);
  memcpy(msg.data(), &h, sizeof(h));
  if (length > 0) memcpy(msg.data() + sizeof(h), payload, length);
  return WriteFull(fd, msg.data(), msg.size());
}

// return the NUL-bounded string of a fixed-size protocol field
std::string FieldString(const char* field, size_t size) {
  return std::string(field, strnlen(field, size));
}

// return true for a mode the provider can describe and scale
bool ValidMode(const rhizo_camera_mode& m) {
  return m.width > 0 && m.height > 0 && m.width % 2 == 0 && m.height % 2 == 0 &&
         m.width <= kMaxDimension && m.height <= kMaxDimension && m.fps_num > 0 && m.fps_den > 0;
}

}

// return the buffer the next frame is read into
uint8_t* FrameMailbox::writeBuffer(size_t len) {
  fill_.data.resize(len);
  return fill_.data.data();
}

// make the filled buffer the latest frame
void FrameMailbox::publish(const rhizo_camera_frame& header) {
  std::lock_guard<std::mutex> lk(mu_);
  uint64_t seq = latest_.seq + 1;
  std::swap(fill_, latest_);
  latest_.width = header.width;
  latest_.height = header.height;
  latest_.seq = seq;
  latest_.monotonicNs = header.monotonic_ns;
  fill_.seq = seq;
  hasLatest_ = true;
  cv_.notify_all();
}

// mark the stream started at its negotiated rate
void FrameMailbox::markStarted(uint32_t fpsNum, uint32_t fpsDen) {
  std::lock_guard<std::mutex> lk(mu_);
  started_ = true;
  startedFps_ = fpsDen != 0 ? double(fpsNum) / fpsDen : 0;
  cv_.notify_all();
}

// mark the stream stopped with an error
void FrameMailbox::markStopped(int32_t error) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!stopped_) stopError_ = error;
  stopped_ = true;
  cv_.notify_all();
}

// return the counter interrupt() bumps
uint64_t FrameMailbox::generation() const {
  std::lock_guard<std::mutex> lk(mu_);
  return generation_;
}

// swap the latest frame newer than afterSeq into out
FrameMailbox::Wait FrameMailbox::waitNewer(uint64_t afterSeq, int timeoutMs, uint64_t generation,
                                           Frame* out) {
  std::unique_lock<std::mutex> lk(mu_);
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
  for (;;) {
    if (generation_ != generation) return Wait::kInterrupted;
    if (hasLatest_ && latest_.seq > afterSeq) {
      std::swap(latest_, *out);
      latest_.seq = out->seq;
      hasLatest_ = false;
      return Wait::kFrame;
    }
    if (stopped_) return Wait::kStopped;
    if (cv_.wait_until(lk, deadline) == std::cv_status::timeout) {
      if (hasLatest_ && latest_.seq > afterSeq && generation_ == generation) continue;
      return Wait::kTimeout;
    }
  }
}

// wake a waiter
void FrameMailbox::interrupt() {
  std::lock_guard<std::mutex> lk(mu_);
  generation_++;
  cv_.notify_all();
}

bool FrameMailbox::started() const {
  std::lock_guard<std::mutex> lk(mu_);
  return started_;
}

// return the rate camerad negotiated, or 0 before STARTED
double FrameMailbox::startedFps() const {
  std::lock_guard<std::mutex> lk(mu_);
  return startedFps_;
}

bool FrameMailbox::stopped(int32_t* error) const {
  std::lock_guard<std::mutex> lk(mu_);
  if (error != nullptr) *error = stopError_;
  return stopped_;
}

CameradClient::CameradClient(std::string socketPath, ListCallback onList)
    : socketPath_(std::move(socketPath)), onList_(std::move(onList)) {}

CameradClient::~CameradClient() { stop(); }

// return the socket path from RHIZO_CAMERA_SOCKET, or the default
std::string CameradClient::DefaultSocketPath() {
  const char* env = getenv("RHIZO_CAMERA_SOCKET");
  return (env != nullptr && *env != '\0') ? std::string(env) : std::string(kDefaultSocket);
}

void CameradClient::start() {
  if (thread_.joinable()) return;
  stopping_ = false;
  thread_ = std::thread([this] { run(); });
}

void CameradClient::stop() {
  stopping_ = true;
  {
    std::lock_guard<std::mutex> lk(writeMu_);
    if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
  }
  {
    std::lock_guard<std::mutex> lk(stateMu_);
    stateCv_.notify_all();
  }
  if (thread_.joinable()) thread_.join();
}

// wait up to timeoutMs for the first LIST
bool CameradClient::waitForFirstList(int timeoutMs) {
  std::unique_lock<std::mutex> lk(stateMu_);
  return stateCv_.wait_for(lk, std::chrono::milliseconds(timeoutMs), [this] { return haveList_; });
}

// sleep between connection attempts unless stopping
void CameradClient::sleepBackoff(int ms) {
  std::unique_lock<std::mutex> lk(stateMu_);
  stateCv_.wait_for(lk, std::chrono::milliseconds(ms), [this] { return stopping_.load(); });
}

// connect to the daemon's socket, or return -1
int CameradClient::connectOnce() {
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (socketPath_.size() >= sizeof(addr.sun_path)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(addr.sun_path, socketPath_.c_str(), socketPath_.size() + 1);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    int saved = errno;
    ::close(fd);
    errno = saved;
    return -1;
  }
  return fd;
}

// connect, serve and reconnect with backoff until stopped
void CameradClient::run() {
  int backoff = kBackoffFirstMs;
  bool absentLogged = false;
  while (!stopping_) {
    int fd = connectOnce();
    if (fd < 0) {
      if (!absentLogged) {
        klogf("camerad not reachable at %s (%s); retrying with backoff", socketPath_.c_str(),
              strerror(errno));
        absentLogged = true;
      }
      sleepBackoff(backoff);
      backoff = std::min(backoff * 2, kBackoffMaxMs);
      continue;
    }
    absentLogged = false;
    connections_++;
    connListed_ = false;
    bool greeted;
    {
      std::lock_guard<std::mutex> lk(writeMu_);
      rhizo_camera_hello hello{};
      hello.version = RHIZO_CAMERA_PROTOCOL_VERSION;
      greeted = WriteMessage(fd, RHIZO_CAMERA_HELLO, &hello, sizeof(hello));
      if (greeted) fd_ = fd;
    }
    if (stopping_) shutdown(fd, SHUT_RDWR);
    klogf("connected to camerad at %s", socketPath_.c_str());
    if (greeted) serve(fd);
    {
      std::lock_guard<std::mutex> lk(writeMu_);
      fd_ = -1;
    }
    ::close(fd);
    dropStreams(-ENOTCONN);
    if (stopping_) break;
    if (onList_) onList_({});
    klogf("camerad connection closed; cameras withdrawn until it is back");
    backoff = connListed_ ? kBackoffFirstMs : std::min(backoff * 2, kBackoffMaxMs);
    sleepBackoff(backoff);
  }
}

// read a message header and check it
bool CameradClient::readMessage(int fd, rhizo_camera_msg_header* header) {
  if (!ReadFull(fd, header, sizeof(*header))) return false;
  if (header->magic != RHIZO_CAMERA_MAGIC) {
    klogf("camerad sent bad magic 0x%08x; dropping the connection", header->magic);
    return false;
  }
  if (header->length > RHIZO_CAMERA_MAX_PAYLOAD) {
    klogf("camerad sent a %u-byte payload, past the %u-byte limit; dropping the connection",
          header->length, RHIZO_CAMERA_MAX_PAYLOAD);
    return false;
  }
  return true;
}

// read messages until the connection drops or breaks the protocol
void CameradClient::serve(int fd) {
  for (;;) {
    rhizo_camera_msg_header h{};
    if (!readMessage(fd, &h)) return;
    switch (h.type) {
      case RHIZO_CAMERA_LIST:
        if (!handleList(fd, h.length)) return;
        break;
      case RHIZO_CAMERA_FRAME:
        if (!handleFrame(fd, h.length)) return;
        break;
      case RHIZO_CAMERA_STARTED: {
        rhizo_camera_started s{};
        if (h.length != sizeof(s)) {
          klogf("camerad STARTED is %u bytes, want %zu; dropping the connection", h.length, sizeof(s));
          return;
        }
        if (!ReadFull(fd, &s, sizeof(s))) return;
        if (auto mb = mailbox(s.stream_id)) {
          klogf("stream %u started at %ux%u %u/%u fps", s.stream_id, s.width, s.height, s.fps_num,
                s.fps_den);
          mb->markStarted(s.fps_num, s.fps_den);
        }
        break;
      }
      case RHIZO_CAMERA_STOPPED: {
        rhizo_camera_stopped s{};
        if (h.length != sizeof(s)) {
          klogf("camerad STOPPED is %u bytes, want %zu; dropping the connection", h.length, sizeof(s));
          return;
        }
        if (!ReadFull(fd, &s, sizeof(s))) return;
        std::shared_ptr<FrameMailbox> mb;
        {
          std::lock_guard<std::mutex> lk(stateMu_);
          auto it = streams_.find(s.stream_id);
          if (it != streams_.end()) {
            mb = it->second;
            streams_.erase(it);
          }
        }
        if (mb) {
          klogf("stream %u stopped by camerad (error %d)", s.stream_id, s.error);
          mb->markStopped(s.error != 0 ? s.error : -EPIPE);
        }
        break;
      }
      default:
        if (!Discard(fd, h.length)) return;
        break;
    }
  }
}

// read a LIST and pass its cameras to the callback
bool CameradClient::handleList(int fd, uint32_t length) {
  rhizo_camera_list list{};
  if (length < sizeof(list)) {
    klogf("camerad LIST is %u bytes, shorter than its header; dropping the connection", length);
    return false;
  }
  if (!ReadFull(fd, &list, sizeof(list))) return false;
  if (list.version != RHIZO_CAMERA_PROTOCOL_VERSION) {
    klogf("camerad speaks protocol %u, want %u; dropping the connection", list.version,
          RHIZO_CAMERA_PROTOCOL_VERSION);
    return false;
  }
  uint64_t want = sizeof(list) + static_cast<uint64_t>(list.count) * sizeof(rhizo_camera_info);
  if (list.count > RHIZO_CAMERA_MAX_CAMERAS || want != length) {
    klogf("camerad LIST of %u cameras is %u bytes, want %llu (at most %u cameras); dropping the connection",
          list.count, length, static_cast<unsigned long long>(want), RHIZO_CAMERA_MAX_CAMERAS);
    return false;
  }
  std::vector<rhizo_camera_info> infos(list.count);
  if (list.count > 0 && !ReadFull(fd, infos.data(), infos.size() * sizeof(rhizo_camera_info))) return false;

  std::vector<HostCamera> cameras;
  for (const rhizo_camera_info& info : infos) {
    if (info.mode_count > RHIZO_CAMERA_MAX_MODES) {
      klogf("camerad listed %u modes for one camera, more than %u; dropping the connection",
            info.mode_count, RHIZO_CAMERA_MAX_MODES);
      return false;
    }
    HostCamera cam;
    cam.key = FieldString(info.key, sizeof(info.key));
    cam.name = FieldString(info.name, sizeof(info.name));
    cam.facing = info.facing;
    for (uint32_t i = 0; i < info.mode_count; i++) {
      const rhizo_camera_mode& m = info.modes[i];
      if (!ValidMode(m)) continue;
      cam.modes.push_back(HostMode{m.width, m.height, m.fps_num, m.fps_den});
    }
    if (cam.key.empty() || cam.modes.empty()) {
      klogf("skipping listed camera '%s': %s", cam.name.c_str(),
            cam.key.empty() ? "no key" : "no usable mode");
      continue;
    }
    cameras.push_back(std::move(cam));
  }
  connListed_ = true;
  {
    std::lock_guard<std::mutex> lk(stateMu_);
    haveList_ = true;
    stateCv_.notify_all();
  }
  if (onList_) onList_(cameras);
  return true;
}

// read a FRAME into its stream's mailbox or drop it
bool CameradClient::handleFrame(int fd, uint32_t length) {
  rhizo_camera_frame f{};
  if (length < sizeof(f)) {
    klogf("camerad FRAME is %u bytes, shorter than its header; dropping the connection", length);
    return false;
  }
  if (!ReadFull(fd, &f, sizeof(f))) return false;
  uint64_t image = static_cast<uint64_t>(f.width) * f.height * 3 / 2;
  if (f.width == 0 || f.height == 0 || f.width % 2 != 0 || f.height % 2 != 0 || f.width > kMaxDimension ||
      f.height > kMaxDimension || sizeof(f) + image != length) {
    klogf("camerad FRAME %ux%u does not fit its %u-byte payload; dropping the connection", f.width,
          f.height, length);
    return false;
  }
  std::shared_ptr<FrameMailbox> mb = mailbox(f.stream_id);
  if (!mb) return Discard(fd, image);
  uint8_t* dst = mb->writeBuffer(static_cast<size_t>(image));
  if (!ReadFull(fd, dst, static_cast<size_t>(image))) return false;
  mb->publish(f);
  return true;
}

// send a whole message to the daemon
bool CameradClient::sendMessage(uint32_t type, const void* payload, uint32_t length) {
  std::lock_guard<std::mutex> lk(writeMu_);
  if (fd_ < 0) return false;
  if (!WriteMessage(fd_, type, payload, length)) {
    shutdown(fd_, SHUT_RDWR);
    return false;
  }
  return true;
}

// open a host camera mode into mailbox
bool CameradClient::open(const std::string& key, const HostMode& mode,
                         const std::shared_ptr<FrameMailbox>& mailbox) {
  if (key.empty() || key.size() >= RHIZO_CAMERA_KEY_LEN) return false;
  rhizo_camera_open o{};
  memcpy(o.key, key.data(), key.size());
  o.stream_id = mailbox->streamId();
  o.width = mode.width;
  o.height = mode.height;
  o.fps_num = mode.fpsNum;
  o.fps_den = mode.fpsDen;
  {
    std::lock_guard<std::mutex> lk(stateMu_);
    streams_[o.stream_id] = mailbox;
  }
  if (!sendMessage(RHIZO_CAMERA_OPEN, &o, sizeof(o))) {
    std::lock_guard<std::mutex> lk(stateMu_);
    streams_.erase(o.stream_id);
    return false;
  }
  return true;
}

// release a stream opened with open()
void CameradClient::close(uint32_t streamId) {
  {
    std::lock_guard<std::mutex> lk(stateMu_);
    streams_.erase(streamId);
  }
  rhizo_camera_close c{};
  c.stream_id = streamId;
  sendMessage(RHIZO_CAMERA_CLOSE, &c, sizeof(c));
}

// stop all of the open streams with an error
void CameradClient::dropStreams(int32_t error) {
  std::map<uint32_t, std::shared_ptr<FrameMailbox>> gone;
  {
    std::lock_guard<std::mutex> lk(stateMu_);
    gone.swap(streams_);
  }
  for (auto& [id, mb] : gone) mb->markStopped(error);
}

std::shared_ptr<FrameMailbox> CameradClient::mailbox(uint32_t streamId) {
  std::lock_guard<std::mutex> lk(stateMu_);
  auto it = streams_.find(streamId);
  return it == streams_.end() ? nullptr : it->second;
}

}

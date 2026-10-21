#include "stream_export.h"

#include <errno.h>
#include <log/log.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

namespace rhizo {
namespace {

// write a message to the Android log
void klog(const char* msg) {
  __android_log_print(ANDROID_LOG_INFO, "rhizo-stream-export", "%s", msg);
}
// format a message and write it to the Android log
void klogf(const char* fmt, ...) {
  char buf[320];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  klog(buf);
}

// return the monotonic time in nanoseconds
int64_t NowNanos() {
  struct timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

constexpr int kAckWaitMs = 200;

constexpr int64_t kReconnectCooldownNs = 2000000000LL;

}

struct StreamExportBackend::Impl {
  int fd = -1;
  uint64_t nextSeq = 1;
  int64_t lastConnectAttemptNs = 0;
  bool everTriedConnect = false;
};

// create the backend state
StreamExportBackend::StreamExportBackend() : impl_(new Impl()) {}

// disconnect and free the backend state
StreamExportBackend::~StreamExportBackend() {
  Disconnect();
  delete impl_;
}

// return whether the export socket is open
bool StreamExportBackend::Connected() const {
  return impl_->fd >= 0;
}

// connect to the stream socket
bool StreamExportBackend::EnsureConnected() {
  if (impl_->fd >= 0) return true;
  const char* path = getenv("RHIZO_STREAM_SOCKET");
  if (!path || !*path) {
    return false;
  }
  const int64_t now = NowNanos();
  if (impl_->everTriedConnect && now - impl_->lastConnectAttemptNs < kReconnectCooldownNs) {
    return false;
  }
  impl_->everTriedConnect = true;
  impl_->lastConnectAttemptNs = now;

  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    klogf("EnsureConnected: socket() failed errno=%d (%s)", errno, strerror(errno));
    return false;
  }
  struct sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof(addr.sun_path)) {
    klogf("EnsureConnected: RHIZO_STREAM_SOCKET path too long: %s", path);
    close(fd);
    return false;
  }
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  if (connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0) {
    klogf("EnsureConnected: connect(%s) failed errno=%d (%s) -- no consumer, staying headless",
          path, errno, strerror(errno));
    close(fd);
    return false;
  }
  impl_->fd = fd;
  impl_->nextSeq = 1;
  klogf("EnsureConnected: connected to %s, presenting via the stream export path", path);
  return true;
}

// close the export socket
void StreamExportBackend::Disconnect() {
  if (impl_->fd >= 0) {
    close(impl_->fd);
    impl_->fd = -1;
  }
}

// send the frame and wait for its ack
bool StreamExportBackend::Present(const StreamFrame& frame) {
  if (impl_->fd < 0) return false;

  rhizo_stream_frame_header hdr{};
  hdr.magic = RHIZO_STREAM_FRAME_MAGIC;
  hdr.version = RHIZO_STREAM_PROTOCOL_VERSION;
  hdr.seq = impl_->nextSeq++;
  hdr.presented_ns = frame.presentedNs;
  hdr.width = frame.width;
  hdr.height = frame.height;
  hdr.drm_fourcc = frame.drmFormat;
  hdr.modifier = frame.modifier;
  hdr.stride_bytes = frame.strideBytes;
  hdr.offset_bytes = frame.offsetBytes;

  struct iovec iov{};
  iov.iov_base = &hdr;
  iov.iov_len = sizeof(hdr);

  char cbuf[CMSG_SPACE(sizeof(int))];
  memset(cbuf, 0, sizeof(cbuf));
  struct msghdr msg{};
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = cbuf;
  msg.msg_controllen = sizeof(cbuf);

  struct cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(cmsg), &frame.dmabufFd, sizeof(int));

  if (sendmsg(impl_->fd, &msg, MSG_NOSIGNAL) != static_cast<ssize_t>(sizeof(hdr))) {
    klogf("Present: sendmsg failed errno=%d (%s) seq=%llu -- dropping the connection",
          errno, strerror(errno), (unsigned long long)hdr.seq);
    Disconnect();
    return false;
  }

  struct pollfd pfd{impl_->fd, POLLIN, 0};
  int pr = poll(&pfd, 1, kAckWaitMs);
  if (pr <= 0) {
    klogf("Present: no release ack for seq=%llu within %dms -- dropping the connection",
          (unsigned long long)hdr.seq, kAckWaitMs);
    Disconnect();
    return false;
  }
  rhizo_stream_release_ack ack{};
  ssize_t n = recv(impl_->fd, &ack, sizeof(ack), MSG_WAITALL);
  if (n != static_cast<ssize_t>(sizeof(ack)) || ack.magic != RHIZO_STREAM_ACK_MAGIC ||
      ack.seq != hdr.seq) {
    klogf("Present: malformed or mismatched release ack for seq=%llu (read n=%zd) -- "
          "dropping the connection", (unsigned long long)hdr.seq, n);
    Disconnect();
    return false;
  }
  return true;
}

}

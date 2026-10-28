#ifndef RHIZO_CAMERA_CAMERAD_CLIENT_H
#define RHIZO_CAMERA_CAMERAD_CLIENT_H

// read the host camera list and stream frames from rhizo-camerad

#include <stddef.h>
#include <stdint.h>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "rhizo/camera_protocol.h"

namespace rhizo::camera {

// a host camera size at its highest frame rate
struct HostMode {
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t fpsNum = 0;
  uint32_t fpsDen = 1;
};

// a host camera and its modes
struct HostCamera {
  std::string key;
  std::string name;
  uint32_t facing = RHIZO_CAMERA_FACING_EXTERNAL;
  std::vector<HostMode> modes;
};

// a packed I420 host frame
struct Frame {
  std::vector<uint8_t> data;
  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t seq = 0;
  int64_t monotonicNs = 0;
};

// hand a stream's frames from the reader to a session
class FrameMailbox {
 public:
  enum class Wait { kFrame, kTimeout, kStopped, kInterrupted };

  explicit FrameMailbox(uint32_t streamId) : streamId_(streamId) {}
  uint32_t streamId() const { return streamId_; }

  uint8_t* writeBuffer(size_t len);
  void publish(const rhizo_camera_frame& header);
  void markStarted(uint32_t fpsNum, uint32_t fpsDen);
  void markStopped(int32_t error);

  uint64_t generation() const;
  Wait waitNewer(uint64_t afterSeq, int timeoutMs, uint64_t generation, Frame* out);
  void interrupt();
  bool started() const;
  double startedFps() const;
  bool stopped(int32_t* error = nullptr) const;

 private:
  const uint32_t streamId_;
  mutable std::mutex mu_;
  std::condition_variable cv_;
  Frame fill_;
  Frame latest_;
  bool hasLatest_ = false;
  bool started_ = false;
  double startedFps_ = 0;
  bool stopped_ = false;
  int32_t stopError_ = 0;
  uint64_t generation_ = 0;
};

// connect to rhizo-camerad and reconnect with backoff
class CameradClient {
 public:
  using ListCallback = std::function<void(const std::vector<HostCamera>&)>;

  CameradClient(std::string socketPath, ListCallback onList);
  ~CameradClient();

  void start();
  void stop();
  bool waitForFirstList(int timeoutMs);
  bool open(const std::string& key, const HostMode& mode, const std::shared_ptr<FrameMailbox>& mailbox);
  void close(uint32_t streamId);
  uint32_t nextStreamId() { return nextStreamId_.fetch_add(1); }
  int connectionCount() const { return connections_.load(); }

  static std::string DefaultSocketPath();

 private:
  void run();
  int connectOnce();
  void serve(int fd);
  bool readMessage(int fd, rhizo_camera_msg_header* header);
  bool handleList(int fd, uint32_t length);
  bool handleFrame(int fd, uint32_t length);
  bool sendMessage(uint32_t type, const void* payload, uint32_t length);
  void dropStreams(int32_t error);
  std::shared_ptr<FrameMailbox> mailbox(uint32_t streamId);
  void sleepBackoff(int ms);

  const std::string socketPath_;
  const ListCallback onList_;
  std::thread thread_;
  std::atomic<bool> stopping_{false};
  std::atomic<int> connections_{0};
  std::atomic<uint32_t> nextStreamId_{1};
  bool connListed_ = false;

  std::mutex writeMu_;
  int fd_ = -1;

  std::mutex stateMu_;
  std::condition_variable stateCv_;
  bool haveList_ = false;
  std::map<uint32_t, std::shared_ptr<FrameMailbox>> streams_;
};

}

#endif

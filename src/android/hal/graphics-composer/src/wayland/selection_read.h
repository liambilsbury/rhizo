#pragma once

#include <poll.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace rhizo_selection {

enum class Read { kComplete, kTimedOut, kFailed };

// return the monotonic time in milliseconds
inline int64_t NowMs() {
  struct timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// read the selection from fd into out
inline Read ReadPayload(int fd, int64_t timeoutMs, std::vector<uint8_t>* out, int* err) {
  const int64_t deadline = NowMs() + timeoutMs;
  uint8_t buf[65536];
  *err = 0;
  while (true) {
    const int64_t remaining = deadline - NowMs();
    if (remaining <= 0) return Read::kTimedOut;
    struct pollfd pfd{fd, POLLIN, 0};
    int pr = poll(&pfd, 1, static_cast<int>(remaining));
    if (pr < 0) {
      if (errno == EINTR) continue;
      *err = errno;
      return Read::kFailed;
    }
    if (pr == 0) return Read::kTimedOut;
    ssize_t r = read(fd, buf, sizeof buf);
    if (r < 0) {
      if (errno == EINTR) continue;
      *err = errno;
      return Read::kFailed;
    }
    if (r == 0) return Read::kComplete;
    out->insert(out->end(), buf, buf + r);
  }
}

// outcome of a finished selection read
enum class Verdict { kReport, kUncarried, kSuperseded };

// sequence numbers for selection events
class Sequencer {
 public:
  // start a new read and return its sequence number
  uint64_t Begin() { return ++newest_; }
  // report the verdict for a finished read
  Verdict Judge(Read outcome, uint64_t seq) const {
    if (seq != newest_.load()) return Verdict::kSuperseded;
    return outcome == Read::kComplete ? Verdict::kReport : Verdict::kUncarried;
  }

 private:
  std::atomic<uint64_t> newest_{0};
};

using ReadDone = std::function<void(Verdict verdict, Read outcome, int err, std::vector<uint8_t>&& bytes)>;

// read the file descriptor on a new thread
inline void ReadInThread(Sequencer& seqr, std::mutex& lock, int fd, uint64_t seq, int64_t timeoutMs,
                         ReadDone done) {
  std::thread([&seqr, &lock, fd, seq, timeoutMs, done = std::move(done)]() mutable {
    std::vector<uint8_t> bytes;
    int err = 0;
    const Read outcome = ReadPayload(fd, timeoutMs, &bytes, &err);
    close(fd);
    std::lock_guard<std::mutex> lg(lock);
    done(seqr.Judge(outcome, seq), outcome, err, std::move(bytes));
  }).detach();
}

}

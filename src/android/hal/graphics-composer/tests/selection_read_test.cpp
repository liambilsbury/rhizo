#include "selection_read.h"

#include <unistd.h>

#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>

using rhizo_selection::Read;
using rhizo_selection::Verdict;

static int failures = 0;

// print the result of a named check and count failures
static void check(bool ok, const char* what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
}

struct Result {
  std::mutex m;
  std::condition_variable cv;
  bool done = false;
  Verdict verdict = Verdict::kSuperseded;
  Read outcome = Read::kFailed;
  std::string bytes;

  // return a callback that stores the read result
  rhizo_selection::ReadDone Hook() {
    return [this](Verdict v, Read o, int, std::vector<uint8_t>&& b) {
      std::lock_guard<std::mutex> lg(m);
      verdict = v;
      outcome = o;
      bytes.assign(b.begin(), b.end());
      done = true;
      cv.notify_all();
    };
  }
  // wait up to 10 seconds for the read to finish
  bool Wait() {
    std::unique_lock<std::mutex> lk(m);
    return cv.wait_for(lk, std::chrono::seconds(10), [this] { return done; });
  }
};

// run the selection read checks
int main() {
  std::mutex lock;
  {
    rhizo_selection::Sequencer seqr;
    int p[2];
    if (pipe(p) != 0) return 2;
    Result r;
    const uint64_t seq = seqr.Begin();
    rhizo_selection::ReadInThread(seqr, lock, p[0], seq, 2000, r.Hook());
    if (write(p[1], "rhizo-clip", 10) != 10) return 2;
    close(p[1]);
    check(r.Wait() && r.verdict == Verdict::kReport && r.bytes == "rhizo-clip",
          "a source that writes and closes is reported, every byte");
  }
  {
    rhizo_selection::Sequencer seqr;
    int p[2];
    if (pipe(p) != 0) return 2;
    Result r;
    const uint64_t seq = seqr.Begin();
    rhizo_selection::ReadInThread(seqr, lock, p[0], seq, 2000, r.Hook());
    seqr.Begin();
    if (write(p[1], "rhizo-old", 9) != 9) return 2;
    close(p[1]);
    check(r.Wait() && r.outcome == Read::kComplete && r.verdict == Verdict::kSuperseded,
          "a complete read of a selection a newer event superseded is not reported");
  }
  {
    rhizo_selection::Sequencer seqr;
    int p[2];
    if (pipe(p) != 0) return 2;
    Result r;
    const uint64_t seq = seqr.Begin();
    if (write(p[1], "rhizo-old", 9) != 9) return 2;
    close(p[1]);
    {
      std::lock_guard<std::mutex> lg(lock);
      rhizo_selection::ReadInThread(seqr, lock, p[0], seq, 2000, r.Hook());
      seqr.Begin();
    }
    check(r.Wait() && r.verdict == Verdict::kSuperseded,
          "the verdict is taken under the lock, after any event begun while it was held");
  }
  {
    rhizo_selection::Sequencer seqr;
    int p[2];
    if (pipe(p) != 0) return 2;
    if (write(p[1], "rhizo", 5) != 5) return 2;
    Result r;
    rhizo_selection::ReadInThread(seqr, lock, p[0], seqr.Begin(), 300, r.Hook());
    check(r.Wait() && r.outcome == Read::kTimedOut && r.verdict == Verdict::kUncarried,
          "the newest selection's read that times out is uncarried, its partial bytes not reported");
    close(p[1]);
  }
  {
    rhizo_selection::Sequencer seqr;
    int p[2];
    if (pipe(p) != 0) return 2;
    Result r;
    rhizo_selection::ReadInThread(seqr, lock, p[0], seqr.Begin(), 300, r.Hook());
    check(r.Wait() && r.verdict == Verdict::kUncarried && r.bytes.empty(),
          "a source that sends nothing is no 0-byte clip");
    close(p[1]);
  }
  {
    rhizo_selection::Sequencer seqr;
    int p[2];
    if (pipe(p) != 0) return 2;
    if (write(p[1], "rhizo", 5) != 5) return 2;
    Result r;
    const uint64_t seq = seqr.Begin();
    rhizo_selection::ReadInThread(seqr, lock, p[0], seq, 300, r.Hook());
    seqr.Begin();
    check(r.Wait() && r.verdict == Verdict::kSuperseded,
          "a superseded read that times out says nothing about the host now");
    close(p[1]);
  }
  if (failures) {
    std::printf("%d failure(s)\n", failures);
    return 1;
  }
  std::printf("all 6 passed\n");
  return 0;
}

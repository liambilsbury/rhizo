#include "rtd_link.h"

#include <poll.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <string>
#include <vector>

using rhizo_rtd::RtdLink;

static int failures = 0;
static int64_t now_ns = 1000000000;
static std::vector<std::string> logged;
static bool deny_connects = false;
static int connect_calls = 0;

// print the result of a named check and count failures
static void check(bool ok, const char* what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
}

// return the fake monotonic time
static int64_t FakeNow() { return now_ns; }

// record a log line
static void Record(const char* msg) { logged.push_back(msg); }

// count the connect and fail it with EACCES while denying
static int FakeConnect(int fd, const struct sockaddr* addr, socklen_t len) {
  connect_calls++;
  if (deny_connects) {
    errno = EACCES;
    return -1;
  }
  return connect(fd, addr, len);
}

// return how many logged lines contain the text
static int CountLogged(const std::string& text) {
  int n = 0;
  for (const auto& line : logged) n += line.find(text) != std::string::npos;
  return n;
}

// bind a seqpacket socket at the path
static int Bind(const std::string& path, bool listening) {
  unlink(path.c_str());
  int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  struct sockaddr_un addr {};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
  if (fd < 0 || bind(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0) return -1;
  if (listening && listen(fd, 4) != 0) return -1;
  return fd;
}

// accept a pending connection within a second, or return -1
static int Accept(int listener) {
  struct pollfd p {listener, POLLIN, 0};
  if (poll(&p, 1, 1000) != 1) return -1;
  return accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
}

// read the next message within the timeout, or return an empty string
static std::string Next(int conn, int timeout_ms = 1000) {
  struct pollfd p {conn, POLLIN, 0};
  if (poll(&p, 1, timeout_ms) != 1) return "";
  char buf[512];
  ssize_t n = recv(conn, buf, sizeof(buf), MSG_DONTWAIT);
  return n > 0 ? std::string(buf, n) : "";
}

// run the rtd link checks
int main() {
  char dir[] = "/tmp/rtd-link-XXXXXX";
  if (!mkdtemp(dir)) {
    std::printf("FAIL could not make a temporary directory\n");
    return 1;
  }
  const std::string path = std::string(dir) + "/rtd";

  RtdLink link(path, Record, FakeNow, FakeConnect);
  check(CountLogged("RHIZO_MARKER power_sessions=off reason=absent errno=2") == 1,
        "a missing socket logs power_sessions=off reason=absent once at start");
  check(!link.TryConnect(), "the link is down while the socket is missing");

  int listener = Bind(path, true);
  check(listener >= 0, "the fake rhizo-rtd listens");
  check(!link.TryConnect(), "no connect is tried within 100 ms of the last attempt");
  now_ns += rhizo_rtd::kRetryNs;
  check(link.TryConnect(), "the link connects once 100 ms have passed");
  check(CountLogged("RHIZO_MARKER power_sessions=on socket=" + path) == 1, "the connect logs power_sessions=on");
  int conn = Accept(listener);
  check(conn >= 0, "the fake rhizo-rtd accepts the link");

  link.Open(7, 100, 10123, 16666667, {100, 101});
  link.Target(7, 11111111);
  link.Threads(7, {100, 102});
  link.SetPaused(7, true);
  link.Actual(7, {4000000, 5000000});
  check(Next(conn) == "open 7 100 10123 16666667 100,101", "open carries the tgid, uid, target and tids");
  check(Next(conn) == "target 7 11111111", "target is sent as it is");
  check(Next(conn) == "threads 7 100,102", "threads is sent as it is");
  check(Next(conn) == "pause 7", "pause is sent as it is");
  check(Next(conn) == "actual 7 4000000,5000000", "actual carries the durations");

  close(conn);
  close(listener);
  listener = Bind(path, true);
  check(listener >= 0, "the fake rhizo-rtd restarts on the same path");
  link.Actual(7, {6000000});
  conn = Accept(listener);
  check(conn >= 0, "a failed send reconnects at once, without waiting 100 ms");
  check(Next(conn) == "open 7 100 10123 11111111 100,102", "the new connection reopens the session with its latest target and tids");
  check(Next(conn) == "pause 7", "the reopened session is paused again");
  check(Next(conn) == "actual 7 6000000", "the failed actual is sent once after the reopen");
  check(Next(conn, 200).empty(), "nothing else is sent on the new connection");
  check(CountLogged("rtd send FAILED") == 1, "the failed send is logged once");
  check(CountLogged("RHIZO_MARKER power_sessions=on") == 2, "the reconnect logs power_sessions=on again");
  check(CountLogged("rtd link reopened 1 session(s)") == 1, "the reopen is logged with the session count");

  close(conn);
  close(listener);
  unlink(path.c_str());
  link.SetPaused(7, false);
  check(CountLogged("RHIZO_MARKER power_sessions=off reason=absent") == 2,
        "a reconnect that finds the socket gone logs power_sessions=off again");
  link.Target(7, 8333333);
  int connected = 0;
  for (int i = 0; i < 20; i++) {
    now_ns += rhizo_rtd::kRetryNs;
    connected += link.TryConnect();
  }
  check(connected == 0, "the link stays down through 20 attempts while rhizo-rtd is gone");
  check(CountLogged("power_sessions=off") == 2, "repeated failed connects with the same reason log nothing more");

  int refusing = Bind(path, false);
  check(refusing >= 0, "a socket file with no listener stands in for a stopped rhizo-rtd");
  now_ns += rhizo_rtd::kRetryNs;
  check(!link.TryConnect(), "a refused connect leaves the link down");
  check(CountLogged("RHIZO_MARKER power_sessions=off reason=Connection refused errno=111") == 1,
        "a new off reason is logged once");
  now_ns += rhizo_rtd::kRetryNs;
  link.TryConnect();
  check(CountLogged("power_sessions=off") == 3, "the same refused reason is not logged again");
  close(refusing);

  listener = Bind(path, true);
  check(listener >= 0, "the fake rhizo-rtd comes back");
  check(!link.TryConnect(), "the link does not connect within 100 ms of the last attempt");
  now_ns += rhizo_rtd::kRetryNs;
  check(link.TryConnect(), "the link connects after 100 ms");
  conn = Accept(listener);
  check(Next(conn) == "open 7 100 10123 8333333 100,102", "changes made while rhizo-rtd was gone are in the reopen");
  check(Next(conn, 200).empty(), "a resumed session is reopened without a pause");

  check(link.Close(7), "close reports the session was open");
  check(Next(conn) == "close 7", "close is sent as it is");
  check(!link.Close(7), "a second close sends nothing");
  link.Actual(7, {1000000});
  link.Target(7, 1);
  check(Next(conn, 200).empty(), "a closed session sends nothing");
  check(link.SessionCount() == 0, "a closed session is forgotten");

  close(conn);
  close(listener);
  listener = Bind(path, true);
  link.Open(8, 200, 10124, 16666667, {200});
  conn = Accept(listener);
  check(Next(conn) == "open 8 200 10124 16666667 200", "an open whose send fails is sent once on the new connection");
  check(Next(conn, 200).empty(), "the closed session is not reopened");

  close(conn);
  close(listener);
  listener = Bind(path, true);
  deny_connects = true;
  int before = connect_calls;
  link.Actual(8, {2000000});
  check(connect_calls == before + 1, "a failed send tries one connect at once, which is denied");
  check(CountLogged("RHIZO_MARKER power_sessions=off reason=Permission denied errno=13") == 1,
        "a denied connect logs power_sessions=off reason=Permission denied once");
  before = connect_calls;
  for (int i = 0; i < 99; i++) {
    now_ns += rhizo_rtd::kRetryNs;
    link.TryConnect();
    link.Actual(8, {2000000});
  }
  check(connect_calls == before, "no connect is tried within 10 s of a denied one");
  now_ns += rhizo_rtd::kRetryNs;
  check(!link.TryConnect(), "a connect 10 s after the denial is denied again");
  check(connect_calls == before + 1, "the connect is tried once the 10 s have passed");
  check(CountLogged("reason=Permission denied") == 1, "the same denial is not logged again");
  deny_connects = false;
  now_ns += rhizo_rtd::kRetryNs;
  check(!link.TryConnect(), "a denial keeps the 10 s interval after the socket would accept");
  now_ns += rhizo_rtd::kDeniedRetryNs;
  check(link.TryConnect(), "the link connects 10 s after the last denied attempt");
  conn = Accept(listener);
  check(Next(conn) == "open 8 200 10124 16666667 200", "the session is reopened after the denial");
  close(conn);
  close(listener);
  unlink(path.c_str());
  link.Target(8, 16666667);
  before = connect_calls;
  now_ns += rhizo_rtd::kRetryNs;
  link.TryConnect();
  check(connect_calls == before + 1, "a missing socket after a denial is tried again within 100 ms");

  rmdir(dir);
  std::printf("%s\n", failures ? "rtd link checks FAILED" : "rtd link checks passed");
  return failures ? 1 : 0;
}

#include "headroom_link.h"

#include <poll.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using rhizo_headroom::HeadroomLink;

static int failures = 0;
static int64_t now_ns = 1000000000;
static std::vector<std::string> logged;
static bool deny_connects = false;
static int connect_calls = 0;
static int listener = -1;
static int conn = -1;
static std::string first_reply;

// print the result of a named check and count failures
static void check(bool ok, const char* what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
}

// return the fake monotonic time
static int64_t FakeNow() { return now_ns; }

// record a log line
static void Record(const char* msg) { logged.push_back(msg); }

// accept a pending connection within a second, or return -1
static int Accept(int fd) {
  struct pollfd p {fd, POLLIN, 0};
  if (poll(&p, 1, 1000) != 1) return -1;
  return accept4(fd, nullptr, nullptr, SOCK_CLOEXEC);
}

// count the connect and fake the daemon side of it
static int FakeConnect(int fd, const struct sockaddr* addr, socklen_t len) {
  connect_calls++;
  if (deny_connects) {
    errno = EACCES;
    return -1;
  }
  int rc = connect(fd, addr, len);
  int err = errno;
  if (rc == 0 && listener >= 0) {
    if (conn >= 0) close(conn);
    conn = Accept(listener);
    if (conn >= 0 && !first_reply.empty()) send(conn, first_reply.data(), first_reply.size(), MSG_NOSIGNAL);
  }
  errno = err;
  return rc;
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

// read the next message within the timeout, or return an empty string
static std::string Next(int fd, int timeout_ms = 1000) {
  struct pollfd p {fd, POLLIN, 0};
  if (poll(&p, 1, timeout_ms) != 1) return "";
  char buf[512];
  ssize_t n = recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
  return n > 0 ? std::string(buf, n) : "";
}

// send the fake daemon's reply
static void Reply(const std::string& msg) { send(conn, msg.data(), msg.size(), MSG_NOSIGNAL); }

// stop the fake daemon
static void StopDaemon(const std::string& path, bool remove) {
  if (conn >= 0) close(conn);
  if (listener >= 0) close(listener);
  conn = listener = -1;
  if (remove) unlink(path.c_str());
}

// run the headroom link checks
int main() {
  char dir[] = "/tmp/headroom-link-XXXXXX";
  if (!mkdtemp(dir)) {
    std::printf("FAIL could not make a temporary directory\n");
    return 1;
  }
  const std::string sock_dir = std::string(dir) + "/rhizo_headroom";
  const std::string path = sock_dir + "/headroomd";
  if (mkdir(sock_dir.c_str(), 0755) != 0) {
    std::printf("FAIL could not make the socket directory\n");
    return 1;
  }

  HeadroomLink link(path, Record, FakeNow, FakeConnect);
  check(CountLogged("RHIZO_MARKER power_headroom=off reason=absent errno=2") == 1,
        "a missing socket logs power_headroom=off reason=absent once at start");
  int before = connect_calls;
  check(link.Supported(), "headroom is supported while the socket directory is bound, before the daemon listens");
  check(std::isnan(link.Query(true, 1000)), "a request while the link is down answers NaN");
  check(connect_calls == before, "no connect is tried within 100 ms of the last attempt");

  listener = Bind(path, true);
  check(listener >= 0, "the fake rhizo-headroomd listens");
  link.Supported();
  check(connect_calls == before, "no connect is tried within 100 ms of the last attempt after the daemon listens");
  now_ns += rhizo_headroom::kRetryNs;
  check(link.Supported(), "headroom stays supported once the daemon listens");
  check(connect_calls == before + 1, "asking whether headroom is supported connects once 100 ms have passed");
  check(CountLogged("RHIZO_MARKER power_headroom=on socket=" + path) == 1, "the connect logs power_headroom=on");
  check(conn >= 0, "the fake rhizo-headroomd accepts the link");
  check(Next(conn, 200).empty(), "asking whether headroom is supported sends nothing");

  Reply("ok 42.50 1000 10");
  check(link.Query(true, 1000) == 42.5f, "an ok reply answers its headroom");
  check(Next(conn) == "headroom average 1000", "an average request names its type and window");
  Reply("nan no-data");
  check(std::isnan(link.Query(false, 500)), "a nan reply answers NaN");
  check(Next(conn) == "headroom min 500", "a min request names its type and window");
  check(CountLogged("headroom link FAILED") == 0, "a nan reply keeps the link up");

  StopDaemon(path, false);
  listener = Bind(path, true);
  check(listener >= 0, "the fake rhizo-headroomd restarts on the same path");
  first_reply = "ok 61.00 1000 10";
  before = connect_calls;
  float value = link.Query(true, 1000);
  check(connect_calls == before + 1, "a failed send reconnects at once, without waiting 100 ms");
  check(value == 61.0f, "the request is answered on the new connection");
  check(Next(conn) == "headroom average 1000", "the request is sent once on the new connection");
  check(Next(conn, 200).empty(), "nothing else is sent on the new connection");
  check(CountLogged("headroom link FAILED send errno=32") == 1, "the failed send is logged once");
  check(CountLogged("RHIZO_MARKER power_headroom=on") == 2, "the reconnect logs power_headroom=on again");

  StopDaemon(path, true);
  first_reply.clear();
  check(std::isnan(link.Query(true, 1000)), "a request after the daemon is gone answers NaN");
  check(CountLogged("RHIZO_MARKER power_headroom=off reason=absent") == 2,
        "a reconnect that finds the socket gone logs power_headroom=off again");
  check(link.Supported(), "headroom stays supported while the daemon is gone");
  before = connect_calls;
  int answered = 0;
  for (int i = 0; i < 20; i++) {
    now_ns += rhizo_headroom::kRetryNs;
    answered += !std::isnan(link.Query(true, 1000));
  }
  check(answered == 0, "every request answers NaN while the daemon is gone");
  check(connect_calls == before + 20, "a down link tries one connect per 100 ms");
  check(CountLogged("power_headroom=off") == 2, "repeated failed connects with the same reason log nothing more");

  int refusing = Bind(path, false);
  check(refusing >= 0, "a socket file with no listener stands in for a stopped rhizo-headroomd");
  now_ns += rhizo_headroom::kRetryNs;
  check(std::isnan(link.Query(true, 1000)), "a refused connect answers NaN");
  check(CountLogged("RHIZO_MARKER power_headroom=off reason=Connection refused errno=111") == 1,
        "a new off reason is logged once");
  close(refusing);

  listener = Bind(path, true);
  first_reply = "ok 75.00 1000 10";
  check(std::isnan(link.Query(true, 1000)), "the link does not connect within 100 ms of the last attempt");
  now_ns += rhizo_headroom::kRetryNs;
  check(link.Query(true, 1000) == 75.0f, "the link connects after 100 ms and answers");
  check(Next(conn) == "headroom average 1000", "the request is sent on the new connection");

  before = connect_calls;
  Reply("bogus");
  check(std::isnan(link.Query(true, 1000)), "a malformed reply answers NaN");
  check(CountLogged("headroom link FAILED bogus errno=0") == 1, "a malformed reply is logged and closes the link");
  check(connect_calls == before, "a malformed reply does not reconnect at once");
  Next(conn);
  now_ns += rhizo_headroom::kRetryNs;
  first_reply = "ok 80.00 1000 10";
  check(link.Query(true, 1000) == 80.0f, "the next request after 100 ms connects again and answers");
  Next(conn);
  check(std::isnan(link.Query(true, 1000)), "a reply that never comes answers NaN within the timeout");
  check(CountLogged("headroom link FAILED recv errno=11") == 1, "the missed reply is logged and closes the link");

  StopDaemon(path, false);
  listener = Bind(path, true);
  deny_connects = true;
  now_ns += rhizo_headroom::kRetryNs;
  before = connect_calls;
  check(std::isnan(link.Query(true, 1000)), "a denied connect answers NaN");
  check(connect_calls == before + 1, "the connect is tried once and denied");
  check(CountLogged("RHIZO_MARKER power_headroom=off reason=Permission denied errno=13") == 1,
        "a denied connect logs power_headroom=off reason=Permission denied once");
  before = connect_calls;
  for (int i = 0; i < 99; i++) {
    now_ns += rhizo_headroom::kRetryNs;
    link.Supported();
    link.Query(true, 1000);
  }
  check(connect_calls == before, "no connect is tried within 10 s of a denied one");
  now_ns += rhizo_headroom::kRetryNs;
  link.Query(true, 1000);
  check(connect_calls == before + 1, "the connect is tried once the 10 s have passed");
  check(CountLogged("reason=Permission denied") == 1, "the same denial is not logged again");
  deny_connects = false;
  first_reply = "ok 90.00 1000 10";
  now_ns += rhizo_headroom::kRetryNs;
  check(std::isnan(link.Query(true, 1000)), "a denial keeps the 10 s interval after the socket would accept");
  now_ns += rhizo_headroom::kDeniedRetryNs;
  check(link.Query(true, 1000) == 90.0f, "the link connects 10 s after the last denied attempt and answers");
  StopDaemon(path, true);

  const std::string off_path = std::string(dir) + "/withheld/headroomd";
  HeadroomLink off(off_path, Record, FakeNow, FakeConnect);
  int supported = 0;
  for (int i = 0; i < 20; i++) {
    now_ns += rhizo_headroom::kRetryNs;
    supported += off.Supported();
  }
  check(supported == 0, "with no socket directory, as when the capability is off, headroom is never supported");
  check(CountLogged("power_headroom=off reason=absent") == 3, "a link with no socket directory logs its off reason once");

  rmdir(sock_dir.c_str());
  rmdir(dir);
  std::printf("%s\n", failures ? "headroom link checks FAILED" : "headroom link checks passed");
  return failures ? 1 : 0;
}

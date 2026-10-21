#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define RC_USAGE 96
#define RC_UNREACHABLE 97
#define RC_NO_TRAILER 98

static const char TRAILER[] = "\0RHIZO_PROBE_RC=";
#define TRAILER_LEN (sizeof(TRAILER) - 1)

// return the monotonic time in seconds
static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// set the receive and send timeouts of a socket
static void set_timeout(int fd, double secs) {
  if (secs < 0.001) secs = 0.001;
  struct timeval tv;
  tv.tv_sec = (time_t)secs;
  tv.tv_usec = (suseconds_t)((secs - (double)tv.tv_sec) * 1e6);
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

// find the last trailer in the buffer
static ssize_t rfind_trailer(const char *buf, size_t len) {
  if (len < TRAILER_LEN) return -1;
  for (size_t i = len - TRAILER_LEN + 1; i-- > 0;) {
    if (memcmp(buf + i, TRAILER, TRAILER_LEN) == 0) return (ssize_t)i;
  }
  return -1;
}

// check for a complete trailer
static int trailer_complete(const char *buf, size_t len, ssize_t at) {
  if (at < 0) return 0;
  for (size_t i = (size_t)at + TRAILER_LEN; i < len; i++) {
    if (buf[i] == '\0') return 1;
  }
  return 0;
}

// send a command to rhizo-probed
int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: rhizo-probe-client <sock> <timeout-s> <command...>\n");
    return RC_USAGE;
  }
  const char *sock_path = argv[1];
  double timeout_s = atof(argv[2]);
  double deadline = now_s() + timeout_s;

  size_t cmd_len = 0;
  for (int i = 3; i < argc; i++) cmd_len += strlen(argv[i]) + 1;
  char *cmd = malloc(cmd_len + 1);
  if (!cmd) { fprintf(stderr, "RHIZO_PROBE_UNREACHABLE: out of memory\n"); return RC_UNREACHABLE; }
  cmd[0] = '\0';
  for (int i = 3; i < argc; i++) {
    if (i > 3) strcat(cmd, " ");
    strcat(cmd, argv[i]);
  }
  strcat(cmd, "\n");
  size_t cmd_bytes = strlen(cmd);

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (strlen(sock_path) >= sizeof(addr.sun_path)) {
    fprintf(stderr, "RHIZO_PROBE_UNREACHABLE: socket path exceeds sun_path (%zu bytes)\n",
            strlen(sock_path));
    return RC_UNREACHABLE;
  }
  strcpy(addr.sun_path, sock_path);

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) { fprintf(stderr, "RHIZO_PROBE_UNREACHABLE: %s\n", strerror(errno)); return RC_UNREACHABLE; }
  double connect_budget = deadline - now_s();
  set_timeout(fd, connect_budget > 0.5 ? connect_budget : 0.5);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    fprintf(stderr, "RHIZO_PROBE_UNREACHABLE: %s\n", strerror(errno));
    close(fd);
    return RC_UNREACHABLE;
  }

  size_t off = 0;
  while (off < cmd_bytes) {
    ssize_t n = write(fd, cmd + off, cmd_bytes - off);
    if (n <= 0) break;
    off += (size_t)n;
  }
  shutdown(fd, SHUT_WR);

  size_t cap = 65536, len = 0;
  char *buf = malloc(cap);
  if (!buf) { fprintf(stderr, "RHIZO_PROBE_UNREACHABLE: out of memory\n"); close(fd); return RC_UNREACHABLE; }
  int timed_out = 0;
  for (;;) {
    double remaining = deadline - now_s();
    if (remaining <= 0) { timed_out = 1; break; }
    set_timeout(fd, remaining);
    if (len + 65536 > cap) {
      cap *= 2;
      char *nb = realloc(buf, cap);
      if (!nb) { timed_out = 1; break; }
      buf = nb;
    }
    ssize_t n = read(fd, buf + len, 65536);
    if (n == 0) break;
    if (n < 0) {
      if (errno == EINTR) continue;
      timed_out = 1;
      break;
    }
    len += (size_t)n;
    ssize_t at = rfind_trailer(buf, len);
    if (trailer_complete(buf, len, at)) break;
  }
  close(fd);

  ssize_t at = rfind_trailer(buf, len);
  if (timed_out && at < 0) {
    fwrite(buf, 1, len, stdout);
    fflush(stdout);
    fprintf(stderr, "RHIZO_PROBE_TIMEOUT: no completion trailer before deadline\n");
    return RC_NO_TRAILER;
  }
  if (at < 0) {
    fwrite(buf, 1, len, stdout);
    fflush(stdout);
    fprintf(stderr, "RHIZO_PROBE_NO_TRAILER: connection closed without a completion marker\n");
    return RC_NO_TRAILER;
  }

  fwrite(buf, 1, (size_t)at, stdout);
  fflush(stdout);

  const char *rc_str = buf + at + TRAILER_LEN;
  size_t rc_max = len - (size_t)at - TRAILER_LEN;
  char rcbuf[32];
  size_t i = 0;
  while (i < rc_max && i < sizeof(rcbuf) - 1 && rc_str[i] != '\0') { rcbuf[i] = rc_str[i]; i++; }
  rcbuf[i] = '\0';
  if (i == 0) return RC_NO_TRAILER;
  char *end = NULL;
  long rc = strtol(rcbuf, &end, 10);
  if (end == rcbuf || (end && *end != '\0')) return RC_NO_TRAILER;
  return (int)rc;
}

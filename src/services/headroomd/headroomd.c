#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

typedef uint64_t u64;
typedef uint32_t u32;

#define P_MS 100
#define SELINUX_MODE_EXIT 78
#define RING_N 101
#define CPU_NEED 8
#define CPU_FIELDS 10
#define FIELD_MAX (1ULL << 60)
#define REQ_MAX 64
#define WINDOW_DIGITS 9
#define REPLY_MAX 64
#define MAX_CLIENTS 32
#define STATUS_EVERY 10
#define STATS_BUF 512

#define INIT_CTX "u:r:init:s0"
#define POWER_CTX "u:r:rhizo_power:s0"
#define HEADROOMD_CTX "u:r:rhizo_headroomd:s0"
#define ENTERING_ENV "RHIZO_HEADROOMD_ENTERING"

// return the boottime clock in nanoseconds
static u64 boottime_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_BOOTTIME, &ts);
	return (u64)ts.tv_sec * 1000000000ULL + (u64)ts.tv_nsec;
}

static int g_quiet;

// print "[rhizo-headroomd] " and fmt to stderr unless g_quiet is set
static void logmsg(const char *fmt, ...)
{
	va_list ap;
	if (g_quiet)
		return;
	va_start(ap, fmt);
	fputs("[rhizo-headroomd] ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	fflush(stderr);
}

// read a file into a buffer
static int read_text(const char *path, char *buf, size_t cap)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	size_t n = 0;
	for (;;) {
		ssize_t r = read(fd, buf + n, cap - 1 - n);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			break;
		n += (size_t)r;
		if (n >= cap - 1)
			break;
	}
	close(fd);
	buf[n] = 0;
	return (int)n;
}

// write a string to an existing file
static int write_text(const char *path, const char *s)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	size_t n = strlen(s);
	ssize_t r = write(fd, s, n);
	int e = errno;
	close(fd);
	if (r != (ssize_t)n) {
		errno = r < 0 ? e : EIO;
		return -1;
	}
	return 0;
}

// parse the aggregate cpu line of /proc/stat
static int parse_cpu_line(const char *text, u64 *taken, u64 *idle)
{
	if (strncmp(text, "cpu", 3) || (text[3] != ' ' && text[3] != '\t'))
		return -1;
	u64 v[CPU_FIELDS] = { 0 };
	int nf = 0;
	const char *p = text + 3;
	for (;;) {
		while (*p == ' ' || *p == '\t')
			p++;
		if (*p == '\n' || *p == 0)
			break;
		if (!isdigit((unsigned char)*p))
			return -1;
		char *end;
		errno = 0;
		unsigned long long x = strtoull(p, &end, 10);
		if (errno || x > FIELD_MAX || (*end != ' ' && *end != '\t' && *end != '\n' && *end != 0))
			return -1;
		if (nf < CPU_FIELDS)
			v[nf] = x;
		nf++;
		p = end;
	}
	if (nf < CPU_NEED)
		return -1;
	*taken = v[0] + v[1] + v[2] + v[5] + v[6] + v[7];
	*idle = v[3] + v[4];
	return 0;
}

// count the per-cpu lines of /proc/stat text
static u32 count_cpus(const char *text)
{
	u32 n = 0;
	for (const char *p = text; p && *p; p = strchr(p, '\n'), p = p ? p + 1 : NULL)
		if (!strncmp(p, "cpu", 3) && isdigit((unsigned char)p[3]))
			n++;
	return n;
}

// return whether ncpu changed or taken went below last_taken
static int counters_restart(u32 ncpu, u32 last_ncpu, u64 taken, u64 last_taken)
{
	return ncpu != last_ncpu || taken < last_taken;
}

// compute the available and total wall-clock ticks
static void wall_counters(u64 taken, u64 ns, u32 ncpu, long hz, u64 *avail, u64 *total)
{
	*total = (u64)((unsigned __int128)ns * ncpu * (u64)hz / 1000000000ULL);
	*avail = *total > taken ? *total - taken : 0;
}

struct sample {
	u64 avail, total, ns;
};

struct ring {
	struct sample s[RING_N];
	u64 pushed;
};

enum { T_MIN, T_AVERAGE };
enum { A_OK, A_NODATA, A_RESET };

// result of a headroom query
struct answer {
	int kind;
	double value;
	u32 window_ms, steps;
};

// add a sample to the ring
static void ring_push(struct ring *r, u64 avail, u64 total, u64 ns)
{
	struct sample *s = &r->s[r->pushed % RING_N];
	s->avail = avail;
	s->total = total;
	s->ns = ns;
	r->pushed++;
}

// return the number of complete steps
static u32 ring_steps(const struct ring *r)
{
	if (!r->pushed)
		return 0;
	return (u32)((r->pushed < RING_N ? r->pushed : RING_N) - 1);
}

// return the ring sample at distance back
static const struct sample *ring_at(const struct ring *r, u32 back)
{
	return &r->s[(r->pushed - 1 - back) % RING_N];
}

// return the absolute difference of two values
static u64 absdiff(int64_t a, int64_t b)
{
	return a > b ? (u64)(a - b) : (u64)(b - a);
}

// clamp a percentage to the range 0 to 100
static double clamp_pct(double v)
{
	if (v < 0.0)
		return 0.0;
	if (v > 100.0)
		return 100.0;
	return v;
}

// compute the headroom of a step
static int step_headroom(const struct sample *a, const struct sample *b, double *out)
{
	if (b->total <= a->total)
		return -1;
	*out = 100.0 * ((double)b->avail - (double)a->avail) / (double)(b->total - a->total);
	return 0;
}

// compute the headroom over a time window
static void ring_query(const struct ring *r, int type, u64 window_ms, struct answer *a)
{
	memset(a, 0, sizeof *a);
	u64 w = window_ms < P_MS ? P_MS : window_ms;
	if (w > (RING_N - 1) * P_MS)
		w = (RING_N - 1) * P_MS;
	u32 have = ring_steps(r);
	if (have == 0) {
		a->kind = A_NODATA;
		return;
	}
	const struct sample *newest = ring_at(r, 0);
	int64_t target = (int64_t)newest->ns - (int64_t)(w * 1000000ULL);
	u32 back = 1;
	u64 best = absdiff((int64_t)ring_at(r, 1)->ns, target);
	for (u32 b = 2; b <= have; b++) {
		u64 d = absdiff((int64_t)ring_at(r, b)->ns, target);
		if (d < best) {
			best = d;
			back = b;
		}
	}
	const struct sample *start = ring_at(r, back);
	if (newest->ns <= start->ns) {
		a->kind = A_RESET;
		return;
	}
	double lowest = 0.0;
	for (u32 j = 0; j < back; j++) {
		double h;
		if (step_headroom(ring_at(r, j + 1), ring_at(r, j), &h)) {
			a->kind = A_RESET;
			return;
		}
		if (j == 0 || h < lowest)
			lowest = h;
	}
	double mean;
	if (step_headroom(start, newest, &mean)) {
		a->kind = A_RESET;
		return;
	}
	a->kind = A_OK;
	a->steps = back;
	a->window_ms = (u32)((newest->ns - start->ns + 500000ULL) / 1000000ULL);
	a->value = clamp_pct(type == T_MIN ? lowest : mean);
}

// parse a "headroom min|average <ms>" line
static int parse_request(const char *req, size_t len, int *type, u64 *window_ms)
{
	char b[REQ_MAX];
	if (len == 0 || len >= sizeof b || memchr(req, 0, len))
		return -1;
	memcpy(b, req, len);
	if (b[len - 1] == '\n')
		len--;
	b[len] = 0;
	const char *p = b;
	if (strncmp(p, "headroom ", 9))
		return -1;
	p += 9;
	if (!strncmp(p, "min ", 4)) {
		*type = T_MIN;
		p += 4;
	} else if (!strncmp(p, "average ", 8)) {
		*type = T_AVERAGE;
		p += 8;
	} else {
		return -1;
	}
	size_t nd = 0;
	u64 w = 0;
	for (; isdigit((unsigned char)p[nd]); nd++)
		w = w * 10 + (u64)(p[nd] - '0');
	if (nd == 0 || nd > WINDOW_DIGITS || p[nd] != '\0')
		return -1;
	*window_ms = w;
	return 0;
}

// format the reply text for a result
static size_t format_reply(const struct answer *a, char *out, size_t cap)
{
	int n;
	if (a->kind == A_OK)
		n = snprintf(out, cap, "ok %.2f %u %u", a->value, a->window_ms, a->steps);
	else if (a->kind == A_NODATA)
		n = snprintf(out, cap, "nan no-data");
	else
		n = snprintf(out, cap, "nan counter-reset");
	return n > 0 && (size_t)n < cap ? (size_t)n : 0;
}

// parse a packet and format the reply
static size_t handle_request(const struct ring *r, const char *req, size_t len, char *out, size_t cap)
{
	int type;
	u64 w;
	if (parse_request(req, len, &type, &w))
		return (size_t)snprintf(out, cap, "err bad-request");
	struct answer a;
	ring_query(r, type, w, &a);
	return format_reply(&a, out, cap);
}

// return in_sandbox && ctx == POWER_CTX
static int peer_allowed(const char *ctx, int in_sandbox)
{
	return in_sandbox && !strcmp(ctx, POWER_CTX);
}

// trim trailing newlines and spaces from a context
static void trim_ctx(char *s)
{
	size_t l = strlen(s);
	while (l && (s[l - 1] == '\n' || s[l - 1] == ' '))
		s[--l] = 0;
}

// read /proc/<pid>/<leaf> into buf
static int proc_read(int pid, const char *leaf, char *buf, size_t cap)
{
	char path[64];
	snprintf(path, sizeof path, "/proc/%d/%s", pid, leaf);
	return read_text(path, buf, cap);
}

// read the inode of a pid namespace link
static int read_pid_ns(const char *path, u64 *ino)
{
	char link[64];
	ssize_t n = readlink(path, link, sizeof link - 1);
	if (n < 0)
		return -1;
	link[n] = 0;
	unsigned long long v;
	if (sscanf(link, "pid:[%llu]", &v) != 1)
		return -1;
	*ino = v;
	return 0;
}

// parse the last integer on the key line of text
static int status_last(const char *text, const char *key, int *out)
{
	size_t kl = strlen(key);
	for (const char *p = text; p; p = strchr(p, '\n'), p = p ? p + 1 : NULL) {
		if (strncmp(p, key, kl))
			continue;
		const char *e = strchr(p, '\n');
		if (!e)
			e = p + strlen(p);
		const char *q = e;
		while (q > p + kl && (q[-1] == ' ' || q[-1] == '\t'))
			q--;
		const char *b = q;
		while (b > p + kl && isdigit((unsigned char)b[-1]))
			b--;
		if (b == q)
			return -1;
		*out = atoi(b);
		return 0;
	}
	return -1;
}

// check that the peer pid namespace is not the host's and pid 1 runs INIT_CTX
static int peer_sandbox(int pid, char *why, size_t cap)
{
	char path[64];
	u64 ino, self;
	snprintf(path, sizeof path, "/proc/%d/ns/pid", pid);
	if (read_pid_ns(path, &ino)) {
		snprintf(why, cap, "failed to read the pid namespace of %d (%s)", pid, strerror(errno));
		return -1;
	}
	if (read_pid_ns("/proc/self/ns/pid", &self)) {
		snprintf(why, cap, "failed to read /proc/self/ns/pid (%s)", strerror(errno));
		return -1;
	}
	if (ino == self) {
		snprintf(why, cap, "peer %d is in the host pid namespace %llu", pid, (unsigned long long)ino);
		return -1;
	}
	DIR *d = opendir("/proc");
	if (!d) {
		snprintf(why, cap, "failed to open /proc (%s)", strerror(errno));
		return -1;
	}
	struct dirent *de;
	char init_ctx[64] = "";
	int found = 0;
	while (!found && (de = readdir(d))) {
		if (de->d_name[0] < '1' || de->d_name[0] > '9')
			continue;
		int cand = atoi(de->d_name);
		u64 cino;
		char st[4096];
		int nsp;
		snprintf(path, sizeof path, "/proc/%d/ns/pid", cand);
		if (read_pid_ns(path, &cino) || cino != ino)
			continue;
		if (proc_read(cand, "status", st, sizeof st) < 0 || status_last(st, "NSpid:", &nsp) || nsp != 1)
			continue;
		found = 1;
		if (proc_read(cand, "attr/current", init_ctx, sizeof init_ctx) < 0)
			init_ctx[0] = 0;
		trim_ctx(init_ctx);
	}
	closedir(d);
	if (!found) {
		snprintf(why, cap, "no pid 1 in pid namespace %llu of peer %d", (unsigned long long)ino, pid);
		return -1;
	}
	if (strcmp(init_ctx, INIT_CTX)) {
		snprintf(why, cap, "pid 1 of pid namespace %llu runs '%s', not %s", (unsigned long long)ino, init_ctx, INIT_CTX);
		return -1;
	}
	return 0;
}

// counters for the status file
struct stats {
	u64 samples, requests, refused, sample_errors, newest_ns;
	int clients;
	char last_error[160];
};

static struct stats g_stats;

// log an error and copy the sanitized message to g_stats.last_error
static void note_error(const char *fmt, ...)
{
	char msg[sizeof g_stats.last_error];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);
	for (char *c = msg; *c; c++)
		if ((unsigned char)*c < ' ' || *c == '"' || *c == '\\' || *c == 0x7f)
			*c = '_';
	memcpy(g_stats.last_error, msg, sizeof msg);
	logmsg("%s", msg);
}

// format the statistics as a JSON line
static int status_build(const struct stats *s, char *buf, size_t cap)
{
	int n = snprintf(buf, cap,
			 "{\"samples\":%llu,\"requests\":%llu,\"refused\":%llu,\"sample_errors\":%llu,"
			 "\"newest_boottime_ns\":%llu,\"clients\":%d,\"last_error\":\"%s\"}\n",
			 (unsigned long long)s->samples, (unsigned long long)s->requests,
			 (unsigned long long)s->refused, (unsigned long long)s->sample_errors,
			 (unsigned long long)s->newest_ns, s->clients, s->last_error);
	return n > 0 && (size_t)n < cap ? n : -1;
}

// write text to path.tmp and rename path.tmp to path
static int write_status_atomic(const char *path, const char *text)
{
	char tmp[600];
	snprintf(tmp, sizeof tmp, "%s.tmp", path);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		return -1;
	size_t n = strlen(text);
	ssize_t w = write(fd, text, n);
	close(fd);
	if (w != (ssize_t)n || rename(tmp, path)) {
		unlink(tmp);
		return -1;
	}
	return 0;
}

// write the status file
static void write_status(const char *path)
{
	char buf[STATS_BUF];
	if (status_build(&g_stats, buf, sizeof buf) < 0) {
		logmsg("status exceeds %zu bytes", sizeof buf);
		return;
	}
	if (write_status_atomic(path, buf))
		note_error("failed to write %s (%s)", path, strerror(errno));
}

static const char *g_selinuxfs = "/sys/fs/selinux";
static const char *g_attr_current = "/proc/self/attr/current";

// parse RHIZO_SELINUX_MODE_FILE or /run/rhizo-selinux-mode
static int selinux_namespace_mode(void)
{
	const char *path = getenv("RHIZO_SELINUX_MODE_FILE");
	if (!path)
		path = "/run/rhizo-selinux-mode";
	char buf[32] = "";
	FILE *f = fopen(path, "re");
	if (!f) {
		logmsg("RHIZO_MARKER headroomd_domain failed reason=selinux-mode mode-file=%s errno=%d", path, errno);
		return -1;
	}
	size_t n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	buf[n] = 0;
	while (n && buf[n - 1] == '\n')
		buf[--n] = 0;
	if (!strcmp(buf, "namespace"))
		return 1;
	if (!strcmp(buf, "host"))
		return 0;
	logmsg("RHIZO_MARKER headroomd_domain failed reason=selinux-mode mode-file=%s value='%s'", path, buf);
	return -1;
}

// re-exec into the HEADROOMD_CTX domain
static void enter_domain(char **argv)
{
	struct stat st;
	int ns = selinux_namespace_mode();
	if (ns < 0)
		exit(SELINUX_MODE_EXIT);
	if (ns) {
		logmsg("RHIZO_MARKER headroomd_domain state=no-selinux mode=namespace want=%s", HEADROOMD_CTX);
		return;
	}
	if (stat(g_selinuxfs, &st) && errno == ENOENT) {
		logmsg("RHIZO_MARKER headroomd_domain state=no-selinux want=%s", HEADROOMD_CTX);
		return;
	}
	char cur[128];
	if (read_text(g_attr_current, cur, sizeof cur) < 0)
		cur[0] = 0;
	trim_ctx(cur);
	if (!strcmp(cur, HEADROOMD_CTX)) {
		unsetenv(ENTERING_ENV);
		logmsg("RHIZO_MARKER headroomd_domain entered=%s", HEADROOMD_CTX);
		return;
	}
	if (!strcmp(cur, "kernel")) {
		logmsg("RHIZO_MARKER headroomd_domain state=deferred current=%s want=%s", cur, HEADROOMD_CTX);
		return;
	}
	if (!strcmp(cur, "u:r:kernel:s0") || getenv(ENTERING_ENV)) {
		logmsg("RHIZO_MARKER headroomd_domain failed reason=%s current=%s want=%s",
		       getenv(ENTERING_ENV) ? "domain-refused" : "domain-kernel", cur, HEADROOMD_CTX);
		exit(1);
	}
	if (write_text("/proc/self/attr/exec", HEADROOMD_CTX)) {
		logmsg("RHIZO_MARKER headroomd_domain failed reason=attr-exec errno=%d current=%s", errno, cur);
		exit(1);
	}
	setenv(ENTERING_ENV, "1", 1);
	char exe[512];
	ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	if (n < 0) {
		logmsg("readlink /proc/self/exe failed (%s)", strerror(errno));
		exit(1);
	}
	exe[n] = 0;
	execv(exe, argv);
	logmsg("execv %s failed (%s)", exe, strerror(errno));
	exit(1);
}

// sendto READY=1 on NOTIFY_SOCKET
static void sd_notify_ready(void)
{
	const char *path = getenv("NOTIFY_SOCKET");
	if (!path || !*path)
		return;
	struct sockaddr_un a;
	memset(&a, 0, sizeof a);
	a.sun_family = AF_UNIX;
	size_t l = strlen(path);
	if (l >= sizeof a.sun_path)
		return;
	memcpy(a.sun_path, path, l);
	if (path[0] == '@')
		a.sun_path[0] = 0;
	int s = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (s < 0)
		return;
	if (sendto(s, "READY=1", 7, 0, (struct sockaddr *)&a, (socklen_t)(offsetof(struct sockaddr_un, sun_path) + l)) < 0)
		logmsg("sendto NOTIFY_SOCKET failed (%s)", strerror(errno));
	close(s);
}

static volatile sig_atomic_t g_stop;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

struct cfg {
	const char *socket_path, *status_path;
	int selftest;
};

// create, bind and listen on the daemon socket
static int listen_socket(const char *path)
{
	struct sockaddr_un a;
	memset(&a, 0, sizeof a);
	a.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof a.sun_path) {
		logmsg("socket path %s is longer than sun_path", path);
		return -1;
	}
	strcpy(a.sun_path, path);
	int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (s < 0) {
		logmsg("socket failed (%s)", strerror(errno));
		return -1;
	}
	unlink(path);
	if (bind(s, (struct sockaddr *)&a, sizeof a) || chmod(path, 0666) || listen(s, 8)) {
		logmsg("bind, chmod or listen failed for %s (%s)", path, strerror(errno));
		close(s);
		return -1;
	}
	return s;
}

// read one /proc/stat sample into the ring
static int take_sample(struct ring *r)
{
	static u64 last_taken;
	static u32 last_ncpu;
	static long hz;
	char buf[8192];
	u64 taken, idle, avail, total;
	u64 ns = boottime_ns();
	int n = read_text("/proc/stat", buf, sizeof buf);
	if (n <= 0) {
		note_error("failed to read /proc/stat (%s)", n < 0 ? strerror(errno) : "empty");
		goto fail;
	}
	char *nl = strchr(buf, '\n');
	if (!nl) {
		note_error("/proc/stat has no newline in the first %d bytes", n);
		goto fail;
	}
	u32 ncpu = count_cpus(nl + 1);
	*nl = 0;
	if (parse_cpu_line(buf, &taken, &idle)) {
		note_error("failed to parse cpu line %.100s", buf);
		goto fail;
	}
	if (!hz)
		hz = sysconf(_SC_CLK_TCK);
	if (ncpu == 0 || hz <= 0) {
		note_error("/proc/stat ncpu=%u _SC_CLK_TCK=%ld", ncpu, hz);
		goto fail;
	}
	if (r->pushed && counters_restart(ncpu, last_ncpu, taken, last_taken))
		r->pushed = 0;
	last_taken = taken;
	last_ncpu = ncpu;
	wall_counters(taken, ns, ncpu, hz, &avail, &total);
	ring_push(r, avail, total, ns);
	g_stats.samples++;
	g_stats.newest_ns = ns;
	return 0;
fail:
	g_stats.sample_errors++;
	r->pushed = 0;
	return -1;
}

// read the peer security context into ctx
static int peer_context(int fd, char *ctx, size_t cap)
{
	socklen_t l = (socklen_t)(cap - 1);
	if (getsockopt(fd, SOL_SOCKET, SO_PEERSEC, ctx, &l) < 0)
		return -1;
	ctx[l] = 0;
	trim_ctx(ctx);
	return 0;
}

// count, log and close a refused peer
static void refuse(int fd, int pid, const char *ctx, const char *why)
{
	g_stats.refused++;
	logmsg("refused peer pid=%d context=%s why=%s", pid, ctx, why);
	close(fd);
}

// call accept4 for pending connections
static void accept_new(int lfd, int *clients, int *nclients)
{
	for (;;) {
		int fd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
		if (fd < 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED)
				note_error("accept4 failed (%s)", strerror(errno));
			return;
		}
		struct ucred cr;
		socklen_t l = sizeof cr;
		char ctx[128] = "", why[256] = "";
		if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &l) < 0 || cr.pid <= 0) {
			refuse(fd, 0, "unknown", "getsockopt SO_PEERCRED failed");
			continue;
		}
		if (peer_context(fd, ctx, sizeof ctx) < 0) {
			snprintf(why, sizeof why, "getsockopt SO_PEERSEC failed (%s)", strerror(errno));
			refuse(fd, cr.pid, "unreadable", why);
			continue;
		}
		if (strcmp(ctx, POWER_CTX)) {
			refuse(fd, cr.pid, ctx, "context is not " POWER_CTX);
			continue;
		}
		int in_sandbox = peer_sandbox(cr.pid, why, sizeof why) == 0;
		if (!peer_allowed(ctx, in_sandbox)) {
			refuse(fd, cr.pid, ctx, why);
			continue;
		}
		if (*nclients >= MAX_CLIENTS) {
			refuse(fd, cr.pid, ctx, "nclients == MAX_CLIENTS");
			continue;
		}
		clients[(*nclients)++] = fd;
	}
}

// close clients[i] and remove clients[i] from clients
static void drop_client(int *clients, int *nclients, int i)
{
	close(clients[i]);
	clients[i] = clients[--*nclients];
}

// recv a packet and call send with the reply
static int serve_client(const struct ring *r, int fd)
{
	char req[REQ_MAX + 1], rep[REPLY_MAX];
	ssize_t n = recv(fd, req, sizeof req, MSG_DONTWAIT | MSG_TRUNC);
	if (n == 0)
		return -1;
	if (n < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
			return 0;
		note_error("recv failed (%s)", strerror(errno));
		return -1;
	}
	size_t rl = handle_request(r, req, (size_t)n > sizeof req ? sizeof req : (size_t)n, rep, sizeof rep);
	if (rl == 0) {
		note_error("reply exceeds %zu bytes", sizeof rep);
		return -1;
	}
	g_stats.requests++;
	if (send(fd, rep, rl, MSG_NOSIGNAL | MSG_DONTWAIT) != (ssize_t)rl) {
		note_error("send failed (%s)", strerror(errno));
		return -1;
	}
	return 0;
}

// serve headroom packets until g_stop is set
static int run_daemon(const struct cfg *cfg)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	static struct ring ring;
	if (take_sample(&ring))
		return 1;
	int lfd = listen_socket(cfg->socket_path);
	if (lfd < 0)
		return 1;
	int tfd = timerfd_create(CLOCK_BOOTTIME, TFD_NONBLOCK | TFD_CLOEXEC);
	if (tfd < 0) {
		logmsg("timerfd_create failed (%s)", strerror(errno));
		close(lfd);
		return 1;
	}
	u64 first = boottime_ns() + (u64)P_MS * 1000000ULL;
	struct itimerspec its = {
		.it_interval = { 0, (long)P_MS * 1000000L },
		.it_value = { (time_t)(first / 1000000000ULL), (long)(first % 1000000000ULL) },
	};
	if (timerfd_settime(tfd, TFD_TIMER_ABSTIME, &its, NULL)) {
		logmsg("timerfd_settime failed (%s)", strerror(errno));
		close(tfd);
		close(lfd);
		return 1;
	}
	write_status(cfg->status_path);
	logmsg("RHIZO_MARKER headroomd_ready period_ms=%d ring=%d socket=%s", P_MS, RING_N, cfg->socket_path);
	sd_notify_ready();

	int clients[MAX_CLIENTS], nclients = 0;
	int rc = 0;
	while (!g_stop) {
		struct pollfd pf[2 + MAX_CLIENTS];
		pf[0] = (struct pollfd){ tfd, POLLIN, 0 };
		pf[1] = (struct pollfd){ lfd, POLLIN, 0 };
		for (int i = 0; i < nclients; i++)
			pf[2 + i] = (struct pollfd){ clients[i], POLLIN, 0 };
		if (poll(pf, (nfds_t)(2 + nclients), -1) < 0) {
			if (errno == EINTR)
				continue;
			logmsg("poll failed (%s)", strerror(errno));
			rc = 1;
			break;
		}
		if (pf[0].revents & POLLIN) {
			u64 exp;
			if (read(tfd, &exp, sizeof exp) == (ssize_t)sizeof exp) {
				if (exp > 1)
					note_error("sample timer overran by %llu periods", (unsigned long long)(exp - 1));
				take_sample(&ring);
				if (g_stats.samples % STATUS_EVERY == 0 || g_stats.sample_errors)
					write_status(cfg->status_path);
			}
		}
		for (int i = nclients - 1; i >= 0; i--) {
			short ev = pf[2 + i].revents;
			if (ev && ((ev & (POLLERR | POLLNVAL)) || serve_client(&ring, clients[i]) < 0))
				drop_client(clients, &nclients, i);
		}
		if (pf[1].revents & POLLIN)
			accept_new(lfd, clients, &nclients);
		g_stats.clients = nclients;
	}
	for (int i = 0; i < nclients; i++)
		close(clients[i]);
	close(tfd);
	close(lfd);
	unlink(cfg->socket_path);
	write_status(cfg->status_path);
	return rc;
}

static int T_pass, T_fail;
static const char *T_case = "";

#define CHECK(cond, ...) \
	do { \
		if (cond) { \
			T_pass++; \
		} else { \
			T_fail++; \
			fprintf(stderr, "FAIL [%s] line=%d ", T_case, __LINE__); \
			fprintf(stderr, __VA_ARGS__); \
			fputc('\n', stderr); \
		} \
	} while (0)

// return whether two values differ by less than 0.005
static int near(double a, double b)
{
	return a - b < 0.005 && b - a < 0.005;
}

// push nsteps steps into the ring
static void fill_ring(struct ring *r, int nsteps, double (*avail_of)(int))
{
	memset(r, 0, sizeof *r);
	u64 avail = 1000, total = 5000, ns = 1000000000ULL;
	ring_push(r, avail, total, ns);
	for (int k = 0; k < nsteps; k++) {
		avail += (u64)avail_of(k);
		total += 100;
		ns += (u64)P_MS * 1000000ULL;
		ring_push(r, avail, total, ns);
	}
}

static double steady40(int k) { (void)k; return 40; }
static double ramp(int k) { return k % 100; }

// test parse_cpu_line, status_last, count_cpus, wall_counters, step_headroom and counters_restart
static void test_parser(void)
{
	T_case = "parser";
	u64 av, tot;
	CHECK(!parse_cpu_line("cpu  10132153 290696 3084719 46828483 16683 0 25195 0 175628 0\n"
			      "cpu0 1265 3 391 5855 2 0 4 0 0 0\n", &av, &tot), "parse_cpu_line(ten-field line) == 0");
	CHECK(av == 10132153ULL + 290696ULL + 3084719ULL + 0 + 25195ULL + 0, "taken == user+nice+system+irq+softirq+steal taken=%llu", (unsigned long long)av);
	CHECK(tot == 46828483ULL + 16683ULL, "idle == idle+iowait idle=%llu", (unsigned long long)tot);
	CHECK(!parse_cpu_line("cpu  1 2 3 4 5 6 7 8 900 800\n", &av, &tot), "parse_cpu_line(guest-heavy line) == 0");
	CHECK(av == 1 + 2 + 3 + 6 + 7 + 8 && tot == 9, "taken == 1+2+3+6+7+8 && idle == 9 taken=%llu idle=%llu", (unsigned long long)av, (unsigned long long)tot);
	CHECK(!parse_cpu_line("cpu  2255 34 2290 22625563 6290 127 456 0\n", &av, &tot), "parse_cpu_line(eight-field line) == 0");
	CHECK(av == 2255ULL + 34 + 2290 + 127 + 456 && tot == 22625563ULL + 6290ULL, "eight-field taken == user+nice+system+irq+softirq && idle == idle+iowait");
	CHECK(!parse_cpu_line("cpu 1 2 3 4 5 6 7 8", &av, &tot) && av == 27 && tot == 9, "parse_cpu_line(single spaces, no newline) == 0 && taken == 27 && idle == 9");
	CHECK(!parse_cpu_line("cpu\t1\t2\t3\t4\t5\t6\t7\t8\n", &av, &tot) && av == 27, "parse_cpu_line(tab-separated line) == 0 && taken == 27");
	CHECK(!parse_cpu_line("cpu  1 2 3 4 5 6 7 8 9 10 11 12\n", &av, &tot) && av == 27, "parse_cpu_line(12-field line) == 0 && taken == 27");
	CHECK(!parse_cpu_line("cpu  0 0 0 0 0 0 0 0 0 0\n", &av, &tot) && av == 0 && tot == 0, "parse_cpu_line(all-zero line) == 0 && taken == 0 && idle == 0");
	CHECK(parse_cpu_line("cpu  1 2 3 4 5 6 7\n", &av, &tot) == -1, "parse_cpu_line(seven fields) == -1");
	CHECK(parse_cpu_line("cpu  1 2 3 4\n", &av, &tot) == -1, "parse_cpu_line(four fields) == -1");
	CHECK(parse_cpu_line("cpu\n", &av, &tot) == -1, "parse_cpu_line(no fields) == -1");
	CHECK(parse_cpu_line("", &av, &tot) == -1, "parse_cpu_line(\"\") == -1");
	CHECK(parse_cpu_line("cpu0 1 2 3 4 5 6 7 8 0 0\n", &av, &tot) == -1, "parse_cpu_line(cpu0 line) == -1");
	CHECK(parse_cpu_line("intr 1 2 3 4 5 6 7 8 9\n", &av, &tot) == -1, "parse_cpu_line(intr line) == -1");
	CHECK(parse_cpu_line("cpu  1 2 x 4 5 6 7 8\n", &av, &tot) == -1, "parse_cpu_line(non-numeric field) == -1");
	CHECK(parse_cpu_line("cpu  1 2 -3 4 5 6 7 8\n", &av, &tot) == -1, "parse_cpu_line(negative field) == -1");
	CHECK(parse_cpu_line("cpu  1 2 +3 4 5 6 7 8\n", &av, &tot) == -1, "parse_cpu_line(+3 field) == -1");
	CHECK(parse_cpu_line("cpu  1 2 3x 4 5 6 7 8\n", &av, &tot) == -1, "parse_cpu_line(3x field) == -1");
	CHECK(parse_cpu_line("cpu  1 2 99999999999999999999999 4 5 6 7 8\n", &av, &tot) == -1, "parse_cpu_line(23-digit field) == -1");
	CHECK(parse_cpu_line("cpu  1 2 1152921504606846977 4 5 6 7 8\n", &av, &tot) == -1, "parse_cpu_line(field > FIELD_MAX) == -1");
	CHECK(parse_cpu_line(" cpu  1 2 3 4 5 6 7 8\n", &av, &tot) == -1, "parse_cpu_line(leading space) == -1");
	CHECK(parse_cpu_line("cpux 1 2 3 4 5 6 7 8\n", &av, &tot) == -1, "parse_cpu_line(cpux line) == -1");

	char st[] = "Name:\tinit\nNSpid:\t4242\t1\nNStgid:\t4242\t1\n";
	int v = 0;
	CHECK(!status_last(st, "NSpid:", &v) && v == 1, "status_last(NSpid 4242 1) == 0 && v == 1");
	CHECK(!status_last("NSpid:\t77\n", "NSpid:", &v) && v == 77, "status_last(NSpid 77) == 0 && v == 77");
	CHECK(status_last("Name:\tx\n", "NSpid:", &v) == -1, "status_last(no NSpid line) == -1");
	CHECK(status_last("NSpid:\t\n", "NSpid:", &v) == -1, "status_last(empty NSpid value) == -1");

	CHECK(count_cpus("cpu  1 2 3 4 5 6 7 8\ncpu0 1 2 3 4 5 6 7 8\ncpu1 1 2 3 4 5 6 7 8\ncpu3 1 2 3 4 5 6 7 8\nintr 5\n") == 3,
	      "count_cpus(cpu, cpu0, cpu1, cpu3, intr) == 3");
	CHECK(count_cpus("cpu  1 2 3 4 5 6 7 8\nintr 5\n") == 0, "count_cpus(cpu, intr) == 0");
	u64 a0, t0, a1, t1;
	wall_counters(1000, 2000000000ULL, 4, 100, &a0, &t0);
	CHECK(t0 == 800 && a0 == 0, "wall_counters(1000, 2 s, 4, 100) total == 800 && avail == 0 avail=%llu total=%llu",
	      (unsigned long long)a0, (unsigned long long)t0);
	wall_counters(10, 1000000000ULL, 4, 100, &a1, &t1);
	CHECK(t1 == 400 && a1 == 390, "wall_counters(10, 1 s, 4, 100) total == 400 && avail == 390 avail=%llu total=%llu", (unsigned long long)a1, (unsigned long long)t1);
	u64 tk0, id0, tk1, id1;
	CHECK(!parse_cpu_line("cpu  100 0 0 1000 0 0 0 50 0 0\n", &tk0, &id0) && !parse_cpu_line("cpu  101 0 0 1039 0 0 0 58 0 0\n", &tk1, &id1),
	      "parse_cpu_line(steal lines) == 0");
	u64 sa0, st0, sa1, st1;
	wall_counters(tk0, 10000000000ULL, 4, 100, &sa0, &st0);
	wall_counters(tk1, 10100000000ULL, 4, 100, &sa1, &st1);
	struct sample s0 = { sa0, st0, 10000000000ULL }, s1 = { sa1, st1, 10100000000ULL };
	double h = -1;
	CHECK(!step_headroom(&s0, &s1, &h) && near(h, 77.5), "step_headroom(busy 1 + steal 8 of 40 ticks) == 77.5 h=%.2f", h);
	CHECK(!counters_restart(4, 4, 101, 100) && !counters_restart(4, 4, 100, 100), "counters_restart(4, 4, 101, 100) == 0 && counters_restart(4, 4, 100, 100) == 0");
	CHECK(counters_restart(4, 4, 99, 100), "counters_restart(4, 4, 99, 100) == 1");
	CHECK(counters_restart(3, 4, 101, 100) && counters_restart(5, 4, 101, 100), "counters_restart(3, 4, 101, 100) == 1 && counters_restart(5, 4, 101, 100) == 1");
}

// test ring_push and ring_query
static void test_ring(void)
{
	T_case = "ring";
	struct ring r;
	struct answer a;

	static const struct { u64 w; u32 n; } W[] = {
		{ 0, 1 }, { 1, 1 }, { 49, 1 }, { 50, 1 }, { 99, 1 }, { 100, 1 }, { 149, 1 }, { 150, 1 }, { 151, 2 }, { 199, 2 },
		{ 250, 2 }, { 251, 3 }, { 1000, 10 }, { 1049, 10 }, { 1050, 10 }, { 1051, 11 }, { 9949, 99 }, { 9950, 99 },
		{ 9951, 100 }, { 10000, 100 }, { 20000, 100 }, { 999999999, 100 },
	};
	fill_ring(&r, 100, ramp);
	CHECK(r.pushed == RING_N && ring_steps(&r) == 100, "ring_steps(RING_N samples) == 100 steps=%u", ring_steps(&r));
	for (size_t i = 0; i < sizeof W / sizeof W[0]; i++) {
		u32 n = W[i].n;
		ring_query(&r, T_MIN, W[i].w, &a);
		CHECK(a.kind == A_OK && a.steps == n && a.window_ms == n * P_MS, "T_MIN W=%llu steps == n && window_ms == n * P_MS steps=%u window_ms=%u", (unsigned long long)W[i].w, a.steps, a.window_ms);
		CHECK(near(a.value, 100.0 - n), "T_MIN W=%llu value == 100 - n value=%.2f expected=%u", (unsigned long long)W[i].w, a.value, 100 - n);
		ring_query(&r, T_AVERAGE, W[i].w, &a);
		CHECK(a.kind == A_OK && a.steps == n && a.window_ms == n * P_MS, "T_AVERAGE W=%llu steps == n && window_ms == n * P_MS steps=%u", (unsigned long long)W[i].w, a.steps);
		CHECK(near(a.value, (100.0 - n + 99.0) / 2.0), "T_AVERAGE W=%llu value == (199 - n) / 2 value=%.2f expected=%.2f", (unsigned long long)W[i].w, a.value, (100.0 - n + 99.0) / 2.0);
	}

	memset(&r, 0, sizeof r);
	static const int avail_steps[] = { 100, 0, 100, 50 };
	ring_push(&r, 0, 0, 0);
	u64 av = 0, tot = 0;
	for (size_t i = 0; i < 4; i++) {
		av += (u64)avail_steps[i];
		tot += 100;
		ring_push(&r, av, tot, (i + 1) * 100000000ULL);
	}
	ring_query(&r, T_AVERAGE, 400, &a);
	CHECK(a.kind == A_OK && near(a.value, 62.5) && a.steps == 4 && a.window_ms == 400, "T_AVERAGE(100, 0, 100, 50) == 62.5 value=%.2f", a.value);
	ring_query(&r, T_MIN, 400, &a);
	CHECK(a.kind == A_OK && near(a.value, 0.0) && a.steps == 4, "T_MIN(100, 0, 100, 50) == 0 value=%.2f", a.value);
	ring_query(&r, T_MIN, 100, &a);
	CHECK(a.kind == A_OK && near(a.value, 50.0) && a.steps == 1, "T_MIN(newest step) == 50 value=%.2f", a.value);
	ring_query(&r, T_AVERAGE, 200, &a);
	CHECK(a.kind == A_OK && near(a.value, 75.0) && a.steps == 2, "T_AVERAGE(newest two steps) == 75 value=%.2f", a.value);

	memset(&r, 0, sizeof r);
	ring_query(&r, T_AVERAGE, 1000, &a);
	CHECK(a.kind == A_NODATA, "ring_query(empty ring).kind == A_NODATA");
	ring_push(&r, 10, 100, 100000000ULL);
	CHECK(ring_steps(&r) == 0, "ring_steps(one sample) == 0");
	ring_query(&r, T_MIN, 1000, &a);
	CHECK(a.kind == A_NODATA, "T_MIN(one sample).kind == A_NODATA");
	ring_query(&r, T_AVERAGE, 100, &a);
	CHECK(a.kind == A_NODATA, "T_AVERAGE(one sample).kind == A_NODATA");
	ring_push(&r, 50, 200, 200000000ULL);
	ring_query(&r, T_MIN, 10000, &a);
	CHECK(a.kind == A_OK && a.steps == 1 && a.window_ms == 100 && near(a.value, 40.0), "two samples steps == 1 && window_ms == 100 && value == 40 value=%.2f window_ms=%u", a.value, a.window_ms);
	ring_push(&r, 90, 300, 300000000ULL);
	ring_push(&r, 130, 400, 400000000ULL);
	ring_query(&r, T_AVERAGE, 1000, &a);
	CHECK(a.kind == A_OK && a.steps == 3 && a.window_ms == 300 && near(a.value, 40.0), "four samples steps == 3 && window_ms == 300 && value == 40 window_ms=%u", a.window_ms);

	static const u64 IRR_MS[] = { 0, 100, 200, 300, 600, 700, 800 };
	static const u64 IRR_AV[] = { 10, 20, 30, 120, 50, 60 };
	static const u64 IRR_TOT[] = { 100, 100, 100, 300, 100, 100 };
	memset(&r, 0, sizeof r);
	av = 0;
	tot = 0;
	ring_push(&r, 0, 0, 0);
	for (size_t i = 0; i < 6; i++) {
		av += IRR_AV[i];
		tot += IRR_TOT[i];
		ring_push(&r, av, tot, IRR_MS[i + 1] * 1000000ULL);
	}
	ring_query(&r, T_AVERAGE, 500, &a);
	CHECK(a.kind == A_OK && a.steps == 3 && a.window_ms == 500 && near(a.value, 46.0), "gap T_AVERAGE W=500 value == 46 && window_ms == 500 && steps == 3 value=%.2f window_ms=%u steps=%u", a.value, a.window_ms, a.steps);
	ring_query(&r, T_MIN, 500, &a);
	CHECK(a.kind == A_OK && a.steps == 3 && a.window_ms == 500 && near(a.value, 40.0), "gap T_MIN W=500 value == 40 && window_ms == 500 value=%.2f window_ms=%u", a.value, a.window_ms);
	ring_query(&r, T_AVERAGE, 350, &a);
	CHECK(a.kind == A_OK && a.steps == 2 && a.window_ms == 200 && near(a.value, 55.0), "gap T_AVERAGE W=350 value == 55 && window_ms == 200 && steps == 2 value=%.2f window_ms=%u steps=%u", a.value, a.window_ms, a.steps);
	ring_query(&r, T_MIN, 350, &a);
	CHECK(a.kind == A_OK && a.steps == 2 && near(a.value, 50.0), "gap T_MIN W=350 value == 50 value=%.2f", a.value);
	ring_query(&r, T_AVERAGE, 1000, &a);
	CHECK(a.kind == A_OK && a.steps == 6 && a.window_ms == 800 && near(a.value, 290.0 * 100.0 / 800.0), "gap T_AVERAGE W=1000 steps == 6 && window_ms == 800 value=%.2f window_ms=%u", a.value, a.window_ms);
	ring_query(&r, T_MIN, 1000, &a);
	CHECK(a.kind == A_OK && a.steps == 6 && near(a.value, 10.0), "gap T_MIN W=1000 value == 10 value=%.2f", a.value);
	ring_query(&r, T_AVERAGE, 100, &a);
	CHECK(a.kind == A_OK && a.steps == 1 && a.window_ms == 100 && near(a.value, 60.0), "gap T_AVERAGE W=100 steps == 1 && value == 60 value=%.2f", a.value);
	ring_query(&r, T_AVERAGE, 300, &a);
	CHECK(a.kind == A_OK && a.steps == 2 && a.window_ms == 200, "gap T_AVERAGE W=300 window_ms == 200 && steps == 2 window_ms=%u steps=%u", a.window_ms, a.steps);
	ring_query(&r, T_AVERAGE, 700, &a);
	CHECK(a.kind == A_OK && a.steps == 5 && a.window_ms == 700, "gap T_AVERAGE W=700 window_ms == 700 && steps == 5 window_ms=%u steps=%u", a.window_ms, a.steps);

	memset(&r, 0, sizeof r);
	ring_push(&r, 0, 0, 1000000000ULL);
	ring_push(&r, 50, 100, 1149600000ULL);
	ring_query(&r, T_AVERAGE, 100, &a);
	CHECK(a.kind == A_OK && a.steps == 1 && a.window_ms == 150, "window_ms(149.6 ms) == 150 window_ms=%u", a.window_ms);
	memset(&r, 0, sizeof r);
	ring_push(&r, 0, 0, 1000000000ULL);
	ring_push(&r, 50, 100, 1149400000ULL);
	ring_query(&r, T_MIN, 100, &a);
	CHECK(a.kind == A_OK && a.window_ms == 149 && near(a.value, 50.0), "window_ms(149.4 ms) == 149 window_ms=%u", a.window_ms);
	memset(&r, 0, sizeof r);
	ring_push(&r, 0, 0, 1000000000ULL);
	ring_push(&r, 50, 100, 1000000000ULL);
	ring_query(&r, T_AVERAGE, 100, &a);
	CHECK(a.kind == A_RESET, "newest.ns <= start.ns kind == A_RESET");

	fill_ring(&r, 250, ramp);
	CHECK(ring_steps(&r) == 100, "ring_steps(wrapped ring) == 100");
	ring_query(&r, T_MIN, 1000, &a);
	CHECK(a.kind == A_OK && a.steps == 10 && near(a.value, 40.0), "wrapped T_MIN W=1000 steps == 10 && value == 40 value=%.2f", a.value);
	ring_query(&r, T_AVERAGE, 1000, &a);
	CHECK(a.kind == A_OK && near(a.value, 44.5), "wrapped T_AVERAGE W=1000 value == 44.5 value=%.2f", a.value);
	ring_query(&r, T_AVERAGE, 20000, &a);
	CHECK(a.kind == A_OK && a.steps == 100 && a.window_ms == 10000 && near(a.value, 49.5), "wrapped T_AVERAGE W=20000 steps == 100 && window_ms == 10000 && value == 49.5 value=%.2f", a.value);

	fill_ring(&r, 10, steady40);
	ring_push(&r, r.s[(r.pushed - 1) % RING_N].avail - 1, r.s[(r.pushed - 1) % RING_N].total + 100, r.s[(r.pushed - 1) % RING_N].ns + 100000000ULL);
	ring_query(&r, T_AVERAGE, 100, &a);
	CHECK(a.kind == A_OK && near(a.value, 0.0), "avail decrease step kind == A_OK && value == 0 kind=%d value=%.2f", a.kind, a.value);
	ring_query(&r, T_MIN, 1000, &a);
	CHECK(a.kind == A_OK && near(a.value, 0.0), "T_MIN W=1000 over the avail decrease step kind == A_OK && value == 0 kind=%d value=%.2f", a.kind, a.value);
	fill_ring(&r, 10, steady40);
	ring_push(&r, r.s[(r.pushed - 1) % RING_N].avail + 5, r.s[(r.pushed - 1) % RING_N].total - 1, r.s[(r.pushed - 1) % RING_N].ns + 100000000ULL);
	ring_query(&r, T_MIN, 100, &a);
	CHECK(a.kind == A_RESET, "total decrease step kind == A_RESET");
	fill_ring(&r, 10, steady40);
	ring_push(&r, r.s[(r.pushed - 1) % RING_N].avail, r.s[(r.pushed - 1) % RING_N].total, r.s[(r.pushed - 1) % RING_N].ns + 100000000ULL);
	ring_query(&r, T_AVERAGE, 100, &a);
	CHECK(a.kind == A_RESET, "T_AVERAGE step with b->total == a->total kind == A_RESET");
	ring_query(&r, T_MIN, 100, &a);
	CHECK(a.kind == A_RESET, "T_MIN step with b->total == a->total kind == A_RESET");
	fill_ring(&r, 10, steady40);
	r.s[(r.pushed - 1 - 5) % RING_N].total = 0;
	ring_query(&r, T_AVERAGE, 200, &a);
	CHECK(a.kind == A_OK && near(a.value, 40.0), "T_AVERAGE W=200 with a reset before the window kind == A_OK && value == 40 kind=%d", a.kind);
	ring_query(&r, T_AVERAGE, 1000, &a);
	CHECK(a.kind == A_RESET, "T_AVERAGE W=1000 with a reset in the window kind == A_RESET");
	ring_query(&r, T_MIN, 1000, &a);
	CHECK(a.kind == A_RESET, "T_MIN W=1000 with a reset in the window kind == A_RESET");

	CHECK(near(clamp_pct(-5.0), 0.0) && near(clamp_pct(105.0), 100.0) && near(clamp_pct(37.5), 37.5), "clamp_pct(-5) == 0 && clamp_pct(105) == 100 && clamp_pct(37.5) == 37.5");
	memset(&r, 0, sizeof r);
	ring_push(&r, 0, 0, 0);
	ring_push(&r, 150, 100, 100000000ULL);
	ring_query(&r, T_AVERAGE, 100, &a);
	CHECK(a.kind == A_OK && near(a.value, 100.0), "T_AVERAGE over 100 percent value == 100 value=%.2f", a.value);
	ring_query(&r, T_MIN, 100, &a);
	CHECK(a.kind == A_OK && near(a.value, 100.0), "T_MIN over 100 percent value == 100 value=%.2f", a.value);
	fill_ring(&r, 10, ramp);
	ring_query(&r, T_MIN, 1000, &a);
	CHECK(a.kind == A_OK && near(a.value, 0.0), "T_MIN(ramp from 0) == 0 value=%.2f", a.value);
}

// return whether s matches one of the four reply shapes
static int wire_shape(const char *s)
{
	if (!strcmp(s, "nan no-data") || !strcmp(s, "nan counter-reset") || !strcmp(s, "err bad-request"))
		return 1;
	unsigned w, st;
	int used = 0;
	double v;
	if (sscanf(s, "ok %lf %u %u%n", &v, &w, &st, &used) != 3 || s[used] != 0)
		return 0;
	const char *dot = strchr(s, '.');
	if (!dot || !isdigit((unsigned char)dot[1]) || !isdigit((unsigned char)dot[2]) || dot[3] != ' ')
		return 0;
	return v >= 0.0 && v <= 100.0 && w % P_MS == 0 && w / P_MS == st && st >= 1 && st <= 100;
}

// test parse_request, handle_request and format_reply
static void test_protocol(void)
{
	T_case = "protocol";
	struct ring r;
	char out[REPLY_MAX];
	int type;
	u64 w;

	static const struct { const char *req; int type; u64 w; } GOOD[] = {
		{ "headroom min 1000", T_MIN, 1000 }, { "headroom average 1000", T_AVERAGE, 1000 },
		{ "headroom min 100", T_MIN, 100 }, { "headroom average 10000", T_AVERAGE, 10000 },
		{ "headroom min 0", T_MIN, 0 }, { "headroom min 20000\n", T_MIN, 20000 },
		{ "headroom average 999999999", T_AVERAGE, 999999999 }, { "headroom min 007", T_MIN, 7 },
	};
	for (size_t i = 0; i < sizeof GOOD / sizeof GOOD[0]; i++) {
		int rc = parse_request(GOOD[i].req, strlen(GOOD[i].req), &type, &w);
		CHECK(rc == 0 && type == GOOD[i].type && w == GOOD[i].w, "parse_request('%s') == 0 rc=%d type=%d w=%llu", GOOD[i].req, rc, type, (unsigned long long)w);
	}
	static const char *const BAD[] = {
		"", "\n", "headroom", "headroom ", "headroom min", "headroom min ", "headroom max 100", "headroom MIN 100",
		"Headroom min 100", "headroom  min 100", "headroom min  100", "headroom min -5", "headroom min +5",
		"headroom min 1e3", "headroom min 0x10", "headroom min 1.5", "headroom min 1 00", "headroom min 100 ",
		"headroom min 100 x", "headroom min 100 pid=1", "headroom min 100 comm=surfaceflinger", "headroom min 100\n\n",
		"headroom min 100\r\n", "headroom min 1000000000", "headroom min abc", "min 100", "headroomi min 100",
		"headroom average", "headroom averages 100", "headroom minimum 100", "headroom\tmin 100", " headroom min 100",
	};
	for (size_t i = 0; i < sizeof BAD / sizeof BAD[0]; i++) {
		int rc = parse_request(BAD[i], strlen(BAD[i]), &type, &w);
		CHECK(rc == -1, "parse_request('%s') == -1", BAD[i]);
	}
	CHECK(parse_request("headroom min 100\0x", 18, &type, &w) == -1, "parse_request(embedded NUL) == -1");
	CHECK(parse_request("headroom min 100", 0, &type, &w) == -1, "parse_request(len 0) == -1");
	char big[200];
	memset(big, '1', sizeof big);
	memcpy(big, "headroom min ", 13);
	CHECK(parse_request(big, sizeof big, &type, &w) == -1, "parse_request(200 bytes) == -1");

	fill_ring(&r, 100, steady40);
	CHECK(handle_request(&r, "headroom min 1000", 17, out, sizeof out) > 0 && !strcmp(out, "ok 40.00 1000 10"), "handle_request(headroom min 1000) == ok 40.00 1000 10 reply='%s'", out);
	CHECK(handle_request(&r, "headroom average 10000", 22, out, sizeof out) > 0 && !strcmp(out, "ok 40.00 10000 100"), "handle_request(headroom average 10000) == ok 40.00 10000 100 reply='%s'", out);
	CHECK(handle_request(&r, "headroom average 1", 18, out, sizeof out) > 0 && !strcmp(out, "ok 40.00 100 1"), "handle_request(headroom average 1) == ok 40.00 100 1 reply='%s'", out);
	CHECK(handle_request(&r, "headroom min 100\n", 17, out, sizeof out) > 0 && !strcmp(out, "ok 40.00 100 1"), "handle_request(headroom min 100\\n) == ok 40.00 100 1 reply='%s'", out);
	handle_request(&r, "headroom min 100 x", 18, out, sizeof out);
	CHECK(!strcmp(out, "err bad-request"), "handle_request(headroom min 100 x) == err bad-request reply='%s'", out);
	handle_request(&r, "headroom max 100", 16, out, sizeof out);
	CHECK(!strcmp(out, "err bad-request"), "handle_request(headroom max 100) == err bad-request reply='%s'", out);
	handle_request(&r, "headroom min soon", 17, out, sizeof out);
	CHECK(!strcmp(out, "err bad-request"), "handle_request(headroom min soon) == err bad-request reply='%s'", out);
	handle_request(&r, "headroom min -1", 15, out, sizeof out);
	CHECK(!strcmp(out, "err bad-request"), "handle_request(headroom min -1) == err bad-request reply='%s'", out);

	struct answer a = { A_OK, 33.333, 300, 3 };
	format_reply(&a, out, sizeof out);
	CHECK(!strcmp(out, "ok 33.33 300 3"), "format_reply(33.333) == ok 33.33 300 3 reply='%s'", out);
	a.value = 66.666;
	format_reply(&a, out, sizeof out);
	CHECK(!strcmp(out, "ok 66.67 300 3"), "format_reply(66.666) == ok 66.67 300 3 reply='%s'", out);
	a.value = 0.0;
	format_reply(&a, out, sizeof out);
	CHECK(!strcmp(out, "ok 0.00 300 3"), "format_reply(0) == ok 0.00 300 3 reply='%s'", out);
	a.value = 100.0;
	a.window_ms = 10000;
	a.steps = 100;
	format_reply(&a, out, sizeof out);
	CHECK(!strcmp(out, "ok 100.00 10000 100"), "format_reply(100) == ok 100.00 10000 100 reply='%s'", out);
	a.kind = A_NODATA;
	format_reply(&a, out, sizeof out);
	CHECK(!strcmp(out, "nan no-data"), "format_reply(A_NODATA) == nan no-data reply='%s'", out);
	a.kind = A_RESET;
	format_reply(&a, out, sizeof out);
	CHECK(!strcmp(out, "nan counter-reset"), "format_reply(A_RESET) == nan counter-reset reply='%s'", out);
	a.kind = A_OK;
	volatile size_t tight = 8;
	CHECK(format_reply(&a, out, tight) == 0, "format_reply(cap 8) == 0");

	memset(&r, 0, sizeof r);
	handle_request(&r, "headroom min 1000", 17, out, sizeof out);
	CHECK(!strcmp(out, "nan no-data"), "handle_request(empty ring) == nan no-data reply='%s'", out);
	fill_ring(&r, 5, steady40);
	r.s[(r.pushed - 1) % RING_N].total = 0;
	handle_request(&r, "headroom average 1000", 21, out, sizeof out);
	CHECK(!strcmp(out, "nan counter-reset"), "handle_request(newest total 0) == nan counter-reset reply='%s'", out);
}

// test wire_shape, status_build and note_error
static void test_disclosure(void)
{
	T_case = "disclosure";
	struct ring r;
	char out[REPLY_MAX];
	CHECK(wire_shape("ok 12.50 1000 10") && wire_shape("nan no-data") && wire_shape("nan counter-reset") && wire_shape("err bad-request"), "wire_shape(each of the four shapes) == 1");
	CHECK(!wire_shape("ok 12.50 1000 10 pid=42") && !wire_shape("ok 12.5 1000 10") && !wire_shape("ok 12.50 1000 11") &&
	      !wire_shape("ok 12.50 1000 10 surfaceflinger") && !wire_shape("nan surfaceflinger") && !wire_shape("ok 120.00 1000 10"),
	      "wire_shape(six other strings) == 0");

	static const char *const REQS[] = {
		"headroom min 100", "headroom average 100", "headroom min 1000", "headroom average 1000", "headroom min 10000",
		"headroom average 20000", "headroom min 0", "headroom min 100 pid=1234", "headroom average 100 comm=kworker/0:1",
		"headroom min cpu0", "headroom min 100 tid 77", "garbage", "", "headroom min /system/bin/surfaceflinger",
	};
	for (int state = 0; state < 4; state++) {
		memset(&r, 0, sizeof r);
		if (state == 1)
			fill_ring(&r, 7, ramp);
		if (state == 2)
			fill_ring(&r, 100, steady40);
		if (state == 3) {
			fill_ring(&r, 5, steady40);
			r.s[(r.pushed - 2) % RING_N].avail = 1ULL << 40;
		}
		for (size_t i = 0; i < sizeof REQS / sizeof REQS[0]; i++) {
			memset(out, 'Z', sizeof out);
			size_t n = handle_request(&r, REQS[i], strlen(REQS[i]), out, sizeof out);
			CHECK(n > 0 && n < sizeof out && out[n] == 0 && wire_shape(out), "state=%d wire_shape(handle_request('%s')) == 1 reply='%s'", state, REQS[i], out);
			CHECK(!strstr(out, "pid") && !strstr(out, "comm") && !strstr(out, "kworker") && !strstr(out, "surfaceflinger") && !strstr(out, "cpu0") && !strstr(out, "tid"),
			      "reply='%s' has no pid, comm, kworker, surfaceflinger, cpu0 or tid", out);
		}
	}

	struct answer a = { A_OK, 50.0, 100, 1 };
	CHECK(sizeof a <= 24, "sizeof(struct answer) <= 24 size=%zu", sizeof a);

	struct stats s = { 5, 3, 2, 1, 123456789ULL, 1, "" };
	char buf[STATS_BUF];
	int n = status_build(&s, buf, sizeof buf);
	CHECK(n > 0 && buf[0] == '{' && strstr(buf, "\"samples\":5") && strstr(buf, "\"requests\":3") && strstr(buf, "\"refused\":2") &&
	      strstr(buf, "\"last_error\":\"\"") && !strstr(buf, "pid") && !strstr(buf, "comm"), "status_build has samples, requests, refused, last_error and no pid or comm status=%s", buf);
	g_quiet = 1;
	memset(&g_stats, 0, sizeof g_stats);
	note_error("read /proc/stat: \"bad\"\n\\ value");
	CHECK(!strchr(g_stats.last_error, '"') && !strchr(g_stats.last_error, '\n') && !strchr(g_stats.last_error, '\\') && strstr(g_stats.last_error, "bad"), "last_error has no quote, newline or backslash last_error=%s", g_stats.last_error);
	CHECK(status_build(&g_stats, buf, sizeof buf) > 0 && strstr(buf, "\"last_error\":\"read /proc/stat: _bad___ value\""), "status_build last_error == sanitized error status=%s", buf);
	volatile size_t tight = 20;
	CHECK(status_build(&s, buf, tight) == -1, "status_build(cap 20) == -1");
}

// test peer_allowed, trim_ctx and peer_sandbox
static void test_peer(void)
{
	T_case = "peer";
	CHECK(peer_allowed("u:r:rhizo_power:s0", 1) == 1, "peer_allowed(POWER_CTX, 1) == 1");
	CHECK(peer_allowed("u:r:rhizo_power:s0", 0) == 0, "peer_allowed(POWER_CTX, 0) == 0");
	CHECK(peer_allowed("u:r:rhizo_delayd:s0", 1) == 0, "peer_allowed(rhizo_delayd, 1) == 0");
	CHECK(peer_allowed("u:r:init:s0", 1) == 0, "peer_allowed(init, 1) == 0");
	CHECK(peer_allowed("u:r:rhizo_power:s0:c512,c768", 1) == 0, "peer_allowed(POWER_CTX:c512,c768, 1) == 0");
	CHECK(peer_allowed("u:r:rhizo_power:s1", 1) == 0, "peer_allowed(rhizo_power:s1, 1) == 0");
	CHECK(peer_allowed("u:r:rhizo_powerx:s0", 1) == 0, "peer_allowed(rhizo_powerx, 1) == 0");
	CHECK(peer_allowed("u:r:rhizo_pow:s0", 1) == 0, "peer_allowed(rhizo_pow, 1) == 0");
	CHECK(peer_allowed("u:r:rhizo_power:s0 ", 1) == 0, "peer_allowed(POWER_CTX with a trailing space, 1) == 0");
	CHECK(peer_allowed("", 1) == 0, "peer_allowed(\"\", 1) == 0");
	CHECK(peer_allowed("unconfined", 1) == 0, "peer_allowed(unconfined, 1) == 0");
	CHECK(peer_allowed("kernel", 0) == 0, "peer_allowed(kernel, 0) == 0");

	char c[64];
	snprintf(c, sizeof c, "u:r:rhizo_power:s0\n");
	trim_ctx(c);
	CHECK(!strcmp(c, POWER_CTX), "trim_ctx(POWER_CTX\\n) == POWER_CTX ctx='%s'", c);
	snprintf(c, sizeof c, "u:r:rhizo_power:s0 \n ");
	trim_ctx(c);
	CHECK(!strcmp(c, POWER_CTX), "trim_ctx(POWER_CTX \\n ) == POWER_CTX ctx='%s'", c);
	snprintf(c, sizeof c, " ");
	trim_ctx(c);
	CHECK(c[0] == 0, "trim_ctx(\" \") == \"\"");

	char why[256] = "";
	CHECK(peer_sandbox((int)getpid(), why, sizeof why) == -1 && strstr(why, "host pid namespace"), "peer_sandbox(getpid()) == -1 && why has host pid namespace why='%s'", why);
	CHECK(peer_sandbox(0x7ffffff0, why, sizeof why) == -1 && strstr(why, "failed to read"), "peer_sandbox(0x7ffffff0) == -1 && why has failed to read why='%s'", why);
}

// create a file and write text
static int selftest_file(const char *path, const char *text)
{
	FILE *f = fopen(path, "we");
	if (!f)
		return -1;
	int bad = fputs(text, f) < 0;
	return fclose(f) || bad ? -1 : 0;
}

// test enter_domain markers and exit status for each mode file
static void test_domain(void)
{
	T_case = "domain";
	char dir[] = "/tmp/rhizo-headroomd-selftest-XXXXXX";
	if (!mkdtemp(dir)) {
		CHECK(0, "mkdtemp %s failed (%s)", dir, strerror(errno));
		return;
	}
	char mode[64], cur[64], logpath[64], out[512];
	snprintf(mode, sizeof mode, "%s/mode", dir);
	snprintf(cur, sizeof cur, "%s/current", dir);
	snprintf(logpath, sizeof logpath, "%s/log", dir);
	CHECK(selftest_file(cur, "kernel") == 0, "failed to write %s (%s)", cur, strerror(errno));
	const char *fs = g_selinuxfs, *attr = g_attr_current;
	g_selinuxfs = dir;
	g_attr_current = cur;
	setenv("RHIZO_SELINUX_MODE_FILE", mode, 1);
	static const struct {
		const char *text, *want;
		int refuse;
	} C[] = {
		{ "namespace\n", "headroomd_domain state=no-selinux mode=namespace", 0 },
		{ "host\n", "headroomd_domain state=deferred", 0 },
		{ "namespaces\n", "headroomd_domain failed reason=selinux-mode", 1 },
		{ "namespace junk\n", "headroomd_domain failed reason=selinux-mode", 1 },
		{ "host \n", "headroomd_domain failed reason=selinux-mode", 1 },
		{ "", "headroomd_domain failed reason=selinux-mode", 1 },
		{ NULL, "headroomd_domain failed reason=selinux-mode", 1 },
	};
	static char name[] = "rhizo-headroomd";
	char *argv[] = { name, NULL };
	for (size_t i = 0; i < sizeof C / sizeof C[0]; i++) {
		unlink(mode);
		if (C[i].text)
			CHECK(selftest_file(mode, C[i].text) == 0, "failed to write %s (%s)", mode, strerror(errno));
		int saved = dup(2), fd = open(logpath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
		CHECK(saved >= 0 && fd >= 0 && dup2(fd, 2) == 2, "failed to redirect stderr to %s (%s)", logpath, strerror(errno));
		close(fd);
		g_quiet = 0;
		int status = 0;
		if (C[i].refuse) {
			pid_t pid = fork();
			if (pid == 0) {
				enter_domain(argv);
				_exit(0);
			}
			CHECK(pid > 0 && waitpid(pid, &status, 0) == pid, "fork or waitpid failed (%s)", strerror(errno));
		} else {
			enter_domain(argv);
		}
		g_quiet = 1;
		fflush(stderr);
		dup2(saved, 2);
		close(saved);
		if (read_text(logpath, out, sizeof out) < 0)
			out[0] = 0;
		CHECK(strstr(out, C[i].want) != NULL, "mode file %s log contains '%s' log='%s'",
		      C[i].text ? C[i].text : "absent", C[i].want, out);
		if (C[i].refuse)
			CHECK(WIFEXITED(status) && WEXITSTATUS(status) == SELINUX_MODE_EXIT, "mode file %s exit status == SELINUX_MODE_EXIT status=%d",
			      C[i].text ? C[i].text : "absent", status);
	}
	unsetenv("RHIZO_SELINUX_MODE_FILE");
	g_selinuxfs = fs;
	g_attr_current = attr;
	unlink(mode);
	unlink(cur);
	unlink(logpath);
	rmdir(dir);
}

// run the test_* functions and print the assertion counts
static int selftest(void)
{
	g_quiet = 1;
	test_parser();
	test_ring();
	test_protocol();
	test_disclosure();
	test_peer();
	test_domain();
	if (T_fail) {
		fprintf(stderr, "rhizo-headroomd selftest failed %d of %d assertions\n", T_fail, T_fail + T_pass);
		return 1;
	}
	printf("rhizo-headroomd selftest passed %d assertions\n", T_pass);
	return 0;
}

// print the usage text to stderr
static void usage(void)
{
	fputs("rhizo-headroomd [--socket PATH] [--status-path PATH] | --selftest\n", stderr);
}

// run the selftest or run_daemon
int main(int argc, char **argv)
{
	struct cfg cfg = { "/run/rhizo-headroom/headroomd", "/run/rhizo-headroomd/status.json", 0 };
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		int has = i + 1 < argc;
		if (!strcmp(a, "--selftest"))
			cfg.selftest = 1;
		else if (!strcmp(a, "--socket") && has)
			cfg.socket_path = argv[++i];
		else if (!strcmp(a, "--status-path") && has)
			cfg.status_path = argv[++i];
		else {
			usage();
			return 2;
		}
	}
	if (cfg.selftest)
		return selftest();
	enter_domain(argv);
	return run_daemon(&cfg);
}

// register a rhizo instance's input devices with its input fence
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/netlink.h>
#include <linux/seccomp.h>
#include <linux/uhid.h>
#include <linux/uinput.h>

#include "../fuse-wire/fuse_wire.h"

#if defined(__x86_64__)
#define THIS_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define THIS_AUDIT_ARCH AUDIT_ARCH_AARCH64
#else
#error "rhizo-inputd's seccomp filter names x86_64 and aarch64 only"
#endif
#ifndef __NR_pidfd_open
#define __NR_pidfd_open 434
#endif
#ifndef __NR_pidfd_getfd
#define __NR_pidfd_getfd 438
#endif
#define SELINUX_MODE_EXIT 78
#define NO_UDEV_EXIT 78
#define SYSNAME_LEN 64
#define MSG_MAX 1024
#define PATH_LEN 256
#define MAX_OWNED 512
#define MAX_PENDING 64
#define MAX_CLIENTS 32
#define OWNED_SOCKET_FMT "/run/udev/rhizo-input-%u.sock"
#define MAX_HANDLES 64
#define MAX_READS 64

static const char *g_mode = "?";

// print a message to stderr prefixed with the daemon mode
static void rz_log(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	fprintf(stderr, "rhizo-inputd %s: ", g_mode);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

// send a seqpacket message with an optional fd
static int send_msg(int s, const char *text, int fd)
{
	struct iovec iov = { .iov_base = (void *)text, .iov_len = strlen(text) };
	char cbuf[CMSG_SPACE(sizeof(int))];
	struct msghdr m = { .msg_iov = &iov, .msg_iovlen = 1 };

	if (fd >= 0) {
		memset(cbuf, 0, sizeof(cbuf));
		m.msg_control = cbuf;
		m.msg_controllen = sizeof(cbuf);
		struct cmsghdr *cm = CMSG_FIRSTHDR(&m);
		cm->cmsg_level = SOL_SOCKET;
		cm->cmsg_type = SCM_RIGHTS;
		cm->cmsg_len = CMSG_LEN(sizeof(int));
		memcpy(CMSG_DATA(cm), &fd, sizeof(int));
	}
	return sendmsg(s, &m, MSG_NOSIGNAL) < 0 ? -1 : 0;
}

// receive a message and an optional fd
static ssize_t recv_msg(int s, char *buf, size_t len, int *fd)
{
	char cbuf[CMSG_SPACE(sizeof(int))];
	struct iovec iov = { .iov_base = buf, .iov_len = len - 1 };
	struct msghdr m = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cbuf,
			    .msg_controllen = sizeof(cbuf) };

	*fd = -1;
	ssize_t n = recvmsg(s, &m, MSG_CMSG_CLOEXEC);
	if (n < 0)
		return -1;
	buf[n] = 0;
	for (struct cmsghdr *cm = CMSG_FIRSTHDR(&m); cm; cm = CMSG_NXTHDR(&m, cm))
		if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
			memcpy(fd, CMSG_DATA(cm), sizeof(int));
	return n;
}

// fill a unix socket address from a path
static int unix_addr(const char *path, struct sockaddr_un *a)
{
	memset(a, 0, sizeof(*a));
	a->sun_family = AF_UNIX;
	if (strlen(path) >= sizeof(a->sun_path)) {
		errno = ENAMETOOLONG;
		return -1;
	}
	strcpy(a->sun_path, path);
	return 0;
}

// connect to a unix seqpacket socket
static int unix_connect(const char *path)
{
	struct sockaddr_un a;
	int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);

	if (s < 0)
		return -1;
	if (unix_addr(path, &a) < 0 || connect(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
		int e = errno;
		close(s);
		errno = e;
		return -1;
	}
	return s;
}

// listen on a unix seqpacket socket
static int unix_listen(const char *path, mode_t mode)
{
	struct sockaddr_un a;
	int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);

	if (s < 0)
		return -1;
	if (unix_addr(path, &a) == 0)
		unlink(path);
	if (unix_addr(path, &a) < 0 || bind(s, (struct sockaddr *)&a, sizeof(a)) < 0 ||
	    chmod(path, mode) < 0 || listen(s, 16) < 0) {
		int e = errno;
		close(s);
		errno = e;
		return -1;
	}
	return s;
}

// get the value of a key from a uevent body
static const char *prop(const char *body, size_t len, const char *key, char *out, size_t outlen)
{
	size_t kl = strlen(key);
	const char *p = body, *end = body + len;

	while (p < end) {
		const char *e = p;
		while (e < end && *e && *e != '\n')
			e++;
		if ((size_t)(e - p) > kl && strncmp(p, key, kl) == 0 && p[kl] == '=') {
			size_t vl = (size_t)(e - p) - kl - 1;
			if (vl >= outlen)
				vl = outlen - 1;
			memcpy(out, p + kl + 1, vl);
			out[vl] = 0;
			return out;
		}
		p = e + 1;
	}
	return NULL;
}

// send a sd_notify message with an optional fd
static int sd_notify_fd(const char *text, int fd)
{
	const char *path = getenv("NOTIFY_SOCKET");
	struct sockaddr_un a = { .sun_family = AF_UNIX };
	char cbuf[CMSG_SPACE(sizeof(int))];
	struct iovec iov = { .iov_base = (void *)text, .iov_len = strlen(text) };
	struct msghdr m = { .msg_name = &a, .msg_iov = &iov, .msg_iovlen = 1 };
	size_t pl = path ? strlen(path) : 0;

	if (!pl || pl >= sizeof(a.sun_path)) {
		errno = ENOENT;
		return -1;
	}
	memcpy(a.sun_path, path, pl);
	if (a.sun_path[0] == '@')
		a.sun_path[0] = 0;
	m.msg_namelen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + pl + (path[0] == '@' ? 0 : 1));
	if (fd >= 0) {
		memset(cbuf, 0, sizeof(cbuf));
		m.msg_control = cbuf;
		m.msg_controllen = sizeof(cbuf);
		struct cmsghdr *cm = CMSG_FIRSTHDR(&m);
		cm->cmsg_level = SOL_SOCKET;
		cm->cmsg_type = SCM_RIGHTS;
		cm->cmsg_len = CMSG_LEN(sizeof(int));
		memcpy(CMSG_DATA(cm), &fd, sizeof(int));
	}
	int s = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (s < 0)
		return -1;
	int r = (int)sendmsg(s, &m, MSG_NOSIGNAL);
	int e = errno;
	close(s);
	errno = e;
	return r < 0 ? -1 : 0;
}

// hand a descriptor to the systemd fd store
static int fdstore(const char *name, int fd)
{
	char text[128];

	snprintf(text, sizeof(text), fd >= 0 ? "FDSTORE=1\nFDNAME=%s" : "FDSTOREREMOVE=1\nFDNAME=%s", name);
	return sd_notify_fd(text, fd);
}

// take back the fds systemd kept for this unit
static void adopt_stored(int *listener, int *cuse)
{
	const char *pid = getenv("LISTEN_PID"), *n = getenv("LISTEN_FDS"), *names = getenv("LISTEN_FDNAMES");
	char buf[512], *save = NULL;

	if (!pid || !n || strtol(pid, NULL, 10) != (long)getpid())
		return;
	snprintf(buf, sizeof(buf), "%s", names ? names : "");
	long count = strtol(n, NULL, 10);
	char *tok = strtok_r(buf, ":", &save);
	for (long i = 0; i < count && i < 64; i++, tok = tok ? strtok_r(NULL, ":", &save) : NULL) {
		int fd = 3 + (int)i;
		fcntl(fd, F_SETFD, FD_CLOEXEC);
		if (tok && !strcmp(tok, "listener") && *listener < 0)
			*listener = fd;
		else if (tok && !strcmp(tok, "cuse") && *cuse < 0)
			*cuse = fd;
		else
			close(fd);
	}
	rz_log("RHIZO_MARKER input_owner=adopted listener=%s cuse=%s", *listener >= 0 ? "yes" : "no",
	       *cuse >= 0 ? "yes" : "no");
	unsetenv("LISTEN_PID");
	unsetenv("LISTEN_FDS");
	unsetenv("LISTEN_FDNAMES");
}


static const char *g_attr_dir = "/proc/self/attr";
static const char *g_selinuxfs = "/sys/fs/selinux";
#define ENTERING_ENV "RHIZO_INPUTD_ENTERING"
static const char *g_deferred_ctx;

// read a context file into out
static int read_ctx(const char *path, char *out, size_t len)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);

	if (fd < 0)
		return -1;
	ssize_t n = read(fd, out, len - 1);
	int e = errno;
	close(fd);
	if (n < 0) {
		errno = e;
		return -1;
	}
	out[n] = 0;
	while (n > 0 && (out[n - 1] == 0 || out[n - 1] == '\n'))
		out[--n] = 0;
	return 0;
}

// read the recorded SELinux mode
static int selinux_namespace_mode(void)
{
	const char *path = getenv("RHIZO_SELINUX_MODE_FILE");
	char buf[32] = "";

	if (!path)
		path = "/run/rhizo-selinux-mode";
	FILE *f = fopen(path, "re");
	if (!f) {
		rz_log("RHIZO_MARKER input_owner=failed reason=selinux-mode mode-file=%s errno=%d", path, errno);
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
	rz_log("RHIZO_MARKER input_owner=failed reason=selinux-mode mode-file=%s value='%s'", path, buf);
	return -1;
}

// re-exec into a selinux context
static void enter_domain(const char *ctx, char **argv)
{
	char path[PATH_LEN], cur[256];
	struct stat st;

	int ns = selinux_namespace_mode();
	if (ns < 0)
		exit(SELINUX_MODE_EXIT);
	if (ns) {
		rz_log("RHIZO_MARKER input_owner=domain state=no-selinux mode=namespace want=%s", ctx);
		return;
	}
	if (stat(g_selinuxfs, &st) < 0) {
		if (errno != ENOENT) {
			rz_log("RHIZO_MARKER input_owner=failed reason=domain-selinuxfs:%d want=%s", errno, ctx);
			exit(1);
		}
		rz_log("RHIZO_MARKER input_owner=domain state=no-selinux want=%s", ctx);
		return;
	}
	snprintf(path, sizeof(path), "%s/current", g_attr_dir);
	if (read_ctx(path, cur, sizeof(cur)) < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=domain-read:%d want=%s", errno, ctx);
		exit(1);
	}
	if (!strcmp(cur, ctx)) {
		unsetenv(ENTERING_ENV);
		rz_log("RHIZO_MARKER input_owner=domain entered=%s", ctx);
		return;
	}
	if (!strcmp(cur, "kernel")) {
		rz_log("RHIZO_MARKER input_owner=domain state=deferred current=%s want=%s", cur, ctx);
		g_deferred_ctx = ctx;
		return;
	}
	if (!strcmp(cur, "u:r:kernel:s0")) {
		rz_log("RHIZO_MARKER input_owner=failed reason=domain-kernel current=%s want=%s", cur, ctx);
		exit(1);
	}
	if (getenv(ENTERING_ENV)) {
		rz_log("RHIZO_MARKER input_owner=failed reason=domain-refused current=%s want=%s", cur, ctx);
		exit(1);
	}
	snprintf(path, sizeof(path), "%s/exec", g_attr_dir);
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0 || write(fd, ctx, strlen(ctx)) != (ssize_t)strlen(ctx)) {
		rz_log("RHIZO_MARKER input_owner=failed reason=domain-setexec:%d current=%s want=%s", errno, cur, ctx);
		exit(1);
	}
	close(fd);
	setenv(ENTERING_ENV, "1", 1);
	execv("/proc/self/exe", argv);
	rz_log("RHIZO_MARKER input_owner=failed reason=domain-exec:%d current=%s want=%s", errno, cur, ctx);
	exit(1);
}

// exit when running as the kernel domain after a policy load
static void exit_if_kernel_after_load(void)
{
	char path[PATH_LEN], cur[256];

	if (!g_deferred_ctx)
		return;
	snprintf(path, sizeof(path), "%s/current", g_attr_dir);
	if (read_ctx(path, cur, sizeof(cur)) < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=domain-read:%d want=%s", errno, g_deferred_ctx);
		exit(1);
	}
	if (strcmp(cur, "u:r:kernel:s0"))
		return;
	rz_log("RHIZO_MARKER input_owner=failed reason=domain-kernel-after-load want=%s"
	       " -- exiting", g_deferred_ctx);
	exit(1);
}


// pending uhid create reported by the broker
struct pending_hid {
	int used;
	int client;
	char tag[64];
	char token[40];
	char devpath[PATH_LEN];
};

static char g_owned[MAX_OWNED][PATH_LEN];
static struct pending_hid g_pending[MAX_PENDING];
static int g_fence = -1;
static const char *g_fence_path;
static const char *g_state_path;
static const char *g_sys_root = "/sys";
static char g_broker_cgroup[PATH_LEN];
static unsigned g_instance;
static int g_listener_uid = -1;
static int g_owned_uid = -1;
static dev_t g_uinput_rdev;
static int g_uevent_netlink = 1;
static struct seccomp_notif_sizes g_sizes;

// return the table index of an owned device path, or -1
static int owned_index(const char *devpath)
{
	for (int i = 0; i < MAX_OWNED; i++)
		if (g_owned[i][0] && strcmp(g_owned[i], devpath) == 0)
			return i;
	return -1;
}

// return whether devpath is an owned device or sits under one
static int owned_covers(const char *devpath)
{
	for (int i = 0; i < MAX_OWNED; i++) {
		size_t n = strlen(g_owned[i]);
		if (n && strncmp(devpath, g_owned[i], n) == 0 && (devpath[n] == 0 || devpath[n] == '/'))
			return 1;
	}
	return 0;
}

// send a line to the fence
static void fence_send(const char *verb, const char *devpath)
{
	char line[MSG_MAX];

	snprintf(line, sizeof(line), "%s %.*s", verb, PATH_LEN, devpath);
	for (int attempt = 0; attempt < 2; attempt++) {
		if (g_fence < 0 && g_fence_path) {
			g_fence = unix_connect(g_fence_path);
			for (int i = 0; g_fence >= 0 && i < MAX_OWNED; i++)
				if (g_owned[i][0] && strcmp(g_owned[i], devpath) != 0) {
					char again[MSG_MAX];
					snprintf(again, sizeof(again), "add %.*s", PATH_LEN, g_owned[i]);
					send_msg(g_fence, again, -1);
				}
		}
		if (g_fence < 0)
			break;
		if (send_msg(g_fence, line, -1) == 0)
			return;
		close(g_fence);
		g_fence = -1;
	}
	rz_log("RHIZO_MARKER input_owner=unsent verb=%s devpath=%s fence=%s errno=%d", verb, devpath,
	       g_fence_path ? g_fence_path : "<none>", errno);
}

// write the owned set to the state file
static void save_state(void)
{
	char tmp[PATH_LEN + 8];

	if (!g_state_path)
		return;
	snprintf(tmp, sizeof(tmp), "%s.new", g_state_path);
	FILE *f = fopen(tmp, "we");
	if (!f) {
		rz_log("RHIZO_MARKER input_owner=failed reason=state:%d path=%s", errno, tmp);
		return;
	}
	for (int i = 0; i < MAX_OWNED; i++)
		if (g_owned[i][0])
			fprintf(f, "%s\n", g_owned[i]);
	if (fclose(f) != 0 || rename(tmp, g_state_path) < 0)
		rz_log("RHIZO_MARKER input_owner=failed reason=state:%d path=%s", errno, g_state_path);
}

// read back the saved owned set
static void load_state(void)
{
	char line[PATH_LEN], path[PATH_LEN * 2];
	struct stat st;
	int n = 0;

	FILE *f = g_state_path ? fopen(g_state_path, "re") : NULL;
	if (!f)
		return;
	while (n < MAX_OWNED && fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\n")] = 0;
		snprintf(path, sizeof(path), "%s%s", g_sys_root, line);
		if (line[0] == '/' && stat(path, &st) == 0)
			snprintf(g_owned[n++], PATH_LEN, "%s", line);
	}
	fclose(f);
	rz_log("RHIZO_MARKER input_owner=restored owned=%d", n);
}

// register a device path as owned
static int own(const char *devpath, const char *by)
{
	if (owned_index(devpath) >= 0)
		return 0;
	for (int i = 0; i < MAX_OWNED; i++)
		if (!g_owned[i][0]) {
			snprintf(g_owned[i], PATH_LEN, "%s", devpath);
			rz_log("RHIZO_MARKER input_owner=registered devpath=%s by=%s", devpath, by);
			save_state();
			fence_send("add", devpath);
			return 0;
		}
	rz_log("RHIZO_MARKER input_owner=failed reason=table-full devpath=%s", devpath);
	return -1;
}

// remove a device path from the owned table
static void disown(const char *devpath)
{
	int i = owned_index(devpath);

	if (i < 0)
		return;
	g_owned[i][0] = 0;
	rz_log("RHIZO_MARKER input_owner=released devpath=%s", devpath);
	save_state();
	fence_send("del", devpath);
}

// match a hid device to its pending create
static struct pending_hid *match_hid(const char *devpath, const char *body, size_t len)
{
	char phys[65];

	if (!prop(body, len, "HID_PHYS", phys, sizeof(phys)) || !phys[0])
		return NULL;
	for (int i = 0; i < MAX_PENDING; i++) {
		struct pending_hid *p = &g_pending[i];
		if (p->used && !p->devpath[0] && !strcmp(p->token, phys)) {
			snprintf(p->devpath, sizeof(p->devpath), "%s", devpath);
			return p;
		}
	}
	return NULL;
}

// get the uhid directory a device path sits in
static int uhid_parent(const char *devpath, char *out, size_t outlen)
{
	static const char pre[] = "/devices/virtual/misc/uhid/";

	if (strncmp(devpath, pre, sizeof(pre) - 1) != 0)
		return 0;
	const char *slash = strchr(devpath + sizeof(pre) - 1, '/');
	size_t n = slash ? (size_t)(slash - devpath) : strlen(devpath);
	if (n >= outlen)
		return 0;
	memcpy(out, devpath, n);
	out[n] = 0;
	return 1;
}

// return whether a device path is owned
static int owned_now(const char *devpath)
{
	char hid[PATH_LEN], path[PATH_LEN * 2], body[4096];

	if (owned_covers(devpath))
		return 1;
	if (!uhid_parent(devpath, hid, sizeof(hid)))
		return 0;
	snprintf(path, sizeof(path), "%s%s/uevent", g_sys_root, hid);
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return 0;
	ssize_t n = read(fd, body, sizeof(body) - 1);
	close(fd);
	if (n <= 0)
		return 0;
	body[n] = 0;
	struct pending_hid *p = match_hid(hid, body, (size_t)n);
	if (!p)
		return 0;
	return own(hid, p->tag) == 0;
}

// return the thread group leader of a thread
static int tgid_of(int tid)
{
	char path[64], line[128];
	int tgid = -1;

	snprintf(path, sizeof(path), "/proc/%d/status", tid);
	FILE *f = fopen(path, "re");
	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f))
		if (!strncmp(line, "Tgid:", 5))
			tgid = (int)strtol(line + 5, NULL, 10);
	fclose(f);
	return tgid > 0 ? tgid : -1;
}

// create the caller's uinput device and register it
static void handle_notification(int listener)
{
	struct seccomp_notif *req = calloc(1, g_sizes.seccomp_notif);
	struct seccomp_notif_resp *resp = calloc(1, g_sizes.seccomp_notif_resp);
	int target = -1, pidfd = -1;
	struct stat st;

	if (!req || !resp) {
		rz_log("RHIZO_MARKER input_owner=failed reason=oom");
		goto out;
	}
	if (ioctl(listener, SECCOMP_IOCTL_NOTIF_RECV, req) < 0) {
		if (errno != ENOENT)
			rz_log("notification receive failed: errno=%d", errno);
		goto out;
	}
	resp->id = req->id;
	int tgid = tgid_of(req->pid);
	if (tgid < 0)
		errno = ESRCH;
	else
		pidfd = (int)syscall(__NR_pidfd_open, tgid, 0);
	if (pidfd >= 0)
		target = (int)syscall(__NR_pidfd_getfd, pidfd, (int)req->data.args[0], 0);
	if (target < 0 || fstat(target, &st) < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=getfd:%d pid=%d tgid=%d fd=%lld", errno, req->pid, tgid,
		       (long long)req->data.args[0]);
		resp->error = -EPERM;
		resp->val = -1;
	} else if (ioctl(listener, SECCOMP_IOCTL_NOTIF_ID_VALID, &req->id) < 0) {
		resp->error = -EINTR;
		resp->val = -1;
	} else if (!S_ISCHR(st.st_mode) || st.st_rdev != g_uinput_rdev) {
		resp->error = -ENOTTY;
		resp->val = -1;
	} else if (ioctl(target, UI_DEV_CREATE) < 0) {
		resp->error = -errno;
		resp->val = -1;
	} else {
		char sysname[SYSNAME_LEN] = { 0 }, devpath[PATH_LEN], by[64];
		int e = 0;
		if (ioctl(target, UI_GET_SYSNAME(sizeof(sysname) - 1), sysname) < 0) {
			rz_log("RHIZO_MARKER input_owner=failed reason=sysname:%d pid=%d", errno, req->pid);
			e = EIO;
		} else {
			snprintf(devpath, sizeof(devpath), "/devices/virtual/input/%s", sysname);
			snprintf(by, sizeof(by), "uinput:pid%d", req->pid);
			if (own(devpath, by) < 0)
				e = ENOSPC;
		}
		if (e) {
			ioctl(target, UI_DEV_DESTROY);
			resp->error = -e;
			resp->val = -1;
		}
	}
	if (ioctl(listener, SECCOMP_IOCTL_NOTIF_SEND, resp) < 0 && errno != ENOENT)
		rz_log("notification reply failed: errno=%d", errno);
out:
	if (target >= 0)
		close(target);
	if (pidfd >= 0)
		close(pidfd);
	free(req);
	free(resp);
}

// handle a kernel uevent
static void handle_uevent(int nl)
{
	char buf[8192], action[32], devpath[PATH_LEN], subsystem[64], hid[PATH_LEN];
	struct sockaddr_nl from;
	socklen_t fl = sizeof(from);

	memset(&from, 0, sizeof(from));
	ssize_t n = recvfrom(nl, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&from, &fl);
	if (n <= 0 || (g_uevent_netlink && from.nl_pid != 0))
		return;
	buf[n] = 0;
	if (!memchr(buf, '@', (size_t)n) || !prop(buf, (size_t)n, "ACTION", action, sizeof(action)) ||
	    !prop(buf, (size_t)n, "DEVPATH", devpath, sizeof(devpath)) ||
	    !prop(buf, (size_t)n, "SUBSYSTEM", subsystem, sizeof(subsystem)))
		return;
	if (!strcmp(action, "remove")) {
		disown(devpath);
		for (int i = 0; i < MAX_PENDING; i++)
			if (g_pending[i].used && !strcmp(g_pending[i].devpath, devpath))
				g_pending[i].used = 0;
		return;
	}
	if (!strcmp(action, "add") && !strcmp(subsystem, "hid") && uhid_parent(devpath, hid, sizeof(hid)) &&
	    !strcmp(hid, devpath)) {
		struct pending_hid *p = match_hid(devpath, buf, (size_t)n);
		if (p)
			own(devpath, p->tag);
	}
}

// record a uhid create under a new token
static int add_pending(const char *tag, int client, char *out, size_t outlen)
{
	struct pending_hid p = { .used = 1, .client = client };
	uint64_t r;

	if (!tag[0] || strlen(tag) >= sizeof(p.tag) || strchr(tag, ' ')) {
		rz_log("malformed pending message");
		return -1;
	}
	if (getrandom(&r, sizeof(r), 0) != (ssize_t)sizeof(r)) {
		rz_log("RHIZO_MARKER input_owner=failed reason=getrandom:%d", errno);
		return -1;
	}
	snprintf(p.tag, sizeof(p.tag), "%s", tag);
	snprintf(p.token, sizeof(p.token), "rhizo-uhid-%u-%016" PRIx64, g_instance, r);
	for (int i = 0; i < MAX_PENDING; i++)
		if (g_pending[i].used && !strcmp(g_pending[i].tag, p.tag)) {
			rz_log("RHIZO_MARKER input_owner=failed reason=pending-duplicate tag=%s", p.tag);
			return -1;
		}
	for (int i = 0; i < MAX_PENDING; i++)
		if (!g_pending[i].used) {
			g_pending[i] = p;
			snprintf(out, outlen, "%s", p.token);
			return 0;
		}
	rz_log("RHIZO_MARKER input_owner=failed reason=pending-full tag=%s", p.tag);
	return -1;
}

// return the uid of a connected client, or -1
static int peer_uid(int c)
{
	struct ucred cr;
	socklen_t l = sizeof(cr);

	return getsockopt(c, SOL_SOCKET, SO_PEERCRED, &cr, &l) == 0 ? (int)cr.uid : -1;
}

#ifndef SO_PEERPIDFD
#define SO_PEERPIDFD 77
#endif

// return the pid a pidfd names, or -1
static int pidfd_pid(int pidfd)
{
	char path[64], line[128];
	int pid = -1;

	snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", pidfd);
	FILE *f = fopen(path, "re");
	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f))
		if (!strncmp(line, "Pid:", 4))
			pid = (int)strtol(line + 4, NULL, 10);
	fclose(f);
	return pid > 0 ? pid : -1;
}

// return whether the peer is this instance's uhid broker
static int peer_is_broker(int c)
{
	struct ucred cr = { .pid = -1 };
	socklen_t l = sizeof(int);
	int pidfd = -1, ok = 0;
	char path[64], line[PATH_LEN * 2];

	if (getsockopt(c, SOL_SOCKET, SO_PEERPIDFD, &pidfd, &l) < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=peerpidfd:%d", errno);
		return 0;
	}
	l = sizeof(cr);
	if (getsockopt(c, SOL_SOCKET, SO_PEERCRED, &cr, &l) < 0)
		goto out;
	snprintf(path, sizeof(path), "/proc/%d/cgroup", (int)cr.pid);
	FILE *f = fopen(path, "re");
	if (!f)
		goto out;
	while (fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\n")] = 0;
		size_t n = strlen(line), s = strlen(g_broker_cgroup);
		if (!strncmp(line, "0::", 3) && n >= 3 + s && !strcmp(line + n - s, g_broker_cgroup))
			ok = 1;
	}
	fclose(f);
	if (ok && pidfd_pid(pidfd) != (int)cr.pid)
		ok = 0;
out:
	close(pidfd);
	if (!ok)
		rz_log("RHIZO_MARKER input_owner=refused-client pid=%d reason=not-the-broker", (int)cr.pid);
	return ok;
}

// open the CUSE channel and answer CUSE_INIT
static int cuse_open_init(const char *path, int fd)
{
	static _Alignas(8) uint8_t buf[FUSE_MIN_READ_BUFFER];
	_Static_assert(sizeof(buf) >= FUSE_MIN_READ_BUFFER, "a CUSE read buffer below FUSE_MIN_READ_BUFFER");
	char info[64];

	if (fd < 0)
		fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=cuse-open:%d path=%s", errno, path);
		return -1;
	}
	ssize_t n = read(fd, buf, sizeof(buf));
	struct fuse_in_header *in = (void *)buf;
	struct cuse_init_in *ci = (void *)(buf + sizeof(*in));
	if (n < (ssize_t)(sizeof(*in) + sizeof(*ci)) || in->opcode != CUSE_INIT || ci->major != FUSE_KERNEL_VERSION) {
		rz_log("RHIZO_MARKER input_owner=failed reason=cuse-init read=%zd errno=%d", n, errno);
		close(fd);
		return -1;
	}
	int ilen = snprintf(info, sizeof(info), "DEVNAME=rhizo-%u-uhid", g_instance) + 1;
	struct cuse_init_out co = {
		.major = FUSE_KERNEL_VERSION,
		.minor = ci->minor < FUSE_KERNEL_MINOR_VERSION ? ci->minor : FUSE_KERNEL_MINOR_VERSION,
		.max_read = sizeof(struct uhid_event),
		.max_write = sizeof(struct uhid_event),
	};
	struct iovec iov[2] = { { &co, sizeof(co) }, { info, (size_t)ilen } };
	if (fuse_wire_reply(fd, in->unique, 0, iov, 2) < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=cuse-init-reply:%d", errno);
		close(fd);
		return -1;
	}
	rz_log("RHIZO_MARKER input_owner=uhid-ready devname=rhizo-%u-uhid", g_instance);
	return fd;
}

// copy a client's text for a log line
static const char *printable(const char *in, char *out, size_t n)
{
	size_t i = 0;

	for (; in[i] && i + 1 < n; i++)
		out[i] = isalnum((unsigned char)in[i]) || strchr("/._:-@+,", in[i]) ? in[i] : '?';
	out[i] = 0;
	return out;
}

// per-client state
struct client {
	int fd;
	int checked, broker, owned_only;
};

// handle a message from a client
static int handle_client(struct client *cl, int *listener, int cuse)
{
	char msg[MSG_MAX], out[64], safe[65];
	int fd, c = cl->fd;

	if (recv_msg(c, msg, sizeof(msg), &fd) <= 0)
		return -1;
	if (cl->owned_only && (peer_uid(c) != g_owned_uid || strncmp(msg, "owned ", 6))) {
		if (fd >= 0)
			close(fd);
		rz_log("RHIZO_MARKER input_owner=refused-owned-socket uid=%d message=%s", peer_uid(c),
		       printable(msg, safe, 33));
		send_msg(c, "refused", -1);
		return 0;
	}
	if (!strcmp(msg, "listener") && fd >= 0 && peer_uid(c) != g_listener_uid) {
		rz_log("RHIZO_MARKER input_owner=refused-listener uid=%d", peer_uid(c));
		close(fd);
		send_msg(c, "refused", -1);
		return 0;
	}
	if (!strcmp(msg, "listener") && fd >= 0) {
		if (*listener >= 0)
			close(*listener);
		*listener = fd;
		if (fdstore("listener", -1) < 0 && errno != ENOENT)
			rz_log("RHIZO_MARKER input_owner=failed reason=fdstore-remove:%d", errno);
		if (fdstore("listener", fd) < 0 && errno != ENOENT)
			rz_log("RHIZO_MARKER input_owner=failed reason=fdstore:%d", errno);
		if (g_fence >= 0)
			close(g_fence);
		g_fence = -1;
		rz_log("RHIZO_MARKER input_owner=listening");
		send_msg(c, "ok", -1);
		return 0;
	}
	if (fd >= 0)
		close(fd);
	if (!strncmp(msg, "owned ", 6)) {
		send_msg(c, owned_now(msg + 6) ? "yes" : "no", -1);
		return 0;
	}
	if (strcmp(msg, "cuse") && strncmp(msg, "pending ", 8) && strncmp(msg, "done ", 5)) {
		rz_log("unknown message '%s'", printable(msg, safe, sizeof(safe)));
		return 0;
	}
	if (!cl->checked) {
		cl->broker = peer_is_broker(c);
		cl->checked = 1;
	}
	if (!cl->broker) {
		send_msg(c, "refused", -1);
		return 0;
	}
	if (!strcmp(msg, "cuse")) {
		send_msg(c, cuse >= 0 ? "ok" : "refused", cuse);
	} else if (!strncmp(msg, "pending ", 8)) {
		char reply_line[80];
		if (add_pending(msg + 8, c, out, sizeof(out)) == 0) {
			snprintf(reply_line, sizeof(reply_line), "ok %s", out);
			send_msg(c, reply_line, -1);
		} else {
			send_msg(c, "refused", -1);
		}
	} else {
		for (int i = 0; i < MAX_PENDING; i++)
			if (g_pending[i].used && !strcmp(g_pending[i].tag, msg + 5)) {
				if (g_pending[i].devpath[0])
					disown(g_pending[i].devpath);
				g_pending[i].used = 0;
			}
	}
	return 0;
}

// accept a client of a listening socket
static void accept_client(int ls, struct client *clients, int owned_only)
{
	int c = accept4(ls, NULL, NULL, SOCK_CLOEXEC);

	for (int i = 0; c >= 0 && i < MAX_CLIENTS; i++)
		if (clients[i].fd < 0) {
			clients[i] = (struct client){ .fd = c, .owned_only = owned_only };
			return;
		}
	if (c >= 0)
		close(c);
}

// serve the supervisor sockets, uevents and clients
static int run_supervise(const char *sock_path, const char *owned_path, int nl, int listener, int cuse)
{
	struct client clients[MAX_CLIENTS];
	int ls, owned_ls;

	if (g_owned_uid == 0 && geteuid() != 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=owned-uid-unserved euid=%d", (int)geteuid());
		return NO_UDEV_EXIT;
	}
	ls = unix_listen(sock_path, 0660);
	if (ls < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=listen:%d path=%s", errno, sock_path);
		return 1;
	}
	owned_ls = unix_listen(owned_path, 0600);
	if (owned_ls < 0) {
		int e = errno;
		rz_log("RHIZO_MARKER input_owner=failed reason=%s:%d path=%s",
		       e == ENOENT ? "no-udev" : "listen", e, owned_path);
		return e == ENOENT ? NO_UDEV_EXIT : 1;
	}
	if (syscall(__NR_seccomp, SECCOMP_GET_NOTIF_SIZES, 0, &g_sizes) < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=notif-sizes:%d", errno);
		return 1;
	}
	for (int i = 0; i < MAX_CLIENTS; i++)
		clients[i] = (struct client){ .fd = -1 };
	rz_log("RHIZO_MARKER input_owner=ready socket=%s owned-socket=%s", sock_path, owned_path);
	if (sd_notify_fd("READY=1", -1) < 0 && errno != ENOENT)
		rz_log("RHIZO_MARKER input_owner=failed reason=notify-ready:%d", errno);
	for (;;) {
		struct pollfd pf[4 + MAX_CLIENTS];
		pf[0] = (struct pollfd){ .fd = ls, .events = POLLIN };
		pf[1] = (struct pollfd){ .fd = nl, .events = POLLIN };
		pf[2] = (struct pollfd){ .fd = listener, .events = POLLIN };
		pf[3] = (struct pollfd){ .fd = owned_ls, .events = POLLIN };
		for (int i = 0; i < MAX_CLIENTS; i++)
			pf[4 + i] = (struct pollfd){ .fd = clients[i].fd, .events = POLLIN };
		if (poll(pf, 4 + MAX_CLIENTS, -1) < 0) {
			if (errno == EINTR)
				continue;
			rz_log("poll failed: errno=%d", errno);
			return 1;
		}
		exit_if_kernel_after_load();
		if (pf[1].revents & POLLIN)
			handle_uevent(nl);
		if (listener >= 0 && (pf[2].revents & POLLIN)) {
			handle_notification(listener);
		} else if (listener >= 0 && (pf[2].revents & (POLLHUP | POLLERR | POLLNVAL))) {
			rz_log("RHIZO_MARKER input_owner=listener-closed");
			close(listener);
			listener = -1;
			if (fdstore("listener", -1) < 0 && errno != ENOENT)
				rz_log("RHIZO_MARKER input_owner=failed reason=fdstore-remove:%d", errno);
		}
		if (pf[0].revents & POLLIN)
			accept_client(ls, clients, 0);
		if (pf[3].revents & POLLIN)
			accept_client(owned_ls, clients, 1);
		for (int i = 0; i < MAX_CLIENTS; i++) {
			if (clients[i].fd < 0 || !pf[4 + i].revents)
				continue;
			if (!(pf[4 + i].revents & POLLIN) || handle_client(&clients[i], &listener, cuse) < 0) {
				for (int k = 0; k < MAX_PENDING; k++)
					if (g_pending[k].used && g_pending[k].client == clients[i].fd)
						g_pending[k].used = 0;
				close(clients[i].fd);
				clients[i] = (struct client){ .fd = -1 };
			}
		}
	}
}

// open the kernel uevent socket
static int uevent_socket(const char *fixture)
{
	if (fixture) {
		g_uevent_netlink = 0;
		return unix_connect(fixture);
	}
	int s = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_KOBJECT_UEVENT);
	int sz = 4 << 20;
	struct sockaddr_nl a = { .nl_family = AF_NETLINK, .nl_groups = 1 };

	if (s < 0)
		return -1;
	setsockopt(s, SOL_SOCKET, SO_RCVBUF, &sz, sizeof(sz));
	if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
		close(s);
		return -1;
	}
	return s;
}


// state for an open of the instance's /dev/uhid
struct handle {
	int used;
	int fd;
	int nonblock;
	uint64_t kh;
	int created;
};

// state for a blocking uhid read
struct pending_read {
	int used;
	uint64_t unique, fh;
	uint32_t size;
};

static struct handle g_h[MAX_HANDLES];
static struct pending_read g_reads[MAX_READS];
static int g_cuse = -1, g_sup = -1;
static const char *g_uhid_path = "/dev/uhid";
static unsigned g_instance;

// send a reply for a FUSE request
static void reply(uint64_t unique, int error, const void *data, uint32_t len)
{
	struct iovec iov = { .iov_base = (void *)data, .iov_len = len };

	if (fuse_wire_reply(g_cuse, unique, error, &iov, len ? 1 : 0) < 0 && errno != ENOENT)
		rz_log("reply to %" PRIu64 " failed: errno=%d", unique, errno);
}

// wake a poller of the CUSE device
static void notify_poll(uint64_t kh)
{
	struct fuse_notify_poll_wakeup_out w = { .kh = kh };
	struct iovec iov = { .iov_base = &w, .iov_len = sizeof(w) };

	fuse_wire_reply(g_cuse, 0, FUSE_NOTIFY_POLL, &iov, 1);
}

// open the host's uhid device
static int open_uhid(void)
{
	struct stat st;

	if (stat(g_uhid_path, &st) == 0 && S_ISSOCK(st.st_mode)) {
		int s = unix_connect(g_uhid_path);
		if (s >= 0)
			fcntl(s, F_SETFL, O_NONBLOCK);
		return s;
	}
	return open(g_uhid_path, O_RDWR | O_CLOEXEC | O_NONBLOCK);
}

// format the tag of a handle
static void tag_of(uint64_t fh, char *out, size_t len)
{
	snprintf(out, len, "uhid%u:%d:%" PRIu64, g_instance, (int)getpid(), fh);
}

// send a line to the supervisor and read its answer
static int sup_send(const char *line, char *ack, size_t acklen)
{
	char a[80] = { 0 };
	int fd = -1;

	if (g_sup >= 0 && send_msg(g_sup, line, -1) == 0 &&
	    (!ack || (recv_msg(g_sup, a, sizeof(a), &fd) > 0 && (!strcmp(a, "ok") || !strncmp(a, "ok ", 3))))) {
		if (fd >= 0)
			close(fd);
		if (ack)
			snprintf(ack, acklen, "%s", a[2] ? a + 3 : "");
		return 0;
	}
	if (fd >= 0)
		close(fd);
	rz_log("RHIZO_MARKER input_owner=unsent to the supervisor (%s): %.80s", a[0] ? a : "no answer", line);
	return -1;
}

// return whether a uhid event type is relayed
static int write_type_ok(uint32_t t)
{
	return t == UHID_CREATE2 || t == UHID_DESTROY || t == UHID_INPUT2 || t == UHID_GET_REPORT_REPLY ||
	       t == UHID_SET_REPORT_REPLY;
}

// record a UHID_CREATE2 with the supervisor
static int report_create(uint64_t fh, uint8_t *ev, size_t size)
{
	char tag[64], line[128], token[80];
	size_t at = offsetof(struct uhid_event, u.create2.phys);
	size_t room = sizeof(((struct uhid_event *)0)->u.create2.phys);

	if (size < at + room)
		return -1;
	tag_of(fh, tag, sizeof(tag));
	snprintf(line, sizeof(line), "pending %s", tag);
	if (sup_send(line, token, sizeof(token)) < 0 || !token[0] || strlen(token) >= room)
		return -1;
	memset(ev + at, 0, room);
	memcpy(ev + at, token, strlen(token));
	return 0;
}

// tell the supervisor a handle is done
static void report_done(uint64_t fh)
{
	char tag[64], line[128];

	tag_of(fh, tag, sizeof(tag));
	snprintf(line, sizeof(line), "done %s", tag);
	sup_send(line, NULL, 0);
}

// check and forward a uhid event written to the device
static void op_write(uint64_t unique, const struct fuse_write_in *wi, uint8_t *data)
{
	struct handle *h = wi->fh < MAX_HANDLES && g_h[wi->fh].used ? &g_h[wi->fh] : NULL;
	uint32_t type;

	if (!h) {
		reply(unique, -EBADF, NULL, 0);
		return;
	}
	if (wi->size < sizeof(type)) {
		reply(unique, -EINVAL, NULL, 0);
		return;
	}
	memcpy(&type, data, sizeof(type));
	if (!write_type_ok(type)) {
		rz_log("RHIZO_MARKER input_owner=refused-event type=%u fh=%" PRIu64, type, wi->fh);
		reply(unique, -EINVAL, NULL, 0);
		return;
	}
	if (type == UHID_CREATE2 && h->created) {
		reply(unique, -EALREADY, NULL, 0);
		return;
	}
	if (type == UHID_CREATE2 && report_create(wi->fh, data, wi->size) < 0) {
		report_done(wi->fh);
		reply(unique, -EIO, NULL, 0);
		return;
	}
	ssize_t n = write(h->fd, data, wi->size);
	if (n < 0) {
		int e = errno;
		if (type == UHID_CREATE2)
			report_done(wi->fh);
		reply(unique, -e, NULL, 0);
		return;
	}
	if (type == UHID_CREATE2) {
		h->created = 1;
		rz_log("RHIZO_MARKER input_owner=uhid-created fh=%" PRIu64, wi->fh);
	}
	if (type == UHID_DESTROY && h->created) {
		report_done(wi->fh);
		h->created = 0;
	}
	struct fuse_write_out wo = { .size = (uint32_t)n };
	reply(unique, 0, &wo, sizeof(wo));
}

// answer a read if the kernel has an event
static int try_read(uint64_t unique, uint64_t fh, uint32_t size)
{
	static uint8_t buf[sizeof(struct uhid_event)];
	ssize_t n = read(g_h[fh].fd, buf, size < sizeof(buf) ? size : sizeof(buf));

	if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
		return 0;
	if (n < 0)
		reply(unique, -errno, NULL, 0);
	else
		reply(unique, 0, buf, (uint32_t)n);
	return 1;
}

// answer or queue a read of the device
static void op_read(uint64_t unique, const struct fuse_read_in *ri)
{
	if (ri->fh >= MAX_HANDLES || !g_h[ri->fh].used) {
		reply(unique, -EBADF, NULL, 0);
		return;
	}
	if (try_read(unique, ri->fh, ri->size))
		return;
	if (g_h[ri->fh].nonblock) {
		reply(unique, -EAGAIN, NULL, 0);
		return;
	}
	for (int i = 0; i < MAX_READS; i++)
		if (!g_reads[i].used) {
			g_reads[i] = (struct pending_read){ 1, unique, ri->fh, ri->size };
			return;
		}
	reply(unique, -EBUSY, NULL, 0);
}

// allocate a handle with a uhid descriptor
static void op_open(uint64_t unique, const struct fuse_open_in *oi)
{
	for (uint64_t fh = 1; fh < MAX_HANDLES; fh++) {
		if (g_h[fh].used)
			continue;
		int fd = open_uhid();
		if (fd < 0) {
			reply(unique, -errno, NULL, 0);
			return;
		}
		g_h[fh] = (struct handle){ .used = 1, .fd = fd, .nonblock = (oi->flags & O_NONBLOCK) != 0 };
		struct fuse_open_out oo = { .fh = fh, .open_flags = FOPEN_DIRECT_IO | FOPEN_NONSEEKABLE };
		reply(unique, 0, &oo, sizeof(oo));
		return;
	}
	reply(unique, -EMFILE, NULL, 0);
}

// close a released handle
static void op_release(uint64_t unique, const struct fuse_release_in *ri)
{
	if (ri->fh < MAX_HANDLES && g_h[ri->fh].used) {
		struct handle *h = &g_h[ri->fh];
		close(h->fd);
		if (h->created)
			report_done(ri->fh);
		for (int i = 0; i < MAX_READS; i++)
			if (g_reads[i].used && g_reads[i].fh == ri->fh) {
				reply(g_reads[i].unique, -EBADF, NULL, 0);
				g_reads[i].used = 0;
			}
		memset(h, 0, sizeof(*h));
	}
	reply(unique, 0, NULL, 0);
}

// report poll readiness or arm a wakeup
static void op_poll(uint64_t unique, const struct fuse_poll_in *pi)
{
	if (pi->fh >= MAX_HANDLES || !g_h[pi->fh].used) {
		reply(unique, -EBADF, NULL, 0);
		return;
	}
	struct handle *h = &g_h[pi->fh];
	struct pollfd p = { .fd = h->fd, .events = (short)pi->events };
	poll(&p, 1, 0);
	if (pi->flags & FUSE_POLL_SCHEDULE_NOTIFY)
		h->kh = pi->kh;
	struct fuse_poll_out po = { .revents = (uint32_t)p.revents };
	reply(unique, 0, &po, sizeof(po));
}

// answer a queued read that was interrupted
static void op_interrupt(const struct fuse_interrupt_in *ii)
{
	for (int i = 0; i < MAX_READS; i++)
		if (g_reads[i].used && g_reads[i].unique == ii->unique) {
			reply(ii->unique, -EINTR, NULL, 0);
			g_reads[i].used = 0;
		}
}

// handle a request from /dev/cuse
static int cuse_request(void)
{
	static _Alignas(8) uint8_t buf[sizeof(struct fuse_in_header) + sizeof(struct fuse_write_in) +
				       sizeof(struct uhid_event) + 4096];
	_Static_assert(sizeof(buf) >= FUSE_MIN_READ_BUFFER, "a CUSE read buffer below FUSE_MIN_READ_BUFFER");
	ssize_t n = read(g_cuse, buf, sizeof(buf));

	if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == ENOENT))
		return 0;
	if (n < 0 || (size_t)n < sizeof(struct fuse_in_header))
		return -1;
	struct fuse_in_header *in = (void *)buf;
	uint8_t *body = buf + sizeof(*in);
	size_t blen = (size_t)n - sizeof(*in);
	static const struct {
		uint32_t op;
		size_t need;
	} need[] = {
		{ FUSE_OPEN, sizeof(struct fuse_open_in) },
		{ FUSE_READ, sizeof(struct fuse_read_in) },     { FUSE_WRITE, sizeof(struct fuse_write_in) },
		{ FUSE_RELEASE, sizeof(struct fuse_release_in) }, { FUSE_POLL, sizeof(struct fuse_poll_in) },
		{ FUSE_INTERRUPT, sizeof(struct fuse_interrupt_in) },
	};
	for (size_t i = 0; i < sizeof(need) / sizeof(need[0]); i++)
		if (need[i].op == in->opcode && blen < need[i].need) {
			if (in->opcode != FUSE_INTERRUPT)
				reply(in->unique, -EINVAL, NULL, 0);
			return 0;
		}
	switch (in->opcode) {
	case FUSE_OPEN:
		op_open(in->unique, (void *)body);
		break;
	case FUSE_READ:
		op_read(in->unique, (void *)body);
		break;
	case FUSE_WRITE: {
		struct fuse_write_in *wi = (void *)body;
		if (blen - sizeof(*wi) < wi->size)
			reply(in->unique, -EINVAL, NULL, 0);
		else
			op_write(in->unique, wi, body + sizeof(*wi));
		break;
	}
	case FUSE_RELEASE:
		op_release(in->unique, (void *)body);
		break;
	case FUSE_POLL:
		op_poll(in->unique, (void *)body);
		break;
	case FUSE_INTERRUPT:
		op_interrupt((void *)body);
		break;
	case FUSE_IOCTL:
		reply(in->unique, -ENOTTY, NULL, 0);
		break;
	case FUSE_DESTROY:
		return -1;
	default:
		reply(in->unique, -ENOSYS, NULL, 0);
	}
	return 0;
}

// install the seccomp filter for serving
static int install_uhid_seccomp(void)
{
	static const int allowed[] = {
		__NR_read,	 __NR_write,	      __NR_readv,  __NR_writev,	      __NR_close,
#ifdef __NR_poll
		__NR_poll,
#endif
		__NR_ppoll,	 __NR_openat, __NR_newfstatat,   __NR_fstat,
		__NR_fcntl,	 __NR_socket,	      __NR_connect, __NR_sendmsg,    __NR_recvmsg,
		__NR_getpid,	 __NR_exit,	      __NR_exit_group, __NR_rt_sigreturn, __NR_brk,
		__NR_mmap,	 __NR_munmap,	      __NR_futex, __NR_lseek,	      __NR_restart_syscall,
	};
	enum { N = sizeof(allowed) / sizeof(allowed[0]) };
	struct sock_filter f[4 + N + 2];
	int k = 0;

	f[k++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
	f[k++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, THIS_AUDIT_ARCH, 1, 0);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
	for (int i = 0; i < N; i++)
		f[k++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned)allowed[i],
						      (uint8_t)(N - i), 0);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
	f[k++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	struct sock_fprog prog = { .len = (unsigned short)k, .filter = f };
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0)
		return -1;
	return (int)syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog);
}

// get this instance's CUSE channel from the supervisor
static int take_cuse(void)
{
	char a[16];
	int fd = -1;

	if (send_msg(g_sup, "cuse", -1) < 0 || recv_msg(g_sup, a, sizeof(a), &fd) <= 0 || strcmp(a, "ok") || fd < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=cuse-refused answer=%s", fd < 0 ? "no-fd" : a);
		if (fd >= 0)
			close(fd);
		return -1;
	}
	return fd;
}

// serve the uhid device through CUSE
static int run_uhid(const char *sup_path, int no_seccomp)
{
	g_sup = unix_connect(sup_path);
	if (g_sup < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=supervisor:%d path=%s",
		       errno, sup_path);
		return 1;
	}
	g_cuse = take_cuse();
	if (g_cuse < 0)
		return 1;
	rz_log("RHIZO_MARKER input_owner=uhid-serving devname=rhizo-%u-uhid", g_instance);
	if (!no_seccomp && install_uhid_seccomp() < 0) {
		rz_log("RHIZO_MARKER input_owner=failed reason=seccomp:%d", errno);
		return 1;
	}
	for (;;) {
		struct pollfd pf[2 + MAX_HANDLES];
		pf[0] = (struct pollfd){ .fd = g_cuse, .events = POLLIN };
		pf[1 + MAX_HANDLES] = (struct pollfd){ .fd = g_sup, .events = POLLIN };
		for (int i = 0; i < MAX_HANDLES; i++) {
			int want = g_h[i].used && g_h[i].kh;
			for (int r = 0; g_h[i].used && r < MAX_READS; r++)
				if (g_reads[r].used && g_reads[r].fh == (uint64_t)i)
					want = 1;
			pf[1 + i] = (struct pollfd){ .fd = want ? g_h[i].fd : -1, .events = POLLIN };
		}
		if (poll(pf, 2 + MAX_HANDLES, -1) < 0) {
			if (errno == EINTR)
				continue;
			return 1;
		}
		exit_if_kernel_after_load();
		if (pf[1 + MAX_HANDLES].revents) {
			rz_log("RHIZO_MARKER input_owner=failed reason=supervisor-gone -- exiting");
			return 1;
		}
		for (int i = 0; i < MAX_HANDLES; i++) {
			if (!(pf[1 + i].revents & (POLLIN | POLLHUP | POLLERR)))
				continue;
			for (int r = 0; r < MAX_READS; r++)
				if (g_reads[r].used && g_reads[r].fh == (uint64_t)i &&
				    try_read(g_reads[r].unique, g_reads[r].fh, g_reads[r].size))
					g_reads[r].used = 0;
			if (g_h[i].kh) {
				notify_poll(g_h[i].kh);
				g_h[i].kh = 0;
			}
		}
		if ((pf[0].revents & POLLIN) && cuse_request() < 0)
			return 0;
		if (pf[0].revents & (POLLHUP | POLLERR | POLLNVAL))
			return 0;
	}
}


// exit 0 when any instance's supervisor owns devpath
static int run_owned(const char *devpath, const char *pattern)
{
	glob_t g;
	int yes = 0;

	if (glob(pattern, 0, NULL, &g) != 0)
		return 1;
	for (size_t i = 0; i < g.gl_pathc && !yes; i++) {
		int s = unix_connect(g.gl_pathv[i]), fd;
		struct timeval tv = { .tv_sec = 5 };
		char q[MSG_MAX], a[16];
		if (s < 0)
			continue;
		setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		snprintf(q, sizeof(q), "owned %s", devpath);
		if (send_msg(s, q, -1) == 0 && recv_msg(s, a, sizeof(a), &fd) > 0 && !strcmp(a, "yes"))
			yes = 1;
		close(s);
	}
	globfree(&g);
	return yes ? 0 : 1;
}

// print the usage text to stderr
static int usage(void)
{
	fprintf(stderr,
		"usage: rhizo-inputd supervise --instance N --socket PATH --fence PATH [--state PATH]\n"
		"                              [--owned-socket PATH] [--owned-uid UID]\n"
		"                              [--cuse PATH | --cuse-fd N] [--uinput-rdev MAJ:MIN] [--sys ROOT]\n"
		"                              [--broker-cgroup SUFFIX] [--listener-uid UID] [--uevents FIXTURE-SOCKET]\n"
		"       rhizo-inputd uhid --instance N --supervisor PATH [--uhid PATH] [--no-seccomp]\n"
		"       (supervise and uhid also take [--attr DIR] [--selinuxfs DIR])\n"
		"       rhizo-inputd owned DEVPATH [--sockets GLOB]\n");
	return 2;
}

// run the supervisor or the uhid server
int main(int argc, char **argv)
{
	const char *sock = NULL, *sup = NULL, *cuse = "/dev/cuse", *uevents = NULL, *broker = NULL;
	const char *sockets = "/run/udev/rhizo-input-*.sock", *owned_sock = NULL;
	char owned_default[PATH_LEN];
	int cuse_fd = -1, no_seccomp = 0;
	unsigned maj = 10, min = 223;

	if (argc < 2)
		return usage();
	g_mode = argv[1];
	signal(SIGPIPE, SIG_IGN);
	for (int i = 2; i < argc; i++) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!strcmp(g_mode, "owned") && i == 2)
			continue;
		if (!v && strcmp(a, "--no-seccomp"))
			return usage();
		if (!strcmp(a, "--socket"))
			sock = argv[++i];
		else if (!strcmp(a, "--fence"))
			g_fence_path = argv[++i];
		else if (!strcmp(a, "--uinput-rdev") && sscanf(v, "%u:%u", &maj, &min) == 2)
			i++;
		else if (!strcmp(a, "--sys"))
			g_sys_root = argv[++i];
		else if (!strcmp(a, "--uevents"))
			uevents = argv[++i];
		else if (!strcmp(a, "--instance"))
			g_instance = (unsigned)strtoul(argv[++i], NULL, 10);
		else if (!strcmp(a, "--supervisor"))
			sup = argv[++i];
		else if (!strcmp(a, "--cuse"))
			cuse = argv[++i];
		else if (!strcmp(a, "--cuse-fd"))
			cuse_fd = (int)strtol(argv[++i], NULL, 10);
		else if (!strcmp(a, "--uhid"))
			g_uhid_path = argv[++i];
		else if (!strcmp(a, "--sockets"))
			sockets = argv[++i];
		else if (!strcmp(a, "--owned-socket"))
			owned_sock = argv[++i];
		else if (!strcmp(a, "--state"))
			g_state_path = argv[++i];
		else if (!strcmp(a, "--broker-cgroup"))
			broker = argv[++i];
		else if (!strcmp(a, "--listener-uid"))
			g_listener_uid = (int)strtol(argv[++i], NULL, 10);
		else if (!strcmp(a, "--owned-uid"))
			g_owned_uid = (int)strtol(argv[++i], NULL, 10);
		else if (!strcmp(a, "--no-seccomp"))
			no_seccomp = 1;
		else if (!strcmp(a, "--attr"))
			g_attr_dir = argv[++i];
		else if (!strcmp(a, "--selinuxfs"))
			g_selinuxfs = argv[++i];
		else
			return usage();
	}
	if (!strcmp(g_mode, "owned"))
		return argc < 3 ? usage() : run_owned(argv[2], sockets);
	if (!strcmp(g_mode, "supervise")) {
		if (!sock)
			return usage();
		enter_domain("u:r:rhizo_inputd:s0", argv);
		g_uinput_rdev = makedev(maj, min);
		if (g_listener_uid < 0)
			g_listener_uid = (int)getuid();
		if (g_owned_uid < 0)
			g_owned_uid = 0;
		if (!owned_sock) {
			snprintf(owned_default, sizeof(owned_default), OWNED_SOCKET_FMT, g_instance);
			owned_sock = owned_default;
		}
		if (broker)
			snprintf(g_broker_cgroup, sizeof(g_broker_cgroup), "%s", broker);
		else
			snprintf(g_broker_cgroup, sizeof(g_broker_cgroup), "/rhizo-inputd-uhid@%u.service", g_instance);
		int nl = uevent_socket(uevents);
		if (nl < 0) {
			rz_log("RHIZO_MARKER input_owner=failed reason=uevent-socket:%d", errno);
			return 1;
		}
		int listener = -1, channel = -1;
		adopt_stored(&listener, &channel);
		load_state();
		if (channel < 0) {
			channel = cuse_open_init(cuse, cuse_fd);
			if (channel < 0)
				return 1;
			if (fdstore("cuse", channel) < 0 && errno != ENOENT)
				rz_log("RHIZO_MARKER input_owner=failed reason=fdstore:%d", errno);
		}
		return run_supervise(sock, owned_sock, nl, listener, channel);
	}
	if (!strcmp(g_mode, "uhid")) {
		if (!sup)
			return usage();
		enter_domain("u:r:rhizo_uhidd:s0", argv);
		return run_uhid(sup, no_seccomp);
	}
	return usage();
}

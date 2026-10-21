#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <unistd.h>

#include <linux/uinput.h>

#ifndef __NR_pidfd_getfd
#define __NR_pidfd_getfd 438
#endif
#ifndef __NR_pidfd_send_signal
#define __NR_pidfd_send_signal 424
#endif

// mock state for a uinput file
struct seen {
	int used;
	int number;
	int created;
};

static struct seen g_seen[64];
static int g_next = -1, g_getfds;

// call the real syscall function
static long real_syscall(long nr, long a, long b, long c, long d, long e, long f)
{
	static long (*real)(long, ...);

	if (!real)
		real = (long (*)(long, ...))dlsym(RTLD_NEXT, "syscall");
	return real(nr, a, b, c, d, e, f);
}

// return whether fd is the device named in var
static int mocked_as(int fd, const char *var)
{
	const char *want = getenv(var);
	unsigned maj, min;
	struct stat st;

	return want && sscanf(want, "%u:%u", &maj, &min) == 2 && fstat(fd, &st) == 0 &&
	       S_ISCHR(st.st_mode) && st.st_rdev == makedev(maj, min);
}

// find or create the state for fd
static struct seen *seen_of(int fd)
{
	int tag = fcntl(fd, F_GETSIG), i;

	if (tag > 0 && tag <= 64 && g_seen[tag - 1].used)
		return &g_seen[tag - 1];
	for (i = 0; i < 64 && g_seen[i].used; i++)
		;
	if (i == 64 || fcntl(fd, F_SETSIG, i + 1) < 0)
		return NULL;
	g_seen[i].used = 1;
	return &g_seen[i];
}

// send a line to the RHIZO_MOCK_NOTE socket
static void announce(const char *line, int wait)
{
	const char *path = getenv("RHIZO_MOCK_NOTE");
	struct sockaddr_un a = { .sun_family = AF_UNIX };
	char go[8];
	int s;

	if (!path || strlen(path) >= sizeof(a.sun_path))
		return;
	strcpy(a.sun_path, path);
	s = socket(AF_UNIX, SOCK_SEQPACKET, 0);
	if (s < 0 || connect(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
		if (s >= 0)
			close(s);
		return;
	}
	if (send(s, line, strlen(line), 0) > 0 && wait)
		recv(s, go, sizeof(go), 0);
	close(s);
}

// mock the uinput ioctl requests
int ioctl(int fd, unsigned long req, ...)
{
	static int (*real)(int, unsigned long, void *);
	char line[64];
	struct seen *st;
	va_list ap;
	void *arg;

	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);
	if (!real)
		real = (int (*)(int, unsigned long, void *))dlsym(RTLD_NEXT, "ioctl");
	if (!mocked_as(fd, "RHIZO_MOCK_UINPUT_RDEV") || !(st = seen_of(fd)))
		return real(fd, req, arg);
	if (req == UI_DEV_CREATE) {
		if (st->created) {
			errno = EINVAL;
			return -1;
		}
		if (g_next < 0)
			g_next = getenv("RHIZO_MOCK_FIRST") ? atoi(getenv("RHIZO_MOCK_FIRST")) : 900;
		st->created = 1;
		st->number = g_next++;
		snprintf(line, sizeof(line), "created input%d", st->number);
		announce(line, 1);
		return 0;
	}
	if (req == UI_DEV_DESTROY) {
		if (!st->created) {
			errno = ENOENT;
			return -1;
		}
		st->created = 0;
		snprintf(line, sizeof(line), "destroyed input%d", st->number);
		announce(line, 0);
		return 0;
	}
	if ((req & ~(_IOC_SIZEMASK << _IOC_SIZESHIFT)) == UI_GET_SYSNAME(0)) {
		const char *fail = getenv("RHIZO_MOCK_SYSNAME_FAIL");
		if (!st->created) {
			errno = ENOENT;
			return -1;
		}
		if (fail && atoi(fail) == st->number) {
			errno = EIO;
			return -1;
		}
		snprintf((char *)arg, _IOC_SIZE(req), "input%d", st->number);
		return 0;
	}
	return real(fd, req, arg);
}

// intercept pidfd_getfd and pidfd_send_signal calls
long syscall(long nr, ...)
{
	long a[6];
	va_list ap;

	va_start(ap, nr);
	for (int i = 0; i < 6; i++)
		a[i] = va_arg(ap, long);
	va_end(ap);
	if (nr == __NR_pidfd_send_signal && getenv("RHIZO_MOCK_KILL_EPERM")) {
		errno = EPERM;
		return -1;
	}
	long r = real_syscall(nr, a[0], a[1], a[2], a[3], a[4], a[5]);
	if (nr == __NR_pidfd_getfd) {
		const char *at = getenv("RHIZO_MOCK_GETFD_PAUSE");
		char line[32];
		int k = ++g_getfds;
		if (at && atoi(at) == k) {
			snprintf(line, sizeof(line), "getfd %d", k);
			announce(line, 1);
		}
	}
	return r;
}

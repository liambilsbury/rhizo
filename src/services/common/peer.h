// SO_PEERCRED uid and cgroup v2 path checks for a unix socket peer
#ifndef RHIZO_SERVICES_PEER_H
#define RHIZO_SERVICES_PEER_H

#ifndef _GNU_SOURCE
#error "_GNU_SOURCE is not defined"
#endif

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef SO_PEERPIDFD
#define SO_PEERPIDFD 77
#endif

#define RHIZO_PEER_LINE_MAX (PATH_MAX + 8)
#define RHIZO_PEER_UID_MAX 4294967294L

#ifdef RHIZO_PEER_NAME
#define RHIZO_PEER_UID_NOTE " (" RHIZO_PEER_NAME ")"
#else
#define RHIZO_PEER_UID_NOTE ""
#endif

// return path after a /rhizo[-N] or androidd[@N].service/android root, or NULL
static inline const char *rhizo_peer_after_sandbox_root(const char *path)
{
    static const char literal[] = "/rhizo", unit[] = "/system.slice/androidd", leaf[] = ".service/android";
    const char *p;
    if (strncmp(path, literal, sizeof(literal) - 1) == 0) {
        p = path + sizeof(literal) - 1;
        if (*p == '-') {
            const char *d = ++p;
            while (isdigit((unsigned char)*p)) {
                p++;
            }
            if (p == d) {
                return NULL;
            }
        }
        return p;
    }
    if (strncmp(path, unit, sizeof(unit) - 1) != 0) {
        return NULL;
    }
    p = path + sizeof(unit) - 1;
    if (*p == '@') {
        const char *d = ++p;
        while (isdigit((unsigned char)*p)) {
            p++;
        }
        if (p == d) {
            return NULL;
        }
    }
    return strncmp(p, leaf, sizeof(leaf) - 1) == 0 ? p + sizeof(leaf) - 1 : NULL;
}

// return whether path is under cgroup_root, or strictly below a sandbox root if cgroup_root is NULL
static inline int rhizo_peer_cgroup_allowed(const char *path, const char *cgroup_root)
{
    size_t len = strlen(path);
    if (path[0] != '/' || strstr(path, "/../") != NULL || strstr(path, "/./") != NULL ||
        (len >= 3 && strcmp(path + len - 3, "/..") == 0)) {
        return 0;
    }
    if (cgroup_root != NULL) {
        size_t n = strlen(cgroup_root);
        return strcmp(cgroup_root, "/") == 0 ||
               (strncmp(path, cgroup_root, n) == 0 && (path[n] == '\0' || path[n] == '/'));
    }
    const char *rest = rhizo_peer_after_sandbox_root(path);
    return rest != NULL && rest[0] == '/' && rest[1] != '\0';
}

// read the newline-terminated 0:: line at a line start of path into out, or return -1
static inline int rhizo_peer_read_cgroup_file(const char *path, char *out, size_t len)
{
    char line[RHIZO_PEER_LINE_MAX];
    FILE *f = fopen(path, "re");
    if (f == NULL) {
        return -1;
    }
    int rc = -1, at_line_start = 1;
    while (fgets(line, sizeof(line), f) != NULL) {
        size_t n = strlen(line);
        int whole = n > 0 && line[n - 1] == '\n';
        if (at_line_start && strncmp(line, "0::", 3) == 0) {
            if (whole && n - 4 < len) {
                memcpy(out, line + 3, n - 4);
                out[n - 4] = '\0';
                rc = 0;
            }
            break;
        }
        at_line_start = whole;
    }
    fclose(f);
    return rc;
}

// read a process's host cgroup v2 path, or return -1
static inline int rhizo_peer_read_cgroup(pid_t pid, char *out, size_t len)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cgroup", (int)pid);
    return rhizo_peer_read_cgroup_file(path, out, len);
}

// parse text of decimal digits up to RHIZO_PEER_UID_MAX into out, or return -1
static inline int rhizo_peer_parse_uid(const char *text, long *out)
{
    if (text == NULL || !isdigit((unsigned char)text[0])) {
        return -1;
    }
    char *end = NULL;
    errno = 0;
    long v = strtol(text, &end, 10);
    if (errno != 0 || end == NULL || *end != '\0' || v < 0 || v > RHIZO_PEER_UID_MAX) {
        return -1;
    }
    *out = v;
    return 0;
}

// call pidfd_send_signal(pidfd, 0) and return the result
static inline int rhizo_peer_signal0(int pidfd)
{
    return (int)syscall(SYS_pidfd_send_signal, pidfd, 0, NULL, 0);
}

static int (*rhizo_peer_probe)(int pidfd) = rhizo_peer_signal0;

// return whether rhizo_peer_probe returns 0 or fails with an errno other than ESRCH
static inline int rhizo_peer_pidfd_alive(int pidfd)
{
    return rhizo_peer_probe(pidfd) == 0 || errno != ESRCH;
}

// copy text into out with each byte outside 0x20 to 0x7e, and 0x5c, written as \xNN
static inline void rhizo_peer_escape(const char *text, char *out, size_t len)
{
    static const char hex[] = "0123456789abcdef";
    size_t o = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p != '\0'; p++) {
        int plain = *p >= 0x20 && *p < 0x7f && *p != '\\';
        if (o + (plain ? 1 : 4) >= len) {
            break;
        }
        if (plain) {
            out[o++] = (char)*p;
        } else {
            out[o++] = '\\';
            out[o++] = 'x';
            out[o++] = hex[*p >> 4];
            out[o++] = hex[*p & 15];
        }
    }
    if (len > 0) {
        out[o] = '\0';
    }
}

// write the refusal for uid, pid and the escaped cgroup into why
static inline void rhizo_peer_cgroup_refusal(char *why, size_t why_len, unsigned uid, int pid, const char *cgroup)
{
    char shown[PATH_MAX];
    rhizo_peer_escape(cgroup, shown, sizeof(shown));
    snprintf(why, why_len, "uid %u pid %d, cgroup '%s' is not below a sandbox root", uid, pid, shown);
}

// return whether the peer uid of fd is uid and the peer cgroup passes rhizo_peer_cgroup_allowed, else write why
static inline int rhizo_peer_allowed(int fd, long uid, const char *cgroup_root, char *why, size_t why_len)
{
    struct ucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) {
        snprintf(why, why_len, "a peer with no SO_PEERCRED (%s)", strerror(errno));
        return 0;
    }
    if ((long)cred.uid != uid) {
        snprintf(why, why_len, "uid %u pid %d, uid is not %ld" RHIZO_PEER_UID_NOTE, cred.uid, (int)cred.pid, uid);
        return 0;
    }
    int pidfd = -1;
    socklen_t plen = sizeof(pidfd);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERPIDFD, &pidfd, &plen) != 0) {
        if (errno != ENOPROTOOPT && errno != EINVAL) {
            snprintf(why, why_len, "uid %u pid %d, getsockopt SO_PEERPIDFD failed (%s)", cred.uid, (int)cred.pid,
                     strerror(errno));
            return 0;
        }
        pidfd = -1;
    }
    char cgroup[PATH_MAX];
    int readable = rhizo_peer_read_cgroup(cred.pid, cgroup, sizeof(cgroup)) == 0;
    int alive = 1;
    if (pidfd >= 0) {
        alive = rhizo_peer_pidfd_alive(pidfd);
        close(pidfd);
    }
    if (!readable || !alive) {
        snprintf(why, why_len, "uid %u pid %d, %s", cred.uid, (int)cred.pid,
                 alive ? "failed to read /proc/<pid>/cgroup" : "pidfd_send_signal failed with ESRCH");
        return 0;
    }
    if (!rhizo_peer_cgroup_allowed(cgroup, cgroup_root)) {
        rhizo_peer_cgroup_refusal(why, why_len, cred.uid, (int)cred.pid, cgroup);
        return 0;
    }
    return 1;
}

#endif

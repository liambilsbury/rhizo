#include <errno.h>
#include <linux/posix_acl.h>
#include <linux/posix_acl_xattr.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <unistd.h>
#ifdef __ANDROID__
#include <android/log.h>
#endif

#ifndef RHIZO_PROBED_SOCK
#define RHIZO_PROBED_SOCK "/data/local/tmp/rhizo-probe.sock"
#endif
#ifndef RHIZO_PROBED_SH
#define RHIZO_PROBED_SH "/system/bin/sh"
#endif
#define SOCK_PATH RHIZO_PROBED_SOCK
#define MAX_CMD 65536

static const uid_t kPeerUid = 0;

// write a message to stderr and logcat
static void note(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
#ifdef __ANDROID__
    va_start(ap, fmt);
    __android_log_vprint(ANDROID_LOG_WARN, "rhizo-probed", fmt, ap);
    va_end(ap);
#endif
}

// compare the peer uid with kPeerUid
static bool peer_allowed(int cfd, struct ucred *cred) {
    socklen_t len = sizeof(*cred);
    memset(cred, 0, sizeof(*cred));
    cred->uid = (uid_t)-1;
    if (getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, cred, &len) != 0 || len != sizeof(*cred))
        return false;
    return cred->uid == kPeerUid;
}

// send a refusal message and close cfd
static void refuse(int cfd, const struct ucred *cred) {
    char msg[96];
    int n = snprintf(msg, sizeof(msg), "RHIZO_PROBE_REFUSED: peer uid %d is not root\n", (int)cred->uid);
    send(cfd, msg, (size_t)n, MSG_DONTWAIT | MSG_NOSIGNAL);
    note("refused a connection from uid %d pid %d", (int)cred->uid, (int)cred->pid);
    close(cfd);
}

// set the socket mode and access list
static int restrict_socket(const char *path) {
    if (chmod(path, 0600) != 0) return -1;
    struct {
        struct posix_acl_xattr_header h;
        struct posix_acl_xattr_entry e[5];
    } acl = {
        {POSIX_ACL_XATTR_VERSION},
        {{ACL_USER_OBJ, ACL_READ | ACL_WRITE, (__u32)ACL_UNDEFINED_ID},
         {ACL_USER, ACL_READ | ACL_WRITE, (__u32)kPeerUid},
         {ACL_GROUP_OBJ, 0, (__u32)ACL_UNDEFINED_ID},
         {ACL_MASK, ACL_READ | ACL_WRITE, (__u32)ACL_UNDEFINED_ID},
         {ACL_OTHER, 0, (__u32)ACL_UNDEFINED_ID}},
    };
    static_assert(sizeof(acl) == sizeof(struct posix_acl_xattr_header) + 5 * sizeof(struct posix_acl_xattr_entry),
                  "posix acl xattr must be packed");
    return setxattr(path, "system.posix_acl_access", &acl, sizeof(acl), 0);
}

// run a command and send its output
static void handle_conn(int cfd) {
    char buf[MAX_CMD];
    size_t len = 0;
    while (len < sizeof(buf) - 1) {
        ssize_t n = read(cfd, buf + len, sizeof(buf) - 1 - len);
        if (n <= 0) break;
        len += (size_t)n;
        if (memchr(buf + (len - (size_t)n), '\n', (size_t)n)) break;
    }
    buf[len] = '\0';
    char *nl = strchr(buf, '\n');
    if (nl) *nl = '\0';

    struct ucred cred;
    if (!peer_allowed(cfd, &cred)) {
        refuse(cfd, &cred);
        return;
    }
    pid_t pid = fork();
    if (pid == 0) {
        dup2(cfd, STDOUT_FILENO);
        dup2(cfd, STDERR_FILENO);
        close(cfd);
        execl(RHIZO_PROBED_SH, "sh", "-c", buf, (char *)NULL);
        _exit(127);
    }
    int status = -1;
    if (pid > 0) waitpid(pid, &status, 0);
    int rc = (pid > 0 && WIFEXITED(status)) ? WEXITSTATUS(status) : 128;
    char trailer[64];
    int tlen = snprintf(trailer + 1, sizeof(trailer) - 2, "RHIZO_PROBE_RC=%d", rc);
    trailer[0] = '\0';
    trailer[1 + tlen] = '\0';
    write(cfd, trailer, (size_t)tlen + 2);
    close(cfd);
}

// serve connections on rhizo-probe.sock
int main(void) {
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sa.sa_flags = SA_NOCLDWAIT;
    sigaction(SIGCHLD, &sa, NULL);

    unlink(SOCK_PATH);
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) { perror("socket"); return 1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    if (restrict_socket(SOCK_PATH) != 0) {
        note("restrict %s to owner and uid %d: %s", SOCK_PATH, (int)kPeerUid, strerror(errno));
        return 1;
    }
    if (listen(lfd, 32) < 0) { perror("listen"); return 1; }

    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) continue;
        pid_t pid = fork();
        if (pid == 0) {
            close(lfd);
            signal(SIGCHLD, SIG_DFL);
            handle_conn(cfd);
            _exit(0);
        }
        close(cfd);
    }
}

#define _GNU_SOURCE
#include <drm/drm.h>
#include <drm/virtgpu_drm.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <gbm.h>

#include "rhizo/stream_protocol.h"

#define DEFAULT_RENDER_NODE "/dev/dri/renderD128"
#define DRM_FORMAT_ABGR8888 0x34324241u
#define DRM_FORMAT_MOD_LINEAR 0ull

// write a prefixed message to stderr
static void logmsg(const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "[stream-export-verify] ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
}

static int64_t now_monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// options for stream-export-verify
struct cfg {
    const char *socket_path;
    const char *report_path;
    const char *dump_path;
    const char *render_node;
    int readback_every;
    int max_frames;
};

enum readback_kind { RB_NONE = 0, RB_SKIPPED, RB_MMAP, RB_VIRTGPU, RB_VIRTGPU_BUSY, RB_GBM };

static const char *readback_name(enum readback_kind k) {
    switch (k) {
        case RB_MMAP: return "mmap";
        case RB_VIRTGPU: return "virtgpu";
        case RB_VIRTGPU_BUSY: return "virtgpu-busy";
        case RB_GBM: return "gbm";
        case RB_SKIPPED: return "skipped";
        default: return "none";
    }
}

// pixel statistics for a frame
struct frame_stats {
    enum readback_kind readback;
    double nonblack_pct, mean_r, mean_g, mean_b;
    double left_r, left_b, right_r, right_b;
    int distinct;
};

struct conn_summary {
    uint64_t frames, refused, undersized, not_dmabuf, readbacks;
    uint64_t first_seq, last_seq;
};

#define READBACK_WAIT_BUDGET_US 120000

// transfer the virtio-gpu buffer into guest memory
static enum readback_kind virtgpu_pull(int drm_fd, int dmabuf_fd, int width, int height,
                                       int64_t *wait_us) {
    *wait_us = 0;
    if (drm_fd < 0) return RB_MMAP;
    struct drm_prime_handle prime;
    memset(&prime, 0, sizeof(prime));
    prime.fd = dmabuf_fd;
    if (ioctl(drm_fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime) != 0) return RB_MMAP;

    struct drm_virtgpu_3d_transfer_from_host xfer;
    memset(&xfer, 0, sizeof(xfer));
    xfer.bo_handle = prime.handle;
    xfer.box.w = (uint32_t)width;
    xfer.box.h = (uint32_t)height;
    xfer.box.d = 1;
    enum readback_kind kind = RB_MMAP;
    if (ioctl(drm_fd, DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST, &xfer) == 0) {
        int64_t t0 = now_monotonic_ns();
        kind = RB_VIRTGPU_BUSY;
        for (;;) {
            struct drm_virtgpu_3d_wait wait_req;
            memset(&wait_req, 0, sizeof(wait_req));
            wait_req.handle = prime.handle;
            wait_req.flags = VIRTGPU_WAIT_NOWAIT;
            int rc = ioctl(drm_fd, DRM_IOCTL_VIRTGPU_WAIT, &wait_req);
            *wait_us = (now_monotonic_ns() - t0) / 1000;
            if (rc == 0) { kind = RB_VIRTGPU; break; }
            if (errno != EBUSY) {
                logmsg("VIRTGPU_WAIT failed: %s -- this frame goes unread", strerror(errno));
                break;
            }
            if (*wait_us >= READBACK_WAIT_BUDGET_US) break;
            usleep(500);
        }
    } else if (errno != ENOTTY && errno != EINVAL) {
        logmsg("VIRTGPU_TRANSFER_FROM_HOST failed: %s -- plain mmap", strerror(errno));
    }
    struct drm_gem_close close_req;
    memset(&close_req, 0, sizeof(close_req));
    close_req.handle = prime.handle;
    ioctl(drm_fd, DRM_IOCTL_GEM_CLOSE, &close_req);
    return kind;
}

// compute color statistics of the frame pixels
static void scan_pixels(const uint8_t *base, const struct rhizo_stream_frame_header *h,
                        struct frame_stats *st) {
    uint8_t seen[4096];
    memset(seen, 0, sizeof(seen));
    uint64_t sr = 0, sg = 0, sb = 0, nonblack = 0;
    uint64_t lr = 0, lb = 0, rr = 0, rb = 0;
    const int half = h->width / 2;
    const uint64_t total = (uint64_t)h->width * (uint64_t)h->height;
    const uint64_t left_n = (uint64_t)half * (uint64_t)h->height;
    const uint64_t right_n = total - left_n;
    int distinct = 0;
    for (int y = 0; y < h->height; y++) {
        const uint8_t *row = base + (size_t)h->offset_bytes + (size_t)y * (size_t)h->stride_bytes;
        for (int x = 0; x < h->width; x++) {
            const uint8_t *px = row + (size_t)x * 4;
            sr += px[0]; sg += px[1]; sb += px[2];
            if (px[0] | px[1] | px[2]) nonblack++;
            if (x < half) { lr += px[0]; lb += px[2]; } else { rr += px[0]; rb += px[2]; }
            unsigned key = ((px[0] >> 3) << 10) | ((px[1] >> 3) << 5) | (px[2] >> 3);
            if (!(seen[key >> 3] & (1u << (key & 7)))) {
                seen[key >> 3] |= (uint8_t)(1u << (key & 7));
                distinct++;
            }
        }
    }
    st->nonblack_pct = total ? 100.0 * (double)nonblack / (double)total : 0.0;
    st->mean_r = total ? (double)sr / (double)total : 0.0;
    st->mean_g = total ? (double)sg / (double)total : 0.0;
    st->mean_b = total ? (double)sb / (double)total : 0.0;
    st->left_r = left_n ? (double)lr / (double)left_n : 0.0;
    st->left_b = left_n ? (double)lb / (double)left_n : 0.0;
    st->right_r = right_n ? (double)rr / (double)right_n : 0.0;
    st->right_b = right_n ? (double)rb / (double)right_n : 0.0;
    st->distinct = distinct;
}

// copy of the newest frame
static struct {
    pthread_mutex_t lock;
    uint8_t *rows;
    size_t cap, len;
    struct rhizo_stream_frame_header hdr;
    int valid;
} g_last = { PTHREAD_MUTEX_INITIALIZER, NULL, 0, 0, {0}, 0 };

// store a copy of the frame as the newest read-back frame
static void last_frame_store(const uint8_t *base, const struct rhizo_stream_frame_header *h) {
    size_t size = (size_t)h->stride_bytes * (size_t)h->height;
    pthread_mutex_lock(&g_last.lock);
    if (g_last.cap < size) {
        uint8_t *n = realloc(g_last.rows, size);
        if (!n) { pthread_mutex_unlock(&g_last.lock); logmsg("out of memory holding a %zu-byte frame", size); return; }
        g_last.rows = n;
        g_last.cap = size;
    }
    memcpy(g_last.rows, base + (size_t)h->offset_bytes, size);
    g_last.len = size;
    g_last.hdr = *h;
    g_last.valid = 1;
    pthread_mutex_unlock(&g_last.lock);
}

// write the last frame to dump_path
static int last_frame_dump(const char *dump_path) {
    if (!dump_path) return 0;
    pthread_mutex_lock(&g_last.lock);
    if (!g_last.valid) {
        pthread_mutex_unlock(&g_last.lock);
        logmsg("dump requested before any frame was read back -- nothing written");
        return -1;
    }
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s.tmp", dump_path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        pthread_mutex_unlock(&g_last.lock);
        logmsg("open(%s) failed: %s", tmp, strerror(errno));
        return -1;
    }
    size_t off = 0;
    while (off < g_last.len) {
        ssize_t w = write(fd, g_last.rows + off, g_last.len - off);
        if (w <= 0) { logmsg("write(%s) failed: %s", tmp, strerror(errno)); close(fd); pthread_mutex_unlock(&g_last.lock); return -1; }
        off += (size_t)w;
    }
    close(fd);
    int rc = rename(tmp, dump_path);
    if (rc != 0) logmsg("rename(%s) failed: %s", tmp, strerror(errno));
    else
        printf("RHIZO_STREAM_VERIFY_DUMP seq=%llu size=%dx%d stride=%d bytes=%zu path=%s\n",
               (unsigned long long)g_last.hdr.seq, g_last.hdr.width, g_last.hdr.height,
               g_last.hdr.stride_bytes, g_last.len, dump_path);
    fflush(stdout);
    pthread_mutex_unlock(&g_last.lock);
    return rc;
}

// wait for SIGUSR1 and write the frame dump
static void *dump_signal_thread(void *arg) {
    const char *dump_path = arg;
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR1);
    for (;;) {
        int sig = 0;
        if (sigwait(&set, &sig) != 0) continue;
        if (sig == SIGUSR1) last_frame_dump(dump_path);
    }
    return NULL;
}

// map the dma-buf and scan its pixels
static int readback_frame(int drm_fd, int dmabuf_fd, const struct rhizo_stream_frame_header *h,
                          struct frame_stats *st, int64_t *wait_us) {
    size_t len = (size_t)h->offset_bytes + (size_t)h->stride_bytes * (size_t)h->height;
    st->readback = virtgpu_pull(drm_fd, dmabuf_fd, h->width, h->height, wait_us);
    if (st->readback == RB_VIRTGPU_BUSY) return -1;
    void *m = mmap(NULL, len, PROT_READ, MAP_SHARED, dmabuf_fd, 0);
    if (m == MAP_FAILED) {
        logmsg("mmap(dma-buf, %zu) failed: %s", len, strerror(errno));
        st->readback = RB_NONE;
        return -1;
    }
    struct dma_buf_sync sync;
    sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
    ioctl(dmabuf_fd, DMA_BUF_IOCTL_SYNC, &sync);
    scan_pixels((const uint8_t *)m, h, st);
    last_frame_store((const uint8_t *)m, h);
    sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
    ioctl(dmabuf_fd, DMA_BUF_IOCTL_SYNC, &sync);
    munmap(m, len);
    return 0;
}

// import a non-linear dma-buf through GBM and scan its linear copy
static int readback_frame_gbm(const char *render_node, int dmabuf_fd,
                              const struct rhizo_stream_frame_header *h, struct frame_stats *st) {
    static struct gbm_device *gbm;
    static int tried;
    st->readback = RB_SKIPPED;
    if (!tried) {
        tried = 1;
        int fd = open(render_node, O_RDWR | O_CLOEXEC);
        if (fd >= 0) gbm = gbm_create_device(fd);
        if (!gbm) {
            logmsg("no GBM device on %s -- a non-linear frame goes unread", render_node);
            if (fd >= 0) close(fd);
        }
    }
    if (!gbm) return -1;
    struct gbm_import_fd_modifier_data d;
    memset(&d, 0, sizeof(d));
    d.width = (uint32_t)h->width;
    d.height = (uint32_t)h->height;
    d.format = h->drm_fourcc;
    d.num_fds = 1;
    d.fds[0] = dmabuf_fd;
    d.strides[0] = h->stride_bytes;
    d.offsets[0] = h->offset_bytes;
    d.modifier = h->modifier;
    struct gbm_bo *bo = gbm_bo_import(gbm, GBM_BO_IMPORT_FD_MODIFIER, &d, 0);
    if (!bo) {
        logmsg("gbm_bo_import of a modifier 0x%llx frame failed: %s", (unsigned long long)h->modifier,
               strerror(errno));
        return -1;
    }
    uint32_t stride = 0;
    void *map_data = NULL;
    uint8_t *m = gbm_bo_map(bo, 0, 0, d.width, d.height, GBM_BO_TRANSFER_READ, &stride, &map_data);
    if (!m) {
        logmsg("gbm_bo_map of a modifier 0x%llx frame failed", (unsigned long long)h->modifier);
        gbm_bo_destroy(bo);
        return -1;
    }
    struct rhizo_stream_frame_header linear = *h;
    linear.offset_bytes = 0;
    linear.stride_bytes = (int)stride;
    scan_pixels(m, &linear, st);
    last_frame_store(m, &linear);
    gbm_bo_unmap(bo, map_data);
    gbm_bo_destroy(bo);
    st->readback = RB_GBM;
    return 0;
}

// return 1 for a dma-buf fd
static int fd_is_dmabuf(int fd) {
    char link[64], target[64];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, target, sizeof(target) - 1);
    if (n <= 0) return 0;
    target[n] = 0;
    return strncmp(target, "/dmabuf", 7) == 0;
}

// print and append the report line
static void report_line(const struct cfg *cfg, const char *line) {
    fputs(line, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    if (!cfg->report_path) return;
    int fd = open(cfg->report_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) { logmsg("open(%s) failed: %s", cfg->report_path, strerror(errno)); return; }
    size_t len = strlen(line);
    char *buf = malloc(len + 2);
    if (buf) {
        memcpy(buf, line, len);
        buf[len] = '\n';
        if (write(fd, buf, len + 1) != (ssize_t)(len + 1)) logmsg("write(%s) short", cfg->report_path);
        free(buf);
    }
    close(fd);
}

// read frames from the socket and send acks
static int serve_connection(int cfd, int drm_fd, const struct cfg *cfg, uint64_t *total_frames,
                            struct conn_summary *sum) {
    memset(sum, 0, sizeof(*sum));
    for (;;) {
        struct rhizo_stream_frame_header hdr;
        struct iovec iov = {&hdr, sizeof(hdr)};
        char cmsgbuf[CMSG_SPACE(sizeof(int))];
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsgbuf;
        msg.msg_controllen = sizeof(cmsgbuf);

        ssize_t n = recvmsg(cfd, &msg, MSG_WAITALL | MSG_CMSG_CLOEXEC);
        if (n != (ssize_t)sizeof(hdr)) {
            if (n != 0) logmsg("short header read n=%zd: %s", n, n < 0 ? strerror(errno) : "eof mid-header");
            break;
        }
        int64_t received_ns = now_monotonic_ns();
        int dmabuf_fd = -1;
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
        if (cmsg && cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS)
            memcpy(&dmabuf_fd, CMSG_DATA(cmsg), sizeof(int));

        if (hdr.magic != RHIZO_STREAM_FRAME_MAGIC || hdr.version != RHIZO_STREAM_PROTOCOL_VERSION) {
            char line[256];
            snprintf(line, sizeof(line),
                     "RHIZO_STREAM_VERIFY_REFUSED magic=0x%08x version=%u fd=%d reason=not-a-frame",
                     hdr.magic, hdr.version, dmabuf_fd);
            report_line(cfg, line);
            sum->refused++;
            if (dmabuf_fd >= 0) close(dmabuf_fd);
            break;
        }
        if (dmabuf_fd < 0) {
            char line[256];
            snprintf(line, sizeof(line), "RHIZO_STREAM_VERIFY_REFUSED seq=%llu reason=no-fd",
                     (unsigned long long)hdr.seq);
            report_line(cfg, line);
            sum->refused++;
            break;
        }

        sum->frames++;
        if (sum->frames == 1) sum->first_seq = hdr.seq;
        sum->last_seq = hdr.seq;
        (*total_frames)++;

        int dmabuf = fd_is_dmabuf(dmabuf_fd);
        if (!dmabuf) sum->not_dmabuf++;
        struct stat sb;
        long long fd_bytes = -1;
        if (fstat(dmabuf_fd, &sb) == 0) fd_bytes = (long long)sb.st_size;
        long long need = (long long)hdr.offset_bytes + (long long)hdr.stride_bytes * (long long)hdr.height;
        int geometry_ok = hdr.width > 0 && hdr.height > 0 && hdr.offset_bytes >= 0 &&
                          hdr.stride_bytes >= hdr.width * 4;
        int sized_ok = geometry_ok && fd_bytes >= need;
        if (!sized_ok) sum->undersized++;

        struct frame_stats st;
        memset(&st, 0, sizeof(st));
        st.readback = RB_SKIPPED;
        int64_t wait_us = 0, t_rb0 = now_monotonic_ns();
        int due = cfg->readback_every > 0 &&
                  (sum->frames == 1 || (cfg->readback_every == 1) ||
                   (sum->frames % (uint64_t)cfg->readback_every) == 0);
        if (due && sized_ok && dmabuf) {
            if (hdr.modifier == DRM_FORMAT_MOD_LINEAR) {
                if (readback_frame(drm_fd, dmabuf_fd, &hdr, &st, &wait_us) == 0) sum->readbacks++;
            } else if (readback_frame_gbm(cfg->render_node, dmabuf_fd, &hdr, &st) == 0) {
                sum->readbacks++;
            }
        }

        char line[512];
        if (st.readback == RB_MMAP || st.readback == RB_VIRTGPU || st.readback == RB_GBM) {
            snprintf(line, sizeof(line),
                     "RHIZO_STREAM_VERIFY seq=%llu size=%dx%d fourcc=0x%08x modifier=0x%016llx "
                     "stride=%d offset=%d fd_bytes=%lld dmabuf=%d sized=%d readback=%s "
                     "nonblack_pct=%.2f distinct=%d mean_r=%.1f mean_g=%.1f mean_b=%.1f "
                     "left_r=%.1f left_b=%.1f right_r=%.1f right_b=%.1f presented_ns=%lld "
                     "received_ns=%lld",
                     (unsigned long long)hdr.seq, hdr.width, hdr.height, hdr.drm_fourcc,
                     (unsigned long long)hdr.modifier, hdr.stride_bytes, hdr.offset_bytes, fd_bytes,
                     dmabuf, sized_ok, readback_name(st.readback), st.nonblack_pct, st.distinct,
                     st.mean_r, st.mean_g, st.mean_b, st.left_r, st.left_b, st.right_r, st.right_b,
                     (long long)hdr.presented_ns, (long long)received_ns);
        } else {
            snprintf(line, sizeof(line),
                     "RHIZO_STREAM_VERIFY seq=%llu size=%dx%d fourcc=0x%08x modifier=0x%016llx "
                     "stride=%d offset=%d fd_bytes=%lld dmabuf=%d sized=%d readback=%s "
                     "presented_ns=%lld received_ns=%lld",
                     (unsigned long long)hdr.seq, hdr.width, hdr.height, hdr.drm_fourcc,
                     (unsigned long long)hdr.modifier, hdr.stride_bytes, hdr.offset_bytes, fd_bytes,
                     dmabuf, sized_ok, readback_name(st.readback), (long long)hdr.presented_ns,
                     (long long)received_ns);
        }
        report_line(cfg, line);
        close(dmabuf_fd);
        int64_t total_us = (now_monotonic_ns() - received_ns) / 1000;
        if (sum->frames <= 3 || (sum->frames % 300) == 0)
            logmsg("timing seq=%llu readback=%s transfer_wait=%lldus readback_total=%lldus "
                   "recv_to_ack=%lldus", (unsigned long long)hdr.seq, readback_name(st.readback),
                   (long long)wait_us, (long long)((now_monotonic_ns() - t_rb0) / 1000),
                   (long long)total_us);

        struct rhizo_stream_release_ack ack;
        ack.magic = RHIZO_STREAM_ACK_MAGIC;
        ack.seq = hdr.seq;
        if (send(cfd, &ack, sizeof(ack), MSG_NOSIGNAL) != (ssize_t)sizeof(ack)) {
            logmsg("could not send the release ack for seq=%llu: %s", (unsigned long long)hdr.seq,
                   strerror(errno));
            break;
        }
        if (cfg->max_frames > 0 && *total_frames >= (uint64_t)cfg->max_frames) break;
    }
    char line[256];
    snprintf(line, sizeof(line),
             "RHIZO_STREAM_VERIFY_CONNECTION frames=%llu first_seq=%llu last_seq=%llu readbacks=%llu "
             "refused=%llu undersized=%llu not_dmabuf=%llu",
             (unsigned long long)sum->frames, (unsigned long long)sum->first_seq,
             (unsigned long long)sum->last_seq, (unsigned long long)sum->readbacks,
             (unsigned long long)sum->refused, (unsigned long long)sum->undersized,
             (unsigned long long)sum->not_dmabuf);
    report_line(cfg, line);
    if (sum->readbacks) last_frame_dump(cfg->dump_path);
    return 0;
}

// return a descriptor for the virtio_gpu render node
static int open_virtgpu_node(const char *render_node) {
    int fd = open(render_node, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        logmsg("open(%s) failed: %s -- readback by plain mmap only", render_node, strerror(errno));
        return -1;
    }
    char name[64] = {0};
    struct drm_version ver;
    memset(&ver, 0, sizeof(ver));
    ver.name = name;
    ver.name_len = sizeof(name) - 1;
    if (ioctl(fd, DRM_IOCTL_VERSION, &ver) != 0) {
        logmsg("DRM_IOCTL_VERSION on %s failed: %s -- readback by plain mmap only", render_node,
               strerror(errno));
        close(fd);
        return -1;
    }
    if (strcmp(name, "virtio_gpu") != 0) {
        logmsg("%s is driver %s, not virtio_gpu -- readback by plain mmap", render_node, name);
        close(fd);
        return -1;
    }
    logmsg("%s is virtio_gpu -- readback through TRANSFER_FROM_HOST", render_node);
    return fd;
}

// listen on the socket and serve connections
static int run_listener(const struct cfg *cfg) {
    int drm_fd = open_virtgpu_node(cfg->render_node);
    if (cfg->dump_path) {
        sigset_t set;
        sigemptyset(&set);
        sigaddset(&set, SIGUSR1);
        pthread_sigmask(SIG_BLOCK, &set, NULL);
        pthread_t th;
        if (pthread_create(&th, NULL, dump_signal_thread, (void *)cfg->dump_path) != 0) {
            logmsg("could not start the SIGUSR1 dump thread: %s", strerror(errno));
            return 1;
        }
        pthread_detach(th);
    }

    unlink(cfg->socket_path);
    int ufd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (ufd < 0) { logmsg("socket(AF_UNIX) failed: %s", strerror(errno)); return 1; }
    struct sockaddr_un uaddr;
    memset(&uaddr, 0, sizeof(uaddr));
    uaddr.sun_family = AF_UNIX;
    if (strlen(cfg->socket_path) >= sizeof(uaddr.sun_path)) {
        logmsg("--socket path is %zu bytes, over the %zu a unix address holds", strlen(cfg->socket_path),
               sizeof(uaddr.sun_path));
        return 1;
    }
    strncpy(uaddr.sun_path, cfg->socket_path, sizeof(uaddr.sun_path) - 1);
    if (bind(ufd, (struct sockaddr *)&uaddr, sizeof(uaddr)) != 0) {
        logmsg("bind(%s) failed: %s", cfg->socket_path, strerror(errno));
        return 1;
    }
    if (listen(ufd, 4) != 0) { logmsg("listen failed: %s", strerror(errno)); return 1; }
    if (chmod(cfg->socket_path, 0666) != 0)
        logmsg("chmod(%s, 0666) failed: %s", cfg->socket_path,
               strerror(errno));
    logmsg("listening for the composer's export connection on %s (readback every %d frame(s)%s%s)",
           cfg->socket_path, cfg->readback_every, cfg->dump_path ? ", dumping to " : "",
           cfg->dump_path ? cfg->dump_path : "");

    uint64_t total = 0;
    for (;;) {
        int cfd = accept4(ufd, NULL, NULL, SOCK_CLOEXEC);
        if (cfd < 0) { if (errno == EINTR) continue; logmsg("accept failed: %s", strerror(errno)); return 1; }
        logmsg("composer connected");
        struct conn_summary sum;
        serve_connection(cfd, drm_fd, cfg, &total, &sum);
        close(cfd);
        logmsg("composer connection closed after %llu frame(s)", (unsigned long long)sum.frames);
        if (cfg->max_frames > 0 && total >= (uint64_t)cfg->max_frames) break;
    }
    return 0;
}

// send a frame header with its dmabuf descriptor
static int send_frame(int fd, uint64_t seq, uint32_t magic, int dmabuf_fd, int w, int h, int stride,
                      uint64_t modifier) {
    struct rhizo_stream_frame_header hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = magic;
    hdr.version = RHIZO_STREAM_PROTOCOL_VERSION;
    hdr.seq = seq;
    hdr.presented_ns = now_monotonic_ns();
    hdr.width = w;
    hdr.height = h;
    hdr.drm_fourcc = DRM_FORMAT_ABGR8888;
    hdr.modifier = modifier;
    hdr.stride_bytes = stride;
    hdr.offset_bytes = 0;
    struct iovec iov = {&hdr, sizeof(hdr)};
    char cbuf[CMSG_SPACE(sizeof(int))];
    memset(cbuf, 0, sizeof(cbuf));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = sizeof(cbuf);
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &dmabuf_fd, sizeof(int));
    return sendmsg(fd, &msg, MSG_NOSIGNAL) == (ssize_t)sizeof(hdr) ? 0 : -1;
}

// wait for the release ack of a frame and return 0 if it matches
static int wait_ack(int fd, uint64_t seq) {
    struct rhizo_stream_release_ack ack;
    ssize_t n = recv(fd, &ack, sizeof(ack), MSG_WAITALL);
    return (n == (ssize_t)sizeof(ack) && ack.magic == RHIZO_STREAM_ACK_MAGIC && ack.seq == seq) ? 0 : -1;
}

// serve generated frames and check the report
static int selftest(const char *render_node) {
    const int w = 256, h = 128;
    int drm_fd = open(render_node, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0) { logmsg("selftest: open(%s) failed: %s", render_node, strerror(errno)); return 1; }
    struct gbm_device *gbm = gbm_create_device(drm_fd);
    if (!gbm) { logmsg("selftest: gbm_create_device failed"); return 1; }
    const uint64_t linear = DRM_FORMAT_MOD_LINEAR;
    struct gbm_bo *bo = gbm_bo_create_with_modifiers2(gbm, w, h, GBM_FORMAT_ABGR8888, &linear, 1,
                                                      GBM_BO_USE_RENDERING);
    if (!bo) bo = gbm_bo_create(gbm, w, h, GBM_FORMAT_ABGR8888, GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
    if (!bo) bo = gbm_bo_create(gbm, w, h, GBM_FORMAT_ABGR8888, GBM_BO_USE_LINEAR);
    if (!bo) { logmsg("selftest: gbm_bo_create failed"); return 1; }
    uint32_t stride = 0;
    void *map_data = NULL;
    uint8_t *m = gbm_bo_map(bo, 0, 0, w, h, GBM_BO_TRANSFER_WRITE, &stride, &map_data);
    if (!m) { logmsg("selftest: gbm_bo_map failed"); return 1; }
    for (int y = 0; y < h; y++) {
        uint8_t *row = m + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
            uint8_t *px = row + (size_t)x * 4;
            px[0] = x < w / 2 ? 255 : 0;
            px[1] = 0;
            px[2] = x < w / 2 ? 0 : 255;
            px[3] = 255;
        }
    }
    gbm_bo_unmap(bo, map_data);
    int bo_fd = gbm_bo_get_fd(bo);
    uint64_t modifier = gbm_bo_get_modifier(bo);
    uint32_t bo_stride = gbm_bo_get_stride(bo);
    if (bo_fd < 0) { logmsg("selftest: gbm_bo_get_fd failed"); return 1; }
    if (modifier != DRM_FORMAT_MOD_LINEAR) {
        logmsg("selftest: the GBM buffer is not linear (modifier 0x%llx)",
               (unsigned long long)modifier);
        return 1;
    }

    char dump[] = "/tmp/stream-export-verify-selftest-XXXXXX";
    int dfd = mkstemp(dump);
    if (dfd < 0) { logmsg("selftest: mkstemp failed: %s", strerror(errno)); return 1; }
    close(dfd);

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) {
        logmsg("selftest: socketpair failed: %s", strerror(errno));
        return 1;
    }
    pid_t child = fork();
    if (child < 0) { logmsg("selftest: fork failed: %s", strerror(errno)); return 1; }
    if (child == 0) {
        close(sv[0]);
        int rc = 0;
        for (uint64_t seq = 1; seq <= 3 && rc == 0; seq++) {
            if (send_frame(sv[1], seq, RHIZO_STREAM_FRAME_MAGIC, bo_fd, w, h, (int)bo_stride, modifier) != 0 ||
                wait_ack(sv[1], seq) != 0)
                rc = 3;
        }
        if (rc == 0 && send_frame(sv[1], 4, 0x4a554e4bu  , bo_fd, w, h, (int)bo_stride, modifier) != 0)
            rc = 4;
        if (rc == 0 && wait_ack(sv[1], 4) == 0) rc = 5;
        _exit(rc);
    }
    close(sv[1]);
    int xfer_fd = open_virtgpu_node(render_node);
    struct cfg cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.readback_every = 1;
    cfg.dump_path = dump;
    cfg.render_node = render_node;
    uint64_t total = 0;
    struct conn_summary sum;
    int pfd[2];
    if (pipe2(pfd, O_CLOEXEC) != 0) { logmsg("selftest: pipe failed"); return 1; }
    int saved_stdout = dup(STDOUT_FILENO);
    dup2(pfd[1], STDOUT_FILENO);
    close(pfd[1]);
    serve_connection(sv[0], xfer_fd, &cfg, &total, &sum);
    fflush(stdout);
    dup2(saved_stdout, STDOUT_FILENO);
    close(saved_stdout);
    close(sv[0]);
    char out[8192];
    ssize_t got = 0, r;
    while ((r = read(pfd[0], out + got, sizeof(out) - 1 - (size_t)got)) > 0) got += r;
    out[got > 0 ? got : 0] = 0;
    close(pfd[0]);
    int status = 0;
    waitpid(child, &status, 0);
    int child_rc = WIFEXITED(status) ? WEXITSTATUS(status) : 99;

    double left_r = -1, left_b = -1, right_r = -1, right_b = -1;
    int dmabuf = -1, sized = -1;
    char rb[16] = "";
    const char *last = NULL, *p = out;
    while ((p = strstr(p, "RHIZO_STREAM_VERIFY seq=")) != NULL) { last = p; p++; }
    if (last) {
        const char *q;
        if ((q = strstr(last, " dmabuf="))) dmabuf = atoi(q + 8);
        if ((q = strstr(last, " sized="))) sized = atoi(q + 7);
        if ((q = strstr(last, " readback="))) sscanf(q + 10, "%15s", rb);
        if ((q = strstr(last, " left_r="))) left_r = atof(q + 8);
        if ((q = strstr(last, " left_b="))) left_b = atof(q + 8);
        if ((q = strstr(last, " right_r="))) right_r = atof(q + 9);
        if ((q = strstr(last, " right_b="))) right_b = atof(q + 9);
    }
    struct stat dsb;
    long long dump_bytes = stat(dump, &dsb) == 0 ? (long long)dsb.st_size : -1;
    unlink(dump);

    int ok = 1;
    if (sum.frames != 3) { logmsg("selftest: served %llu frame(s), wanted 3", (unsigned long long)sum.frames); ok = 0; }
    if (sum.refused != 1) { logmsg("selftest: refused %llu, wanted the one junk frame refused", (unsigned long long)sum.refused); ok = 0; }
    if (child_rc != 0) { logmsg("selftest: the sender exited %d (3=no ack for a real frame, 5=junk was acked)", child_rc); ok = 0; }
    if (dmabuf != 1) { logmsg("selftest: the GBM buffer's fd was not seen as a dma-buf (dmabuf=%d)", dmabuf); ok = 0; }
    if (sized != 1) { logmsg("selftest: the fd's size did not cover the header's geometry (sized=%d)", sized); ok = 0; }
    if (strcmp(rb, "mmap") != 0 && strcmp(rb, "virtgpu") != 0) { logmsg("selftest: no readback happened (readback=%s)", rb[0] ? rb : "<none>"); ok = 0; }
    if (!(left_r > 200 && left_b < 50 && right_b > 200 && right_r < 50)) {
        logmsg("selftest: the readback did not show red-left/blue-right: left_r=%.1f left_b=%.1f right_r=%.1f right_b=%.1f",
               left_r, left_b, right_r, right_b);
        ok = 0;
    }
    if (dump_bytes != (long long)bo_stride * h) { logmsg("selftest: the dump holds %lld bytes, wanted stride*height=%lld", dump_bytes, (long long)bo_stride * h); ok = 0; }
    if (!ok) {
        fputs(out, stderr);
        return 1;
    }
    printf("RHIZO_STREAM_VERIFY_SELFTEST_OK frames=%llu refused=%llu readback=%s left_r=%.1f left_b=%.1f "
           "right_r=%.1f right_b=%.1f dump_bytes=%lld\n",
           (unsigned long long)sum.frames, (unsigned long long)sum.refused, rb, left_r, left_b, right_r,
           right_b, dump_bytes);
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "usage: rhizo-stream-export-verify --socket PATH [--report FILE] [--dump FILE]\n"
        "                                  [--readback-every N] [--frames N] [--render-node PATH]\n"
        "       rhizo-stream-export-verify --selftest [--render-node PATH]\n"
        "  --socket PATH       listen here for the composer's export connection\n"
        "  --report FILE       append one RHIZO_STREAM_VERIFY line per frame (also on stdout)\n"
        "  --dump FILE         write the newest read-back frame's pixels (rows, memory order R,G,B,A) to FILE\n"
        "                      on SIGUSR1 and when the composer's connection closes\n"
        "  --readback-every N  read the pixels back on every Nth frame (default 30; 1 = every frame; 0 = never)\n"
        "  --frames N          exit after N frames in total (default 0: serve forever)\n");
}

// verify frames from the composer or run the selftest
int main(int argc, char **argv) {
    struct cfg cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.readback_every = 30;
    cfg.render_node = DEFAULT_RENDER_NODE;
    int do_selftest = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) cfg.socket_path = argv[++i];
        else if (!strcmp(argv[i], "--report") && i + 1 < argc) cfg.report_path = argv[++i];
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc) cfg.dump_path = argv[++i];
        else if (!strcmp(argv[i], "--readback-every") && i + 1 < argc) cfg.readback_every = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) cfg.max_frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--render-node") && i + 1 < argc) cfg.render_node = argv[++i];
        else if (!strcmp(argv[i], "--selftest")) do_selftest = 1;
        else { usage(); return 2; }
    }
    signal(SIGPIPE, SIG_IGN);
    if (do_selftest) return selftest(cfg.render_node);
    if (!cfg.socket_path || cfg.readback_every < 0) { usage(); return 2; }
    return run_listener(&cfg);
}

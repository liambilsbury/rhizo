#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>

#include "rhizo/stream_protocol.h"

#define DRM_FORMAT_ABGR8888 0x34324241u

static int64_t now_monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// write a prefixed message to stderr
static void logmsg(const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "[stream-export-test] ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
}

#define CHECK_VA(expr, what) do { \
    VAStatus _st = (expr); \
    if (_st != VA_STATUS_SUCCESS) { \
        logmsg("%s failed: %s (%d)", (what), vaErrorStr(_st), _st); \
        return 1; \
    } \
} while (0)

// paint the surface half red and half blue
static int paint_pattern(VADisplay dpy, VASurfaceID surf) {
    VAImage img;
    CHECK_VA(vaDeriveImage(dpy, surf, &img), "vaDeriveImage");
    void *p;
    CHECK_VA(vaMapBuffer(dpy, img.buf, &p), "vaMapBuffer");
    for (uint32_t row = 0; row < img.height; row++) {
        uint8_t *line = (uint8_t *)p + img.offsets[0] + row * img.pitches[0];
        for (uint32_t col = 0; col < img.width; col++) {
            uint8_t *px = line + col * 4;
            px[0] = col < img.width / 2 ? 255 : 0;
            px[1] = 0;
            px[2] = col < img.width / 2 ? 0 : 255;
            px[3] = 255;
        }
    }
    vaUnmapBuffer(dpy, img.buf);
    vaDestroyImage(dpy, img.image_id);
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "usage: rhizo-stream-export-test --socket PATH [--frames N] [--size WxH]\n"
        "                                [--render-node PATH]\n");
}

// send test frames to the export socket
int main(int argc, char **argv) {
    const char *sock_path = NULL;
    const char *render_node = "/dev/dri/renderD128";
    int frames = 4, width = 1280, height = 800;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) sock_path = argv[++i];
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--render-node") && i + 1 < argc) render_node = argv[++i];
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
            if (sscanf(argv[++i], "%dx%d", &width, &height) != 2) { usage(); return 2; }
        }
        else { usage(); return 2; }
    }
    if (!sock_path || frames <= 0 || width <= 0 || height <= 0) { usage(); return 2; }

    int drm_fd = open(render_node, O_RDWR);
    if (drm_fd < 0) {
        logmsg("open(%s) failed: %s", render_node, strerror(errno));
        return 1;
    }
    VADisplay dpy = vaGetDisplayDRM(drm_fd);
    if (!dpy) {
        logmsg("vaGetDisplayDRM(%s) failed", render_node);
        return 1;
    }
    int major, minor;
    CHECK_VA(vaInitialize(dpy, &major, &minor), "vaInitialize");

    VASurfaceAttrib attr;
    attr.type = VASurfaceAttribPixelFormat;
    attr.flags = VA_SURFACE_ATTRIB_SETTABLE;
    attr.value.type = VAGenericValueTypeInteger;
    attr.value.value.i = VA_FOURCC_RGBA;
    VASurfaceID surf;
    CHECK_VA(vaCreateSurfaces(dpy, VA_RT_FORMAT_RGB32, width, height, &surf, 1, &attr, 1),
             "vaCreateSurfaces");
    if (paint_pattern(dpy, surf) != 0) return 1;

    VADRMPRIMESurfaceDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    CHECK_VA(vaExportSurfaceHandle(dpy, surf, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                   VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_COMPOSED_LAYERS,
                                   &desc), "vaExportSurfaceHandle");

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        logmsg("socket(AF_UNIX) failed: %s", strerror(errno));
        return 1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        logmsg("--socket path is %zu bytes, over the %zu a unix address holds",
               strlen(sock_path), sizeof(addr.sun_path));
        return 1;
    }
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        logmsg("connect(%s) failed: %s", sock_path, strerror(errno));
        return 1;
    }

    for (int i = 0; i < frames; i++) {
        struct rhizo_stream_frame_header hdr;
        memset(&hdr, 0, sizeof(hdr));
        hdr.magic = RHIZO_STREAM_FRAME_MAGIC;
        hdr.version = RHIZO_STREAM_PROTOCOL_VERSION;
        hdr.seq = (uint64_t)(i + 1);
        hdr.presented_ns = now_monotonic_ns();
        hdr.width = width;
        hdr.height = height;
        hdr.drm_fourcc = DRM_FORMAT_ABGR8888;
        hdr.modifier = desc.objects[0].drm_format_modifier;
        hdr.stride_bytes = (int32_t)desc.layers[0].pitch[0];
        hdr.offset_bytes = (int32_t)desc.layers[0].offset[0];

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
        memcpy(CMSG_DATA(cmsg), &desc.objects[0].fd, sizeof(int));
        if (sendmsg(fd, &msg, MSG_NOSIGNAL) != (ssize_t)sizeof(hdr)) {
            logmsg("sendmsg for seq=%d failed: %s", i + 1, strerror(errno));
            return 1;
        }

        struct rhizo_stream_release_ack ack;
        ssize_t n = recv(fd, &ack, sizeof(ack), MSG_WAITALL);
        if (n != (ssize_t)sizeof(ack) || ack.magic != RHIZO_STREAM_ACK_MAGIC ||
            ack.seq != hdr.seq) {
            logmsg("release ack for seq=%d read n=%zd magic=0x%x seq=%llu",
                   i + 1, n, ack.magic, (unsigned long long)ack.seq);
            return 1;
        }
    }
    close(fd);
    printf("RHIZO_STREAM_EXPORT_TEST_OK frames=%d size=%dx%d drm_fourcc=0x%08x\n",
           frames, width, height, DRM_FORMAT_ABGR8888);
    return 0;
}

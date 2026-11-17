#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_vpp.h>
#include <va/va_enc_vp9.h>
#include <va/va_enc_av1.h>
#include <va/va_enc_h264.h>

#define RHIZO_PEER_NAME "system"
#include "../common/peer.h"
#include "rhizo/stream_protocol.h"

#define MAX_TCP_CLIENTS 8
#define DEFAULT_RENDER_NODE "/dev/dri/renderD128"
#define DEFAULT_PROBE_SOCKET "/run/rhizo/data/local/tmp/rhizo-probe.sock"
#define AID_SYSTEM 1000
#define AID_GRAPHICS 1003
#define REFUSAL_LOG_MS 10000

static int g_verbose = 0;
static long g_peer_uid = AID_SYSTEM;
static const char *g_peer_cgroup = NULL;
static int64_t g_refusal_logged_ms = 0;
static unsigned long g_refusals_unlogged = 0;

static int64_t now_monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// write a prefixed message to stderr
static void logmsg(const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "[rhizo-streamd] ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
}

#define CHECK_VA(expr, what) do { \
    VAStatus _st = (expr); \
    if (_st != VA_STATUS_SUCCESS) { \
        logmsg("%s failed with %s (%d)", (what), vaErrorStr(_st), _st); \
        return -1; \
    } \
} while (0)

enum stream_codec { CODEC_NONE = 0, CODEC_VP9, CODEC_AV1, CODEC_H264 };

static const char *codec_name(enum stream_codec c) {
    switch (c) {
        case CODEC_VP9: return "vp9";
        case CODEC_AV1: return "av1";
        case CODEC_H264: return "h264";
        default: return "none";
    }
}

// return whether profile has VAEntrypointEncSliceLP
static int profile_has_lp_encode(VADisplay dpy, VAProfile profile) {
    int max_ep = vaMaxNumEntrypoints(dpy);
    VAEntrypoint *eps = malloc(sizeof(VAEntrypoint) * max_ep);
    if (!eps) return 0;
    int num_ep = 0;
    VAStatus st = vaQueryConfigEntrypoints(dpy, profile, eps, &num_ep);
    int found = 0;
    if (st == VA_STATUS_SUCCESS) {
        for (int i = 0; i < num_ep; i++) {
            if (eps[i] == VAEntrypointEncSliceLP) { found = 1; break; }
        }
    }
    free(eps);
    return found;
}

// choose the codec to encode with
static enum stream_codec pick_codec(VADisplay dpy, const char *forced, int allow_h264,
                                     VAProfile *out_profile) {
    if (forced) {
        if (!strcmp(forced, "vp9") && profile_has_lp_encode(dpy, VAProfileVP9Profile0)) {
            *out_profile = VAProfileVP9Profile0;
            return CODEC_VP9;
        }
        if (!strcmp(forced, "av1")) {
            logmsg("--codec av1 has no AV1 encode function");
            return CODEC_NONE;
        }
        if (!strcmp(forced, "h264")) {
            if (!allow_h264) {
                logmsg("--codec h264 without --allow-h264");
                return CODEC_NONE;
            }
            if (profile_has_lp_encode(dpy, VAProfileH264Main)) {
                *out_profile = VAProfileH264Main;
                return CODEC_H264;
            }
        }
        return CODEC_NONE;
    }
    if (profile_has_lp_encode(dpy, VAProfileVP9Profile0)) {
        *out_profile = VAProfileVP9Profile0;
        return CODEC_VP9;
    }
    return CODEC_NONE;
}

// print the H.264 patent notice
static void print_h264_patent_disclosure(void) {
    fprintf(stderr,
        "rhizo-streamd: --codec h264 was requested. H.264/AVC decode and encode\n"
        "are covered by patent pools (MPEG LA's AVC pool, and Access Advance's\n"
        "HEVC/AVC pool) independent of any copyright question. This project has\n"
        "not sought or obtained a patent license for either pool, and ships no\n"
        "clause claiming one. Proceeding because --codec h264 was passed\n"
        "explicitly; the default codec remains VP9.\n");
}

static uint32_t va_fourcc_for_drm(uint32_t drm) {
    switch (drm) {
        case 0x34325241u: return VA_FOURCC_BGRA;
        case 0x34324241u: return VA_FOURCC_RGBA;
        case 0x34325258u: return VA_FOURCC_BGRX;
        case 0x34324258u: return VA_FOURCC_RGBX;
        default: return 0;
    }
}

// VA-API state for an encoder
struct va_ctx {
    VADisplay dpy;
    int drm_fd;
    enum stream_codec codec;
    VAProfile profile;
    VAConfigID enc_config;
    VAContextID enc_context;
    VAConfigID vpp_config;
    VAContextID vpp_context;
    int width;
    int height;
    VASurfaceID nv12_surface;
    VABufferID coded_buf;
    uint64_t frame_count;
};

// open the DRM render node and call vaInitialize on the VA display
static int va_open(struct va_ctx *ctx, const char *render_node) {
    memset(ctx, 0, sizeof(*ctx));
    ctx->drm_fd = open(render_node, O_RDWR);
    if (ctx->drm_fd < 0) {
        logmsg("open(%s) failed (%s)", render_node, strerror(errno));
        return -1;
    }
    ctx->dpy = vaGetDisplayDRM(ctx->drm_fd);
    if (!ctx->dpy) {
        logmsg("vaGetDisplayDRM(%s) failed", render_node);
        return -1;
    }
    int major, minor;
    CHECK_VA(vaInitialize(ctx->dpy, &major, &minor), "vaInitialize");
    logmsg("VA-API %d.%d on %s", major, minor, render_node);
    return 0;
}

// create the VA-API encode and VPP contexts
static int va_setup_encoder(struct va_ctx *ctx, enum stream_codec codec, VAProfile profile,
                             int width, int height) {
    ctx->codec = codec;
    ctx->profile = profile;
    ctx->width = width;
    ctx->height = height;

    VAConfigAttrib attribs[2];
    attribs[0].type = VAConfigAttribRTFormat;
    attribs[1].type = VAConfigAttribRateControl;
    CHECK_VA(vaGetConfigAttributes(ctx->dpy, profile, VAEntrypointEncSliceLP, attribs, 2),
             "vaGetConfigAttributes(enc)");
    if (!(attribs[0].value & VA_RT_FORMAT_YUV420)) {
        logmsg("%s EncSliceLP has no VA_RT_FORMAT_YUV420", codec_name(codec));
        return -1;
    }
    if (!(attribs[1].value & VA_RC_CQP)) {
        logmsg("%s EncSliceLP has no VA_RC_CQP", codec_name(codec));
        return -1;
    }
    attribs[0].value = VA_RT_FORMAT_YUV420;
    attribs[1].value = VA_RC_CQP;
    CHECK_VA(vaCreateConfig(ctx->dpy, profile, VAEntrypointEncSliceLP, attribs, 2,
                            &ctx->enc_config), "vaCreateConfig(enc)");

    VASurfaceAttrib nv12_attr;
    nv12_attr.type = VASurfaceAttribPixelFormat;
    nv12_attr.flags = VA_SURFACE_ATTRIB_SETTABLE;
    nv12_attr.value.type = VAGenericValueTypeInteger;
    nv12_attr.value.value.i = VA_FOURCC_NV12;
    CHECK_VA(vaCreateSurfaces(ctx->dpy, VA_RT_FORMAT_YUV420, width, height,
                              &ctx->nv12_surface, 1, &nv12_attr, 1), "vaCreateSurfaces(nv12)");

    CHECK_VA(vaCreateContext(ctx->dpy, ctx->enc_config, width, height, VA_PROGRESSIVE,
                             &ctx->nv12_surface, 1, &ctx->enc_context), "vaCreateContext(enc)");

    CHECK_VA(vaCreateBuffer(ctx->dpy, ctx->enc_context, VAEncCodedBufferType,
                            (unsigned int)(width * height), 1, NULL, &ctx->coded_buf),
             "vaCreateBuffer(coded)");

    VAConfigAttrib vpp_attr;
    vpp_attr.type = VAConfigAttribRTFormat;
    vpp_attr.value = VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_RGB32;
    CHECK_VA(vaCreateConfig(ctx->dpy, VAProfileNone, VAEntrypointVideoProc, &vpp_attr, 1,
                            &ctx->vpp_config), "vaCreateConfig(vpp)");
    CHECK_VA(vaCreateContext(ctx->dpy, ctx->vpp_config, width, height, VA_PROGRESSIVE,
                             &ctx->nv12_surface, 1, &ctx->vpp_context), "vaCreateContext(vpp)");
    return 0;
}

// free the VA-API encode and VPP objects
static void va_teardown_encoder(struct va_ctx *ctx) {
    if (ctx->coded_buf) vaDestroyBuffer(ctx->dpy, ctx->coded_buf);
    if (ctx->vpp_context) vaDestroyContext(ctx->dpy, ctx->vpp_context);
    if (ctx->vpp_config) vaDestroyConfig(ctx->dpy, ctx->vpp_config);
    if (ctx->enc_context) vaDestroyContext(ctx->dpy, ctx->enc_context);
    if (ctx->nv12_surface) vaDestroySurfaces(ctx->dpy, &ctx->nv12_surface, 1);
    if (ctx->enc_config) vaDestroyConfig(ctx->dpy, ctx->enc_config);
    ctx->coded_buf = 0;
    ctx->vpp_context = 0;
    ctx->vpp_config = 0;
    ctx->enc_context = 0;
    ctx->nv12_surface = 0;
    ctx->enc_config = 0;
    ctx->width = 0;
    ctx->height = 0;
}

// convert the RGBA surface to NV12
static int va_convert_to_nv12(struct va_ctx *ctx, VASurfaceID rgba_surface) {
    VAProcPipelineParameterBuffer pipe;
    memset(&pipe, 0, sizeof(pipe));
    pipe.surface = rgba_surface;

    VABufferID pipe_buf;
    CHECK_VA(vaCreateBuffer(ctx->dpy, ctx->vpp_context, VAProcPipelineParameterBufferType,
                            sizeof(pipe), 1, &pipe, &pipe_buf), "vaCreateBuffer(vpp pipeline)");
    CHECK_VA(vaBeginPicture(ctx->dpy, ctx->vpp_context, ctx->nv12_surface), "vaBeginPicture(vpp)");
    CHECK_VA(vaRenderPicture(ctx->dpy, ctx->vpp_context, &pipe_buf, 1), "vaRenderPicture(vpp)");
    CHECK_VA(vaEndPicture(ctx->dpy, ctx->vpp_context), "vaEndPicture(vpp)");
    vaDestroyBuffer(ctx->dpy, pipe_buf);
    CHECK_VA(vaSyncSurface(ctx->dpy, ctx->nv12_surface), "vaSyncSurface(vpp out)");
    return 0;
}

// encode a VP9 keyframe from the NV12 surface
static int encode_one_frame_vp9(struct va_ctx *ctx, uint8_t **out_data, uint32_t *out_len) {
    VAEncSequenceParameterBufferVP9 seq;
    memset(&seq, 0, sizeof(seq));
    seq.max_frame_width = ctx->width;
    seq.max_frame_height = ctx->height;
    seq.kf_auto = 0;
    seq.kf_min_dist = 1;
    seq.kf_max_dist = 1;
    seq.intra_period = 1;
    seq.bits_per_second = 0;

    VAEncPictureParameterBufferVP9 pic;
    memset(&pic, 0, sizeof(pic));
    for (int i = 0; i < 8; i++) pic.reference_frames[i] = VA_INVALID_ID;
    pic.frame_width_src = ctx->width;
    pic.frame_height_src = ctx->height;
    pic.frame_width_dst = ctx->width;
    pic.frame_height_dst = ctx->height;
    pic.reconstructed_frame = ctx->nv12_surface;
    pic.coded_buf = ctx->coded_buf;
    pic.ref_flags.bits.force_kf = 1;
    pic.pic_flags.bits.frame_type = 0;
    pic.pic_flags.bits.show_frame = 1;
    pic.luma_ac_qindex = 60;
    pic.luma_dc_qindex_delta = 1;
    pic.chroma_ac_qindex_delta = 1;
    pic.chroma_dc_qindex_delta = 1;
    pic.filter_level = 0;
    pic.sharpness_level = 0;

    VABufferID seq_buf, pic_buf, seg_buf;
    CHECK_VA(vaCreateBuffer(ctx->dpy, ctx->enc_context, VAEncSequenceParameterBufferType,
                            sizeof(seq), 1, &seq, &seq_buf), "vaCreateBuffer(seq)");
    CHECK_VA(vaCreateBuffer(ctx->dpy, ctx->enc_context, VAEncPictureParameterBufferType,
                            sizeof(pic), 1, &pic, &pic_buf), "vaCreateBuffer(pic)");
    VAEncMiscParameterTypeVP9PerSegmantParam seg;
    memset(&seg, 0, sizeof(seg));
    CHECK_VA(vaCreateBuffer(ctx->dpy, ctx->enc_context, VAQMatrixBufferType,
                            sizeof(seg), 1, &seg, &seg_buf), "vaCreateBuffer(qmatrix)");

    VABufferID buffers[3] = {seq_buf, pic_buf, seg_buf};
    CHECK_VA(vaBeginPicture(ctx->dpy, ctx->enc_context, ctx->nv12_surface), "vaBeginPicture(enc)");
    CHECK_VA(vaRenderPicture(ctx->dpy, ctx->enc_context, buffers, 3), "vaRenderPicture(enc)");
    CHECK_VA(vaEndPicture(ctx->dpy, ctx->enc_context), "vaEndPicture(enc)");

    vaDestroyBuffer(ctx->dpy, seq_buf);
    vaDestroyBuffer(ctx->dpy, pic_buf);
    vaDestroyBuffer(ctx->dpy, seg_buf);

    CHECK_VA(vaSyncSurface(ctx->dpy, ctx->nv12_surface), "vaSyncSurface(enc)");

    VACodedBufferSegment *seg_out;
    CHECK_VA(vaMapBuffer(ctx->dpy, ctx->coded_buf, (void **)&seg_out), "vaMapBuffer(coded)");
    if (seg_out->status & VA_CODED_BUF_STATUS_SLICE_OVERFLOW_MASK) {
        logmsg("VA_CODED_BUF_STATUS_SLICE_OVERFLOW_MASK set at width*height=%d",
               ctx->width * ctx->height);
        vaUnmapBuffer(ctx->dpy, ctx->coded_buf);
        return -1;
    }
    *out_data = seg_out->buf;
    *out_len = seg_out->size;
    ctx->frame_count++;
    return 0;
}

// write the IVF file header
static void write_ivf_header(FILE *f, uint32_t codec_fourcc, int width, int height,
                              uint32_t framecount) {
    uint8_t hdr[32] = {0};
    memcpy(hdr + 0, "DKIF", 4);
    uint16_t version = 0, header_len = 32;
    memcpy(hdr + 4, &version, 2);
    memcpy(hdr + 6, &header_len, 2);
    memcpy(hdr + 8, &codec_fourcc, 4);
    uint16_t w16 = (uint16_t)width, h16 = (uint16_t)height;
    memcpy(hdr + 12, &w16, 2);
    memcpy(hdr + 14, &h16, 2);
    uint32_t rate = 30, scale = 1;
    memcpy(hdr + 16, &rate, 4);
    memcpy(hdr + 20, &scale, 4);
    memcpy(hdr + 24, &framecount, 4);
    fwrite(hdr, 1, 32, f);
}

// write an IVF frame header and data
static void write_ivf_frame(FILE *f, const uint8_t *data, uint32_t len, uint64_t pts) {
    uint8_t hdr[12];
    memcpy(hdr + 0, &len, 4);
    memcpy(hdr + 4, &pts, 8);
    fwrite(hdr, 1, 12, f);
    fwrite(data, 1, len, f);
}

// encode synthetic frames to an IVF file
static int selftest_encode(const char *render_node, const char *out_path,
                            const char *forced_codec, int allow_h264, int frames, int width,
                            int height) {
    struct va_ctx ctx;
    if (va_open(&ctx, render_node) != 0) return 1;

    VAProfile profile;
    enum stream_codec codec = pick_codec(ctx.dpy, forced_codec, allow_h264, &profile);
    if (codec == CODEC_NONE) {
        logmsg("no usable EncSliceLP profile found forced=%s allow_h264=%d",
               forced_codec ? forced_codec : "auto", allow_h264);
        return 1;
    }
    logmsg("selftest codec=%s profile=%d", codec_name(codec), (int)profile);

    if (va_setup_encoder(&ctx, codec, profile, width, height) != 0) return 1;

    VAImage img;
    CHECK_VA(vaDeriveImage(ctx.dpy, ctx.nv12_surface, &img), "vaDeriveImage(selftest)");
    void *p;
    CHECK_VA(vaMapBuffer(ctx.dpy, img.buf, &p), "vaMapBuffer(selftest image)");
    uint8_t *base = (uint8_t *)p;
    for (uint32_t row = 0; row < img.height; row++) {
        memset(base + img.offsets[0] + row * img.pitches[0], (row * 2) & 0xff, img.width);
    }
    for (uint32_t row = 0; row < img.height / 2; row++) {
        uint8_t *uv = base + img.offsets[1] + row * img.pitches[1];
        for (uint32_t col = 0; col < img.width / 2; col++) {
            uv[col * 2] = 128;
            uv[col * 2 + 1] = 128;
        }
    }
    vaUnmapBuffer(ctx.dpy, img.buf);
    vaDestroyImage(ctx.dpy, img.image_id);

    if (codec != CODEC_VP9) {
        logmsg("no encode path for a codec other than VP9");
        return 1;
    }

    FILE *f = fopen(out_path, "wb");
    if (!f) {
        logmsg("fopen(%s) failed (%s)", out_path, strerror(errno));
        return 1;
    }
    write_ivf_header(f, 0x30395056  , width, height,
                     (uint32_t)frames);

    uint64_t total_bytes = 0;
    int64_t t0 = now_monotonic_ns();
    for (int i = 0; i < frames; i++) {
        uint8_t *coded;
        uint32_t coded_len;
        if (encode_one_frame_vp9(&ctx, &coded, &coded_len) != 0) { fclose(f); return 1; }
        write_ivf_frame(f, coded, coded_len, (uint64_t)i);
        total_bytes += coded_len;
        vaUnmapBuffer(ctx.dpy, ctx.coded_buf);
    }
    int64_t elapsed_ns = now_monotonic_ns() - t0;
    fclose(f);

    double fps = elapsed_ns > 0 ? (double)frames * 1e9 / (double)elapsed_ns : 0.0;
    printf("RHIZO_STREAMD_SELFTEST_OK codec=%s frames=%d size=%dx%d bytes=%llu fps=%.2f out=%s\n",
           codec_name(codec), frames, width, height, (unsigned long long)total_bytes, fps,
           out_path);
    return 0;
}

// write a shell command line to the rhizo-probed socket
static void probe_run(const char *probe_socket, const char *cmd) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, probe_socket, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        if (g_verbose) logmsg("connect(%s) failed (%s)", probe_socket, strerror(errno));
        close(fd);
        return;
    }
    char line[256];
    int n = snprintf(line, sizeof(line), "%s\n", cmd);
    ssize_t ignore = write(fd, line, (size_t)n);
    (void)ignore;
    shutdown(fd, SHUT_WR);
    char discard[256];
    while (read(fd, discard, sizeof(discard)) > 0) {}
    close(fd);
}

// write an inject touch command to rhizo-probed
static void relay_touch(const char *probe_socket, int64_t display_id, const char *sub, int x,
                         int y) {
    char cmd[192];
    snprintf(cmd, sizeof(cmd),
             "sh -c 'echo inject touch %s %lld %d %d > /data/rhizo_control/control'", sub,
             (long long)display_id, x, y);
    probe_run(probe_socket, cmd);
}

enum client_kind { CLIENT_RAW = 0, CLIENT_WS = 1 };

struct daemon_state {
    struct va_ctx ctx;
    const char *probe_socket;
    int64_t primary_display_id;
    int listen_fd;
    const char *html_path;
    int tcp_clients[MAX_TCP_CLIENTS];
    enum client_kind client_kind[MAX_TCP_CLIENTS];
    pthread_mutex_t clients_lock;
};

// hello message for stream viewers
struct stream_wire_hello {
    uint32_t magic;
    uint32_t version;
    uint32_t codec_fourcc;
    int32_t width;
    int32_t height;
};

#define RHIZO_STREAM_WIRE_MAGIC 0x52535731u

static uint32_t codec_fourcc(enum stream_codec c) {
    switch (c) {
        case CODEC_VP9: return 0x30395056u;
        case CODEC_AV1: return 0x31305641u;
        case CODEC_H264: return 0x34363248u;
        default: return 0;
    }
}

// touch event from a viewer
struct stream_input_msg {
    uint32_t kind;
    int32_t x;
    int32_t y;
};

#define WS_OP_TEXT 0x1
#define WS_OP_BINARY 0x2
#define WS_GUID "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

static void sha1(const uint8_t *data, size_t len, uint8_t out[20]) {
    uint32_t h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    uint64_t bitlen = (uint64_t)len * 8;
    size_t padded = ((len + 8) / 64 + 1) * 64;
    uint8_t *buf = calloc(1, padded);
    memcpy(buf, data, len);
    buf[len] = 0x80;
    for (int i = 0; i < 8; i++) buf[padded - 1 - i] = (uint8_t)(bitlen >> (8 * i));
    for (size_t chunk = 0; chunk < padded; chunk += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)buf[chunk + i * 4] << 24) | ((uint32_t)buf[chunk + i * 4 + 1] << 16) |
                   ((uint32_t)buf[chunk + i * 4 + 2] << 8) | buf[chunk + i * 4 + 3];
        for (int i = 16; i < 80; i++) {
            uint32_t v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
            w[i] = (v << 1) | (v >> 31);
        }
        uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) { f = (b & c) | ((~b) & d); k = 0x5A827999; }
            else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
            else { f = b ^ c ^ d; k = 0xCA62C1D6; }
            uint32_t temp = ((a << 5) | (a >> 27)) + f + e + k + w[i];
            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp;
        }
        h0 += a; h1 += b; h2 += c; h3 += d; h4 += e;
    }
    free(buf);
    uint32_t h[5] = {h0, h1, h2, h3, h4};
    for (int i = 0; i < 5; i++) {
        out[i * 4] = (uint8_t)(h[i] >> 24); out[i * 4 + 1] = (uint8_t)(h[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(h[i] >> 8); out[i * 4 + 3] = (uint8_t)h[i];
    }
}

static void base64_encode(const uint8_t *data, size_t len, char *out) {
    static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i = 0, o = 0;
    for (; i + 3 <= len; i += 3) {
        uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1] << 8) | data[i + 2];
        out[o++] = tbl[(v >> 18) & 63]; out[o++] = tbl[(v >> 12) & 63];
        out[o++] = tbl[(v >> 6) & 63]; out[o++] = tbl[v & 63];
    }
    size_t rem = len - i;
    if (rem == 1) {
        uint32_t v = (uint32_t)data[i] << 16;
        out[o++] = tbl[(v >> 18) & 63]; out[o++] = tbl[(v >> 12) & 63]; out[o++] = '='; out[o++] = '=';
    } else if (rem == 2) {
        uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1] << 8);
        out[o++] = tbl[(v >> 18) & 63]; out[o++] = tbl[(v >> 12) & 63]; out[o++] = tbl[(v >> 6) & 63];
        out[o++] = '=';
    }
    out[o] = '\0';
}

// write an unmasked WebSocket frame with sendmsg
static ssize_t ws_send_frame(int fd, int opcode, const uint8_t *payload, size_t len) {
    uint8_t hdr[10];
    size_t hlen;
    hdr[0] = (uint8_t)(0x80 | (opcode & 0x0F));
    if (len < 126) { hdr[1] = (uint8_t)len; hlen = 2; }
    else if (len <= 0xFFFF) { hdr[1] = 126; hdr[2] = (uint8_t)(len >> 8); hdr[3] = (uint8_t)len; hlen = 4; }
    else {
        hdr[1] = 127;
        for (int i = 0; i < 8; i++) hdr[2 + i] = (uint8_t)(len >> (8 * (7 - i)));
        hlen = 10;
    }
    struct iovec iov[2] = {{hdr, hlen}, {(void *)payload, len}};
    struct msghdr msg = {0};
    msg.msg_iov = iov;
    msg.msg_iovlen = payload ? 2 : 1;
    return sendmsg(fd, &msg, MSG_NOSIGNAL);
}

// read a WebSocket frame payload
static ssize_t ws_recv_frame(int fd, uint8_t *out, size_t max_out, int *opcode) {
    uint8_t hdr[2];
    if (recv(fd, hdr, 2, MSG_WAITALL) != 2) return -1;
    if (!(hdr[0] & 0x80) || (hdr[0] & 0x70)) return -1;
    *opcode = hdr[0] & 0x0F;
    if (!(hdr[1] & 0x80)) return -1;
    uint64_t len = hdr[1] & 0x7F;
    if (len == 126) {
        uint8_t ext[2];
        if (recv(fd, ext, 2, MSG_WAITALL) != 2) return -1;
        len = ((uint16_t)ext[0] << 8) | ext[1];
    } else if (len == 127) {
        uint8_t ext[8];
        if (recv(fd, ext, 8, MSG_WAITALL) != 8) return -1;
        len = 0;
        for (int i = 0; i < 8; i++) len = (len << 8) | ext[i];
    }
    if (len > max_out) return -1;
    uint8_t mask[4];
    if (recv(fd, mask, 4, MSG_WAITALL) != 4) return -1;
    if (len && recv(fd, out, len, MSG_WAITALL) != (ssize_t)len) return -1;
    for (uint64_t i = 0; i < len; i++) out[i] ^= mask[i % 4];
    return (ssize_t)len;
}

// read HTTP headers up to \r\n\r\n into buf
static ssize_t http_recv_request(int fd, char *buf, size_t max) {
    size_t n = 0;
    while (n + 1 < max) {
        ssize_t r = recv(fd, buf + n, 1, 0);
        if (r != 1) return -1;
        n++;
        if (n >= 4 && !memcmp(buf + n - 4, "\r\n\r\n", 4)) { buf[n] = '\0'; return (ssize_t)n; }
    }
    return -1;
}

// copy an HTTP header value into out
static int http_header(const char *req, const char *name, char *out, size_t outlen) {
    const char *p = req;
    size_t nlen = strlen(name);
    while ((p = strcasestr(p, name))) {
        if (p[nlen] == ':') {
            p += nlen + 1;
            while (*p == ' ') p++;
            const char *end = strstr(p, "\r\n");
            if (!end) return 0;
            size_t vlen = (size_t)(end - p);
            if (vlen >= outlen) vlen = outlen - 1;
            memcpy(out, p, vlen);
            out[vlen] = '\0';
            return 1;
        }
        p += nlen;
    }
    return 0;
}

// write the viewer page to cfd
static void serve_http_page(int cfd, const char *html_path) {
    FILE *f = fopen(html_path, "rb");
    if (!f) {
        const char *msg = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        send(cfd, msg, strlen(msg), MSG_NOSIGNAL);
        return;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char header[160];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
        "Content-Length: %ld\r\nConnection: close\r\n\r\n", size);
    send(cfd, header, (size_t)hlen, MSG_NOSIGNAL);
    char buf[8192];
    size_t r;
    while ((r = fread(buf, 1, sizeof(buf), f)) > 0) send(cfd, buf, r, MSG_NOSIGNAL);
    fclose(f);
}

// complete the WebSocket handshake
static int ws_handshake(int cfd, const char *req) {
    char key[128];
    if (!http_header(req, "Sec-WebSocket-Key", key, sizeof(key))) return 0;
    char combined[128 + sizeof(WS_GUID)];
    snprintf(combined, sizeof(combined), "%s%s", key, WS_GUID);
    uint8_t digest[20];
    sha1((const uint8_t *)combined, strlen(combined), digest);
    char accept_b64[32];
    base64_encode(digest, sizeof(digest), accept_b64);
    char resp[256];
    int rlen = snprintf(resp, sizeof(resp),
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n", accept_b64);
    return send(cfd, resp, (size_t)rlen, MSG_NOSIGNAL) == rlen;
}

// return whether the connection starts with "GET "
static int looks_like_http(int cfd) {
    struct timeval tv = {0, 150000};
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    char peek[4] = {0};
    ssize_t n = recv(cfd, peek, sizeof(peek), MSG_PEEK);
    struct timeval none = {0, 0};
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof(none));
    return n == 4 && !memcmp(peek, "GET ", 4);
}

// write an encoded chunk to each viewer
static void broadcast_chunk(struct daemon_state *st, const uint8_t *data, uint32_t len,
                            int64_t presented_ns) {
    uint32_t framed_len = len;
    pthread_mutex_lock(&st->clients_lock);
    for (int i = 0; i < MAX_TCP_CLIENTS; i++) {
        if (st->tcp_clients[i] < 0) continue;
        ssize_t sent;
        if (st->client_kind[i] == CLIENT_WS) {
            sent = ws_send_frame(st->tcp_clients[i], WS_OP_BINARY, data, len);
        } else {
            struct iovec iov[3] = {{&presented_ns, sizeof(presented_ns)},
                                    {&framed_len, sizeof(framed_len)}, {(void *)data, len}};
            struct msghdr msg = {0};
            msg.msg_iov = iov;
            msg.msg_iovlen = 3;
            sent = sendmsg(st->tcp_clients[i], &msg, MSG_NOSIGNAL);
        }
        if (sent < 0) {
            close(st->tcp_clients[i]);
            st->tcp_clients[i] = -1;
        }
    }
    pthread_mutex_unlock(&st->clients_lock);
}

struct input_reader_arg {
    struct daemon_state *st;
    int fd;
    int slot;
};

// parse the touch fields from a JSON frame
static int parse_ws_input(const char *json, char *kind, size_t kind_len, int *x, int *y) {
    const char *k = strstr(json, "\"kind\"");
    const char *xv = strstr(json, "\"x\"");
    const char *yv = strstr(json, "\"y\"");
    if (!k || !xv || !yv) return 0;
    k = strchr(k, ':'); if (!k) return 0;
    k = strchr(k, '"'); if (!k) return 0;
    k++;
    size_t i = 0;
    while (*k && *k != '"' && i + 1 < kind_len) kind[i++] = *k++;
    kind[i] = '\0';
    if (strcmp(kind, "down") && strcmp(kind, "move") && strcmp(kind, "up")) return 0;
    xv = strchr(xv, ':'); if (!xv) return 0;
    yv = strchr(yv, ':'); if (!yv) return 0;
    *x = atoi(xv + 1);
    *y = atoi(yv + 1);
    return 1;
}

// read viewer input and call relay_touch
static void *input_reader_thread(void *arg) {
    struct input_reader_arg *a = arg;
    if (a->st->client_kind[a->slot] == CLIENT_WS) {
        uint8_t buf[512];
        for (;;) {
            int opcode;
            ssize_t n = ws_recv_frame(a->fd, buf, sizeof(buf) - 1, &opcode);
            if (n < 0 || opcode == 0x8) break;
            if (opcode != WS_OP_TEXT) continue;
            buf[n] = '\0';
            char kind[8];
            int x, y;
            if (parse_ws_input((const char *)buf, kind, sizeof(kind), &x, &y)) {
                relay_touch(a->st->probe_socket, a->st->primary_display_id, kind, x, y);
            }
        }
    } else {
        struct stream_input_msg msg;
        for (;;) {
            ssize_t n = recv(a->fd, &msg, sizeof(msg), MSG_WAITALL);
            if (n != (ssize_t)sizeof(msg)) break;
            const char *sub = msg.kind == 0 ? "down" : msg.kind == 1 ? "move" : "up";
            relay_touch(a->st->probe_socket, a->st->primary_display_id, sub, msg.x, msg.y);
        }
    }
    pthread_mutex_lock(&a->st->clients_lock);
    if (a->st->tcp_clients[a->slot] == a->fd) {
        close(a->fd);
        a->st->tcp_clients[a->slot] = -1;
    }
    pthread_mutex_unlock(&a->st->clients_lock);
    free(a);
    return NULL;
}

// add a viewer slot and write the hello
static void place_client(struct daemon_state *st, int cfd, enum client_kind kind,
                         const void *hello, size_t hello_len) {
    pthread_mutex_lock(&st->clients_lock);
    int placed = -1;
    for (int i = 0; i < MAX_TCP_CLIENTS; i++) {
        if (st->tcp_clients[i] < 0) {
            st->tcp_clients[i] = cfd;
            st->client_kind[i] = kind;
            placed = i;
            break;
        }
    }
    int hello_ok = 0;
    if (placed >= 0) {
        ssize_t sent = (kind == CLIENT_WS)
            ? ws_send_frame(cfd, WS_OP_TEXT, (const uint8_t *)hello, hello_len)
            : send(cfd, hello, hello_len, MSG_NOSIGNAL);
        hello_ok = (kind == CLIENT_WS) ? (sent >= 0) : (sent == (ssize_t)hello_len);
        if (!hello_ok) st->tcp_clients[placed] = -1;
    }
    pthread_mutex_unlock(&st->clients_lock);
    if (placed < 0) {
        logmsg("MAX_TCP_CLIENTS viewers connected, closed viewer fd");
        close(cfd);
        return;
    }
    if (!hello_ok) {
        logmsg("failed to write the stream hello (%s)", strerror(errno));
        close(cfd);
        return;
    }
    struct input_reader_arg *a = malloc(sizeof(*a));
    a->st = st;
    a->fd = cfd;
    a->slot = placed;
    pthread_t reader;
    pthread_create(&reader, NULL, input_reader_thread, a);
    pthread_detach(reader);
}

// call accept for TCP viewer connections
static void *tcp_accept_thread(void *arg) {
    struct daemon_state *st = arg;
    for (;;) {
        int cfd = accept(st->listen_fd, NULL, NULL);
        if (cfd < 0) continue;

        if (looks_like_http(cfd)) {
            char req[4096];
            if (http_recv_request(cfd, req, sizeof(req)) < 0) { close(cfd); continue; }
            char upgrade[32];
            int is_ws = http_header(req, "Upgrade", upgrade, sizeof(upgrade)) &&
                        !strcasecmp(upgrade, "websocket");
            if (!is_ws) {
                serve_http_page(cfd, st->html_path);
                close(cfd);
                continue;
            }
            if (!ws_handshake(cfd, req)) { close(cfd); continue; }
            char hello_json[64];
            int hlen = snprintf(hello_json, sizeof(hello_json),
                "{\"codec\":\"%s\",\"width\":%d,\"height\":%d}",
                codec_name(st->ctx.codec), st->ctx.width, st->ctx.height);
            place_client(st, cfd, CLIENT_WS, hello_json, (size_t)hlen);
            continue;
        }

        struct stream_wire_hello hello;
        memset(&hello, 0, sizeof(hello));
        hello.magic = RHIZO_STREAM_WIRE_MAGIC;
        hello.version = RHIZO_STREAM_PROTOCOL_VERSION;
        hello.codec_fourcc = codec_fourcc(st->ctx.codec);
        hello.width = st->ctx.width;
        hello.height = st->ctx.height;
        place_client(st, cfd, CLIENT_RAW, &hello, sizeof(hello));
    }
    return NULL;
}

// encode and broadcast frames from the composer
static void serve_composer_connection(struct daemon_state *st, int cfd) {
    for (;;) {
        struct rhizo_stream_frame_header hdr;
        struct iovec iov = {&hdr, sizeof(hdr)};
        char cmsgbuf[CMSG_SPACE(sizeof(int))];
        struct msghdr msg = {0};
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsgbuf;
        msg.msg_controllen = sizeof(cmsgbuf);

        ssize_t n = recvmsg(cfd, &msg, MSG_WAITALL);
        if (n != (ssize_t)sizeof(hdr)) {
            if (n != 0) logmsg("recvmsg returned n=%zd for the frame header", n);
            break;
        }
        if (hdr.magic != RHIZO_STREAM_FRAME_MAGIC) {
            logmsg("frame magic 0x%x != RHIZO_STREAM_FRAME_MAGIC", hdr.magic);
            break;
        }
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
        if (!cmsg || cmsg->cmsg_type != SCM_RIGHTS) {
            logmsg("frame seq=%llu has no SCM_RIGHTS fd", (unsigned long long)hdr.seq);
            break;
        }
        int dmabuf_fd;
        memcpy(&dmabuf_fd, CMSG_DATA(cmsg), sizeof(int));

        uint32_t va_fourcc = va_fourcc_for_drm(hdr.drm_fourcc);
        if (va_fourcc == 0) {
            logmsg("frame seq=%llu drm format 0x%x has no va_fourcc_for_drm mapping",
                   (unsigned long long)hdr.seq, hdr.drm_fourcc);
            close(dmabuf_fd);
            break;
        }

        if (st->ctx.width != hdr.width || st->ctx.height != hdr.height) {
            va_teardown_encoder(&st->ctx);
            if (va_setup_encoder(&st->ctx, st->ctx.codec, st->ctx.profile, hdr.width,
                                 hdr.height) != 0) {
                logmsg("va_setup_encoder failed at %dx%d for "
                       "frame seq=%llu", hdr.width, hdr.height, (unsigned long long)hdr.seq);
                close(dmabuf_fd);
                break;
            }
            logmsg("encoder context rebuilt at %dx%d", hdr.width, hdr.height);
        }

        VADRMPRIMESurfaceDescriptor desc;
        memset(&desc, 0, sizeof(desc));
        desc.fourcc = va_fourcc;
        desc.width = (uint32_t)hdr.width;
        desc.height = (uint32_t)hdr.height;
        desc.num_objects = 1;
        desc.objects[0].fd = dmabuf_fd;
        desc.objects[0].size = (uint32_t)(hdr.stride_bytes * hdr.height);
        desc.objects[0].drm_format_modifier = hdr.modifier;
        desc.num_layers = 1;
        desc.layers[0].drm_format = hdr.drm_fourcc;
        desc.layers[0].num_planes = 1;
        desc.layers[0].object_index[0] = 0;
        desc.layers[0].offset[0] = (uint32_t)hdr.offset_bytes;
        desc.layers[0].pitch[0] = (uint32_t)hdr.stride_bytes;

        VASurfaceAttribExternalBuffers ext_buf;
        memset(&ext_buf, 0, sizeof(ext_buf));
        VASurfaceAttrib attribs[2];
        attribs[0].type = VASurfaceAttribMemoryType;
        attribs[0].flags = VA_SURFACE_ATTRIB_SETTABLE;
        attribs[0].value.type = VAGenericValueTypeInteger;
        attribs[0].value.value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2;
        attribs[1].type = VASurfaceAttribExternalBufferDescriptor;
        attribs[1].flags = VA_SURFACE_ATTRIB_SETTABLE;
        attribs[1].value.type = VAGenericValueTypePointer;
        attribs[1].value.value.p = &desc;

        VASurfaceID rgba_surface;
        VAStatus vst = vaCreateSurfaces(st->ctx.dpy, VA_RT_FORMAT_RGB32, hdr.width, hdr.height,
                                        &rgba_surface, 1, attribs, 2);
        if (vst != VA_STATUS_SUCCESS) {
            logmsg("vaCreateSurfaces(import) failed (%s)", vaErrorStr(vst));
            close(dmabuf_fd);
            break;
        }

        int ok = (va_convert_to_nv12(&st->ctx, rgba_surface) == 0);
        uint8_t *coded = NULL;
        uint32_t coded_len = 0;
        if (ok) ok = (encode_one_frame_vp9(&st->ctx, &coded, &coded_len) == 0);
        if (ok) {
            broadcast_chunk(st, coded, coded_len, hdr.presented_ns);
            vaUnmapBuffer(st->ctx.dpy, st->ctx.coded_buf);
        }
        vaDestroySurfaces(st->ctx.dpy, &rgba_surface, 1);
        close(dmabuf_fd);

        struct rhizo_stream_release_ack ack;
        ack.magic = RHIZO_STREAM_ACK_MAGIC;
        ack.seq = hdr.seq;
        ssize_t sent = send(cfd, &ack, sizeof(ack), MSG_NOSIGNAL);
        if (sent != (ssize_t)sizeof(ack)) {
            logmsg("failed to write release ack for seq=%llu",
                   (unsigned long long)hdr.seq);
            break;
        }
        if (!ok) logmsg("failed to encode frame seq=%llu",
                        (unsigned long long)hdr.seq);
    }
    close(cfd);
}

// return the systemd activation socket fd
static int systemd_socket_fd(void) {
    const char *pid_s = getenv("LISTEN_PID");
    const char *fds_s = getenv("LISTEN_FDS");
    if (!pid_s || !fds_s) return -1;
    if (atoi(pid_s) != (int)getpid()) return -1;
    if (atoi(fds_s) < 1) return -1;
    return 3;
}

// bind and listen on socket_path with group AID_GRAPHICS and mode 0660, or return -1
static int listen_composer_socket(const char *socket_path) {
    unlink(socket_path);
    int ufd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (ufd < 0) { logmsg("socket(AF_UNIX) failed (%s)", strerror(errno)); return -1; }
    struct sockaddr_un uaddr;
    memset(&uaddr, 0, sizeof(uaddr));
    uaddr.sun_family = AF_UNIX;
    strncpy(uaddr.sun_path, socket_path, sizeof(uaddr.sun_path) - 1);
    if (bind(ufd, (struct sockaddr *)&uaddr, sizeof(uaddr)) != 0) {
        logmsg("bind(%s) failed (%s)", socket_path, strerror(errno));
        close(ufd);
        return -1;
    }
    if (geteuid() == 0 && chown(socket_path, (uid_t)-1, AID_GRAPHICS) != 0)
        logmsg("chown(%s, -1, %d) failed (%s)", socket_path, AID_GRAPHICS, strerror(errno));
    if (chmod(socket_path, 0660) != 0) {
        logmsg("chmod(%s, 0660) failed (%s)", socket_path,
               strerror(errno));
        close(ufd);
        unlink(socket_path);
        return -1;
    }
    if (listen(ufd, 4) != 0) {
        logmsg("listen(unix) failed (%s)", strerror(errno));
        close(ufd);
        return -1;
    }
    return ufd;
}

// log a refused connection if REFUSAL_LOG_MS passed since the last refusal line
static void log_refusal(const char *why) {
    int64_t now = now_monotonic_ns() / 1000000;
    if (g_refusal_logged_ms != 0 && now - g_refusal_logged_ms < REFUSAL_LOG_MS) {
        g_refusals_unlogged++;
        return;
    }
    if (g_refusals_unlogged > 0)
        logmsg("refused a connection from %s unlogged_refusals=%lu", why,
               g_refusals_unlogged);
    else
        logmsg("refused a connection from %s", why);
    g_refusal_logged_ms = now;
    g_refusals_unlogged = 0;
}

// call accept and return the fd if rhizo_peer_allowed returns 1, or -1
static int accept_composer(int ufd) {
    int cfd = accept(ufd, NULL, NULL);
    if (cfd < 0) return -1;
    char why[PATH_MAX + 160];
    if (!rhizo_peer_allowed(cfd, g_peer_uid, g_peer_cgroup, why, sizeof(why))) {
        log_refusal(why);
        close(cfd);
        return -1;
    }
    return cfd;
}

// return whether recv on fd returns 0 or fails with ECONNRESET
static int hung_up(int fd) {
    struct timeval tv = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    char b;
    ssize_t n = recv(fd, &b, 1, 0);
    return n == 0 || (n < 0 && errno == ECONNRESET);
}

// print ok or FAIL and what, and return !ok
static int selftest_case(int ok, const char *what) {
    printf("%s %s\n", ok ? "ok" : "FAIL", what);
    return !ok;
}

// write body to path, or return -1
static int write_fixture(const char *path, const char *body) {
    FILE *f = fopen(path, "we");
    if (!f) return -1;
    int ok = fputs(body, f) >= 0;
    return (fclose(f) == 0 && ok) ? 0 : -1;
}

// test rhizo_peer_read_cgroup_file on fixture files and return the failure count
static int selftest_cgroup_files(const char *dir) {
    static char longline[RHIZO_PEER_LINE_MAX + 64];
    int n = snprintf(longline, sizeof(longline), "1:name=x:/");
    memset(longline + n, 'a', (size_t)(RHIZO_PEER_LINE_MAX - 1 - n));
    snprintf(longline + RHIZO_PEER_LINE_MAX - 1, sizeof(longline) - (RHIZO_PEER_LINE_MAX - 1),
             "0::/rhizo/init\n0::/user.slice/real\n");
    const struct {
        const char *body;
        const char *want;
        const char *what;
    } cases[] = {
        {"0::/rhizo/system/uid_1000/pid_117\n", "/rhizo/system/uid_1000/pid_117",
         "rhizo_peer_read_cgroup_file(0::/rhizo/system/uid_1000/pid_117\\n) == /rhizo/system/uid_1000/pid_117"},
        {"1:name=systemd:/user.slice/evil\r0::/rhizo/init\n0::/user.slice/real\n", "/user.slice/real",
         "rhizo_peer_read_cgroup_file(1:name=systemd:/user.slice/evil\\r0::/rhizo/init\\n0::/user.slice/real\\n) == "
         "/user.slice/real"},
        {longline, "/user.slice/real",
         "rhizo_peer_read_cgroup_file(v1 line of RHIZO_PEER_LINE_MAX - 1 bytes, "
         "0::/rhizo/init\\n0::/user.slice/real\\n) == /user.slice/real"},
        {"0::/rhizo/init", NULL, "rhizo_peer_read_cgroup_file(0::/rhizo/init) == -1"},
    };
    int fails = 0;
    char path[PATH_MAX + 32], got[PATH_MAX];
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        snprintf(path, sizeof(path), "%s/cgroup-%zu", dir, i);
        int rc = write_fixture(path, cases[i].body) == 0 ? rhizo_peer_read_cgroup_file(path, got, sizeof(got)) : -2;
        int ok = cases[i].want ? (rc == 0 && strcmp(got, cases[i].want) == 0) : rc == -1;
        if (!ok) printf("  rc=%d out='%s'\n", rc, rc == 0 ? got : "");
        fails += selftest_case(ok, cases[i].what);
        unlink(path);
    }
    return fails;
}

static int g_probe_errno;

// set errno to g_probe_errno and return -1
static int failing_probe(int pidfd) {
    (void)pidfd;
    errno = g_probe_errno;
    return -1;
}

// test rhizo_peer_allowed with rhizo_peer_probe failing with EACCES, EPERM and ESRCH, and return the failure count
static int selftest_probe(int ufd, const struct sockaddr_un *a, const char *cg) {
    const struct {
        int err;
        const char *cgroup;
        int want;
        const char *reason;
        const char *what;
    } cases[] = {
        {EACCES, cg, 1, "", "rhizo_peer_allowed(cg) == 1 with rhizo_peer_probe errno EACCES"},
        {EACCES, "/rhizo-streamd-selftest-nowhere", 0, "is not below a sandbox root",
         "rhizo_peer_allowed(/rhizo-streamd-selftest-nowhere) == 0 with rhizo_peer_probe errno EACCES"},
        {EPERM, cg, 1, "", "rhizo_peer_allowed(cg) == 1 with rhizo_peer_probe errno EPERM"},
        {ESRCH, cg, 0, "pidfd_send_signal failed with ESRCH",
         "rhizo_peer_allowed(cg) == 0 with rhizo_peer_probe errno ESRCH"},
    };
    int fails = 0;
    int (*real_probe)(int) = rhizo_peer_probe;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        int cl = socket(AF_UNIX, SOCK_STREAM, 0);
        int cfd = -1, got = -1;
        char why[PATH_MAX + 160] = "";
        if (cl >= 0 && connect(cl, (const struct sockaddr *)a, sizeof(*a)) == 0) cfd = accept(ufd, NULL, NULL);
        if (cfd >= 0) {
            rhizo_peer_probe = failing_probe;
            g_probe_errno = cases[i].err;
            got = rhizo_peer_allowed(cfd, (long)getuid(), cases[i].cgroup, why, sizeof(why));
            rhizo_peer_probe = real_probe;
        }
        int ok = got == cases[i].want && strstr(why, cases[i].reason) != NULL;
        if (!ok) printf("  admitted=%d why='%s'\n", got, why);
        fails += selftest_case(ok, cases[i].what);
        if (cfd >= 0) close(cfd);
        if (cl >= 0) close(cl);
    }
    return fails;
}

// test rhizo_peer_parse_uid and return the failure count
static int selftest_uid_parse(void) {
    const struct {
        const char *text;
        long want;
    } cases[] = {
        {"0", 0}, {"1000", 1000}, {"4294967294", 4294967294L}, {"", -1}, {"12x", -1}, {"-1", -1}, {"+1", -1},
        {" 1", -1}, {"4294967295", -1}, {"99999999999999999999", -1},
    };
    int bad = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        long v = -1;
        int rc = rhizo_peer_parse_uid(cases[i].text, &v);
        long got = rc == 0 ? v : -1;
        if (got != cases[i].want) {
            printf("  rhizo_peer_parse_uid('%s') returned %ld, expected %ld\n", cases[i].text, got,
                   cases[i].want);
            bad++;
        }
    }
    return selftest_case(bad == 0, "rhizo_peer_parse_uid(cases[i].text) == cases[i].want for each case");
}

// test rhizo_peer_cgroup_refusal and rhizo_peer_escape, and return the failure count
static int selftest_refusal_escape(void) {
    char why[PATH_MAX + 160], text[PATH_MAX], shown[PATH_MAX];
    rhizo_peer_cgroup_refusal(why, sizeof(why), 1000, 42, "/user.slice/a\nRHIZO_MARKER x\x1b[2J\\\xff");
    int ok = strcmp(why, "uid 1000 pid 42, cgroup '/user.slice/a\\x0aRHIZO_MARKER x\\x1b[2J\\x5c\\xff' is not below "
                         "a sandbox root") == 0;
    if (!ok) {
        rhizo_peer_escape(why, shown, sizeof(shown));
        printf("  why='%s'\n", shown);
    }
    int fails = selftest_case(ok, "rhizo_peer_cgroup_refusal() writes bytes 0x0a, 0x1b, 0x5c and 0xff of cgroup as "
                                  "\\xNN");
    memset(text, '\n', sizeof(text) - 1);
    text[sizeof(text) - 1] = '\0';
    rhizo_peer_escape(text, shown, sizeof(shown));
    size_t n = strlen(shown);
    fails += selftest_case(n > 0 && n < sizeof(shown) && n % 4 == 0 && strncmp(shown + n - 4, "\\x0a", 4) == 0,
                           "strlen(rhizo_peer_escape(PATH_MAX - 1 newlines)) % 4 == 0 and ends in \\x0a");
    return fails;
}

// run the --selftest-peer cases and return 1 if a case failed
static int selftest_peer(void) {
    const char *tmp = getenv("TMPDIR");
    char dir[PATH_MAX], cg[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/rhizo-streamd-peer-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (!mkdtemp(dir)) { printf("FAIL mkdtemp(%s) failed (%s)\n", dir, strerror(errno)); return 1; }
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    const char *path = a.sun_path;
    int fails = 0;
    if (snprintf(a.sun_path, sizeof(a.sun_path), "%s/streamd", dir) >= (int)sizeof(a.sun_path)) {
        printf("FAIL %s/streamd is longer than sun_path\n", dir);
        rmdir(dir);
        return 1;
    }
    if (rhizo_peer_read_cgroup(getpid(), cg, sizeof(cg)) != 0 || cg[0] != '/') {
        printf("FAIL rhizo_peer_read_cgroup(getpid()) failed\n");
        rmdir(dir);
        return 1;
    }
    int ufd = listen_composer_socket(path);
    struct stat sb;
    fails += selftest_case(ufd >= 0 && stat(path, &sb) == 0 && (sb.st_mode & 07777) == 0660,
                           "listen_composer_socket() >= 0 && st_mode == 0660");
    long me = (long)getuid();
    const struct {
        long uid;
        const char *cgroup;
        int want;
        const char *what;
    } cases[] = {
        {me + 1, cg, 0, "accept_composer() < 0 && hung_up(cl) for g_peer_uid me + 1, g_peer_cgroup cg"},
        {me, NULL, 0, "accept_composer() < 0 && hung_up(cl) for g_peer_uid me, g_peer_cgroup NULL"},
        {me, "/rhizo-streamd-selftest-nowhere", 0,
         "accept_composer() < 0 && hung_up(cl) for g_peer_uid me, g_peer_cgroup /rhizo-streamd-selftest-nowhere"},
        {me, cg, 1, "accept_composer() >= 0 for g_peer_uid me, g_peer_cgroup cg"},
    };
    for (size_t i = 0; ufd >= 0 && i < sizeof(cases) / sizeof(cases[0]); i++) {
        g_peer_uid = cases[i].uid;
        g_peer_cgroup = cases[i].cgroup;
        int cl = socket(AF_UNIX, SOCK_STREAM, 0);
        struct rhizo_stream_frame_header hdr;
        memset(&hdr, 0, sizeof(hdr));
        hdr.magic = RHIZO_STREAM_FRAME_MAGIC;
        hdr.seq = i + 1;
        if (cl < 0 || connect(cl, (struct sockaddr *)&a, sizeof(a)) != 0 ||
            send(cl, &hdr, sizeof(hdr), MSG_NOSIGNAL) != (ssize_t)sizeof(hdr)) {
            fails += selftest_case(0, cases[i].what);
            if (cl >= 0) close(cl);
            continue;
        }
        int cfd = accept_composer(ufd);
        if (cases[i].want) {
            struct rhizo_stream_frame_header got;
            int read_ok = cfd >= 0 && recv(cfd, &got, sizeof(got), MSG_WAITALL) == (ssize_t)sizeof(got) &&
                          got.magic == RHIZO_STREAM_FRAME_MAGIC && got.seq == hdr.seq;
            fails += selftest_case(cfd >= 0, cases[i].what);
            fails += selftest_case(read_ok, "recv(cfd) == hdr with RHIZO_STREAM_FRAME_MAGIC and hdr.seq");
            if (cfd >= 0) close(cfd);
        } else {
            if (cfd >= 0) close(cfd);
            fails += selftest_case(cfd < 0 && hung_up(cl), cases[i].what);
        }
        close(cl);
    }
    g_peer_uid = AID_SYSTEM;
    g_peer_cgroup = NULL;
    if (ufd >= 0) fails += selftest_probe(ufd, &a, cg);
    if (ufd >= 0) close(ufd);
    unlink(path);
    fails += selftest_cgroup_files(dir);
    fails += selftest_uid_parse();
    fails += selftest_refusal_escape();
    rmdir(dir);
    if (fails) printf("SELFTEST failures=%d\n", fails);
    else printf("SELFTEST failures=0\n");
    return fails ? 1 : 0;
}

// serve composer frames to TCP viewers
static int run_daemon(const char *render_node, const char *socket_path, int tcp_port,
                      const char *forced_codec, int allow_h264, const char *probe_socket,
                      const char *html_path, const char *bind_addr) {
    struct daemon_state st;
    memset(&st, 0, sizeof(st));
    st.probe_socket = probe_socket;
    st.primary_display_id = 1;
    st.html_path = html_path;
    pthread_mutex_init(&st.clients_lock, NULL);
    for (int i = 0; i < MAX_TCP_CLIENTS; i++) st.tcp_clients[i] = -1;

    if (va_open(&st.ctx, render_node) != 0) return 1;
    VAProfile profile;
    enum stream_codec codec = pick_codec(st.ctx.dpy, forced_codec, allow_h264, &profile);
    if (codec == CODEC_NONE) {
        logmsg("no usable codec forced=%s allow_h264=%d",
               forced_codec ? forced_codec : "auto", allow_h264);
        return 1;
    }
    logmsg("codec=%s profile=%d", codec_name(codec), (int)profile);
    if (codec != CODEC_VP9) {
        logmsg("no encode path for codec=%s",
               codec_name(codec));
        return 1;
    }
    if (va_setup_encoder(&st.ctx, codec, profile, 1280, 800) != 0) return 1;

    int ufd = systemd_socket_fd();
    if (ufd >= 0) {
        logmsg("listening on LISTEN_FDS fd 3");
    } else {
        if (!socket_path) {
            logmsg("no --socket and no LISTEN_FDS");
            return 1;
        }
        ufd = listen_composer_socket(socket_path);
        if (ufd < 0) return 1;
        logmsg("listening on %s", socket_path);
    }
    if (g_peer_uid != AID_SYSTEM || g_peer_cgroup != NULL)
        logmsg("--peer-uid %ld --peer-cgroup %s", g_peer_uid,
               g_peer_cgroup != NULL ? g_peer_cgroup : "unset");
    else
        logmsg("peer uid=%d cgroup below /rhizo[-N] or androidd[@N].service/android", AID_SYSTEM);

    int tfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(tfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in taddr;
    memset(&taddr, 0, sizeof(taddr));
    taddr.sin_family = AF_INET;
    if (inet_pton(AF_INET, bind_addr, &taddr.sin_addr) != 1) {
        logmsg("inet_pton failed for --bind %s", bind_addr);
        return 1;
    }
    taddr.sin_port = htons((uint16_t)tcp_port);
    if (bind(tfd, (struct sockaddr *)&taddr, sizeof(taddr)) != 0 || listen(tfd, MAX_TCP_CLIENTS) != 0) {
        logmsg("TCP listen on port %d failed (%s)", tcp_port, strerror(errno));
        return 1;
    }
    logmsg("listening on %s:%d", bind_addr, tcp_port);
    st.listen_fd = tfd;
    pthread_t accept_thread;
    pthread_create(&accept_thread, NULL, tcp_accept_thread, &st);

    for (;;) {
        int cfd = accept_composer(ufd);
        if (cfd < 0) continue;
        logmsg("composer connected");
        serve_composer_connection(&st, cfd);
        logmsg("composer connection closed");
    }
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "rhizo-streamd [--socket PATH] --port N [--codec vp9|av1|h264]\n"
        "    [--allow-h264] [--render-node PATH] [--probe-socket PATH]\n"
        "    [--html PATH] [--bind ADDR] [--peer-uid UID] [--peer-cgroup PATH]\n"
        "    [--verbose]\n"
        "rhizo-streamd --selftest-encode OUT.ivf [--codec vp9|av1] [--render-node PATH]\n"
        "    [--frames N] [--size WxH]\n"
        "rhizo-streamd --selftest-peer\n");
}

// parse a positive integer argument
static int parse_positive(const char *what, const char *text, int *out) {
    char *end = NULL;
    errno = 0;
    long v = strtol(text, &end, 10);
    if (errno != 0 || !end || *end != '\0' || v <= 0 || v > 100000) {
        logmsg("failed to parse %s %s", what, text);
        return -1;
    }
    *out = (int)v;
    return 0;
}

// parse a WxH size argument
static int parse_size(const char *text, int *w, int *h) {
    const char *x = strchr(text, 'x');
    if (!x) { logmsg("failed to parse --size %s", text); return -1; }
    char head[32];
    size_t n = (size_t)(x - text);
    if (n == 0 || n >= sizeof(head)) { logmsg("failed to parse --size %s", text); return -1; }
    memcpy(head, text, n);
    head[n] = '\0';
    if (parse_positive("--size width", head, w) != 0) return -1;
    return parse_positive("--size height", x + 1, h);
}

// return the viewer page path
static const char *default_html_path(void) {
    static char path[PATH_MAX + 32];
    char exe[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0) return "viewer.html";
    exe[n] = '\0';
    char *slash = strrchr(exe, '/');
    if (!slash) return "viewer.html";
    *slash = '\0';
    snprintf(path, sizeof(path), "%s/viewer.html", exe);
    return path;
}

// parse arguments and run rhizo-streamd
int main(int argc, char **argv) {
    const char *socket_path = NULL;
    const char *render_node = DEFAULT_RENDER_NODE;
    const char *probe_socket = DEFAULT_PROBE_SOCKET;
    const char *forced_codec = NULL;
    const char *selftest_out = NULL;
    const char *html_path = NULL;
    const char *bind_addr = "127.0.0.1";
    int tcp_port = 0;
    int allow_h264 = 0;
    int selftest_frames = 1;
    int selftest_w = 128, selftest_h = 96;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) socket_path = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) tcp_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--codec") && i + 1 < argc) forced_codec = argv[++i];
        else if (!strcmp(argv[i], "--allow-h264")) allow_h264 = 1;
        else if (!strcmp(argv[i], "--render-node") && i + 1 < argc) render_node = argv[++i];
        else if (!strcmp(argv[i], "--probe-socket") && i + 1 < argc) probe_socket = argv[++i];
        else if (!strcmp(argv[i], "--html") && i + 1 < argc) html_path = argv[++i];
        else if (!strcmp(argv[i], "--bind") && i + 1 < argc) bind_addr = argv[++i];
        else if (!strcmp(argv[i], "--selftest-encode") && i + 1 < argc) selftest_out = argv[++i];
        else if (!strcmp(argv[i], "--selftest-peer")) return selftest_peer();
        else if (!strcmp(argv[i], "--peer-uid") && i + 1 < argc) {
            if (rhizo_peer_parse_uid(argv[++i], &g_peer_uid) != 0) {
                logmsg("failed to parse --peer-uid '%s'", argv[i]);
                return 2;
            }
        }
        else if (!strcmp(argv[i], "--peer-cgroup") && i + 1 < argc) g_peer_cgroup = argv[++i];
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
            if (parse_positive("--frames", argv[++i], &selftest_frames) != 0) return 2;
        }
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
            if (parse_size(argv[++i], &selftest_w, &selftest_h) != 0) return 2;
        }
        else if (!strcmp(argv[i], "--verbose")) g_verbose = 1;
        else { usage(); return 2; }
    }
    if (!html_path) html_path = default_html_path();

    if (allow_h264 && forced_codec && !strcmp(forced_codec, "h264")) {
        print_h264_patent_disclosure();
    }

    if (selftest_out) {
        return selftest_encode(render_node, selftest_out, forced_codec, allow_h264,
                               selftest_frames, selftest_w, selftest_h);
    }

    if (tcp_port <= 0) { usage(); return 2; }
    signal(SIGPIPE, SIG_IGN);
    return run_daemon(render_node, socket_path, tcp_port, forced_codec, allow_h264, probe_socket,
                      html_path, bind_addr);
}

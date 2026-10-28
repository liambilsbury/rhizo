// serve the host's PipeWire cameras to the camera provider HAL
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <malloc.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/timerfd.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/buffers.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/pod/iter.h>
#include <spa/utils/result.h>

#include "mjpeg.h"
#include "rhizo/camera_protocol.h"

#define MAX_CLIENTS 16
#define MAX_NODES 64
#define STREAMS_PER_CLIENT RHIZO_CAMERA_MAX_CAMERAS
#define MAX_MODE_FORMATS 8
#define MAX_MODE_RATES 16
#define MAX_POD_RATES 16
#define MAX_CANDIDATES 2048
#define CLIENT_PAYLOAD_MAX 1024
#define CONTROL_BACKLOG_MAX (1u << 20)
#define FRAMES_QUEUED_MAX 2
#define LIST_DEBOUNCE_MS 100
#define LIST_DEBOUNCE_CAP_MS 1000
#define OPEN_TIMEOUT_MS 10000
#define MAX_DIM 4096
#define MAX_PLAUSIBLE_FPS 240
#define NOMINAL_FPS 30
#define SNDBUF_BYTES (4 << 20)
#define AID_CAMERASERVER 1047
#define REFUSAL_LOG_MS 10000

#ifndef SO_PEERPIDFD
#define SO_PEERPIDFD 77
#endif

#define HDR_LEN ((uint32_t)sizeof(struct rhizo_camera_msg_header))
#define LIST_PAYLOAD_MAX \
    (sizeof(struct rhizo_camera_list) + RHIZO_CAMERA_MAX_CAMERAS * sizeof(struct rhizo_camera_info))

_Static_assert(sizeof(struct rhizo_camera_info) == 712, "rhizo_camera_info wire size");
_Static_assert(sizeof(struct rhizo_camera_frame) == 32, "rhizo_camera_frame wire size");
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "the protocol is little endian");

static const char *g_socket_path = "/run/rhizo-camera/camerad";
static int g_verbose = 0;
static long g_peer_uid = AID_CAMERASERVER;
static const char *g_peer_cgroup = NULL;
static int64_t g_refusal_logged_ms = 0;
static unsigned long g_refusals_unlogged = 0;

enum layout_kind { PLANAR_UV, PLANAR_VU, SEMI_UV, SEMI_VU, PACKED_422, PACKED_RGB, MJPEG };

#define FORMAT_MJPG 0x4d4a5047u

// a raw format's spa id, layout and component offsets
struct raw_format {
    uint32_t spa;
    const char *name;
    int kind;
    uint8_t bpp;
    uint8_t o0, o1, o2;
};

static const struct raw_format RAW_FORMATS[] = {
    {SPA_VIDEO_FORMAT_I420, "I420", PLANAR_UV, 1, 0, 0, 0},
    {SPA_VIDEO_FORMAT_YV12, "YV12", PLANAR_VU, 1, 0, 0, 0},
    {SPA_VIDEO_FORMAT_NV12, "NV12", SEMI_UV, 1, 0, 0, 0},
    {SPA_VIDEO_FORMAT_NV21, "NV21", SEMI_VU, 1, 0, 0, 0},
    {SPA_VIDEO_FORMAT_YUY2, "YUY2", PACKED_422, 4, 0, 1, 3},
    {SPA_VIDEO_FORMAT_UYVY, "UYVY", PACKED_422, 4, 1, 0, 2},
    {SPA_VIDEO_FORMAT_YVYU, "YVYU", PACKED_422, 4, 0, 3, 1},
    {SPA_VIDEO_FORMAT_RGBx, "RGBx", PACKED_RGB, 4, 0, 1, 2},
    {SPA_VIDEO_FORMAT_RGBA, "RGBA", PACKED_RGB, 4, 0, 1, 2},
    {SPA_VIDEO_FORMAT_BGRx, "BGRx", PACKED_RGB, 4, 2, 1, 0},
    {SPA_VIDEO_FORMAT_BGRA, "BGRA", PACKED_RGB, 4, 2, 1, 0},
    {SPA_VIDEO_FORMAT_xRGB, "xRGB", PACKED_RGB, 4, 1, 2, 3},
    {SPA_VIDEO_FORMAT_ARGB, "ARGB", PACKED_RGB, 4, 1, 2, 3},
    {SPA_VIDEO_FORMAT_xBGR, "xBGR", PACKED_RGB, 4, 3, 2, 1},
    {SPA_VIDEO_FORMAT_ABGR, "ABGR", PACKED_RGB, 4, 3, 2, 1},
    {SPA_VIDEO_FORMAT_RGB, "RGB", PACKED_RGB, 3, 0, 1, 2},
    {SPA_VIDEO_FORMAT_BGR, "BGR", PACKED_RGB, 3, 2, 1, 0},
    {FORMAT_MJPG, "MJPG", MJPEG, 0, 0, 0, 0},
};
#define N_RAW_FORMATS (sizeof(RAW_FORMATS) / sizeof(RAW_FORMATS[0]))

#define RATE_FIXED 0
#define RATE_RANGE 1
#define RATE_NOMINAL 2

struct rate_entry {
    uint32_t format;
    uint32_t kind;
    struct spa_fraction rate;
    struct spa_fraction lo;
};

// a size at its best rate, its formats and rates
struct mode_entry {
    struct rhizo_camera_mode mode;
    uint32_t formats[MAX_MODE_FORMATS];
    uint32_t n_formats;
    struct rate_entry rates[MAX_MODE_RATES];
    uint32_t n_rates;
};

// a format, size and rate offer from EnumFormat
struct candidate {
    uint32_t format;
    uint32_t width;
    uint32_t height;
    uint32_t fps_num;
    uint32_t fps_den;
    uint32_t rate_kind;
    uint32_t lo_num;
    uint32_t lo_den;
};

// a rate an EnumFormat pod offers
struct rate_spec {
    struct spa_fraction rate;
    struct spa_fraction lo;
    uint32_t kind;
};

// a PipeWire Video/Source node and its output port
struct cam_node {
    int used;
    uint32_t id;
    char serial[32];
    struct pw_proxy *proxy;
    struct spa_hook listener;
    int info_seen;
    int is_camera;
    char key[RHIZO_CAMERA_KEY_LEN];
    char name[RHIZO_CAMERA_NAME_LEN];
    uint32_t facing;
    uint32_t port_id;
    struct pw_proxy *port_proxy;
    struct spa_hook port_listener;
    int enum_seq;
    int sync_seq;
    int enum_pending;
    int enum_deferred;
    struct candidate *cand;
    uint32_t n_cand;
    int saw_compressed;
    int enumerated;
    struct mode_entry modes[RHIZO_CAMERA_MAX_MODES];
    uint32_t n_modes;
};

struct outmsg {
    struct outmsg *next;
    uint64_t serial;
    uint32_t stream_id;
    int is_frame;
    size_t len;
    size_t off;
    unsigned char data[];
};
#define MSG_PAYLOAD(m) ((m)->data + HDR_LEN)

struct client;

// a HAL stream from a camera at a mode
struct cam_stream {
    int used;
    struct client *owner;
    uint32_t stream_id;
    uint32_t node_id;
    char key[RHIZO_CAMERA_KEY_LEN];
    struct mode_entry mode;
    struct pw_stream *stream;
    struct spa_hook listener;
    uint32_t req_format;
    struct spa_fraction req_rate;
    uint32_t req_kind;
    const struct raw_format *format;
    struct mjpeg_decoder *mjpeg;
    int full_range;
    int started;
    int ended;
    int end_error;
    int64_t deadline_ms;
    uint64_t seq;
    uint64_t frames;
    uint64_t dropped;
    uint64_t unreadable;
};

struct client {
    int fd;
    int id;
    int hello;
    int wants_list;
    struct rhizo_camera_msg_header hdr;
    unsigned char in[sizeof(struct rhizo_camera_msg_header) + CLIENT_PAYLOAD_MAX];
    size_t inlen;
    int queue_open;
    int overflow;
    int sending;
    struct outmsg *head;
    struct outmsg *tail;
    size_t control_bytes;
    struct cam_stream streams[STREAMS_PER_CLIENT];
};

static struct client g_clients[MAX_CLIENTS];
static struct cam_node g_nodes[MAX_NODES];
static pthread_mutex_t g_qlock = PTHREAD_MUTEX_INITIALIZER;

static struct pw_thread_loop *g_loop;
static struct pw_context *g_context;
static struct pw_core *g_core;
static struct spa_hook g_core_listener;
static struct pw_registry *g_registry;
static struct spa_hook g_registry_listener;

static volatile sig_atomic_t g_stop = 0;
static int g_stop_fd = -1;
static int g_wake_fd = -1;
static int g_timer_fd = -1;
static int g_pipewire_lost = 0;

static int g_sync_seq = 0;
static int g_settled = 0;
static int g_dirty = 0;
static int g_stream_count = 0;

static int64_t g_list_due_ms = 0;
static int64_t g_list_first_ms = 0;
static unsigned char g_list_buf[LIST_PAYLOAD_MAX];
static uint32_t g_list_len = 0;
static int g_list_valid = 0;
static int g_listed_count = 0;
static int g_next_client_id = 1;
static char g_status_path[PATH_MAX];
static int g_status_cameras = -1;
static int g_status_streams = -1;
static uint64_t g_msg_serial = 0;
static uint64_t g_trim_mark = 0;
static int g_trim_pending = 0;

// return monotonic time in milliseconds
static int64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// return monotonic time in nanoseconds
static int64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

// wake the poll loop from either thread
static void wake(void)
{
    uint64_t one = 1;
    ssize_t ignore = write(g_wake_fd, &one, sizeof(one));
    (void)ignore;
}

// set the stop flag and wake the poll loop
static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
    uint64_t one = 1;
    ssize_t ignore = write(g_stop_fd, &one, sizeof(one));
    (void)ignore;
}

// return the raw format of a spa format, or NULL
static const struct raw_format *raw_format_of(uint32_t spa)
{
    for (size_t i = 0; i < N_RAW_FORMATS; i++) {
        if (RAW_FORMATS[i].spa == spa) {
            return &RAW_FORMATS[i];
        }
    }
    return NULL;
}

// return a format's rank in the preference order
static int format_rank(uint32_t spa)
{
    for (size_t i = 0; i < N_RAW_FORMATS; i++) {
        if (RAW_FORMATS[i].spa == spa) {
            return (int)i;
        }
    }
    return (int)N_RAW_FORMATS;
}

// return a facing value's short name
static const char *facing_name(uint32_t facing)
{
    return facing == RHIZO_CAMERA_FACING_FRONT ? "front" : facing == RHIZO_CAMERA_FACING_BACK ? "back" : "external";
}

// compare two frame rates as numerator and denominator pairs
static int fps_cmp(uint32_t an, uint32_t ad, uint32_t bn, uint32_t bd)
{
    uint64_t l = (uint64_t)an * bd, r = (uint64_t)bn * ad;
    return l < r ? -1 : l > r ? 1 : 0;
}

// compare two frame rates as fractions
static int frac_cmp(struct spa_fraction a, struct spa_fraction b)
{
    return fps_cmp(a.num, a.denom, b.num, b.denom);
}

struct plane_view {
    const uint8_t *p;
    size_t stride;
};

// return a format's plane count and each plane's size
static uint32_t format_planes(const struct raw_format *f, uint32_t w, uint32_t h, size_t row[3], uint32_t rows[3])
{
    switch (f->kind) {
    case PLANAR_UV:
    case PLANAR_VU:
        row[0] = w, row[1] = row[2] = w / 2;
        rows[0] = h, rows[1] = rows[2] = h / 2;
        return 3;
    case SEMI_UV:
    case SEMI_VU:
        row[0] = row[1] = w;
        rows[0] = h, rows[1] = h / 2;
        return 2;
    case PACKED_422:
        row[0] = (size_t)w * 2;
        rows[0] = h;
        return 1;
    default:
        row[0] = (size_t)w * f->bpp;
        rows[0] = h;
        return 1;
    }
}

// resolve a PipeWire buffer's planes, or -1 when unreadable
static int map_planes(const struct spa_buffer *buf, const struct raw_format *f, uint32_t w, uint32_t h,
                      struct plane_view out[3])
{
    size_t row[3] = {0};
    uint32_t rows[3] = {0};
    uint32_t planes = format_planes(f, w, h, row, rows);
    if (buf->n_datas < 1) {
        return -1;
    }
    if (buf->n_datas >= planes) {
        for (uint32_t i = 0; i < planes; i++) {
            const struct spa_data *d = &buf->datas[i];
            if (d->data == NULL || d->chunk == NULL || d->chunk->offset > d->maxsize) {
                return -1;
            }
            size_t avail = d->maxsize - d->chunk->offset;
            if (d->chunk->size > 0 && d->chunk->size < avail) {
                avail = d->chunk->size;
            }
            if (d->chunk->stride < 0) {
                return -1;
            }
            size_t stride = d->chunk->stride > 0 ? (size_t)d->chunk->stride : row[i];
            if (stride < row[i] || stride * (rows[i] - 1) + row[i] > avail) {
                return -1;
            }
            out[i].p = (const uint8_t *)d->data + d->chunk->offset;
            out[i].stride = stride;
        }
        return 0;
    }
    const struct spa_data *d = &buf->datas[0];
    if (d->data == NULL || d->chunk == NULL || d->chunk->offset > d->maxsize || d->chunk->stride < 0) {
        return -1;
    }
    size_t avail = d->maxsize - d->chunk->offset;
    if (d->chunk->size > 0 && d->chunk->size < avail) {
        avail = d->chunk->size;
    }
    size_t stride0 = d->chunk->stride > 0 ? (size_t)d->chunk->stride : row[0];
    size_t pos = 0;
    for (uint32_t i = 0; i < planes; i++) {
        size_t stride = i == 0 ? stride0 : (f->kind == PLANAR_UV || f->kind == PLANAR_VU) ? stride0 / 2 : stride0;
        if (stride < row[i] || pos + stride * (rows[i] - 1) + row[i] > avail) {
            return -1;
        }
        out[i].p = (const uint8_t *)d->data + d->chunk->offset + pos;
        out[i].stride = stride;
        pos += stride * rows[i];
    }
    return 0;
}

// clamp to a byte
static inline uint8_t clamp8(int v)
{
    return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}

// return the full-range BT.601 luma of an rgb colour
static inline uint8_t rgb_y(int r, int g, int b)
{
    return clamp8((19595 * r + 38470 * g + 7471 * b + 32768) >> 16);
}

static inline uint8_t rgb_u(int r, int g, int b)
{
    return clamp8(((-11059 * r - 21709 * g + 32768 * b + 32768) >> 16) + 128);
}

static inline uint8_t rgb_v(int r, int g, int b)
{
    return clamp8(((32768 * r - 27439 * g - 5329 * b + 32768) >> 16) + 128);
}

static uint8_t g_expand_y[256], g_expand_c[256], g_identity[256];

// fill the range tables
static void init_range_tables(void)
{
    for (int v = 0; v < 256; v++) {
        g_expand_y[v] = clamp8((int)((v - 16) * 255.0 / 219.0 + (v >= 16 ? 0.5 : -0.5)));
        g_expand_c[v] = clamp8(128 + (int)((v - 128) * 255.0 / 224.0 + (v >= 128 ? 0.5 : -0.5)));
        g_identity[v] = (uint8_t)v;
    }
}

// copy a plane through a sample table
static void copy_plane(uint8_t *dst, size_t dst_stride, const struct plane_view *src, size_t row, uint32_t rows,
                       const uint8_t *lut)
{
    for (uint32_t y = 0; y < rows; y++) {
        const uint8_t *s = src->p + y * src->stride;
        uint8_t *d = dst + y * dst_stride;
        if (lut == g_identity) {
            memcpy(d, s, row);
            continue;
        }
        for (size_t x = 0; x < row; x++) {
            d[x] = lut[s[x]];
        }
    }
}

// convert a raw frame to packed full-range I420
static void convert_frame(const struct raw_format *f, const struct plane_view *pl, uint32_t w, uint32_t h,
                          int full_range, uint8_t *dst)
{
    uint32_t cw = w / 2, ch = h / 2;
    uint8_t *dy = dst, *du = dst + (size_t)w * h, *dv = du + (size_t)cw * ch;
    const uint8_t *ly = full_range ? g_identity : g_expand_y, *lc = full_range ? g_identity : g_expand_c;
    switch (f->kind) {
    case PLANAR_UV:
    case PLANAR_VU:
        copy_plane(dy, w, &pl[0], w, h, ly);
        copy_plane(du, cw, &pl[f->kind == PLANAR_UV ? 1 : 2], cw, ch, lc);
        copy_plane(dv, cw, &pl[f->kind == PLANAR_UV ? 2 : 1], cw, ch, lc);
        break;
    case SEMI_UV:
    case SEMI_VU: {
        int uo = f->kind == SEMI_UV ? 0 : 1;
        copy_plane(dy, w, &pl[0], w, h, ly);
        for (uint32_t y = 0; y < ch; y++) {
            const uint8_t *s = pl[1].p + y * pl[1].stride;
            for (uint32_t x = 0; x < cw; x++) {
                du[(size_t)y * cw + x] = lc[s[2 * x + uo]];
                dv[(size_t)y * cw + x] = lc[s[2 * x + 1 - uo]];
            }
        }
        break;
    }
    case PACKED_422:
        for (uint32_t y = 0; y < h; y++) {
            const uint8_t *s = pl[0].p + y * pl[0].stride;
            uint8_t *d = dy + (size_t)y * w;
            for (uint32_t x = 0; x < cw; x++) {
                d[2 * x] = ly[s[4 * x + f->o0]];
                d[2 * x + 1] = ly[s[4 * x + f->o0 + 2]];
            }
        }
        for (uint32_t y = 0; y < ch; y++) {
            const uint8_t *s0 = pl[0].p + (size_t)(2 * y) * pl[0].stride;
            const uint8_t *s1 = s0 + pl[0].stride;
            for (uint32_t x = 0; x < cw; x++) {
                du[(size_t)y * cw + x] = lc[(s0[4 * x + f->o1] + s1[4 * x + f->o1] + 1) >> 1];
                dv[(size_t)y * cw + x] = lc[(s0[4 * x + f->o2] + s1[4 * x + f->o2] + 1) >> 1];
            }
        }
        break;
    default:
        for (uint32_t by = 0; by < ch; by++) {
            for (uint32_t bx = 0; bx < cw; bx++) {
                int rs = 0, gs = 0, bs = 0;
                for (uint32_t k = 0; k < 4; k++) {
                    uint32_t x = 2 * bx + (k & 1), y = 2 * by + (k >> 1);
                    const uint8_t *px = pl[0].p + y * pl[0].stride + (size_t)x * f->bpp;
                    int r = px[f->o0], g = px[f->o1], b = px[f->o2];
                    dy[(size_t)y * w + x] = rgb_y(r, g, b);
                    rs += r, gs += g, bs += b;
                }
                rs = (rs + 2) >> 2, gs = (gs + 2) >> 2, bs = (bs + 2) >> 2;
                du[(size_t)by * cw + bx] = rgb_u(rs, gs, bs);
                dv[(size_t)by * cw + bx] = rgb_v(rs, gs, bs);
            }
        }
        break;
    }
}

// return the length of s cut on a UTF-8 boundary
static size_t utf8_prefix(const char *s, size_t max)
{
    size_t len = strlen(s);
    if (len <= max) {
        return len;
    }
    while (max > 0 && ((unsigned char)s[max] & 0xc0) == 0x80) {
        max--;
    }
    return max;
}

// write node.name as the key, hashing a long one
static void make_key(const char *name, char *key)
{
    size_t len = strlen(name);
    if (len < RHIZO_CAMERA_KEY_LEN) {
        memcpy(key, name, len + 1);
        return;
    }
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        hash = (hash ^ (unsigned char)name[i]) * 16777619u;
    }
    size_t head = utf8_prefix(name, RHIZO_CAMERA_KEY_LEN - 1 - 9);
    snprintf(key, RHIZO_CAMERA_KEY_LEN, "%.*s~%08x", (int)head, name, hash);
}

// write a display name cut on a UTF-8 boundary
static void make_name(const char *text, char *name)
{
    size_t n = utf8_prefix(text, RHIZO_CAMERA_NAME_LEN - 1);
    memcpy(name, text, n);
    name[n] = '\0';
}

// return a camera's facing from libcamera or its USB port
static uint32_t facing_of(const char *location, const char *v4l2_path)
{
    if (location != NULL) {
        return strcmp(location, "front") == 0 ? RHIZO_CAMERA_FACING_FRONT
               : strcmp(location, "back") == 0 ? RHIZO_CAMERA_FACING_BACK
                                               : RHIZO_CAMERA_FACING_EXTERNAL;
    }
    unsigned int index;
    char tail;
    if (v4l2_path == NULL || sscanf(v4l2_path, "/dev/video%u%c", &index, &tail) != 1) {
        return RHIZO_CAMERA_FACING_EXTERNAL;
    }
    char link[64], real[PATH_MAX];
    snprintf(link, sizeof(link), "/sys/class/video4linux/video%u/device", index);
    if (realpath(link, real) == NULL) {
        return RHIZO_CAMERA_FACING_EXTERNAL;
    }
    for (int depth = 0; depth < 4; depth++) {
        char attr[PATH_MAX + 16], value[32] = {0};
        snprintf(attr, sizeof(attr), "%s/removable", real);
        FILE *f = fopen(attr, "r");
        if (f != NULL) {
            char *ok = fgets(value, sizeof(value), f);
            fclose(f);
            return ok != NULL && strncmp(value, "fixed", 5) == 0 ? RHIZO_CAMERA_FACING_FRONT
                                                                 : RHIZO_CAMERA_FACING_EXTERNAL;
        }
        char *slash = strrchr(real, '/');
        if (slash == NULL || slash == real) {
            break;
        }
        *slash = '\0';
    }
    return RHIZO_CAMERA_FACING_EXTERNAL;
}

// return whether a node's role, factory or api is a camera's
static int props_are_camera(const char *role, const char *factory, const char *api)
{
    if (role != NULL && strcmp(role, "Camera") == 0) {
        return 1;
    }
    if (factory != NULL && (strcmp(factory, "api.v4l2.source") == 0 || strcmp(factory, "api.libcamera.source") == 0)) {
        return 1;
    }
    return api != NULL && (strcmp(api, "v4l2") == 0 || strcmp(api, "libcamera") == 0);
}

// a property's values in a format pod
struct pod_values {
    const uint8_t *body;
    uint32_t n;
    uint32_t stride;
    uint32_t choice;
};

// read a property's values of a spa type, or -1
static int pod_values(const struct spa_pod *obj, uint32_t key, uint32_t type, uint32_t elem, struct pod_values *out)
{
    const struct spa_pod_prop *prop = spa_pod_find_prop(obj, NULL, key);
    if (prop == NULL) {
        return -1;
    }
    const struct spa_pod *v = &prop->value;
    if (v->type == SPA_TYPE_Choice) {
        if (v->size < sizeof(struct spa_pod_choice_body)) {
            return -1;
        }
        const struct spa_pod_choice *c = (const struct spa_pod_choice *)v;
        uint32_t child = c->body.child.size;
        if (c->body.child.type != type || child < elem) {
            return -1;
        }
        out->n = (v->size - (uint32_t)sizeof(struct spa_pod_choice_body)) / child;
        out->stride = child;
        out->choice = c->body.type;
        out->body = (const uint8_t *)SPA_POD_CONTENTS(struct spa_pod_choice, c);
    } else {
        if (v->type != type || v->size < elem) {
            return -1;
        }
        out->n = 1;
        out->stride = v->size;
        out->choice = SPA_CHOICE_None;
        out->body = SPA_POD_BODY_CONST(v);
    }
    return out->n > 0 ? 0 : -1;
}

// return value i of a property
static const void *pod_value(const struct pod_values *v, uint32_t i)
{
    return v->body + (size_t)i * v->stride;
}

static const struct spa_rectangle RANGE_SIZES[] = {
    {3840, 2160}, {2560, 1440}, {1920, 1080}, {1600, 1200}, {1280, 960}, {1280, 720}, {1024, 768},
    {800, 600},   {640, 480},   {640, 360},   {352, 288},   {320, 240},  {176, 144},
};

// record a format, size and rate offer
static void add_candidate(struct candidate *cand, uint32_t *n_cand, uint32_t format, struct spa_rectangle size,
                          const struct rate_spec *r)
{
    if (*n_cand >= MAX_CANDIDATES) {
        return;
    }
    cand[(*n_cand)++] = (struct candidate){format, size.width, size.height, r->rate.num, r->rate.denom, r->kind,
                                           r->lo.num, r->lo.denom};
}

// record a format's offers at each size or size range
static void add_sizes(struct candidate *cand, uint32_t *n_cand, uint32_t format, const struct pod_values *sizes,
                      const struct rate_spec *rate)
{
    if (sizes->choice == SPA_CHOICE_None || sizes->choice == SPA_CHOICE_Enum) {
        for (uint32_t si = 0; si < sizes->n; si++) {
            add_candidate(cand, n_cand, format, *(const struct spa_rectangle *)pod_value(sizes, si), rate);
        }
    } else if ((sizes->choice == SPA_CHOICE_Range || sizes->choice == SPA_CHOICE_Step) && sizes->n >= 3) {
        const struct spa_rectangle *lo = pod_value(sizes, 1), *hi = pod_value(sizes, 2);
        const struct spa_rectangle *step = sizes->choice == SPA_CHOICE_Step && sizes->n >= 4 ? pod_value(sizes, 3)
                                                                                             : NULL;
        add_candidate(cand, n_cand, format, *hi, rate);
        for (size_t i = 0; i < sizeof(RANGE_SIZES) / sizeof(RANGE_SIZES[0]); i++) {
            struct spa_rectangle r = RANGE_SIZES[i];
            if (r.width < lo->width || r.width > hi->width || r.height < lo->height || r.height > hi->height ||
                (r.width == hi->width && r.height == hi->height)) {
                continue;
            }
            if (step != NULL && ((step->width && (r.width - lo->width) % step->width) ||
                                 (step->height && (r.height - lo->height) % step->height))) {
                continue;
            }
            add_candidate(cand, n_cand, format, r, rate);
        }
    }
}

// collect raw and MJPG offers, or 1 on another codec
static int collect_candidates(const struct spa_pod *param, struct candidate *cand, uint32_t *n_cand)
{
    uint32_t media_type, media_subtype;
    if (!spa_pod_is_object(param) || spa_format_parse(param, &media_type, &media_subtype) < 0 ||
        media_type != SPA_MEDIA_TYPE_video) {
        return 0;
    }
    int mjpg = media_subtype == SPA_MEDIA_SUBTYPE_mjpg;
    if (media_subtype != SPA_MEDIA_SUBTYPE_raw && !mjpg) {
        return 1;
    }
    struct pod_values formats, sizes, rates;
    if (pod_values(param, SPA_FORMAT_VIDEO_size, SPA_TYPE_Rectangle, sizeof(struct spa_rectangle), &sizes) < 0 ||
        pod_values(param, SPA_FORMAT_VIDEO_framerate, SPA_TYPE_Fraction, sizeof(struct spa_fraction), &rates) < 0) {
        return 0;
    }
    if (!mjpg && (pod_values(param, SPA_FORMAT_VIDEO_format, SPA_TYPE_Id, sizeof(uint32_t), &formats) < 0 ||
                  (formats.choice != SPA_CHOICE_None && formats.choice != SPA_CHOICE_Enum))) {
        return 0;
    }
    struct rate_spec specs[MAX_POD_RATES];
    uint32_t n_specs = 0;
    if ((rates.choice == SPA_CHOICE_Range || rates.choice == SPA_CHOICE_Step) && rates.n >= 3) {
        struct spa_fraction lo = *(const struct spa_fraction *)pod_value(&rates, 1);
        struct spa_fraction hi = *(const struct spa_fraction *)pod_value(&rates, 2);
        if (hi.num != 0 && hi.denom != 0 && lo.denom != 0 && fps_cmp(hi.num, hi.denom, MAX_PLAUSIBLE_FPS, 1) <= 0) {
            specs[n_specs++] = (struct rate_spec){hi, lo, RATE_RANGE};
        }
    } else if (rates.choice == SPA_CHOICE_None || rates.choice == SPA_CHOICE_Enum) {
        for (uint32_t i = 0; i < rates.n && n_specs < MAX_POD_RATES; i++) {
            struct spa_fraction f = *(const struct spa_fraction *)pod_value(&rates, i);
            if (f.num == 0 || f.denom == 0 || fps_cmp(f.num, f.denom, MAX_PLAUSIBLE_FPS, 1) > 0) {
                continue;
            }
            int seen = 0;
            for (uint32_t k = 0; k < n_specs; k++) {
                seen |= frac_cmp(specs[k].rate, f) == 0;
            }
            if (!seen) {
                specs[n_specs++] = (struct rate_spec){f, f, RATE_FIXED};
            }
        }
    }
    if (n_specs == 0) {
        if (rates.choice != SPA_CHOICE_Range && rates.choice != SPA_CHOICE_Step && rates.choice != SPA_CHOICE_None &&
            rates.choice != SPA_CHOICE_Enum) {
            return 0;
        }
        specs[n_specs++] = (struct rate_spec){SPA_FRACTION(NOMINAL_FPS, 1), SPA_FRACTION(0, 1), RATE_NOMINAL};
    }
    for (uint32_t k = 0; k < n_specs; k++) {
        if (mjpg) {
            add_sizes(cand, n_cand, FORMAT_MJPG, &sizes, &specs[k]);
            continue;
        }
        for (uint32_t fi = 0; fi < formats.n; fi++) {
            uint32_t format = *(const uint32_t *)pod_value(&formats, fi);
            const struct raw_format *rf = raw_format_of(format);
            int repeat = 0;
            for (uint32_t fj = 0; fj < fi; fj++) {
                repeat |= *(const uint32_t *)pod_value(&formats, fj) == format;
            }
            if (rf == NULL || rf->kind == MJPEG || repeat) {
                continue;
            }
            add_sizes(cand, n_cand, format, &sizes, &specs[k]);
        }
    }
    return 0;
}

// return true when an I420 size fits a frame message
static int size_ok(uint32_t w, uint32_t h)
{
    return w >= 2 && h >= 2 && w <= MAX_DIM && h <= MAX_DIM && w % 2 == 0 && h % 2 == 0;
}

// order modes by largest area, then widest
static int mode_before(const struct mode_entry *a, const struct mode_entry *b)
{
    uint64_t aa = (uint64_t)a->mode.width * a->mode.height, ba = (uint64_t)b->mode.width * b->mode.height;
    return aa != ba ? aa > ba : a->mode.width > b->mode.width;
}

// group offers into a mode per size at best rate
static uint32_t group_modes(const struct candidate *cand, uint32_t n_cand, struct mode_entry *out, uint32_t max)
{
    static struct mode_entry groups[MAX_CANDIDATES];
    uint32_t n = 0;
    for (uint32_t i = 0; i < n_cand; i++) {
        const struct candidate *c = &cand[i];
        if (!size_ok(c->width, c->height) || c->fps_num == 0 || c->fps_den == 0) {
            continue;
        }
        struct mode_entry *g = NULL;
        for (uint32_t j = 0; j < n; j++) {
            if (groups[j].mode.width == c->width && groups[j].mode.height == c->height &&
                (groups[j].formats[0] == FORMAT_MJPG) == (c->format == FORMAT_MJPG)) {
                g = &groups[j];
                break;
            }
        }
        if (g == NULL) {
            g = &groups[n++];
            memset(g, 0, sizeof(*g));
            g->mode = (struct rhizo_camera_mode){c->width, c->height, c->fps_num, c->fps_den};
            g->formats[g->n_formats++] = c->format;
            continue;
        }
        int cmp = fps_cmp(c->fps_num, c->fps_den, g->mode.fps_num, g->mode.fps_den);
        if (cmp > 0) {
            g->mode.fps_num = c->fps_num, g->mode.fps_den = c->fps_den;
            memset(g->formats, 0, sizeof(g->formats));
            g->n_formats = 0;
            g->formats[g->n_formats++] = c->format;
        } else if (cmp == 0 && g->n_formats < MAX_MODE_FORMATS) {
            int have = 0;
            for (uint32_t k = 0; k < g->n_formats; k++) {
                have |= g->formats[k] == c->format;
            }
            if (!have) {
                g->formats[g->n_formats++] = c->format;
            }
        }
    }
    for (uint32_t j = 0; j < n; j++) {
        if (groups[j].formats[0] != FORMAT_MJPG || groups[j].mode.width == 0) {
            continue;
        }
        for (uint32_t k = 0; k < n; k++) {
            struct mode_entry *r = &groups[k];
            if (k == j || r->mode.width != groups[j].mode.width || r->mode.height != groups[j].mode.height) {
                continue;
            }
            if (fps_cmp(r->mode.fps_num, r->mode.fps_den, groups[j].mode.fps_num, groups[j].mode.fps_den) >= 0) {
                groups[j].mode.width = 0;
            } else {
                r->mode.width = 0;
            }
        }
    }
    uint32_t kept = 0;
    for (uint32_t j = 0; j < n; j++) {
        if (groups[j].mode.width != 0) {
            groups[kept++] = groups[j];
        }
    }
    n = kept;
    for (uint32_t j = 0; j < n; j++) {
        struct mode_entry *g = &groups[j];
        for (uint32_t i = 0; i < n_cand && g->n_rates < MAX_MODE_RATES; i++) {
            const struct candidate *c = &cand[i];
            int in_mode = 0;
            for (uint32_t k = 0; k < g->n_formats; k++) {
                in_mode |= g->formats[k] == c->format;
            }
            if (!in_mode || c->width != g->mode.width || c->height != g->mode.height || c->fps_num == 0 ||
                c->fps_den == 0) {
                continue;
            }
            struct rate_entry e = {c->format, c->rate_kind, SPA_FRACTION(c->fps_num, c->fps_den),
                                   SPA_FRACTION(c->lo_num, c->lo_den)};
            int seen = 0;
            for (uint32_t k = 0; k < g->n_rates; k++) {
                seen |= memcmp(&g->rates[k], &e, sizeof(e)) == 0;
            }
            if (!seen) {
                g->rates[g->n_rates++] = e;
            }
        }
    }
    for (uint32_t j = 0; j < n; j++) {
        struct mode_entry *g = &groups[j];
        for (uint32_t a = 1; a < g->n_formats; a++) {
            for (uint32_t b = a; b > 0 && format_rank(g->formats[b]) < format_rank(g->formats[b - 1]); b--) {
                uint32_t t = g->formats[b];
                g->formats[b] = g->formats[b - 1];
                g->formats[b - 1] = t;
            }
        }
    }
    for (uint32_t a = 1; a < n; a++) {
        for (uint32_t b = a; b > 0 && mode_before(&groups[b], &groups[b - 1]); b--) {
            struct mode_entry t = groups[b];
            groups[b] = groups[b - 1];
            groups[b - 1] = t;
        }
    }
    uint32_t keep = n < max ? n : max;
    memset(out, 0, sizeof(*out) * max);
    memcpy(out, groups, sizeof(*out) * keep);
    return keep;
}

// choose the lowest offered rate at or above the request
static void choose_rate(const struct mode_entry *m, struct spa_fraction want, uint32_t *format,
                        struct spa_fraction *rate, uint32_t *kind)
{
    int found = 0;
    for (uint32_t fi = 0; fi < m->n_formats; fi++) {
        for (uint32_t i = 0; i < m->n_rates; i++) {
            const struct rate_entry *e = &m->rates[i];
            if (e->format != m->formats[fi] || frac_cmp(e->rate, want) < 0) {
                continue;
            }
            struct spa_fraction r = e->rate;
            if (e->kind == RATE_RANGE) {
                r = frac_cmp(want, e->lo) >= 0 ? want : e->lo;
            } else if (e->kind == RATE_NOMINAL) {
                r = want;
            }
            if (!found || frac_cmp(r, *rate) < 0) {
                found = 1;
                *format = e->format;
                *rate = r;
                *kind = e->kind;
            }
        }
    }
    if (!found) {
        *format = m->formats[0];
        *rate = SPA_FRACTION(m->mode.fps_num, m->mode.fps_den);
        *kind = RATE_FIXED;
    }
}

// return a message with its header filled
static struct outmsg *msg_new(uint32_t type, uint32_t payload_len, uint32_t stream_id, int is_frame)
{
    struct outmsg *m = malloc(sizeof(*m) + HDR_LEN + payload_len);
    if (m == NULL) {
        return NULL;
    }
    m->next = NULL;
    m->serial = __atomic_add_fetch(&g_msg_serial, 1, __ATOMIC_RELAXED);
    m->stream_id = stream_id;
    m->is_frame = is_frame;
    m->len = HDR_LEN + payload_len;
    m->off = 0;
    struct rhizo_camera_msg_header h = {RHIZO_CAMERA_MAGIC, type, payload_len, 0};
    memcpy(m->data, &h, HDR_LEN);
    return m;
}

// return true when a queued message may be dropped
static int droppable(const struct client *c, const struct outmsg *m)
{
    return !(m == c->head && (c->sending || m->off > 0));
}

// queue a message, returning the frames it dropped or -1
static int enqueue(struct client *c, struct outmsg *m)
{
    int dropped = 0;
    pthread_mutex_lock(&g_qlock);
    if (!c->queue_open) {
        pthread_mutex_unlock(&g_qlock);
        free(m);
        return -1;
    }
    if (m->is_frame) {
        int queued = 0;
        for (struct outmsg *q = c->head; q != NULL; q = q->next) {
            queued += q->is_frame && q->stream_id == m->stream_id && droppable(c, q);
        }
        while (queued >= FRAMES_QUEUED_MAX) {
            struct outmsg *prev = NULL, *q = c->head;
            while (q != NULL && !(q->is_frame && q->stream_id == m->stream_id && droppable(c, q))) {
                prev = q;
                q = q->next;
            }
            if (q == NULL) {
                break;
            }
            if (prev == NULL) {
                c->head = q->next;
            } else {
                prev->next = q->next;
            }
            if (c->tail == q) {
                c->tail = prev;
            }
            free(q);
            queued--;
            dropped++;
        }
    } else {
        c->control_bytes += m->len;
        if (c->control_bytes > CONTROL_BACKLOG_MAX) {
            c->overflow = 1;
        }
    }
    if (c->tail == NULL) {
        c->head = c->tail = m;
    } else {
        c->tail->next = m;
        c->tail = m;
    }
    pthread_mutex_unlock(&g_qlock);
    wake();
    return dropped;
}

// discard a stream's droppable queued frames
static void purge_frames(struct client *c, uint32_t stream_id)
{
    pthread_mutex_lock(&g_qlock);
    struct outmsg *prev = NULL, *q = c->head;
    while (q != NULL) {
        struct outmsg *next = q->next;
        if (q->is_frame && q->stream_id == stream_id && droppable(c, q)) {
            if (prev == NULL) {
                c->head = next;
            } else {
                prev->next = next;
            }
            if (c->tail == q) {
                c->tail = prev;
            }
            free(q);
        } else {
            prev = q;
        }
        q = next;
    }
    pthread_mutex_unlock(&g_qlock);
}

// send a client's queued output without blocking, or -1
static int flush_client(struct client *c)
{
    int rc = 0;
    pthread_mutex_lock(&g_qlock);
    while (c->head != NULL) {
        struct outmsg *m = c->head;
        c->sending = 1;
        pthread_mutex_unlock(&g_qlock);
        ssize_t w = send(c->fd, m->data + m->off, m->len - m->off, MSG_NOSIGNAL | MSG_DONTWAIT);
        int err = errno;
        pthread_mutex_lock(&g_qlock);
        c->sending = 0;
        if (w < 0) {
            if (err != EAGAIN && err != EWOULDBLOCK && err != EINTR) {
                rc = -1;
            }
            break;
        }
        m->off += (size_t)w;
        if (m->off < m->len) {
            break;
        }
        c->head = m->next;
        if (c->head == NULL) {
            c->tail = NULL;
        }
        if (!m->is_frame) {
            c->control_bytes -= m->len;
        }
        free(m);
    }
    pthread_mutex_unlock(&g_qlock);
    return rc;
}

// return true when a client has output waiting
static int client_has_output(struct client *c)
{
    pthread_mutex_lock(&g_qlock);
    int any = c->head != NULL;
    pthread_mutex_unlock(&g_qlock);
    return any;
}

// queue a stream's STOPPED
static void send_stopped(struct client *c, uint32_t stream_id, int error)
{
    struct outmsg *m = msg_new(RHIZO_CAMERA_STOPPED, sizeof(struct rhizo_camera_stopped), stream_id, 0);
    if (m == NULL) {
        return;
    }
    struct rhizo_camera_stopped s = {stream_id, error};
    memcpy(MSG_PAYLOAD(m), &s, sizeof(s));
    enqueue(c, m);
}

// mark the camera set changed
static void mark_dirty(void)
{
    g_dirty = 1;
    wake();
}

// request a PipeWire roundtrip and clear the settled flag
static int issue_sync(void)
{
    g_sync_seq = pw_core_sync(g_core, PW_ID_CORE, g_sync_seq);
    g_settled = 0;
    return g_sync_seq;
}

// return the tracked node with a global id
static struct cam_node *node_by_id(uint32_t id)
{
    for (int i = 0; i < MAX_NODES; i++) {
        if (g_nodes[i].used && g_nodes[i].id == id) {
            return &g_nodes[i];
        }
    }
    return NULL;
}

// count the open streams reading a node
static int streams_on_node(uint32_t node_id)
{
    int n = 0;
    for (int i = 0; i < MAX_CLIENTS; i++) {
        for (int j = 0; j < STREAMS_PER_CLIENT; j++) {
            n += g_clients[i].streams[j].used && g_clients[i].streams[j].node_id == node_id;
        }
    }
    return n;
}

// format a mode as log text
static void mode_text(const struct rhizo_camera_mode *m, char *out, size_t len)
{
    if (m->fps_den == 1) {
        snprintf(out, len, "%ux%u@%u", m->width, m->height, m->fps_num);
    } else {
        snprintf(out, len, "%ux%u@%u/%u", m->width, m->height, m->fps_num, m->fps_den);
    }
}

// log a camera's modes
static void log_camera(const struct cam_node *n)
{
    if (n->n_modes == 0) {
        fprintf(stderr, "[camerad] camera '%s' %s, not listed\n", n->key,
                n->saw_compressed ? "offers only compressed formats the daemon does not decode (H264 and the like)"
                                  : "offers no format the daemon converts");
        return;
    }
    char line[RHIZO_CAMERA_MAX_MODES * 30 + 1] = "";
    size_t used = 0;
    for (uint32_t i = 0; i < n->n_modes && used < sizeof(line) - 30; i++) {
        char m[24];
        mode_text(&n->modes[i].mode, m, sizeof(m));
        used += (size_t)snprintf(line + used, sizeof(line) - used, " %s%s", m,
                                 n->modes[i].formats[0] == FORMAT_MJPG ? "(MJPG)" : "");
    }
    fprintf(stderr, "[camerad] camera '%s' ('%s', facing %s): %u mode%s:%s\n", n->key, n->name, facing_name(n->facing),
            n->n_modes, n->n_modes == 1 ? "" : "s", line);
}

// enumerate a node's formats unless a stream reads it
static void start_enum(struct cam_node *n)
{
    if (n->port_proxy == NULL) {
        return;
    }
    if (streams_on_node(n->id) > 0) {
        n->enum_deferred = 1;
        return;
    }
    if (n->cand == NULL && (n->cand = calloc(MAX_CANDIDATES, sizeof(*n->cand))) == NULL) {
        fprintf(stderr, "[camerad] out of memory enumerating node %u\n", n->id);
        return;
    }
    n->enum_deferred = 0;
    n->n_cand = 0;
    n->saw_compressed = 0;
    n->enum_seq = pw_port_enum_params((struct pw_port *)n->port_proxy, 0, SPA_PARAM_EnumFormat, 0, UINT32_MAX, NULL);
    n->sync_seq = issue_sync();
    n->enum_pending = 1;
}

// turn a finished enumeration into the node's modes
static void finish_enum(struct cam_node *n)
{
    struct mode_entry modes[RHIZO_CAMERA_MAX_MODES];
    uint32_t count = group_modes(n->cand, n->n_cand, modes, RHIZO_CAMERA_MAX_MODES);
    free(n->cand);
    n->cand = NULL;
    n->enum_pending = 0;
    int changed = !n->enumerated || count != n->n_modes || memcmp(modes, n->modes, sizeof(modes)) != 0;
    n->enumerated = 1;
    if (changed) {
        memcpy(n->modes, modes, sizeof(modes));
        n->n_modes = count;
        if (n->is_camera) {
            log_camera(n);
        }
        mark_dirty();
    }
}

// read a node's camera-ness, key, name and facing
static void on_node_info(void *data, const struct pw_node_info *info)
{
    struct cam_node *n = data;
    if (!(info->change_mask & PW_NODE_CHANGE_MASK_PROPS) || info->props == NULL) {
        return;
    }
    const struct spa_dict *p = info->props;
    const char *node_name = spa_dict_lookup(p, PW_KEY_NODE_NAME);
    const char *desc = spa_dict_lookup(p, PW_KEY_NODE_DESCRIPTION);
    const char *nick = spa_dict_lookup(p, PW_KEY_NODE_NICK);
    const char *role = spa_dict_lookup(p, PW_KEY_MEDIA_ROLE);
    const char *factory = spa_dict_lookup(p, PW_KEY_FACTORY_NAME);
    const char *api = spa_dict_lookup(p, PW_KEY_DEVICE_API);
    char fallback[32];
    snprintf(fallback, sizeof(fallback), "camera-%u", n->id);
    if (node_name == NULL || node_name[0] == '\0') {
        node_name = fallback;
    }
    char key[RHIZO_CAMERA_KEY_LEN] = {0}, name[RHIZO_CAMERA_NAME_LEN] = {0};
    make_key(node_name, key);
    make_name(desc != NULL ? desc : nick != NULL ? nick : node_name, name);
    int camera = props_are_camera(role, factory, api);
    uint32_t facing = camera ? facing_of(spa_dict_lookup(p, "api.libcamera.location"),
                                         spa_dict_lookup(p, "api.v4l2.path"))
                             : RHIZO_CAMERA_FACING_EXTERNAL;
    int changed = !n->info_seen || camera != n->is_camera || strcmp(key, n->key) != 0 || strcmp(name, n->name) != 0 ||
                  facing != n->facing;
    n->info_seen = 1;
    if (!changed) {
        return;
    }
    n->is_camera = camera;
    n->facing = facing;
    memcpy(n->key, key, sizeof(key));
    memcpy(n->name, name, sizeof(name));
    if (!camera) {
        fprintf(stderr, "[camerad] node %u '%s' is a Video/Source but not a camera (media.role '%s', factory '%s'), "
                        "not listed\n", n->id, key, role ? role : "-", factory ? factory : "-");
    } else if (n->enumerated) {
        log_camera(n);
    } else {
        fprintf(stderr, "[camerad] node %u '%s' is a camera (media.role '%s', factory '%s'), reading its formats\n",
                n->id, key, role ? role : "-", factory ? factory : "-");
    }
    mark_dirty();
}

static const struct pw_node_events node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = on_node_info,
};

// re-read the port's formats when its EnumFormat param changes
static void on_port_info(void *data, const struct pw_port_info *info)
{
    struct cam_node *n = data;
    if (!(info->change_mask & PW_PORT_CHANGE_MASK_PARAMS)) {
        return;
    }
    for (uint32_t i = 0; i < info->n_params; i++) {
        if (info->params[i].id == SPA_PARAM_EnumFormat && (info->params[i].flags & SPA_PARAM_INFO_READ)) {
            start_enum(n);
            return;
        }
    }
}

// collect an EnumFormat result of the current enumeration
static void on_port_param(void *data, int seq, uint32_t id, uint32_t index, uint32_t next, const struct spa_pod *param)
{
    struct cam_node *n = data;
    (void)index;
    (void)next;
    if (id != SPA_PARAM_EnumFormat || seq != n->enum_seq || !n->enum_pending || param == NULL || n->cand == NULL) {
        return;
    }
    if (collect_candidates(param, n->cand, &n->n_cand)) {
        n->saw_compressed = 1;
    }
}

static const struct pw_port_events port_events = {
    PW_VERSION_PORT_EVENTS,
    .info = on_port_info,
    .param = on_port_param,
};

// drop a node's port and the modes it gave
static void forget_port(struct cam_node *n)
{
    if (n->port_proxy != NULL) {
        spa_hook_remove(&n->port_listener);
        pw_proxy_destroy(n->port_proxy);
        n->port_proxy = NULL;
    }
    free(n->cand);
    n->cand = NULL;
    n->port_id = SPA_ID_INVALID;
    n->enum_pending = 0;
    n->enum_deferred = 0;
    if (n->n_modes > 0) {
        n->n_modes = 0;
        memset(n->modes, 0, sizeof(n->modes));
        mark_dirty();
    }
}

// mark a stream ended from either thread
static void end_stream(struct cam_stream *s, int error)
{
    if (!s->ended) {
        s->ended = 1;
        s->end_error = error;
        wake();
    }
}

// track a new Video/Source node or its first output port
static void on_global(void *data, uint32_t id, uint32_t permissions, const char *type, uint32_t version,
                      const struct spa_dict *props)
{
    (void)data;
    (void)permissions;
    (void)version;
    if (props == NULL) {
        return;
    }
    if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
        const char *cls = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
        if (cls == NULL || strcmp(cls, "Video/Source") != 0) {
            return;
        }
        struct cam_node *n = NULL;
        for (int i = 0; i < MAX_NODES && n == NULL; i++) {
            if (!g_nodes[i].used) {
                n = &g_nodes[i];
            }
        }
        if (n == NULL) {
            fprintf(stderr, "[camerad] tracking %d video sources already, ignoring node %u\n", MAX_NODES, id);
            return;
        }
        memset(n, 0, sizeof(*n));
        const char *serial = spa_dict_lookup(props, PW_KEY_OBJECT_SERIAL);
        if (serial != NULL && strlen(serial) < sizeof(n->serial)) {
            snprintf(n->serial, sizeof(n->serial), "%s", serial);
        } else {
            snprintf(n->serial, sizeof(n->serial), "%u", id);
        }
        n->proxy = pw_registry_bind(g_registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
        if (n->proxy == NULL) {
            fprintf(stderr, "[camerad] cannot bind node %u\n", id);
            return;
        }
        n->used = 1;
        n->id = id;
        n->port_id = SPA_ID_INVALID;
        pw_node_add_listener((struct pw_node *)n->proxy, &n->listener, &node_events, n);
        issue_sync();
        if (g_verbose) {
            fprintf(stderr, "[camerad] video source node %u (serial %s)\n", id, n->serial);
        }
    } else if (strcmp(type, PW_TYPE_INTERFACE_Port) == 0) {
        const char *dir = spa_dict_lookup(props, PW_KEY_PORT_DIRECTION);
        const char *node_id = spa_dict_lookup(props, PW_KEY_NODE_ID);
        if (dir == NULL || node_id == NULL || strcmp(dir, "out") != 0) {
            return;
        }
        struct cam_node *n = node_by_id((uint32_t)strtoul(node_id, NULL, 10));
        if (n == NULL || n->port_proxy != NULL) {
            return;
        }
        n->port_proxy = pw_registry_bind(g_registry, id, PW_TYPE_INTERFACE_Port, PW_VERSION_PORT, 0);
        if (n->port_proxy == NULL) {
            fprintf(stderr, "[camerad] cannot bind port %u of node %u\n", id, n->id);
            return;
        }
        n->port_id = id;
        pw_port_add_listener((struct pw_port *)n->port_proxy, &n->port_listener, &port_events, n);
        issue_sync();
    }
}

// drop a removed node with its streams, or a port
static void on_global_remove(void *data, uint32_t id)
{
    (void)data;
    for (int i = 0; i < MAX_NODES; i++) {
        struct cam_node *n = &g_nodes[i];
        if (!n->used) {
            continue;
        }
        if (n->port_id == id) {
            forget_port(n);
            continue;
        }
        if (n->id != id) {
            continue;
        }
        for (int c = 0; c < MAX_CLIENTS; c++) {
            for (int j = 0; j < STREAMS_PER_CLIENT; j++) {
                struct cam_stream *s = &g_clients[c].streams[j];
                if (s->used && s->node_id == id) {
                    end_stream(s, -ENODEV);
                }
            }
        }
        if (n->is_camera) {
            fprintf(stderr, "[camerad] camera '%s' (node %u) removed\n", n->key, id);
        }
        forget_port(n);
        spa_hook_remove(&n->listener);
        pw_proxy_destroy(n->proxy);
        memset(n, 0, sizeof(*n));
        mark_dirty();
    }
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = on_global,
    .global_remove = on_global_remove,
};

// finish the enumerations whose roundtrip returned
static void on_core_done(void *data, uint32_t id, int seq)
{
    (void)data;
    if (id != PW_ID_CORE) {
        return;
    }
    for (int i = 0; i < MAX_NODES; i++) {
        if (g_nodes[i].used && g_nodes[i].enum_pending && g_nodes[i].sync_seq == seq) {
            finish_enum(&g_nodes[i]);
        }
    }
    if (seq == g_sync_seq && !g_settled) {
        g_settled = 1;
        mark_dirty();
    }
}

// log PipeWire errors and stop on a lost connection
static void on_core_error(void *data, uint32_t id, int seq, int res, const char *message)
{
    (void)data;
    (void)seq;
    fprintf(stderr, "[camerad] pipewire error on object %u: %s (%s)\n", id, spa_strerror(res),
            message ? message : "");
    if (id == PW_ID_CORE && res == -EPIPE) {
        g_pipewire_lost = 1;
        on_signal(0);
    }
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = on_core_done,
    .error = on_core_error,
};

// return the listed cameras in global id order
static int listed_cameras(struct cam_node **out, int *left)
{
    struct cam_node *all[MAX_NODES];
    int m = 0, n = 0;
    *left = 0;
    for (int i = 0; i < MAX_NODES; i++) {
        struct cam_node *c = &g_nodes[i];
        if (c->used && c->info_seen && c->is_camera && c->enumerated && c->n_modes > 0) {
            all[m++] = c;
        }
    }
    for (int a = 1; a < m; a++) {
        for (int b = a; b > 0 && all[b]->id < all[b - 1]->id; b--) {
            struct cam_node *t = all[b];
            all[b] = all[b - 1];
            all[b - 1] = t;
        }
    }
    for (int i = 0; i < m; i++) {
        int dup = 0;
        for (int j = 0; j < n; j++) {
            dup |= strcmp(out[j]->key, all[i]->key) == 0;
        }
        if (dup) {
            continue;
        }
        if (n == RHIZO_CAMERA_MAX_CAMERAS) {
            (*left)++;
            continue;
        }
        out[n++] = all[i];
    }
    return n;
}

// build the LIST payload and return its length
static uint32_t build_list(unsigned char *out, int *count_out, int *left)
{
    struct cam_node *cams[RHIZO_CAMERA_MAX_CAMERAS];
    int count = listed_cameras(cams, left);
    struct rhizo_camera_list hdr = {RHIZO_CAMERA_PROTOCOL_VERSION, (uint32_t)count};
    memcpy(out, &hdr, sizeof(hdr));
    for (int i = 0; i < count; i++) {
        struct rhizo_camera_info info;
        memset(&info, 0, sizeof(info));
        memcpy(info.key, cams[i]->key, sizeof(info.key));
        memcpy(info.name, cams[i]->name, sizeof(info.name));
        info.facing = cams[i]->facing;
        info.mode_count = cams[i]->n_modes;
        for (uint32_t j = 0; j < cams[i]->n_modes; j++) {
            info.modes[j] = cams[i]->modes[j].mode;
        }
        memcpy(out + sizeof(hdr) + (size_t)i * sizeof(info), &info, sizeof(info));
    }
    *count_out = count;
    return (uint32_t)(sizeof(hdr) + (size_t)count * sizeof(struct rhizo_camera_info));
}

// send STARTED and set buffer params on a negotiated format
static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param)
{
    struct cam_stream *s = data;
    if (id != SPA_PARAM_Format || s->ended) {
        return;
    }
    if (param == NULL) {
        s->format = NULL;
        return;
    }
    uint32_t media_type, media_subtype;
    struct spa_video_info_raw info;
    struct spa_video_info_mjpg mjpg;
    memset(&info, 0, sizeof(info));
    memset(&mjpg, 0, sizeof(mjpg));
    int parsed = spa_format_parse(param, &media_type, &media_subtype) >= 0 && media_type == SPA_MEDIA_TYPE_video;
    if (parsed && media_subtype == SPA_MEDIA_SUBTYPE_mjpg && spa_format_video_mjpg_parse(param, &mjpg) >= 0) {
        info.format = FORMAT_MJPG;
        info.size = mjpg.size;
        info.framerate = mjpg.framerate;
    } else if (!parsed || media_subtype != SPA_MEDIA_SUBTYPE_raw || spa_format_video_raw_parse(param, &info) < 0 ||
               info.format == FORMAT_MJPG) {
        fprintf(stderr, "[camerad] client %d stream %u: unreadable format negotiated\n", s->owner->id, s->stream_id);
        end_stream(s, -EPROTO);
        return;
    }
    const struct raw_format *f = raw_format_of(info.format);
    if (f == NULL || info.format != s->req_format || info.size.width != s->mode.mode.width ||
        info.size.height != s->mode.mode.height) {
        fprintf(stderr, "[camerad] client %d stream %u: negotiated %ux%u format %u, not the %ux%u it asked for\n",
                s->owner->id, s->stream_id, info.size.width, info.size.height, info.format, s->mode.mode.width,
                s->mode.mode.height);
        end_stream(s, -EPROTO);
        return;
    }
    if (f->kind == MJPEG && s->mjpeg == NULL && (s->mjpeg = mjpeg_decoder_new()) == NULL) {
        end_stream(s, -ENOMEM);
        return;
    }
    s->format = f;
    s->full_range = f->kind == PACKED_RGB || f->kind == MJPEG || info.color_range == SPA_VIDEO_COLOR_RANGE_0_255;
    uint8_t buffer[256];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 16),
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
    pw_stream_update_params(s->stream, params, 1);
    if (s->started) {
        return;
    }
    struct outmsg *m = msg_new(RHIZO_CAMERA_STARTED, sizeof(struct rhizo_camera_started), s->stream_id, 0);
    if (m == NULL) {
        end_stream(s, -ENOMEM);
        return;
    }
    struct spa_fraction rate = info.framerate.num != 0 && info.framerate.denom != 0 ? info.framerate : s->req_rate;
    struct rhizo_camera_started st = {s->stream_id, s->mode.mode.width, s->mode.mode.height, rate.num, rate.denom, 0};
    memcpy(MSG_PAYLOAD(m), &st, sizeof(st));
    s->started = 1;
    fprintf(stderr, "[camerad] client %d stream %u started: '%s' %ux%u@%u/%u %s%s\n", s->owner->id, s->stream_id,
            s->key, info.size.width, info.size.height, info.framerate.num, info.framerate.denom, f->name,
            f->kind == PACKED_RGB || f->kind == MJPEG ? "" : s->full_range ? " full range"
                                                                              : " limited range, expanded to full");
    enqueue(s->owner, m);
}

// queue the newest buffer as an I420 FRAME
static void on_process(void *data)
{
    struct cam_stream *s = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(s->stream), *newer;
    if (b == NULL) {
        return;
    }
    while ((newer = pw_stream_dequeue_buffer(s->stream)) != NULL) {
        pw_stream_queue_buffer(s->stream, b);
        b = newer;
        s->dropped++;
    }
    const struct raw_format *f = s->format;
    if (f == NULL || s->ended || !s->started || b->buffer->n_datas < 1 || b->buffer->datas[0].chunk == NULL ||
        b->buffer->datas[0].chunk->size == 0) {
        pw_stream_queue_buffer(s->stream, b);
        return;
    }
    uint32_t w = s->mode.mode.width, h = s->mode.mode.height;
    int64_t taken_ns = mono_ns();
    size_t image = (size_t)w * h * 3 / 2;
    struct outmsg *m = msg_new(RHIZO_CAMERA_FRAME, (uint32_t)(sizeof(struct rhizo_camera_frame) + image),
                               s->stream_id, 1);
    if (m == NULL) {
        s->dropped++;
        pw_stream_queue_buffer(s->stream, b);
        return;
    }
    uint8_t *out = MSG_PAYLOAD(m) + sizeof(struct rhizo_camera_frame);
    const struct spa_data *d = &b->buffer->datas[0];
    const char *why = NULL;
    if (d->chunk->flags & SPA_CHUNK_FLAG_CORRUPTED) {
        why = "the producer marked it corrupted";
    } else if (f->kind == MJPEG) {
        if (d->data == NULL || d->chunk->offset > d->maxsize) {
            why = "unmapped or out-of-bounds MJPEG buffer";
        } else {
            size_t avail = d->maxsize - d->chunk->offset, size = d->chunk->size < avail ? d->chunk->size : avail;
            const char *err = NULL;
            if (mjpeg_decode(s->mjpeg, (const uint8_t *)d->data + d->chunk->offset, size, w, h, out, &err) != 0) {
                why = err;
            }
        }
    } else {
        struct plane_view planes[3];
        if (map_planes(b->buffer, f, w, h, planes) < 0) {
            why = "its planes do not fit the buffer";
        } else {
            convert_frame(f, planes, w, h, s->full_range, out);
        }
    }
    if (why != NULL) {
        if (s->unreadable++ == 0) {
            fprintf(stderr, "[camerad] client %d stream %u: unreadable %s frame (%s; %u datas, type %u, offset %u "
                            "size %u stride %d maxsize %u, %ux%u), dropping such frames\n", s->owner->id,
                    s->stream_id, f->name, why, b->buffer->n_datas, d->type, d->chunk->offset, d->chunk->size,
                    d->chunk->stride, d->maxsize, w, h);
        }
        free(m);
        pw_stream_queue_buffer(s->stream, b);
        return;
    }
    pw_stream_queue_buffer(s->stream, b);
    struct rhizo_camera_frame fr = {s->stream_id, w, h, 0, s->seq++, taken_ns};
    memcpy(MSG_PAYLOAD(m), &fr, sizeof(fr));
    int dropped = enqueue(s->owner, m);
    if (dropped > 0) {
        s->dropped += (uint64_t)dropped;
    }
    s->frames++;
}

// log stream state changes and end a failed stream
static void on_stream_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
    struct cam_stream *s = data;
    fprintf(stderr, "[camerad] client %d stream %u state %s -> %s%s%s\n", s->owner->id, s->stream_id,
            pw_stream_state_as_string(old), pw_stream_state_as_string(state), error ? ": " : "", error ? error : "");
    if (state == PW_STREAM_STATE_ERROR) {
        end_stream(s, -EIO);
    } else if (state == PW_STREAM_STATE_UNCONNECTED && old != PW_STREAM_STATE_UNCONNECTED) {
        end_stream(s, -ENODEV);
    }
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_stream_state,
    .param_changed = on_param_changed,
    .process = on_process,
};

// connect a capture stream to a camera node's mode
static int connect_stream(struct cam_stream *s, const struct cam_node *n)
{
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Video",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Camera",
        PW_KEY_MEDIA_CLASS, "Stream/Input/Video",
        PW_KEY_APP_NAME, "Android (Rhizo)",
        PW_KEY_NODE_NAME, "rhizo.camera",
        PW_KEY_NODE_DESCRIPTION, "Rhizo camera (Android)",
        PW_KEY_MEDIA_NAME, "Android camera",
        PW_KEY_TARGET_OBJECT, n->serial,
        PW_KEY_NODE_DONT_RECONNECT, "true",
        NULL);
    pw_properties_set(props, "node.dont-fallback", "true");
    pw_properties_set(props, "rhizo.camera.key", n->key);
    s->stream = pw_stream_new(g_core, "rhizo.camera", props);
    if (s->stream == NULL) {
        fprintf(stderr, "[camerad] pw_stream_new failed: %s\n", strerror(errno));
        return -1;
    }
    pw_stream_add_listener(s->stream, &s->listener, &stream_events, s);

    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_pod_frame obj;
    int mjpg = s->req_format == FORMAT_MJPG;
    spa_pod_builder_push_object(&b, &obj, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
    spa_pod_builder_add(&b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
                        SPA_POD_Id(mjpg ? SPA_MEDIA_SUBTYPE_mjpg : SPA_MEDIA_SUBTYPE_raw), 0);
    if (!mjpg) {
        spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_format, SPA_POD_Id(s->req_format), 0);
    }
    spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(s->mode.mode.width,
                                                                                   s->mode.mode.height)), 0);
    struct spa_fraction rate = s->req_rate;
    if (s->req_kind == RATE_NOMINAL) {
        spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_framerate,
                            SPA_POD_CHOICE_RANGE_Fraction(&rate, &SPA_FRACTION(0, 1), &rate), 0);
    } else {
        spa_pod_builder_add(&b, SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&rate), 0);
    }
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_pop(&b, &obj);

    int res = pw_stream_connect(s->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                                PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
    if (res < 0) {
        fprintf(stderr, "[camerad] pw_stream_connect failed for '%s': %s\n", n->key, spa_strerror(res));
        spa_hook_remove(&s->listener);
        pw_stream_destroy(s->stream);
        s->stream = NULL;
        return -1;
    }
    return 0;
}

// destroy a stream's PipeWire stream and free its slot
static void destroy_stream(struct cam_stream *s)
{
    uint32_t node_id = s->node_id;
    if (s->stream != NULL) {
        spa_hook_remove(&s->listener);
        pw_stream_destroy(s->stream);
        g_stream_count--;
    }
    mjpeg_decoder_free(s->mjpeg);
    memset(s, 0, sizeof(*s));
    g_trim_mark = __atomic_load_n(&g_msg_serial, __ATOMIC_RELAXED);
    g_trim_pending = 1;
    struct cam_node *n = node_by_id(node_id);
    if (n != NULL && n->enum_deferred && streams_on_node(node_id) == 0) {
        start_enum(n);
    }
}

// return a client's stream by HAL stream id
static struct cam_stream *stream_by_id(struct client *c, uint32_t stream_id)
{
    for (int i = 0; i < STREAMS_PER_CLIENT; i++) {
        if (c->streams[i].used && c->streams[i].stream_id == stream_id) {
            return &c->streams[i];
        }
    }
    return NULL;
}

// handle an OPEN, or return -1 on a protocol error
static int open_stream(struct client *c, const struct rhizo_camera_open *req)
{
    char mode[24];
    struct rhizo_camera_mode asked = {req->width, req->height, req->fps_num, req->fps_den};
    mode_text(&asked, mode, sizeof(mode));
    if (stream_by_id(c, req->stream_id) != NULL) {
        fprintf(stderr, "[camerad] client %d opened stream %u twice\n", c->id, req->stream_id);
        return -1;
    }
    struct cam_node *cams[RHIZO_CAMERA_MAX_CAMERAS], *n = NULL;
    int left;
    int count = listed_cameras(cams, &left);
    for (int i = 0; i < count && n == NULL; i++) {
        if (strcmp(cams[i]->key, req->key) == 0) {
            n = cams[i];
        }
    }
    if (n == NULL) {
        fprintf(stderr, "[camerad] client %d stream %u: no camera '%s'\n", c->id, req->stream_id, req->key);
        send_stopped(c, req->stream_id, -ENODEV);
        return 0;
    }
    const struct mode_entry *m = NULL;
    for (uint32_t i = 0; i < n->n_modes && m == NULL; i++) {
        if (n->modes[i].mode.width == req->width && n->modes[i].mode.height == req->height) {
            m = &n->modes[i];
        }
    }
    struct spa_fraction want = SPA_FRACTION(req->fps_num, req->fps_den);
    if (m == NULL || want.num == 0 || want.denom == 0 ||
        fps_cmp(want.num, want.denom, m->mode.fps_num, m->mode.fps_den) > 0) {
        fprintf(stderr, "[camerad] client %d stream %u: '%s' has no mode for %s\n", c->id, req->stream_id, n->key,
                mode);
        send_stopped(c, req->stream_id, -EINVAL);
        return 0;
    }
    uint32_t format, kind;
    struct spa_fraction rate;
    choose_rate(m, want, &format, &rate, &kind);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        for (int j = 0; j < STREAMS_PER_CLIENT; j++) {
            struct cam_stream *o = &g_clients[i].streams[j];
            if (o->used && o->node_id == n->id &&
                (o->mode.mode.width != m->mode.width || o->mode.mode.height != m->mode.height ||
                 o->req_format != format || frac_cmp(o->req_rate, rate) != 0)) {
                fprintf(stderr, "[camerad] client %d stream %u: '%s' already streams another size or rate\n", c->id,
                        req->stream_id, n->key);
                send_stopped(c, req->stream_id, -EBUSY);
                return 0;
            }
        }
    }
    struct cam_stream *s = NULL;
    for (int i = 0; i < STREAMS_PER_CLIENT && s == NULL; i++) {
        if (!c->streams[i].used) {
            s = &c->streams[i];
        }
    }
    if (s == NULL) {
        fprintf(stderr, "[camerad] client %d stream %u: %d streams open already\n", c->id, req->stream_id,
                STREAMS_PER_CLIENT);
        send_stopped(c, req->stream_id, -EMFILE);
        return 0;
    }
    memset(s, 0, sizeof(*s));
    s->owner = c;
    s->stream_id = req->stream_id;
    s->node_id = n->id;
    memcpy(s->key, n->key, sizeof(s->key));
    s->mode = *m;
    s->req_format = format;
    s->req_rate = rate;
    s->req_kind = kind;
    s->deadline_ms = mono_ms() + OPEN_TIMEOUT_MS;
    if (connect_stream(s, n) != 0) {
        memset(s, 0, sizeof(*s));
        send_stopped(c, req->stream_id, -EIO);
        return 0;
    }
    s->used = 1;
    g_stream_count++;
    const struct raw_format *f = raw_format_of(format);
    fprintf(stderr, "[camerad] client %d stream %u: opening '%s' (node %u, serial %s) for %s at %u/%u%s as %s\n",
            c->id, req->stream_id, n->key, n->id, n->serial, mode, rate.num, rate.denom,
            kind == RATE_NOMINAL ? " (nominal)" : "", f ? f->name : "?");
    return 0;
}

// handle a CLOSE and discard the stream's queued frames
static void close_stream(struct client *c, uint32_t stream_id)
{
    struct cam_stream *s = stream_by_id(c, stream_id);
    if (s == NULL) {
        if (g_verbose) {
            fprintf(stderr, "[camerad] client %d closed stream %u, which is not open\n", c->id, stream_id);
        }
        return;
    }
    fprintf(stderr, "[camerad] client %d stream %u closed: %llu frames, %llu dropped, %llu unreadable\n", c->id,
            stream_id, (unsigned long long)s->frames, (unsigned long long)s->dropped,
            (unsigned long long)s->unreadable);
    destroy_stream(s);
    purge_frames(c, stream_id);
}

// queue the current LIST to a client
static void send_list(struct client *c)
{
    struct outmsg *m = msg_new(RHIZO_CAMERA_LIST, g_list_len, 0, 0);
    if (m == NULL) {
        return;
    }
    memcpy(MSG_PAYLOAD(m), g_list_buf, g_list_len);
    enqueue(c, m);
}

// schedule a debounced LIST
static void schedule_list(int64_t now)
{
    if (g_list_due_ms == 0) {
        g_list_first_ms = now;
    }
    g_list_due_ms = now + LIST_DEBOUNCE_MS;
    if (g_list_due_ms > g_list_first_ms + LIST_DEBOUNCE_CAP_MS) {
        g_list_due_ms = g_list_first_ms + LIST_DEBOUNCE_CAP_MS;
    }
}

// send the rebuilt LIST to the clients awaiting it
static void send_lists(void)
{
    unsigned char fresh[LIST_PAYLOAD_MAX];
    int count = 0, left = 0;
    uint32_t len = build_list(fresh, &count, &left);
    int changed = !g_list_valid || len != g_list_len || memcmp(fresh, g_list_buf, len) != 0;
    if (changed) {
        memcpy(g_list_buf, fresh, len);
        g_list_len = len;
        g_list_valid = 1;
        g_listed_count = count;
        char names[RHIZO_CAMERA_MAX_CAMERAS * (RHIZO_CAMERA_KEY_LEN + 4) + 1] = "";
        size_t used = 0;
        for (int i = 0; i < count && used < sizeof(names); i++) {
            const struct rhizo_camera_info *info =
                (const struct rhizo_camera_info *)(fresh + sizeof(struct rhizo_camera_list) +
                                                   (size_t)i * sizeof(struct rhizo_camera_info));
            used += (size_t)snprintf(names + used, sizeof(names) - used, "%s'%.*s'", i ? ", " : " ",
                                     RHIZO_CAMERA_KEY_LEN - 1, info->key);
        }
        fprintf(stderr, "[camerad] listing %d camera%s%s%s\n", count, count == 1 ? "" : "s", names,
                left > 0 ? " (more than the protocol carries; the rest are not listed)" : "");
    }
    for (int i = 0; i < MAX_CLIENTS; i++) {
        struct client *c = &g_clients[i];
        if (c->fd >= 0 && c->hello && (changed || c->wants_list)) {
            send_list(c);
            c->wants_list = 0;
        }
    }
}

// answer a HELLO with the LIST once the view settles
static void answer_hello(struct client *c)
{
    if (g_settled && g_list_valid && g_list_due_ms == 0) {
        send_list(c);
        return;
    }
    c->wants_list = 1;
    if (g_list_due_ms == 0) {
        schedule_list(mono_ms());
    }
}

// check a message header, or return -1
static int header_ok(const struct rhizo_camera_msg_header *h, const char **why)
{
    if (h->magic != RHIZO_CAMERA_MAGIC) {
        *why = "bad magic";
        return -1;
    }
    if (h->type != RHIZO_CAMERA_HELLO && h->type != RHIZO_CAMERA_OPEN && h->type != RHIZO_CAMERA_CLOSE) {
        *why = "unknown message type";
        return -1;
    }
    if (h->length > CLIENT_PAYLOAD_MAX) {
        *why = "message too long";
        return -1;
    }
    return 0;
}

// handle a whole client message, -1 on a protocol error
static int dispatch(struct client *c, uint32_t type, const unsigned char *p, uint32_t len)
{
    if (type == RHIZO_CAMERA_HELLO) {
        struct rhizo_camera_hello h;
        if (len < sizeof(h)) {
            fprintf(stderr, "[camerad] client %d sent a short HELLO\n", c->id);
            return -1;
        }
        memcpy(&h, p, sizeof(h));
        if (h.version != RHIZO_CAMERA_PROTOCOL_VERSION) {
            fprintf(stderr, "[camerad] client %d speaks protocol %u, the daemon %u\n", c->id, h.version,
                    RHIZO_CAMERA_PROTOCOL_VERSION);
            return -1;
        }
        if (!c->hello) {
            fprintf(stderr, "[camerad] client %d sent HELLO\n", c->id);
        }
        c->hello = 1;
        pw_thread_loop_lock(g_loop);
        answer_hello(c);
        pw_thread_loop_unlock(g_loop);
        return 0;
    }
    if (!c->hello) {
        fprintf(stderr, "[camerad] client %d sent message %u before HELLO\n", c->id, type);
        return -1;
    }
    if (type == RHIZO_CAMERA_OPEN) {
        struct rhizo_camera_open o;
        if (len < sizeof(o)) {
            fprintf(stderr, "[camerad] client %d sent a short OPEN\n", c->id);
            return -1;
        }
        memcpy(&o, p, sizeof(o));
        if (memchr(o.key, '\0', sizeof(o.key)) == NULL) {
            fprintf(stderr, "[camerad] client %d sent an OPEN whose key is not terminated\n", c->id);
            return -1;
        }
        pw_thread_loop_lock(g_loop);
        int rc = open_stream(c, &o);
        pw_thread_loop_unlock(g_loop);
        return rc;
    }
    struct rhizo_camera_close cl;
    if (len < sizeof(cl)) {
        fprintf(stderr, "[camerad] client %d sent a short CLOSE\n", c->id);
        return -1;
    }
    memcpy(&cl, p, sizeof(cl));
    pw_thread_loop_lock(g_loop);
    close_stream(c, cl.stream_id);
    pw_thread_loop_unlock(g_loop);
    return 0;
}

// read a client's input and handle its whole messages
static int client_read(struct client *c)
{
    for (int budget = 0; budget < 64; budget++) {
        size_t need = c->inlen < HDR_LEN ? HDR_LEN - c->inlen : HDR_LEN + c->hdr.length - c->inlen;
        ssize_t got = read(c->fd, c->in + c->inlen, need);
        if (got == 0) {
            return -1;
        }
        if (got < 0) {
            return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1;
        }
        c->inlen += (size_t)got;
        if (c->inlen == HDR_LEN) {
            const char *why = NULL;
            memcpy(&c->hdr, c->in, HDR_LEN);
            if (header_ok(&c->hdr, &why) != 0) {
                fprintf(stderr, "[camerad] client %d: %s (magic 0x%08x type %u length %u), dropping it\n", c->id, why,
                        c->hdr.magic, c->hdr.type, c->hdr.length);
                return -1;
            }
        }
        if (c->inlen >= HDR_LEN && c->inlen == HDR_LEN + c->hdr.length) {
            int rc = dispatch(c, c->hdr.type, c->in + HDR_LEN, c->hdr.length);
            c->inlen = 0;
            if (rc != 0) {
                return -1;
            }
        }
    }
    return 0;
}

// drop a client with its streams, queue and socket
static void drop_client(struct client *c, const char *why)
{
    if (c->fd < 0) {
        return;
    }
    pw_thread_loop_lock(g_loop);
    for (int i = 0; i < STREAMS_PER_CLIENT; i++) {
        struct cam_stream *s = &c->streams[i];
        if (s->used) {
            fprintf(stderr, "[camerad] client %d stream %u released: %llu frames, %llu dropped, %llu unreadable\n",
                    c->id, s->stream_id, (unsigned long long)s->frames, (unsigned long long)s->dropped,
                    (unsigned long long)s->unreadable);
            destroy_stream(s);
        }
    }
    pw_thread_loop_unlock(g_loop);
    pthread_mutex_lock(&g_qlock);
    c->queue_open = 0;
    while (c->head != NULL) {
        struct outmsg *next = c->head->next;
        free(c->head);
        c->head = next;
    }
    c->tail = NULL;
    c->control_bytes = 0;
    c->overflow = 0;
    pthread_mutex_unlock(&g_qlock);
    close(c->fd);
    c->fd = -1;
    fprintf(stderr, "[camerad] client %d %s\n", c->id, why);
}

// return a cgroup path after a sandbox root, or NULL
static const char *after_sandbox_root(const char *path)
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

// return true when a cgroup is strictly below a sandbox root
static int cgroup_allowed(const char *path)
{
    size_t len = strlen(path);
    if (path[0] != '/' || strstr(path, "/../") != NULL || strstr(path, "/./") != NULL ||
        (len >= 3 && strcmp(path + len - 3, "/..") == 0)) {
        return 0;
    }
    if (g_peer_cgroup != NULL) {
        size_t n = strlen(g_peer_cgroup);
        return strcmp(g_peer_cgroup, "/") == 0 ||
               (strncmp(path, g_peer_cgroup, n) == 0 && (path[n] == '\0' || path[n] == '/'));
    }
    const char *rest = after_sandbox_root(path);
    return rest != NULL && rest[0] == '/' && rest[1] != '\0';
}

// read a process's host cgroup v2 path, or return -1
static int read_cgroup(pid_t pid, char *out, size_t len)
{
    char path[64], line[PATH_MAX + 8];
    snprintf(path, sizeof(path), "/proc/%d/cgroup", (int)pid);
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return -1;
    }
    int rc = -1;
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, "0::", 3) == 0) {
            line[strcspn(line, "\n")] = '\0';
            size_t n = strlen(line + 3);
            if (n < len) {
                memcpy(out, line + 3, n + 1);
                rc = 0;
            }
            break;
        }
    }
    fclose(f);
    return rc;
}

// return true when the peer is a sandboxed cameraserver
static int peer_allowed(int fd, char *why, size_t why_len)
{
    struct ucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) {
        snprintf(why, why_len, "no peer credentials (%s)", strerror(errno));
        return 0;
    }
    if ((long)cred.uid != g_peer_uid) {
        snprintf(why, why_len, "uid %u pid %d: not uid %ld (cameraserver)", cred.uid, (int)cred.pid, g_peer_uid);
        return 0;
    }
    int pidfd = -1;
    socklen_t plen = sizeof(pidfd);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERPIDFD, &pidfd, &plen) != 0) {
        if (errno != ENOPROTOOPT && errno != EINVAL) {
            snprintf(why, why_len, "uid %u pid %d: the peer is gone (%s)", cred.uid, (int)cred.pid, strerror(errno));
            return 0;
        }
        pidfd = -1;
    }
    char cgroup[PATH_MAX];
    int readable = read_cgroup(cred.pid, cgroup, sizeof(cgroup)) == 0;
    int alive = 1;
    if (pidfd >= 0) {
        alive = syscall(SYS_pidfd_send_signal, pidfd, 0, NULL, 0) == 0 || errno == EPERM;
        close(pidfd);
    }
    if (!readable || !alive) {
        snprintf(why, why_len, "uid %u pid %d: %s", cred.uid, (int)cred.pid,
                 alive ? "its cgroup is unreadable" : "it exited before its cgroup was read");
        return 0;
    }
    if (!cgroup_allowed(cgroup)) {
        snprintf(why, why_len, "uid %u pid %d: cgroup '%s' is outside every Rhizo Android sandbox", cred.uid,
                 (int)cred.pid, cgroup);
        return 0;
    }
    return 1;
}

// log a refused connection at most once per REFUSAL_LOG_MS
static void log_refusal(const char *why)
{
    int64_t now = mono_ms();
    if (g_refusal_logged_ms != 0 && now - g_refusal_logged_ms < REFUSAL_LOG_MS) {
        g_refusals_unlogged++;
        return;
    }
    fprintf(stderr, "[camerad] refused a connection, not Android's camera provider: %s", why);
    if (g_refusals_unlogged > 0) {
        fprintf(stderr, " (%lu more refused since the last such line)", g_refusals_unlogged);
    }
    fputc('\n', stderr);
    g_refusal_logged_ms = now;
    g_refusals_unlogged = 0;
}

// accept a connection from Android's camera provider
static void accept_client(int listen_fd)
{
    int fd = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (fd < 0) {
        return;
    }
    char why[PATH_MAX + 160];
    if (!peer_allowed(fd, why, sizeof(why))) {
        log_refusal(why);
        close(fd);
        return;
    }
    struct client *c = NULL;
    for (int i = 0; i < MAX_CLIENTS && c == NULL; i++) {
        if (g_clients[i].fd < 0) {
            c = &g_clients[i];
        }
    }
    if (c == NULL) {
        fprintf(stderr, "[camerad] %d clients connected already, refusing another\n", MAX_CLIENTS);
        close(fd);
        return;
    }
    int sndbuf = SNDBUF_BYTES;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    c->fd = fd;
    c->id = g_next_client_id++;
    c->hello = 0;
    c->wants_list = 0;
    c->inlen = 0;
    pthread_mutex_lock(&g_qlock);
    c->queue_open = 1;
    c->overflow = 0;
    c->sending = 0;
    c->head = c->tail = NULL;
    c->control_bytes = 0;
    pthread_mutex_unlock(&g_qlock);
    fprintf(stderr, "[camerad] client %d connected\n", c->id);
}

// trim the heap once an ended stream's frames are freed
static void maybe_trim(void)
{
    if (!g_trim_pending) {
        return;
    }
    pthread_mutex_lock(&g_qlock);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        for (struct outmsg *q = g_clients[i].head; q != NULL; q = q->next) {
            if (q->is_frame && q->serial <= g_trim_mark) {
                pthread_mutex_unlock(&g_qlock);
                return;
            }
        }
    }
    pthread_mutex_unlock(&g_qlock);
    g_trim_pending = 0;
#ifdef __GLIBC__
    malloc_trim(0);
#endif
    if (g_verbose) {
        fprintf(stderr, "[camerad] returned freed stream memory to the system\n");
    }
}

// write the camera and stream counts beside the socket
static void write_status(int cameras, int streams)
{
    if (cameras == g_status_cameras && streams == g_status_streams) {
        return;
    }
    g_status_cameras = cameras;
    g_status_streams = streams;
    char tmp[PATH_MAX + 8];
    snprintf(tmp, sizeof(tmp), "%s.new", g_status_path);
    FILE *f = fopen(tmp, "w");
    if (f == NULL) {
        fprintf(stderr, "[camerad] could not write %s: %s\n", tmp, strerror(errno));
        return;
    }
    fprintf(f, "cameras=%d\nstreams=%d\n", cameras, streams);
    fclose(f);
    if (rename(tmp, g_status_path) != 0) {
        fprintf(stderr, "[camerad] could not write %s: %s\n", g_status_path, strerror(errno));
    }
}

// derive the status file path beside the socket
static void derive_status_path(const char *socket_path, char *out, size_t out_len)
{
    char buf[PATH_MAX - 16];
    snprintf(buf, sizeof(buf), "%s", socket_path);
    char *slash = strrchr(buf, '/');
    if (slash != NULL) {
        *slash = '\0';
        snprintf(out, out_len, "%s/status", buf);
    } else {
        snprintf(out, out_len, "status");
    }
}

// arm the timer at a monotonic deadline, disarm on 0
static void arm_timer(int64_t due_ms)
{
    struct itimerspec its;
    memset(&its, 0, sizeof(its));
    if (due_ms > 0) {
        its.it_value.tv_sec = due_ms / 1000;
        its.it_value.tv_nsec = (due_ms % 1000) * 1000000;
    }
    timerfd_settime(g_timer_fd, due_ms > 0 ? TFD_TIMER_ABSTIME : 0, &its, NULL);
}

// reap ended streams, time out opens and send due LISTs
static void service(void)
{
    int64_t now = mono_ms();
    int64_t next = 0;
    pw_thread_loop_lock(g_loop);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        struct client *c = &g_clients[i];
        if (c->fd < 0) {
            continue;
        }
        for (int j = 0; j < STREAMS_PER_CLIENT; j++) {
            struct cam_stream *s = &c->streams[j];
            if (!s->used) {
                continue;
            }
            if (!s->ended && !s->started && now >= s->deadline_ms) {
                fprintf(stderr, "[camerad] client %d stream %u: no format negotiated in %d ms (is a session "
                                "manager linking it?)\n", c->id, s->stream_id, OPEN_TIMEOUT_MS);
                end_stream(s, -ETIMEDOUT);
            }
            if (s->ended) {
                fprintf(stderr, "[camerad] client %d stream %u stopped: %s (%llu frames, %llu dropped, %llu "
                                "unreadable)\n", c->id, s->stream_id, strerror(-s->end_error),
                        (unsigned long long)s->frames, (unsigned long long)s->dropped,
                        (unsigned long long)s->unreadable);
                uint32_t id = s->stream_id;
                int error = s->end_error;
                destroy_stream(s);
                send_stopped(c, id, error);
                continue;
            }
            if (!s->started && (next == 0 || s->deadline_ms < next)) {
                next = s->deadline_ms;
            }
        }
    }
    if (g_dirty) {
        g_dirty = 0;
        schedule_list(now);
    }
    if (g_list_due_ms != 0 && now >= g_list_due_ms) {
        g_list_due_ms = 0;
        if (g_settled) {
            send_lists();
        }
    }
    if (g_list_due_ms != 0 && (next == 0 || g_list_due_ms < next)) {
        next = g_list_due_ms;
    }
    int streams = g_stream_count;
    pw_thread_loop_unlock(g_loop);
    arm_timer(next);
    write_status(g_list_valid ? g_listed_count : 0, streams);
}

// return true when a daemon listens at a socket path
static int socket_path_is_live(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return 0;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    int live = connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
    close(fd);
    return live;
}

// create, bind and listen on the daemon socket
static int make_listen_socket(const char *path)
{
    struct sockaddr_un addr;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "[camerad] socket path too long: %s\n", path);
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    if (socket_path_is_live(path)) {
        fprintf(stderr, "[camerad] %s is a live daemon's socket -- refusing; stop that daemon or pass another "
                        "socket path\n", path);
        close(fd);
        return -1;
    }
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close(fd);
        return -1;
    }
    if (chmod(path, 0666) != 0) {
        perror("chmod");
    }
    if (listen(fd, MAX_CLIENTS) != 0) {
        perror("listen");
        close(fd);
        return -1;
    }
    return fd;
}

static int g_selftest_fails = 0;

// record a self-test result
static void expect(int ok, const char *what)
{
    fprintf(stderr, "SELFTEST %s %s\n", ok ? "OK:  " : "FAIL:", what);
    g_selftest_fails += !ok;
}

// build a format's padded source image from a reference I420
static void build_yuv_source(const struct raw_format *f, const uint8_t *ref, uint32_t w, uint32_t h, uint32_t pad,
                             uint8_t *src, struct plane_view pl[3])
{
    const uint8_t *ry = ref, *ru = ref + w * h, *rv = ru + (w / 2) * (h / 2);
    uint32_t cw = w / 2, ch = h / 2;
    size_t row[3];
    uint32_t rows[3];
    uint32_t planes = format_planes(f, w, h, row, rows);
    uint8_t *at = src;
    for (uint32_t i = 0; i < planes; i++) {
        pl[i].p = at;
        pl[i].stride = row[i] + pad;
        at += pl[i].stride * rows[i];
    }
    uint8_t *p0 = (uint8_t *)pl[0].p;
    if (f->kind == PACKED_422) {
        for (uint32_t y = 0; y < h; y++) {
            for (uint32_t x = 0; x < cw; x++) {
                uint8_t *px = p0 + y * pl[0].stride + 4 * x;
                px[f->o0] = ry[y * w + 2 * x];
                px[f->o0 + 2] = ry[y * w + 2 * x + 1];
                px[f->o1] = ru[(y / 2) * cw + x];
                px[f->o2] = rv[(y / 2) * cw + x];
            }
        }
        return;
    }
    for (uint32_t y = 0; y < h; y++) {
        memcpy(p0 + y * pl[0].stride, ry + y * w, w);
    }
    for (uint32_t y = 0; y < ch; y++) {
        for (uint32_t x = 0; x < cw; x++) {
            if (f->kind == PLANAR_UV || f->kind == PLANAR_VU) {
                ((uint8_t *)pl[f->kind == PLANAR_UV ? 1 : 2].p)[y * pl[1].stride + x] = ru[y * cw + x];
                ((uint8_t *)pl[f->kind == PLANAR_UV ? 2 : 1].p)[y * pl[1].stride + x] = rv[y * cw + x];
            } else {
                uint8_t *uv = (uint8_t *)pl[1].p + y * pl[1].stride + 2 * x;
                uv[f->kind == SEMI_UV ? 0 : 1] = ru[y * cw + x];
                uv[f->kind == SEMI_UV ? 1 : 0] = rv[y * cw + x];
            }
        }
    }
}

// test the conversion of each raw format against a reference
static void selftest_conversion(void)
{
    enum { W = 8, H = 4 };
    uint8_t ref[W * H * 3 / 2], expanded[W * H * 3 / 2], out[W * H * 3 / 2], src[4096];
    for (int i = 0; i < W * H; i++) {
        ref[i] = (uint8_t)(16 + 7 * i);
    }
    for (int i = 0; i < (W / 2) * (H / 2) * 2; i++) {
        ref[W * H + i] = (uint8_t)(16 + 14 * i);
    }
    for (int i = 0; i < W * H * 3 / 2; i++) {
        double v = i < W * H ? (ref[i] - 16) * 255.0 / 219.0 : (ref[i] - 128) * 255.0 / 224.0;
        int r = (int)(v < 0 ? v - 0.5 : v + 0.5);
        expanded[i] = clamp8(i < W * H ? r : 128 + r);
    }
    expect(expanded[0] == 0 && g_expand_y[235] == 255 && g_expand_c[16] == 0 && g_expand_c[128] == 128 &&
               g_expand_c[240] == 255,
           "the range tables map limited range's ends and centre to full range's");
    static const int colours[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}};
    static const int want_yuv[4][3] = {{76, 85, 255}, {150, 44, 21}, {29, 255, 107}, {255, 128, 128}};
    for (size_t k = 0; k < N_RAW_FORMATS; k++) {
        const struct raw_format *f = &RAW_FORMATS[k];
        struct plane_view pl[3];
        char what[112];
        if (f->kind == MJPEG) {
            continue;
        }
        memset(src, 0xee, sizeof(src));
        memset(out, 0, sizeof(out));
        if (f->kind != PACKED_RGB) {
            build_yuv_source(f, ref, W, H, 3, src, pl);
            convert_frame(f, pl, W, H, 1, out);
            snprintf(what, sizeof(what), "%s full range with padded rows passes through to I420 unchanged", f->name);
            expect(memcmp(out, ref, sizeof(ref)) == 0, what);
            convert_frame(f, pl, W, H, 0, out);
            snprintf(what, sizeof(what), "%s limited range is expanded to full range", f->name);
            expect(memcmp(out, expanded, sizeof(expanded)) == 0, what);
            continue;
        }
        pl[0].p = src;
        pl[0].stride = (size_t)W * f->bpp + 5;
        for (int y = 0; y < H; y++) {
            for (int x = 0; x < W; x++) {
                const int *rgb = colours[(x / 2) % 4];
                uint8_t *px = src + y * pl[0].stride + (size_t)x * f->bpp;
                px[f->o0] = (uint8_t)rgb[0], px[f->o1] = (uint8_t)rgb[1], px[f->o2] = (uint8_t)rgb[2];
            }
        }
        convert_frame(f, pl, W, H, 0, out);
        int ok = 1;
        for (int bx = 0; bx < W / 2; bx++) {
            const int *want = want_yuv[bx % 4];
            int yv = out[bx * 2], uv = out[W * H + bx], vv = out[W * H + (W / 2) * (H / 2) + bx];
            ok &= abs(yv - want[0]) <= 1 && abs(uv - want[1]) <= 1 && abs(vv - want[2]) <= 1;
        }
        snprintf(what, sizeof(what), "%s converts red, green, blue and white to full-range BT.601", f->name);
        expect(ok, what);
    }
}

// test plane resolution on fake buffers
static void selftest_planes(void)
{
    static uint8_t mem[4096];
    struct spa_chunk chunks[3];
    struct spa_data datas[3];
    struct spa_buffer buf = {0, 3, NULL, datas};
    struct plane_view pl[3];
    const struct raw_format *nv12 = raw_format_of(SPA_VIDEO_FORMAT_NV12), *i420 = raw_format_of(SPA_VIDEO_FORMAT_I420);
    memset(datas, 0, sizeof(datas));
    memset(chunks, 0, sizeof(chunks));
    for (int i = 0; i < 3; i++) {
        datas[i].data = mem + i * 1024;
        datas[i].maxsize = 1024;
        datas[i].chunk = &chunks[i];
    }
    buf.n_datas = 1;
    chunks[0] = (struct spa_chunk){16, 20 * 6 * 3 / 2, 20, 0};
    expect(map_planes(&buf, nv12, 16, 6, pl) == 0 && pl[0].p == mem + 16 && pl[0].stride == 20 &&
               pl[1].p == mem + 16 + 20 * 6 && pl[1].stride == 20,
           "NV12 in one block: the UV plane follows the padded luma at the luma stride");
    chunks[0] = (struct spa_chunk){0, 20 * 6 * 3 / 2, 20, 0};
    expect(map_planes(&buf, i420, 16, 6, pl) == 0 && pl[1].p == mem + 120 && pl[1].stride == 10 &&
               pl[2].p == mem + 120 + 30 && pl[2].stride == 10,
           "I420 in one block: U then V follow the luma at half its stride");
    chunks[0] = (struct spa_chunk){1000, 100, 16, 0};
    expect(map_planes(&buf, nv12, 16, 6, pl) < 0, "a block that runs past maxsize is refused");
    chunks[0] = (struct spa_chunk){2000, 100, 16, 0};
    expect(map_planes(&buf, nv12, 16, 6, pl) < 0, "an offset past maxsize is refused");
    chunks[0] = (struct spa_chunk){0, 100, -16, 0};
    expect(map_planes(&buf, nv12, 16, 6, pl) < 0, "a negative stride is refused");
    chunks[0] = (struct spa_chunk){0, 100, 8, 0};
    expect(map_planes(&buf, nv12, 16, 6, pl) < 0, "a stride shorter than a row is refused");
    buf.n_datas = 3;
    chunks[0] = (struct spa_chunk){4, 24 * 6, 24, 0};
    chunks[1] = (struct spa_chunk){0, 12 * 3, 12, 0};
    chunks[2] = (struct spa_chunk){8, 12 * 3, 12, 0};
    expect(map_planes(&buf, i420, 16, 6, pl) == 0 && pl[0].p == mem + 4 && pl[1].p == mem + 1024 &&
               pl[2].p == mem + 2048 + 8 && pl[2].stride == 12,
           "I420 in three datas: each plane at a separate chunk offset and stride");
    chunks[2] = (struct spa_chunk){8, 10, 12, 0};
    expect(map_planes(&buf, i420, 16, 6, pl) < 0, "a plane whose chunk is shorter than its rows is refused");
}

// test that keys fit the protocol as unique whole UTF-8
static void selftest_keys(void)
{
    char key[RHIZO_CAMERA_KEY_LEN], other[RHIZO_CAMERA_KEY_LEN], name[RHIZO_CAMERA_NAME_LEN];
    make_key("v4l2_input.pci-0000_00_14.0-usb-0_5_1.0", key);
    expect(strcmp(key, "v4l2_input.pci-0000_00_14.0-usb-0_5_1.0") == 0, "a short node.name is the key unchanged");
    const char *a = "libcamera_input.a-very-long-camera-name-that-does-not-fit-the-protocol-key-field-camera-one";
    const char *b = "libcamera_input.a-very-long-camera-name-that-does-not-fit-the-protocol-key-field-camera-two";
    make_key(a, key);
    make_key(b, other);
    expect(strlen(key) == RHIZO_CAMERA_KEY_LEN - 1 && strncmp(key, a, 54) == 0 && key[54] == '~',
           "a long node.name keeps its head and ends in a hash, within the key field");
    expect(strcmp(key, other) != 0, "two long names sharing a head get different keys");
    char utf[200];
    memset(utf, 'x', sizeof(utf));
    memcpy(utf + 53, "\xc3\xa9", 2);
    utf[sizeof(utf) - 1] = '\0';
    make_key(utf, key);
    expect(strlen(key) == 53 + 9 && key[53] == '~', "a cut never splits a UTF-8 sequence");
    memset(utf, 'n', sizeof(utf));
    memcpy(utf + 126, "\xe2\x82\xac", 3);
    utf[sizeof(utf) - 1] = '\0';
    make_name(utf, name);
    expect(strlen(name) == 126, "a long description is cut before a UTF-8 sequence it would split");
}

// test the grouping of offers into modes
static void selftest_modes(void)
{
    struct candidate cand[64];
    struct mode_entry modes[RHIZO_CAMERA_MAX_MODES];
    uint32_t n = 0;
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 640, 480, 15, 1, 0, 0, 0};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 320, 240, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_NV12, 640, 480, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 641, 480, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 8192, 8192, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_I420, 320, 240, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 160, 120, 0, 1, 0, 0, 0};
    uint32_t count = group_modes(cand, n, modes, RHIZO_CAMERA_MAX_MODES);
    expect(count == 2 && modes[0].mode.width == 640 && modes[0].mode.fps_num == 30 && modes[0].n_formats == 1 &&
               modes[0].formats[0] == SPA_VIDEO_FORMAT_NV12,
           "a size's mode is its best rate, with only the formats that reach it");
    expect(count == 2 && modes[1].mode.width == 320 && modes[1].n_formats == 2 &&
               modes[1].formats[0] == SPA_VIDEO_FORMAT_I420 && modes[1].formats[1] == SPA_VIDEO_FORMAT_YUY2,
           "formats of one mode are in preference order; odd, oversized and rateless sizes are left out");
    n = 0;
    for (uint32_t i = 0; i < 40; i++) {
        cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 64 + 16 * i, 48 + 12 * i, 30, 1, 0, 0, 0};
    }
    count = group_modes(cand, n, modes, RHIZO_CAMERA_MAX_MODES);
    expect(count == RHIZO_CAMERA_MAX_MODES && modes[0].mode.width == 64 + 16 * 39 &&
               modes[RHIZO_CAMERA_MAX_MODES - 1].mode.width == 64 + 16 * 8,
           "forty sizes become the thirty-two largest, largest first");
    n = 0;
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 640, 480, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){FORMAT_MJPG, 640, 480, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 1280, 720, 10, 1, 0, 0, 0};
    cand[n++] = (struct candidate){FORMAT_MJPG, 1280, 720, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){FORMAT_MJPG, 1920, 1080, 30, 1, 0, 0, 0};
    cand[n++] = (struct candidate){FORMAT_MJPG, 320, 240, 15, 1, 0, 0, 0};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_NV12, 320, 240, 30, 1, 0, 0, 0};
    count = group_modes(cand, n, modes, RHIZO_CAMERA_MAX_MODES);
    expect(count == 4 && modes[0].mode.width == 1920 && modes[0].formats[0] == FORMAT_MJPG && modes[0].n_formats == 1 &&
               modes[1].mode.width == 1280 && modes[1].formats[0] == FORMAT_MJPG && modes[1].mode.fps_num == 30 &&
               modes[1].n_formats == 1,
           "a size only MJPG offers, or offers faster than raw, is an MJPG mode");
    expect(count == 4 && modes[2].mode.width == 640 && modes[2].formats[0] == SPA_VIDEO_FORMAT_YUY2 &&
               modes[2].n_formats == 1 && modes[3].mode.width == 320 && modes[3].formats[0] == SPA_VIDEO_FORMAT_NV12 &&
               modes[3].mode.fps_num == 30,
           "a size raw offers as fast as MJPG, or faster, stays raw, with no MJPG among its formats");
}

// test the parsing of EnumFormat pods
static void selftest_pods(void)
{
    uint8_t buffer[1024];
    struct candidate cand[64];
    uint32_t n;
    struct spa_pod_builder b;
    const struct spa_pod *pod;
    struct spa_fraction def = SPA_FRACTION(25, 1), zero = SPA_FRACTION(0, 1), open = SPA_FRACTION(INT32_MAX, 1);

    b = (struct spa_pod_builder)SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    pod = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(3, SPA_VIDEO_FORMAT_YUY2, SPA_VIDEO_FORMAT_YUY2,
                                                        SPA_VIDEO_FORMAT_GRAY8),
        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(640, 480)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_ENUM_Fraction(3, &SPA_FRACTION(15, 1), &SPA_FRACTION(15, 1),
                                                                 &SPA_FRACTION(30, 1)));
    n = 0;
    collect_candidates(pod, cand, &n);
    expect(n == 2 && cand[0].format == SPA_VIDEO_FORMAT_YUY2 && cand[0].fps_num == 15 && cand[1].fps_num == 30 &&
               cand[0].rate_kind == RATE_FIXED && cand[1].rate_kind == RATE_FIXED,
           "an enum of rates gives each rate once, and a format the daemon cannot convert is skipped");

    b = (struct spa_pod_builder)SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    pod = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_NV12),
        SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(640, 480), &SPA_RECTANGLE(160, 120),
                                                              &SPA_RECTANGLE(1280, 720)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&def, &zero, &open));
    n = 0;
    collect_candidates(pod, cand, &n);
    int sizes_ok = n == 7 && cand[0].width == 1280 && cand[0].height == 720;
    for (uint32_t i = 0; i < n; i++) {
        sizes_ok &= cand[i].width <= 1280 && cand[i].height <= 720 && cand[i].width >= 160 && cand[i].height >= 120;
    }
    expect(sizes_ok, "a size range gives its largest size and the common sizes inside it");
    expect(n > 0 && cand[0].fps_num == NOMINAL_FPS && cand[0].fps_den == 1 && cand[0].rate_kind == RATE_NOMINAL,
           "an open-ended rate range (libcamera's 0 to INT32_MAX) gives a nominal rate");

    b = (struct spa_pod_builder)SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    pod = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_I420),
        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(320, 240)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&zero));
    n = 0;
    collect_candidates(pod, cand, &n);
    expect(n == 1 && cand[0].fps_num == NOMINAL_FPS && cand[0].rate_kind == RATE_NOMINAL,
           "a variable rate (0/1) gives a nominal rate");

    b = (struct spa_pod_builder)SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    pod = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_YUY2),
        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(320, 240)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(60, 1), &SPA_FRACTION(10, 1),
                                                                  &SPA_FRACTION(60, 1)));
    n = 0;
    collect_candidates(pod, cand, &n);
    expect(n == 1 && cand[0].fps_num == 60 && cand[0].rate_kind == RATE_RANGE && cand[0].lo_num == 10,
           "a bounded rate range gives its top, with its low end, as a range");

    b = (struct spa_pod_builder)SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    pod = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_mjpg),
        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(1920, 1080)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(30, 1)));
    n = 0;
    expect(collect_candidates(pod, cand, &n) == 0 && n == 1 && cand[0].format == FORMAT_MJPG && cand[0].width == 1920,
           "an MJPG format gives a mode, as MJPG");

    b = (struct spa_pod_builder)SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    pod = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_h264),
        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(1920, 1080)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(30, 1)));
    n = 0;
    expect(collect_candidates(pod, cand, &n) == 1 && n == 0, "an H264 format is reported compressed and gives no mode");

    b = (struct spa_pod_builder)SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    pod = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_Id(FORMAT_MJPG),
        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(320, 240)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(30, 1)));
    n = 0;
    collect_candidates(pod, cand, &n);
    expect(n == 0, "a raw pod naming the daemon's private MJPG id gives no mode");
}

// test the rate an OPEN gets
static void selftest_rates(void)
{
    struct candidate cand[16];
    struct mode_entry modes[RHIZO_CAMERA_MAX_MODES];
    uint32_t n = 0, format, kind;
    struct spa_fraction rate;
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 640, 480, 60, 1, RATE_FIXED, 60, 1};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 640, 480, 30, 1, RATE_FIXED, 30, 1};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_NV12, 640, 480, 60, 1, RATE_FIXED, 60, 1};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_NV12, 640, 480, 25, 1, RATE_FIXED, 25, 1};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 320, 240, 60, 1, RATE_RANGE, 15, 1};
    cand[n++] = (struct candidate){SPA_VIDEO_FORMAT_YUY2, 320, 240, 10, 1, RATE_FIXED, 10, 1};
    uint32_t count = group_modes(cand, n, modes, RHIZO_CAMERA_MAX_MODES);
    expect(count == 2 && modes[0].n_rates == 4 && modes[1].n_rates == 2,
           "a mode keeps every rate its formats offer at its size");
    const struct mode_entry *m = &modes[0];
    choose_rate(m, SPA_FRACTION(24, 1), &format, &rate, &kind);
    expect(format == SPA_VIDEO_FORMAT_NV12 && rate.num == 25, "24 fps gets 25, the lowest offered at or above it");
    choose_rate(m, SPA_FRACTION(30, 1), &format, &rate, &kind);
    expect(format == SPA_VIDEO_FORMAT_YUY2 && rate.num == 30, "30 fps gets 30");
    choose_rate(m, SPA_FRACTION(30000, 1001), &format, &rate, &kind);
    expect(rate.num == 30 && rate.denom == 1, "29.97 fps gets 30");
    choose_rate(m, SPA_FRACTION(60, 1), &format, &rate, &kind);
    expect(format == SPA_VIDEO_FORMAT_NV12 && rate.num == 60, "60 fps gets 60, the preferred format on a tie");
    m = &modes[1];
    choose_rate(m, SPA_FRACTION(24, 1), &format, &rate, &kind);
    expect(rate.num == 24 && kind == RATE_RANGE, "inside a range the request itself is asked for");
    choose_rate(m, SPA_FRACTION(12, 1), &format, &rate, &kind);
    expect(rate.num == 15 && kind == RATE_RANGE, "below a range's low end its low end is asked for, not a slower rate");
    choose_rate(m, SPA_FRACTION(5, 1), &format, &rate, &kind);
    expect(rate.num == 10 && kind == RATE_FIXED, "the slowest fixed rate at or above the request beats a range's end");
}

// test the message header checks
static void selftest_headers(void)
{
    const char *why = NULL;
    struct rhizo_camera_msg_header h = {RHIZO_CAMERA_MAGIC, RHIZO_CAMERA_OPEN, sizeof(struct rhizo_camera_open), 0};
    expect(header_ok(&h, &why) == 0, "an OPEN header is accepted");
    h.magic = 0x12345678;
    expect(header_ok(&h, &why) < 0 && strcmp(why, "bad magic") == 0, "a bad magic is refused");
    h.magic = RHIZO_CAMERA_MAGIC;
    h.type = RHIZO_CAMERA_FRAME;
    expect(header_ok(&h, &why) < 0, "a daemon-to-HAL type from the HAL is refused");
    h.type = RHIZO_CAMERA_HELLO;
    h.length = CLIENT_PAYLOAD_MAX + 1;
    expect(header_ok(&h, &why) < 0 && strcmp(why, "message too long") == 0, "an oversized payload is refused");
    expect(facing_of("front", NULL) == RHIZO_CAMERA_FACING_FRONT && facing_of("back", NULL) == RHIZO_CAMERA_FACING_BACK &&
               facing_of("external", NULL) == RHIZO_CAMERA_FACING_EXTERNAL &&
               facing_of(NULL, "/dev/video0/../../etc") == RHIZO_CAMERA_FACING_EXTERNAL,
           "facing follows api.libcamera.location, and a malformed v4l2 path is external");
}

// test the sandbox cgroup checks
static void selftest_peer_cgroups(void)
{
    static const struct {
        const char *path;
        int want;
    } cases[] = {
        {"/system.slice/androidd.service/android/uid_1047/pid_812", 1},
        {"/system.slice/androidd.service/android/init", 1},
        {"/system.slice/androidd@3.service/android/uid_1047/pid_9", 1},
        {"/rhizo/uid_1047/pid_812", 1},
        {"/rhizo-2/init", 1},
        {"/system.slice/androidd.service/android", 0},
        {"/system.slice/androidd.service/launcher", 0},
        {"/system.slice/androidd.service/androidx/uid_1047", 0},
        {"/system.slice/androidd@.service/android/init", 0},
        {"/system.slice/androidd@3x.service/android/init", 0},
        {"/system.slice/androiddx.service/android/init", 0},
        {"/rhizo", 0},
        {"/rhizo/", 0},
        {"/rhizo-/init", 0},
        {"/rhizox/init", 0},
        {"/rhizo-host/init", 0},
        {"/rhizo/../user.slice/user-1000.slice", 0},
        {"/user.slice/user-1000.slice/user@1000.service/app.slice/rhizo/init", 0},
        {"rhizo/init", 0},
        {"/", 0},
    };
    int bad = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        if (cgroup_allowed(cases[i].path) != cases[i].want) {
            fprintf(stderr, "SELFTEST: cgroup '%s' %s\n", cases[i].path, cases[i].want ? "refused" : "admitted");
            bad++;
        }
    }
    expect(bad == 0, "a peer cgroup is admitted only strictly below /rhizo[-N] or androidd[@N].service/android");
    g_peer_cgroup = "/user.slice/user-1000.slice";
    expect(cgroup_allowed("/user.slice/user-1000.slice") && cgroup_allowed("/user.slice/user-1000.slice/x") &&
               !cgroup_allowed("/user.slice/user-1000.slicex") && !cgroup_allowed("/rhizo/init"),
           "a test prefix admits that cgroup and its children only, and replaces the sandbox rule");
    g_peer_cgroup = NULL;
}

// run the self-test and return nonzero on failure
static int run_selftest(void)
{
    init_range_tables();
    selftest_conversion();
    selftest_planes();
    selftest_keys();
    selftest_modes();
    selftest_pods();
    selftest_rates();
    selftest_peer_cgroups();
    selftest_headers();
    if (g_selftest_fails > 0) {
        fprintf(stderr, "SELFTEST: %d case(s) FAILED\n", g_selftest_fails);
        return 1;
    }
    fprintf(stderr, "SELFTEST: all cases passed\n");
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [--socket PATH] [--peer-uid UID] [--peer-cgroup PATH] [-v]\n"
            "       %s --status [--socket PATH]\n"
            "       %s --selftest\n",
            argv0, argv0, argv0);
}

// print the status file written by the running daemon
static int print_status(const char *socket_path)
{
    char status_path[PATH_MAX];
    derive_status_path(socket_path, status_path, sizeof(status_path));
    FILE *f = fopen(status_path, "r");
    if (f == NULL) {
        printf("cameras=0\nstreams=0\n");
        return 0;
    }
    char line[128];
    while (fgets(line, sizeof(line), f) != NULL) {
        fputs(line, stdout);
    }
    fclose(f);
    return 0;
}

// run the camera daemon
int main(int argc, char *argv[])
{
    int do_selftest = 0, do_status = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            g_socket_path = argv[++i];
        } else if (strcmp(argv[i], "--peer-uid") == 0 && i + 1 < argc) {
            g_peer_uid = strtol(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--peer-cgroup") == 0 && i + 1 < argc) {
            g_peer_cgroup = argv[++i];
        } else if (strcmp(argv[i], "-v") == 0) {
            g_verbose = 1;
        } else if (strcmp(argv[i], "--selftest") == 0) {
            do_selftest = 1;
        } else if (strcmp(argv[i], "--status") == 0) {
            do_status = 1;
        } else {
            usage(argv[0]);
            return 2;
        }
    }
    if (do_selftest) {
        return run_selftest();
    }
    if (do_status) {
        return print_status(g_socket_path);
    }

    setvbuf(stderr, NULL, _IOLBF, 0);
#ifdef __GLIBC__
    // malloc_trim never releases the top of a glibc thread arena
    mallopt(M_ARENA_MAX, 1);
#endif
    init_range_tables();
    derive_status_path(g_socket_path, g_status_path, sizeof(g_status_path));
    g_stop_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    g_wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    g_timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (g_stop_fd < 0 || g_wake_fd < 0 || g_timer_fd < 0) {
        perror("eventfd/timerfd");
        return 1;
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        g_clients[i].fd = -1;
    }

    pw_init(&argc, &argv);
    g_loop = pw_thread_loop_new("rhizo-camerad", NULL);
    if (g_loop == NULL) {
        fprintf(stderr, "[camerad] pw_thread_loop_new failed\n");
        return 1;
    }
    g_context = pw_context_new(pw_thread_loop_get_loop(g_loop), NULL, 0);
    if (g_context == NULL) {
        fprintf(stderr, "[camerad] pw_context_new failed\n");
        return 1;
    }
    if (pw_thread_loop_start(g_loop) != 0) {
        fprintf(stderr, "[camerad] pw_thread_loop_start failed\n");
        return 1;
    }
    pw_thread_loop_lock(g_loop);
    g_core = pw_context_connect(g_context, NULL, 0);
    if (g_core != NULL) {
        pw_core_add_listener(g_core, &g_core_listener, &core_events, NULL);
        g_registry = pw_core_get_registry(g_core, PW_VERSION_REGISTRY, 0);
        pw_registry_add_listener(g_registry, &g_registry_listener, &registry_events, NULL);
        issue_sync();
    }
    pw_thread_loop_unlock(g_loop);
    if (g_core == NULL || g_registry == NULL) {
        fprintf(stderr, "[camerad] cannot connect to PipeWire (is it running?)\n");
        return 1;
    }

    int listen_fd = make_listen_socket(g_socket_path);
    if (listen_fd < 0) {
        return 1;
    }
    write_status(0, 0);
    fprintf(stderr, "[camerad] serving cameras on %s (protocol %u, pipewire %s)\n", g_socket_path,
            RHIZO_CAMERA_PROTOCOL_VERSION, pw_get_library_version());
    if (g_peer_uid != AID_CAMERASERVER || g_peer_cgroup != NULL) {
        fprintf(stderr, "[camerad] TEST OVERRIDE: accepting uid %ld in cgroup %s, not the camera provider\n",
                g_peer_uid, g_peer_cgroup != NULL ? g_peer_cgroup : "(the sandbox roots)");
    } else {
        fprintf(stderr, "[camerad] accepting uid %d (cameraserver) inside a Rhizo Android sandbox's cgroup only\n",
                AID_CAMERASERVER);
    }

    while (!g_stop) {
        struct pollfd fds[MAX_CLIENTS + 4];
        int idx[MAX_CLIENTS + 4];
        int n = 0;
        fds[n] = (struct pollfd){g_stop_fd, POLLIN, 0}, idx[n++] = -1;
        fds[n] = (struct pollfd){g_wake_fd, POLLIN, 0}, idx[n++] = -2;
        fds[n] = (struct pollfd){g_timer_fd, POLLIN, 0}, idx[n++] = -3;
        fds[n] = (struct pollfd){listen_fd, POLLIN, 0}, idx[n++] = -4;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (g_clients[i].fd >= 0) {
                short events = POLLIN | (client_has_output(&g_clients[i]) ? POLLOUT : 0);
                fds[n] = (struct pollfd){g_clients[i].fd, events, 0}, idx[n++] = i;
            }
        }
        if (poll(fds, (nfds_t)n, -1) < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("poll");
            break;
        }
        for (int k = 0; k < n; k++) {
            if (fds[k].revents == 0) {
                continue;
            }
            if (idx[k] == -2 || idx[k] == -3) {
                uint64_t drained;
                ssize_t ignore = read(fds[k].fd, &drained, sizeof(drained));
                (void)ignore;
                continue;
            }
            if (idx[k] == -4) {
                accept_client(listen_fd);
                continue;
            }
            if (idx[k] < 0) {
                continue;
            }
            struct client *c = &g_clients[idx[k]];
            if (c->fd < 0) {
                continue;
            }
            if ((fds[k].revents & (POLLIN | POLLHUP | POLLERR)) && client_read(c) != 0) {
                drop_client(c, "disconnected");
                continue;
            }
            if ((fds[k].revents & POLLOUT) && flush_client(c) != 0) {
                drop_client(c, "stopped reading (send failed)");
            }
        }
        service();
        for (int i = 0; i < MAX_CLIENTS; i++) {
            struct client *c = &g_clients[i];
            if (c->fd < 0) {
                continue;
            }
            pthread_mutex_lock(&g_qlock);
            int overflow = c->overflow;
            pthread_mutex_unlock(&g_qlock);
            if (overflow) {
                drop_client(c, "left more than a megabyte of messages unread, dropping it");
            } else if (flush_client(c) != 0) {
                drop_client(c, "stopped reading (send failed)");
            }
        }
        maybe_trim();
    }

    for (int i = 0; i < MAX_CLIENTS; i++) {
        drop_client(&g_clients[i], "closed at shutdown");
    }
    close(listen_fd);
    unlink(g_socket_path);
    pw_thread_loop_lock(g_loop);
    for (int i = 0; i < MAX_NODES; i++) {
        if (g_nodes[i].used) {
            forget_port(&g_nodes[i]);
            spa_hook_remove(&g_nodes[i].listener);
            pw_proxy_destroy(g_nodes[i].proxy);
            g_nodes[i].used = 0;
        }
    }
    pw_proxy_destroy((struct pw_proxy *)g_registry);
    pw_thread_loop_unlock(g_loop);
    pw_thread_loop_stop(g_loop);
    pw_core_disconnect(g_core);
    pw_context_destroy(g_context);
    pw_thread_loop_destroy(g_loop);
    pw_deinit();
    fprintf(stderr, "[camerad] stopped%s\n", g_pipewire_lost ? ": lost the connection to PipeWire" : "");
    return g_pipewire_lost ? 1 : 0;
}

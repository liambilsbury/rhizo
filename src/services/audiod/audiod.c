// relay the audio HAL's streams through PipeWire
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/result.h>

#define MAX_CLIENTS 16
#define RING_BYTES (1 << 20)
#define LABEL_MAX 64
#define NAME_MAX_ 128
#define HEADER_MAX 256
#define IDLE_TIMEOUT_S_DEFAULT 20

#define AUDIOD_MAX_BUS 4

static const char *g_socket_path = "/run/rhizo-audio/audiod";
static int g_playback_socket = 1;
static const char *g_mic_socket_path = NULL;
static const char *g_map_path = "/run/rhizo-audio-map";
static const char *g_sink_prefix = "rhizo_sink_";
static int g_verbose = 0;
static int g_idle_timeout_s = IDLE_TIMEOUT_S_DEFAULT;
static time_t g_map_mtime = -1;

enum client_state { CLIENT_HEADER = 0, CLIENT_STREAM = 1 };
enum label_rule { LABELS_ANY = 0, LABELS_PLAYBACK = 1, LABELS_MIC = 2 };

struct client {
    int fd;
    int state;
    int is_mic;
    char hdrbuf[HEADER_MAX];
    size_t hdrlen;
    time_t last_activity;

    char label[LABEL_MAX];
    char app[NAME_MAX_];
    int rate;
    int channels;

    pthread_mutex_t lock;
    unsigned char ring[RING_BYTES];
    size_t head;
    size_t tail;

    unsigned long long bytes_in;
    unsigned long long bytes_out;
    unsigned long long underruns;
    unsigned long long overruns;

    struct pw_stream *stream;
    struct spa_hook listener;
};

static struct client g_clients[MAX_CLIENTS];
static struct pw_thread_loop *g_loop;
static struct pw_context *g_context;
static struct pw_core *g_core;
static volatile sig_atomic_t g_stop = 0;
static int g_stop_fd = -1;

static int g_stream_count = 0;
static int g_capture_count = 0;
static int g_wake_fd = -1;
static char g_status_path[PATH_MAX];

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

// write the stream count to the status file
static void write_status(void)
{
    if (g_status_path[0] == '\0') {
        return;
    }
    FILE *f = fopen(g_status_path, "w");
    if (f == NULL) {
        fprintf(stderr, "[audiod] could not write %s: %s\n", g_status_path, strerror(errno));
        return;
    }
    fprintf(f, "streams=%d\ncaptures=%d\n", g_stream_count, g_capture_count);
    fclose(f);
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

// return the monotonic time in seconds
static time_t mono_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

// return the mtime of the bus map, or 0 when it cannot be read
static time_t map_mtime(void)
{
    struct stat st;
    return stat(g_map_path, &st) == 0 ? st.st_mtime : 0;
}

// return the number of bytes queued in the ring
static size_t ring_available(const struct client *c)
{
    return (c->head - c->tail) % RING_BYTES;
}

// copy bytes into the ring, dropping what does not fit
static void ring_write(struct client *c, const unsigned char *data, size_t len)
{
    pthread_mutex_lock(&c->lock);
    size_t free_bytes = RING_BYTES - 1 - ring_available(c);
    if (len > free_bytes) {
        c->overruns++;
        len = free_bytes;
    }
    for (size_t i = 0; i < len; i++) {
        c->ring[(c->head + i) % RING_BYTES] = data[i];
    }
    c->head = (c->head + len) % RING_BYTES;
    c->bytes_in += len;
    pthread_mutex_unlock(&c->lock);
}

// copy bytes out of the ring
static size_t ring_read(struct client *c, unsigned char *out, size_t want)
{
    pthread_mutex_lock(&c->lock);
    size_t have = ring_available(c);
    size_t n = want < have ? want : have;
    for (size_t i = 0; i < n; i++) {
        out[i] = c->ring[(c->tail + i) % RING_BYTES];
    }
    c->tail = (c->tail + n) % RING_BYTES;
    c->bytes_out += n;
    if (n < want) {
        c->underruns++;
    }
    pthread_mutex_unlock(&c->lock);
    return n;
}

// fill the PipeWire buffer from the ring
static void on_process(void *userdata)
{
    struct client *c = userdata;
    struct pw_buffer *b = pw_stream_dequeue_buffer(c->stream);
    if (b == NULL) {
        return;
    }
    struct spa_buffer *buf = b->buffer;
    unsigned char *dst = buf->datas[0].data;
    if (dst == NULL) {
        pw_stream_queue_buffer(c->stream, b);
        return;
    }
    size_t stride = (size_t)c->channels * 2;
    size_t want = buf->datas[0].maxsize;
    if (b->requested != 0) {
        size_t requested = b->requested * stride;
        if (requested < want) {
            want = requested;
        }
    }
    size_t got = ring_read(c, dst, want);
    if (got < want) {
        memset(dst + got, 0, want - got);
    }
    buf->datas[0].chunk->offset = 0;
    buf->datas[0].chunk->stride = (int32_t)stride;
    buf->datas[0].chunk->size = (uint32_t)want;
    pw_stream_queue_buffer(c->stream, b);
}

// log the stream state changes
static void on_stream_state_changed(void *userdata, enum pw_stream_state old,
                                     enum pw_stream_state state, const char *error)
{
    struct client *c = userdata;
    fprintf(stderr, "[audiod] %s stream state %s -> %s%s%s\n", c->label,
            pw_stream_state_as_string(old), pw_stream_state_as_string(state),
            error ? ": " : "", error ? error : "");
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_stream_state_changed,
    .process = on_process,
};

// copy captured whole frames into the ring
static void ring_write_capture(struct client *c, const unsigned char *data, size_t len)
{
    size_t frame = (size_t)c->channels * 2;
    size_t cap = (size_t)c->rate * frame / 4;
    len -= len % frame;
    pthread_mutex_lock(&c->lock);
    size_t have = ring_available(c);
    size_t room = have < cap ? cap - have : 0;
    if (len > room) {
        c->overruns++;
        len = room - room % frame;
    }
    for (size_t i = 0; i < len; i++) {
        c->ring[(c->head + i) % RING_BYTES] = data[i];
    }
    c->head = (c->head + len) % RING_BYTES;
    c->bytes_in += len;
    pthread_mutex_unlock(&c->lock);
}

// queue a captured buffer and wake the poll loop
static void on_capture_process(void *userdata)
{
    struct client *c = userdata;
    struct pw_buffer *b = pw_stream_dequeue_buffer(c->stream);
    if (b == NULL) {
        return;
    }
    struct spa_data *d = &b->buffer->datas[0];
    if (d->data != NULL && d->chunk != NULL && d->chunk->size > 0) {
        uint32_t off = SPA_MIN(d->chunk->offset, d->maxsize);
        uint32_t size = SPA_MIN(d->chunk->size, d->maxsize - off);
        ring_write_capture(c, (const unsigned char *)d->data + off, size);
        uint64_t one = 1;
        ssize_t ignore = write(g_wake_fd, &one, sizeof(one));
        (void)ignore;
    }
    pw_stream_queue_buffer(c->stream, b);
}

static const struct pw_stream_events capture_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_stream_state_changed,
    .process = on_capture_process,
};

// create and connect a microphone client's PipeWire capture stream
static int start_capture(struct client *c)
{
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_CLASS, "Stream/Input/Audio",
        NULL);
    pw_properties_set(props, PW_KEY_NODE_NAME, "rhizo.mic");
    pw_properties_set(props, PW_KEY_NODE_DESCRIPTION, "Android microphone");
    pw_properties_set(props, PW_KEY_APP_NAME, "Android");
    pw_properties_set(props, PW_KEY_MEDIA_NAME, "Android microphone");

    c->stream = pw_stream_new(g_core, "rhizo.mic", props);
    if (c->stream == NULL) {
        fprintf(stderr, "[audiod] pw_stream_new failed for the microphone\n");
        return -1;
    }
    pw_stream_add_listener(c->stream, &c->listener, &capture_events, c);

    uint8_t params_buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(params_buffer, sizeof(params_buffer));
    struct spa_audio_info_raw info = {
        .format = SPA_AUDIO_FORMAT_S16_LE,
        .rate = (uint32_t)c->rate,
        .channels = (uint32_t)c->channels,
    };
    if (c->channels == 2) {
        info.position[0] = SPA_AUDIO_CHANNEL_FL;
        info.position[1] = SPA_AUDIO_CHANNEL_FR;
    }
    const struct spa_pod *params[1];
    params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);

    int res = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                                PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS |
                                    PW_STREAM_FLAG_RT_PROCESS,
                                params, 1);
    if (res < 0) {
        fprintf(stderr, "[audiod] pw_stream_connect failed for the microphone: %s (rate=%d channels=%d)\n",
                spa_strerror(res), c->rate, c->channels);
        return -1;
    }
    fprintf(stderr, "[audiod] capture node 'rhizo.mic' up (default source, %d Hz %d ch)\n", c->rate,
            c->channels);
    g_capture_count++;
    write_status();
    return 0;
}

// send the queued capture to a microphone client without blocking
static int flush_capture(struct client *c)
{
    int rc = 0;
    pthread_mutex_lock(&c->lock);
    while (ring_available(c) > 0) {
        size_t have = ring_available(c);
        size_t run = RING_BYTES - c->tail;
        if (run > have) {
            run = have;
        }
        ssize_t w = send(c->fd, c->ring + c->tail, run, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (w < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                rc = -1;
            }
            break;
        }
        c->tail = (c->tail + (size_t)w) % RING_BYTES;
        c->bytes_out += (size_t)w;
    }
    pthread_mutex_unlock(&c->lock);
    return rc;
}

// look up the package for a bus, falling back to the bus name
static void lookup_app_name(const char *label, char *out, size_t out_len)
{
    strncpy(out, label, out_len - 1);
    out[out_len - 1] = '\0';
    FILE *f = fopen(g_map_path, "r");
    if (f == NULL) {
        fprintf(stderr, "[audiod] %s found no map yet (%s), naming the node for its bus\n", label,
                errno == ENOENT ? "not created" : strerror(errno));
        return;
    }
    char line[256];
    while (fgets(line, sizeof(line), f) != NULL) {
        char bus[LABEL_MAX], pkg[NAME_MAX_];
        if (sscanf(line, "%63s %127s", bus, pkg) == 2 && strcmp(bus, label) == 0) {
            snprintf(out, out_len, "%s", pkg);
            fclose(f);
            return;
        }
    }
    fclose(f);
    fprintf(stderr, "[audiod] %s has no line in the map yet, naming the node for its bus\n", label);
}

// create and connect the PipeWire stream of a client
static int start_stream(struct client *c)
{
    char node_name[NAME_MAX_ + 32];
    char target[NAME_MAX_ + 32];
    snprintf(node_name, sizeof(node_name), "rhizo.%s", c->label);
    snprintf(target, sizeof(target), "%s%s", g_sink_prefix, c->label);

    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Playback",
        PW_KEY_MEDIA_ROLE, "Music",
        PW_KEY_MEDIA_CLASS, "Stream/Output/Audio",
        NULL);
    pw_properties_set(props, PW_KEY_NODE_NAME, node_name);
    pw_properties_set(props, PW_KEY_NODE_DESCRIPTION, c->app);
    pw_properties_set(props, PW_KEY_APP_NAME, c->app);
    pw_properties_set(props, PW_KEY_MEDIA_NAME, c->app);
    pw_properties_set(props, "rhizo.bus", c->label);
    pw_properties_set(props, PW_KEY_TARGET_OBJECT, target);

    c->stream = pw_stream_new(g_core, node_name, props);
    if (c->stream == NULL) {
        fprintf(stderr, "[audiod] pw_stream_new failed for %s\n", c->label);
        return -1;
    }
    pw_stream_add_listener(c->stream, &c->listener, &stream_events, c);

    uint8_t params_buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(params_buffer, sizeof(params_buffer));
    struct spa_audio_info_raw info = {
        .format = SPA_AUDIO_FORMAT_S16_LE,
        .rate = (uint32_t)c->rate,
        .channels = (uint32_t)c->channels,
    };
    if (c->channels == 2) {
        info.position[0] = SPA_AUDIO_CHANNEL_FL;
        info.position[1] = SPA_AUDIO_CHANNEL_FR;
    }
    const struct spa_pod *params[1];
    params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);

    int res = pw_stream_connect(c->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                                PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS |
                                    PW_STREAM_FLAG_RT_PROCESS,
                                params, 1);
    if (res < 0) {
        fprintf(stderr,
                "[audiod] pw_stream_connect failed for %s: %s "
                "(rate=%d channels=%d target='%s' node='%s')\n",
                c->label, spa_strerror(res), c->rate, c->channels, target, node_name);
        return -1;
    }
    fprintf(stderr, "[audiod] node '%s' up (app '%s', target '%s', %d Hz %d ch)\n", node_name,
            c->app, target, c->rate, c->channels);
    g_stream_count++;
    write_status();
    return 0;
}

// push the app name into the live node properties
static void rename_stream(struct client *c)
{
    struct pw_properties *props = pw_properties_new(
        PW_KEY_NODE_DESCRIPTION, c->app,
        PW_KEY_APP_NAME, c->app,
        PW_KEY_MEDIA_NAME, c->app,
        NULL);
    pw_thread_loop_lock(g_loop);
    pw_stream_update_properties(c->stream, &props->dict);
    pw_thread_loop_unlock(g_loop);
    pw_properties_free(props);
}

// close a client and its stream
static void drop_client(struct client *c)
{
    if (c->fd < 0) {
        return;
    }
    fprintf(stderr, "[audiod] %s closed: %llu bytes in, %llu out, %llu underruns, %llu overruns\n",
            c->label, c->bytes_in, c->bytes_out, c->underruns, c->overruns);
    if (c->stream != NULL) {
        pw_thread_loop_lock(g_loop);
        pw_stream_destroy(c->stream);
        pw_thread_loop_unlock(g_loop);
        c->stream = NULL;
        if (c->is_mic) {
            g_capture_count--;
        } else {
            g_stream_count--;
        }
        write_status();
    }
    close(c->fd);
    c->fd = -1;
}

// reset a client slot for a newly accepted connection
static void reset_client_slot(struct client *c, int fd, int is_mic)
{
    memset(c->label, 0, sizeof(c->label));
    memset(c->app, 0, sizeof(c->app));
    memset(c->hdrbuf, 0, sizeof(c->hdrbuf));
    c->hdrlen = 0;
    c->state = CLIENT_HEADER;
    c->head = c->tail = 0;
    c->rate = c->channels = 0;
    c->bytes_in = c->bytes_out = c->underruns = c->overruns = 0;
    c->last_activity = mono_now();
    c->stream = NULL;
    c->is_mic = is_mic;
    c->fd = fd;
}

// check a label is one of the bus ports or the primary fallback
static int label_is_valid(const char *label)
{
    if (strcmp(label, "primary") == 0) {
        return 1;
    }
    if (strlen(label) == 4 && strncmp(label, "bus", 3) == 0 && label[3] >= '0' &&
        label[3] <= '0' + AUDIOD_MAX_BUS - 1) {
        return 1;
    }
    return 0;
}

// parse the HAL header line into label, rate and channels
static int parse_header_line(const char *line, int rule, char *label_out,
                              size_t label_out_len, int *rate_out, int *channels_out)
{
    char label[LABEL_MAX], format[32];
    int rate = 0, channels = 0;
    if (sscanf(line, "rhizo-audio/1 port=%63s rate=%d channels=%d format=%31s", label, &rate,
               &channels, format) != 4) {
        return -1;
    }
    if (strcmp(format, "s16le") != 0 || channels < 1 || channels > 8 || rate < 8000 ||
        rate > 192000) {
        return -1;
    }
    if (rule == LABELS_PLAYBACK && !label_is_valid(label)) {
        return -1;
    }
    if (rule == LABELS_MIC && strcmp(label, "mic") != 0) {
        return -1;
    }
    snprintf(label_out, label_out_len, "%s", label);
    *rate_out = rate;
    *channels_out = channels;
    return 0;
}

// return whether a daemon is listening at a socket path
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

// create, bind and listen on a daemon socket
static int make_listen_socket(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
    if (socket_path_is_live(path)) {
        fprintf(stderr, "[audiod] %s is a live daemon's socket -- refusing; stop that "
                        "daemon or pass another socket path\n", path);
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

// header parser test case
struct selftest_case {
    int rule;
    const char *line;
    int want_ok;
    const char *want_label;
    int want_rate;
    int want_channels;
};

static const struct selftest_case SELFTEST_CASES[] = {
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus0 rate=48000 channels=2 format=s16le", 1, "bus0", 48000, 2},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus1 rate=48000 channels=2 format=s16le", 1, "bus1", 48000, 2},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus2 rate=48000 channels=2 format=s16le", 1, "bus2", 48000, 2},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus3 rate=192000 channels=8 format=s16le", 1, "bus3", 192000, 8},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=primary rate=44100 channels=1 format=s16le", 1, "primary", 44100, 1},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus4 rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=speaker rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=../../etc/passwd rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=BUS0 rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus00 rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus0 rate=48000 channels=2 format=s24le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus0 rate=4000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus0 rate=999999 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus0 rate=48000 channels=0 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus0 rate=48000 channels=9 format=s16le", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=bus0 rate=48000 channels=2", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "not a header at all", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "", 0, NULL, 0, 0},
    {LABELS_PLAYBACK, "rhizo-audio/1 port=mic rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_MIC, "rhizo-audio/1 port=mic rate=48000 channels=2 format=s16le", 1, "mic", 48000, 2},
    {LABELS_MIC, "rhizo-audio/1 port=mic rate=44100 channels=1 format=s16le", 1, "mic", 44100, 1},
    {LABELS_MIC, "rhizo-audio/1 port=bus0 rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_MIC, "rhizo-audio/1 port=primary rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
    {LABELS_MIC, "rhizo-audio/1 port=mic rate=48000 channels=2 format=s24le", 0, NULL, 0, 0},
    {LABELS_MIC, "rhizo-audio/1 port=mic0 rate=48000 channels=2 format=s16le", 0, NULL, 0, 0},
};
#define N_SELFTEST_CASES (sizeof(SELFTEST_CASES) / sizeof(SELFTEST_CASES[0]))

// run the header cases and return the number of mismatches
static int run_header_cases(void)
{
    int mismatches = 0;
    for (size_t i = 0; i < N_SELFTEST_CASES; i++) {
        const struct selftest_case *tc = &SELFTEST_CASES[i];
        char label[LABEL_MAX] = {0};
        int rate = 0, channels = 0;
        int rc = parse_header_line(tc->line, tc->rule, label, sizeof(label), &rate, &channels);
        int got_ok = (rc == 0);
        if (got_ok != tc->want_ok) {
            fprintf(stderr, "SELFTEST FAIL: '%s' -> %s, wanted %s\n", tc->line,
                    got_ok ? "accepted" : "refused", tc->want_ok ? "accepted" : "refused");
            mismatches++;
            continue;
        }
        if (got_ok && tc->want_label != NULL &&
            (strcmp(label, tc->want_label) != 0 || rate != tc->want_rate ||
             channels != tc->want_channels)) {
            fprintf(stderr,
                    "SELFTEST FAIL: '%s' parsed label='%s' rate=%d channels=%d, wanted "
                    "label='%s' rate=%d channels=%d\n",
                    tc->line, label, rate, channels, tc->want_label, tc->want_rate,
                    tc->want_channels);
            mismatches++;
            continue;
        }
        fprintf(stderr, "SELFTEST OK:   %s '%s' -> %s\n", tc->rule == LABELS_MIC ? "mic" : "playback",
                tc->line, got_ok ? "accepted" : "refused");
    }
    return mismatches;
}

// run the header self-test and return nonzero on failure
static int run_selftest(void)
{
    if (N_SELFTEST_CASES == 0) {
        fprintf(stderr, "SELFTEST FAIL: no header cases enumerated -- this checks nothing\n");
        return 1;
    }
    int mismatches = run_header_cases();
    if (mismatches > 0) {
        fprintf(stderr, "SELFTEST: %d of %zu case(s) FAILED\n", mismatches, N_SELFTEST_CASES);
        return 1;
    }
    fprintf(stderr, "SELFTEST: all %zu header cases passed\n", N_SELFTEST_CASES);
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [--socket PATH | --no-socket] [--mic-socket PATH] [--map PATH]\n"
            "          [--sink-prefix PREFIX] [--idle-timeout SECONDS] [-v]\n"
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
        printf("streams=0\n");
        return 0;
    }
    char line[128];
    int any = 0;
    while (fgets(line, sizeof(line), f) != NULL) {
        fputs(line, stdout);
        any = 1;
    }
    if (!any) {
        printf("streams=0\n");
    }
    fclose(f);
    return 0;
}

// run the audio daemon
int main(int argc, char *argv[])
{
    int do_selftest = 0;
    int do_status = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            g_socket_path = argv[++i];
        } else if (strcmp(argv[i], "--no-socket") == 0) {
            g_playback_socket = 0;
        } else if (strcmp(argv[i], "--mic-socket") == 0 && i + 1 < argc) {
            g_mic_socket_path = argv[++i];
        } else if (strcmp(argv[i], "--map") == 0 && i + 1 < argc) {
            g_map_path = argv[++i];
        } else if (strcmp(argv[i], "--sink-prefix") == 0 && i + 1 < argc) {
            g_sink_prefix = argv[++i];
        } else if (strcmp(argv[i], "--idle-timeout") == 0 && i + 1 < argc) {
            g_idle_timeout_s = atoi(argv[++i]);
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

    if (!g_playback_socket && g_mic_socket_path == NULL) {
        fprintf(stderr, "[audiod] --no-socket without --mic-socket leaves nothing to serve\n");
        return 2;
    }
    derive_status_path(g_playback_socket ? g_socket_path : g_mic_socket_path, g_status_path,
                       sizeof(g_status_path));
    write_status();

    g_stop_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    g_wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (g_stop_fd < 0 || g_wake_fd < 0) {
        perror("eventfd");
        return 1;
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    for (int i = 0; i < MAX_CLIENTS; i++) {
        g_clients[i].fd = -1;
        pthread_mutex_init(&g_clients[i].lock, NULL);
    }

    pw_init(&argc, &argv);
    g_loop = pw_thread_loop_new("rhizo-audiod", NULL);
    if (g_loop == NULL) {
        fprintf(stderr, "[audiod] pw_thread_loop_new failed\n");
        return 1;
    }
    g_context = pw_context_new(pw_thread_loop_get_loop(g_loop), NULL, 0);
    if (g_context == NULL) {
        fprintf(stderr, "[audiod] pw_context_new failed\n");
        return 1;
    }
    if (pw_thread_loop_start(g_loop) != 0) {
        fprintf(stderr, "[audiod] pw_thread_loop_start failed\n");
        return 1;
    }
    pw_thread_loop_lock(g_loop);
    g_core = pw_context_connect(g_context, NULL, 0);
    pw_thread_loop_unlock(g_loop);
    if (g_core == NULL) {
        fprintf(stderr, "[audiod] cannot connect to PipeWire (is it running?)\n");
        return 1;
    }

    int listen_fd = -1, mic_fd = -1;
    if (g_playback_socket && (listen_fd = make_listen_socket(g_socket_path)) < 0) {
        return 1;
    }
    if (g_mic_socket_path != NULL && (mic_fd = make_listen_socket(g_mic_socket_path)) < 0) {
        return 1;
    }
    fprintf(stderr, "[audiod] playback on %s, microphone on %s (map %s, idle timeout %ds)\n",
            g_playback_socket ? g_socket_path : "nothing (--no-socket)",
            g_mic_socket_path != NULL ? g_mic_socket_path : "nothing (no --mic-socket)", g_map_path,
            g_idle_timeout_s);

    unsigned char buf[16384];
    while (!g_stop) {
        struct pollfd fds[MAX_CLIENTS + 4];
        int idx[MAX_CLIENTS + 4];
        int n = 0;
        fds[n].fd = g_stop_fd;
        fds[n].events = POLLIN;
        idx[n] = -2;
        n++;
        fds[n].fd = g_wake_fd;
        fds[n].events = POLLIN;
        idx[n] = -4;
        n++;
        if (listen_fd >= 0) {
            fds[n].fd = listen_fd;
            fds[n].events = POLLIN;
            idx[n] = -1;
            n++;
        }
        if (mic_fd >= 0) {
            fds[n].fd = mic_fd;
            fds[n].events = POLLIN;
            idx[n] = -3;
            n++;
        }
        for (int i = 0; i < MAX_CLIENTS; i++) {
            struct client *c = &g_clients[i];
            if (c->fd >= 0) {
                fds[n].fd = c->fd;
                fds[n].events = POLLIN;
                if (c->is_mic && c->state == CLIENT_STREAM) {
                    pthread_mutex_lock(&c->lock);
                    if (ring_available(c) > 0) {
                        fds[n].events |= POLLOUT;
                    }
                    pthread_mutex_unlock(&c->lock);
                }
                idx[n] = i;
                n++;
            }
        }
        int ready = poll(fds, n, 1000);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("poll");
            break;
        }
        for (int k = 0; k < n; k++) {
            if ((fds[k].revents & (POLLIN | POLLOUT | POLLHUP | POLLERR)) == 0) {
                continue;
            }
            if (idx[k] == -2) {
                continue;
            }
            if (idx[k] == -4) {
                uint64_t drained;
                ssize_t ignore = read(g_wake_fd, &drained, sizeof(drained));
                (void)ignore;
                for (int i = 0; i < MAX_CLIENTS; i++) {
                    struct client *mc = &g_clients[i];
                    if (mc->fd >= 0 && mc->is_mic && mc->state == CLIENT_STREAM && flush_capture(mc) != 0) {
                        drop_client(mc);
                    }
                }
                continue;
            }
            if (idx[k] == -1 || idx[k] == -3) {
                int cfd = accept4(idx[k] == -1 ? listen_fd : mic_fd, NULL, NULL,
                                  SOCK_CLOEXEC | SOCK_NONBLOCK);
                if (cfd < 0) {
                    continue;
                }
                int slot = -1;
                for (int i = 0; i < MAX_CLIENTS; i++) {
                    if (g_clients[i].fd < 0) {
                        slot = i;
                        break;
                    }
                }
                if (slot < 0) {
                    fprintf(stderr, "[audiod] too many streams, refusing\n");
                    close(cfd);
                    continue;
                }
                reset_client_slot(&g_clients[slot], cfd, idx[k] == -3);
                continue;
            }
            struct client *c = &g_clients[idx[k]];
            if (c->fd < 0) {
                continue;
            }
            if (c->state == CLIENT_HEADER) {
                if (c->hdrlen + 1 >= sizeof(c->hdrbuf)) {
                    fprintf(stderr, "[audiod] header line too long, refusing\n");
                    close(c->fd);
                    c->fd = -1;
                    continue;
                }
                ssize_t got = read(c->fd, c->hdrbuf + c->hdrlen, sizeof(c->hdrbuf) - 1 - c->hdrlen);
                if (got == 0 || (got < 0 && errno != EINTR && errno != EAGAIN)) {
                    close(c->fd);
                    c->fd = -1;
                    continue;
                }
                if (got <= 0) {
                    continue;
                }
                c->last_activity = mono_now();
                c->hdrlen += (size_t)got;
                char *nl = memchr(c->hdrbuf, '\n', c->hdrlen);
                if (nl == NULL) {
                    continue;
                }
                *nl = '\0';
                int rc = parse_header_line(c->hdrbuf, c->is_mic ? LABELS_MIC : LABELS_PLAYBACK,
                                            c->label, sizeof(c->label), &c->rate, &c->channels);
                if (rc != 0) {
                    fprintf(stderr, "[audiod] bad %s header, refusing: '%s'\n",
                            c->is_mic ? "microphone" : "playback", c->hdrbuf);
                    close(c->fd);
                    c->fd = -1;
                    continue;
                }
                int rc2;
                if (c->is_mic) {
                    snprintf(c->app, sizeof(c->app), "Android");
                    pw_thread_loop_lock(g_loop);
                    rc2 = start_capture(c);
                    pw_thread_loop_unlock(g_loop);
                } else {
                    lookup_app_name(c->label, c->app, sizeof(c->app));
                    pw_thread_loop_lock(g_loop);
                    rc2 = start_stream(c);
                    pw_thread_loop_unlock(g_loop);
                }
                if (rc2 != 0) {
                    close(c->fd);
                    c->fd = -1;
                    continue;
                }
                c->state = CLIENT_STREAM;
                continue;
            }
            if (c->is_mic) {
                if (fds[k].revents & (POLLIN | POLLHUP | POLLERR)) {
                    ssize_t got = read(c->fd, buf, sizeof(buf));
                    if (got == 0 || (got < 0 && errno != EINTR && errno != EAGAIN)) {
                        drop_client(c);
                        continue;
                    }
                }
                if ((fds[k].revents & POLLOUT) && flush_capture(c) != 0) {
                    drop_client(c);
                }
                continue;
            }
            ssize_t got = read(c->fd, buf, sizeof(buf));
            if (got > 0) {
                c->last_activity = mono_now();
                ring_write(c, buf, (size_t)got);
                if (g_verbose) {
                    fprintf(stderr, "[audiod] %s +%zd bytes (queued %zu)\n", c->label, got,
                            ring_available(c));
                }
            } else if (got == 0 || (got < 0 && errno != EINTR && errno != EAGAIN)) {
                drop_client(c);
            }
        }

        if (g_idle_timeout_s > 0) {
            time_t now = mono_now();
            for (int i = 0; i < MAX_CLIENTS; i++) {
                struct client *c = &g_clients[i];
                if (c->fd >= 0 && !(c->is_mic && c->state == CLIENT_STREAM) &&
                    now - c->last_activity >= g_idle_timeout_s) {
                    fprintf(stderr, "[audiod] %s idle for %lds, reaping\n",
                            c->label[0] ? c->label : "(no header)", (long)(now - c->last_activity));
                    drop_client(c);
                }
            }
        }

        time_t mtime = map_mtime();
        if (mtime != g_map_mtime) {
            g_map_mtime = mtime;
            for (int i = 0; i < MAX_CLIENTS; i++) {
                struct client *c = &g_clients[i];
                if (c->fd < 0 || c->state != CLIENT_STREAM) {
                    continue;
                }
                char resolved[NAME_MAX_];
                lookup_app_name(c->label, resolved, sizeof(resolved));
                if (strcmp(resolved, c->app) != 0) {
                    fprintf(stderr, "[audiod] %s renamed app '%s' -> '%s'\n", c->label, c->app,
                            resolved);
                    snprintf(c->app, sizeof(c->app), "%s", resolved);
                    rename_stream(c);
                }
            }
        }
    }

    for (int i = 0; i < MAX_CLIENTS; i++) {
        drop_client(&g_clients[i]);
    }
    if (listen_fd >= 0) {
        close(listen_fd);
        unlink(g_socket_path);
    }
    if (mic_fd >= 0) {
        close(mic_fd);
        unlink(g_mic_socket_path);
    }
    pw_thread_loop_stop(g_loop);
    pw_core_disconnect(g_core);
    pw_context_destroy(g_context);
    pw_thread_loop_destroy(g_loop);
    pw_deinit();
    fprintf(stderr, "[audiod] stopped\n");
    return 0;
}

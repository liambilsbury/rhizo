// pre-fix copy of audiod.c for the audiod-daemon selftest
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
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
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/result.h>

#define MAX_CLIENTS 16
#define RING_BYTES (1 << 20)
#define LABEL_MAX 64
#define NAME_MAX_ 128

static const char *g_socket_path = "/run/rhizo-audio/audiod";
static const char *g_map_path = "/run/rhizo-audio-map";
static const char *g_sink_prefix = "rhizo_sink_";
static int g_verbose = 0;

struct client {
    int fd;
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

// wake the poll loop
static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
    uint64_t one = 1;
    ssize_t ignore = write(g_stop_fd, &one, sizeof(one));
    (void)ignore;
}

static size_t ring_available(const struct client *c)
{
    return (c->head - c->tail) % RING_BYTES;
}

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

/* fill the PipeWire buffer from the ring */
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

/* log a stream state change */
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

/* look up the package name for a bus label */
static void lookup_app_name(const char *label, char *out, size_t out_len)
{
    strncpy(out, label, out_len - 1);
    out[out_len - 1] = '\0';
    FILE *f = fopen(g_map_path, "r");
    if (f == NULL) {
        return;
    }
    char line[256];
    while (fgets(line, sizeof(line), f) != NULL) {
        char bus[LABEL_MAX], pkg[NAME_MAX_];
        if (sscanf(line, "%63s %127s", bus, pkg) == 2 && strcmp(bus, label) == 0) {
            snprintf(out, out_len, "%s", pkg);
            break;
        }
    }
    fclose(f);
}

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
    return 0;
}

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
    }
    close(c->fd);
    c->fd = -1;
}

/* read the HAL's header line */
static int read_header(struct client *c)
{
    char line[256];
    size_t used = 0;
    while (used + 1 < sizeof(line)) {
        ssize_t n = read(c->fd, line + used, 1);
        if (n == 0) {
            return -1;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (line[used] == '\n') {
            break;
        }
        used++;
    }
    line[used] = '\0';

    char label[LABEL_MAX], format[32];
    int rate = 0, channels = 0;
    if (sscanf(line, "rhizo-audio/1 port=%63s rate=%d channels=%d format=%31s", label, &rate,
               &channels, format) != 4) {
        fprintf(stderr, "[audiod] bad header: '%s'\n", line);
        return -1;
    }
    if (strcmp(format, "s16le") != 0 || channels < 1 || channels > 8 || rate < 8000 ||
        rate > 192000) {
        fprintf(stderr, "[audiod] unsupported stream: %s\n", line);
        return -1;
    }
    snprintf(c->label, sizeof(c->label), "%s", label);
    c->rate = rate;
    c->channels = channels;
    lookup_app_name(c->label, c->app, sizeof(c->app));
    return 0;
}

static int make_listen_socket(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", g_socket_path);
    unlink(g_socket_path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close(fd);
        return -1;
    }
    if (chmod(g_socket_path, 0666) != 0) {
        perror("chmod");
    }
    if (listen(fd, MAX_CLIENTS) != 0) {
        perror("listen");
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char *argv[])
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            g_socket_path = argv[++i];
        } else if (strcmp(argv[i], "--map") == 0 && i + 1 < argc) {
            g_map_path = argv[++i];
        } else if (strcmp(argv[i], "--sink-prefix") == 0 && i + 1 < argc) {
            g_sink_prefix = argv[++i];
        } else if (strcmp(argv[i], "-v") == 0) {
            g_verbose = 1;
        } else {
            fprintf(stderr,
                    "usage: %s [--socket PATH] [--map PATH] [--sink-prefix PREFIX] [-v]\n",
                    argv[0]);
            return 2;
        }
    }

    g_stop_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (g_stop_fd < 0) {
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

    int listen_fd = make_listen_socket();
    if (listen_fd < 0) {
        return 1;
    }
    fprintf(stderr, "[audiod] listening on %s (map %s)\n", g_socket_path, g_map_path);

    unsigned char buf[16384];
    while (!g_stop) {
        struct pollfd fds[MAX_CLIENTS + 2];
        int idx[MAX_CLIENTS + 2];
        int n = 0;
        fds[n].fd = g_stop_fd;
        fds[n].events = POLLIN;
        idx[n] = -2;
        n++;
        fds[n].fd = listen_fd;
        fds[n].events = POLLIN;
        idx[n] = -1;
        n++;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (g_clients[i].fd >= 0) {
                fds[n].fd = g_clients[i].fd;
                fds[n].events = POLLIN;
                idx[n] = i;
                n++;
            }
        }
        int ready = poll(fds, n, -1);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("poll");
            break;
        }
        for (int k = 0; k < n; k++) {
            if ((fds[k].revents & (POLLIN | POLLHUP | POLLERR)) == 0) {
                continue;
            }
            if (idx[k] == -2) {
                continue;
            }
            if (idx[k] == -1) {
                int cfd = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC);
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
                struct client *c = &g_clients[slot];
                memset(c->label, 0, sizeof(c->label));
                c->head = c->tail = 0;
                c->bytes_in = c->bytes_out = c->underruns = c->overruns = 0;
                c->fd = cfd;
                if (read_header(c) != 0) {
                    close(cfd);
                    c->fd = -1;
                    continue;
                }
                pw_thread_loop_lock(g_loop);
                int rc = start_stream(c);
                pw_thread_loop_unlock(g_loop);
                if (rc != 0) {
                    close(cfd);
                    c->fd = -1;
                }
                continue;
            }
            struct client *c = &g_clients[idx[k]];
            ssize_t got = read(c->fd, buf, sizeof(buf));
            if (got > 0) {
                ring_write(c, buf, (size_t)got);
                if (g_verbose) {
                    fprintf(stderr, "[audiod] %s +%zd bytes (queued %zu)\n", c->label, got,
                            ring_available(c));
                }
            } else if (got == 0 || (got < 0 && errno != EINTR && errno != EAGAIN)) {
                drop_client(c);
            }
        }
    }

    for (int i = 0; i < MAX_CLIENTS; i++) {
        drop_client(&g_clients[i]);
    }
    close(listen_fd);
    unlink(g_socket_path);
    pw_thread_loop_stop(g_loop);
    pw_core_disconnect(g_core);
    pw_context_destroy(g_context);
    pw_thread_loop_destroy(g_loop);
    pw_deinit();
    fprintf(stderr, "[audiod] stopped\n");
    return 0;
}

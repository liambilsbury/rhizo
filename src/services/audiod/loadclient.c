#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

// return the monotonic time in nanoseconds
static long long now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// send synthetic PCM to rhizo-audiod
int main(int argc, char **argv)
{
    const char *sock_path = NULL;
    const char *port = "bus0";
    int rate = 48000, channels = 2;
    double seconds = 2.0, feed_mult = 1.0;
    int silent = 0;
    const char *raw_header = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
            sock_path = argv[++i];
        } else if (!strcmp(argv[i], "--port") && i + 1 < argc) {
            port = argv[++i];
        } else if (!strcmp(argv[i], "--rate") && i + 1 < argc) {
            rate = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--channels") && i + 1 < argc) {
            channels = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            seconds = atof(argv[++i]);
        } else if (!strcmp(argv[i], "--feed-mult") && i + 1 < argc) {
            feed_mult = atof(argv[++i]);
        } else if (!strcmp(argv[i], "--silent")) {
            silent = 1;
        } else if (!strcmp(argv[i], "--raw-header") && i + 1 < argc) {
            raw_header = argv[++i];
        } else {
            fprintf(stderr,
                    "usage: %s --socket PATH [--port LABEL] [--rate HZ] [--channels N]\n"
                    "       [--seconds S] [--feed-mult F] [--silent] [--raw-header STR]\n",
                    argv[0]);
            return 2;
        }
    }
    if (sock_path == NULL) {
        fprintf(stderr, "%s: --socket is required\n", argv[0]);
        return 2;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sock_path);
    int connected = (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    if (!connected) {
        printf("audiod-loadclient v1 label=%s seconds=%.3f feed_mult=%.3f rate=%d channels=%d "
               "bytes_sent=0 connected=0 header_accepted=0\n",
               port, seconds, feed_mult, rate, channels);
        return 1;
    }

    if (silent) {
        struct timespec ts = {.tv_sec = (time_t)seconds, .tv_nsec = 0};
        nanosleep(&ts, NULL);
        printf("audiod-loadclient v1 label=%s seconds=%.3f feed_mult=%.3f rate=%d channels=%d "
               "bytes_sent=0 connected=1 header_accepted=0\n",
               port, seconds, feed_mult, rate, channels);
        close(fd);
        return 0;
    }

    char header[256];
    int hlen;
    if (raw_header != NULL) {
        hlen = snprintf(header, sizeof(header), "%s\n", raw_header);
    } else {
        hlen = snprintf(header, sizeof(header), "rhizo-audio/1 port=%s rate=%d channels=%d format=s16le\n",
                         port, rate, channels);
    }
    ssize_t hw = write(fd, header, (size_t)hlen);
    int header_accepted = (hw == hlen);

    unsigned long long bytes_sent = 0;
    if (header_accepted && seconds > 0 && feed_mult > 0) {
        double bytes_per_sec = (double)rate * channels * 2 * feed_mult;
        unsigned char chunk[4096];
        memset(chunk, 0x55, sizeof(chunk));
        long long t0 = now_ns();
        long long deadline = t0 + (long long)(seconds * 1e9);
        while (now_ns() < deadline) {
            long long elapsed = now_ns() - t0;
            unsigned long long target = (unsigned long long)(bytes_per_sec * (double)elapsed / 1e9);
            if (bytes_sent >= target) {
                struct timespec ts = {.tv_sec = 0, .tv_nsec = 2000000};
                nanosleep(&ts, NULL);
                continue;
            }
            size_t want = target - bytes_sent;
            if (want > sizeof(chunk)) {
                want = sizeof(chunk);
            }
            ssize_t w = write(fd, chunk, want);
            if (w <= 0) {
                break;
            }
            bytes_sent += (unsigned long long)w;
        }
    }
    close(fd);

    printf("audiod-loadclient v1 label=%s seconds=%.3f feed_mult=%.3f rate=%d channels=%d "
           "bytes_sent=%llu connected=1 header_accepted=%d\n",
           port, seconds, feed_mult, rate, channels, bytes_sent, header_accepted);
    return 0;
}

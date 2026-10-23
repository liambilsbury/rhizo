#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <wayland-client.h>
#include "zkde-screencast-unstable-v1-client-protocol.h"

#define SCREENCAST_VERSION 2
#define POINTER_HIDDEN 1

static struct zkde_screencast_unstable_v1 *screencast;
static int state;
static char why[256];

// bind the screencast interface when the registry lists it
static void on_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version)
{
	if (strcmp(iface, zkde_screencast_unstable_v1_interface.name) || version < SCREENCAST_VERSION)
		return;
	screencast = wl_registry_bind(reg, name, &zkde_screencast_unstable_v1_interface, SCREENCAST_VERSION);
}

// ignore a removed registry global
static void on_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
}

static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

// record that the compositor stopped the stream
static void on_closed(void *data, struct zkde_screencast_stream_unstable_v1 *s)
{
	state = -2;
}

// record that the compositor made the output and its feed
static void on_created(void *data, struct zkde_screencast_stream_unstable_v1 *s, uint32_t node)
{
	state = 1;
}

// record why the compositor refused the output
static void on_failed(void *data, struct zkde_screencast_stream_unstable_v1 *s, const char *error)
{
	snprintf(why, sizeof(why), "%s", error);
	state = -1;
}

static const struct zkde_screencast_stream_unstable_v1_listener stream_listener = { on_closed, on_created, on_failed };

static volatile sig_atomic_t stop;

// stop the main loop on SIGTERM or SIGINT
static void on_signal(int sig)
{
	stop = 1;
}

// make a kwin virtual output of the given size and hold it until SIGTERM or SIGINT
int main(int argc, char **argv)
{
	struct wl_display *dpy;
	struct zkde_screencast_stream_unstable_v1 *stream;
	struct pollfd pfd;
	int w, h;

	if (argc != 4 || (w = atoi(argv[2])) <= 0 || (h = atoi(argv[3])) <= 0) {
		fprintf(stderr, "usage: kde-virtual-output <name> <width> <height>\n");
		return 2;
	}
	dpy = wl_display_connect(NULL);
	if (!dpy) {
		printf("err no wayland display\n");
		return 1;
	}
	wl_registry_add_listener(wl_display_get_registry(dpy), &registry_listener, NULL);
	wl_display_roundtrip(dpy);
	if (!screencast) {
		printf("err the compositor offers no zkde_screencast_unstable_v1 at version %d\n", SCREENCAST_VERSION);
		return 1;
	}
	stream = zkde_screencast_unstable_v1_stream_virtual_output(screencast, argv[1], w, h,
								    wl_fixed_from_int(1), POINTER_HIDDEN);
	zkde_screencast_stream_unstable_v1_add_listener(stream, &stream_listener, NULL);
	while (state == 0)
		if (wl_display_dispatch(dpy) < 0) {
			printf("err the wayland connection failed\n");
			return 1;
		}
	if (state < 0) {
		printf("err the compositor refused the virtual output: %s\n", state == -2 ? "stream closed" : why);
		return 1;
	}
	printf("ok\n");
	fflush(stdout);
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	pfd.fd = wl_display_get_fd(dpy);
	pfd.events = POLLIN;
	while (!stop && state > 0) {
		wl_display_flush(dpy);
		if (poll(&pfd, 1, -1) < 0)
			continue;
		if ((pfd.revents & POLLIN) && wl_display_dispatch(dpy) < 0)
			break;
	}
	zkde_screencast_stream_unstable_v1_close(stream);
	wl_display_roundtrip(dpy);
	wl_display_disconnect(dpy);
	return 0;
}

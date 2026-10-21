#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "fake-input-client-protocol.h"

#define FAKE_INPUT_VERSION 4
#define LINE_MAX_BYTES 126
#define FIXED_MIN (-8388608.0)
#define FIXED_MAX (8388607.99609375)

static struct org_kde_kwin_fake_input *fake;
static uint32_t fake_version;

// bind the fake-input interface when the registry announces it
static void on_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version)
{
	if (strcmp(iface, org_kde_kwin_fake_input_interface.name))
		return;
	fake_version = version;
	if (version >= FAKE_INPUT_VERSION)
		fake = wl_registry_bind(reg, name, &org_kde_kwin_fake_input_interface, FAKE_INPUT_VERSION);
}

// ignore a removed registry global
static void on_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
}

static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

static char why[192];

// parse a decimal number into *v
static int number(const char *s, double *v)
{
	char *end;

	errno = 0;
	*v = strtod(s, &end);
	if (errno || end == s || *end) {
		snprintf(why, sizeof(why), "not a number: %s", s);
		return 0;
	}
	if (!isfinite(*v) || *v < FIXED_MIN || *v > FIXED_MAX) {
		snprintf(why, sizeof(why), "not a number from %.0f to %.8f: %s", FIXED_MIN, FIXED_MAX, s);
		return 0;
	}
	return 1;
}

// parse an integer from 0 to max
static int whole(const char *s, unsigned long max, uint32_t *v)
{
	char *end;
	unsigned long n;

	errno = 0;
	n = strtoul(s, &end, 10);
	if (errno || end == s || *end || *s == '-' || n > max) {
		snprintf(why, sizeof(why), "not a whole number from 0 to %lu: %s", max, s);
		return 0;
	}
	*v = (uint32_t)n;
	return 1;
}

// send an event line to kwin
static const char *send_line(char *line)
{
	char *verb = strtok(line, " \t\n");
	char *a = strtok(NULL, " \t\n");
	char *b = strtok(NULL, " \t\n");
	char *extra = strtok(NULL, " \t\n");
	double x, y;
	uint32_t code, state;

	if (!verb)
		return NULL;
	if (!a || !b || extra) {
		snprintf(why, sizeof(why), "%s takes exactly two arguments", verb);
		return why;
	}
	if (!strcmp(verb, "move")) {
		if (!number(a, &x) || !number(b, &y))
			return why;
		org_kde_kwin_fake_input_pointer_motion_absolute(fake, wl_fixed_from_double(x), wl_fixed_from_double(y));
	} else if (!strcmp(verb, "button")) {
		if (!whole(a, UINT32_MAX, &code) || !whole(b, 1, &state))
			return why;
		org_kde_kwin_fake_input_button(fake, code, state);
	} else if (!strcmp(verb, "key")) {
		if (!whole(a, UINT32_MAX, &code) || !whole(b, 1, &state))
			return why;
		org_kde_kwin_fake_input_keyboard_key(fake, code, state);
	} else if (!strcmp(verb, "axis")) {
		if (!whole(a, 1, &code) || !number(b, &x))
			return why;
		org_kde_kwin_fake_input_axis(fake, code, wl_fixed_from_double(x));
	} else {
		snprintf(why, sizeof(why), "unknown event: %s", verb);
		return why;
	}
	return NULL;
}

// print ok or err to stdout
static void answer(const char *refused)
{
	const char *c;

	if (refused) {
		fputs("err ", stdout);
		for (c = refused; *c; c++)
			putchar((unsigned char)*c < 0x20 || *c == 0x7f ? '?' : *c);
		putchar('\n');
	} else {
		puts("ok");
	}
	fflush(stdout);
}

// read event lines from stdin and send them
int main(void)
{
	struct wl_display *dpy = wl_display_connect(NULL);
	struct wl_registry *reg;
	char *line = NULL;
	size_t cap = 0;
	ssize_t len;
	const char *refused;

	if (!dpy) {
		fprintf(stderr, "wl_display_connect: %s\n", strerror(errno));
		return 1;
	}
	reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	if (wl_display_roundtrip(dpy) < 0) {
		fprintf(stderr, "wl_display_roundtrip: %s\n", strerror(errno));
		return 1;
	}
	if (!fake_version) {
		fprintf(stderr, "kwin offers no org_kde_kwin_fake_input to this client\n");
		return 1;
	}
	if (!fake) {
		fprintf(stderr, "kwin offers org_kde_kwin_fake_input version %u, this needs %d\n", fake_version, FAKE_INPUT_VERSION);
		return 1;
	}
	org_kde_kwin_fake_input_authenticate(fake, "rhizo-systest", "system test input");
	while ((len = getline(&line, &cap, stdin)) != -1) {
		if (memchr(line, '\0', len)) {
			answer("an event line holds a NUL byte");
			continue;
		}
		if (len - (line[len - 1] == '\n') > LINE_MAX_BYTES) {
			snprintf(why, sizeof(why), "an event line is longer than %d bytes", LINE_MAX_BYTES);
			answer(why);
			continue;
		}
		refused = send_line(line);
		if (refused) {
			answer(refused);
			continue;
		}
		if (wl_display_roundtrip(dpy) < 0) {
			fprintf(stderr, "wl_display_roundtrip: %s\n", strerror(errno));
			return 1;
		}
		answer(NULL);
	}
	return 0;
}

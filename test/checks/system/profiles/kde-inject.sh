#!/bin/bash
# test the kde-inject parser against a stub libwayland
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
src=$(realpath "${1:-../system/inject/kde-inject.c}") || exit 1

if ! command -v cc >/dev/null; then
  echo "SKIP check-kde-inject: no C compiler (cc) on this host"
  exit 0
fi
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/wayland-client.h" <<'EOF'
#ifndef STUB_WAYLAND_CLIENT_H
#define STUB_WAYLAND_CLIENT_H
#include <stdint.h>
typedef int32_t wl_fixed_t;
struct wl_display;
struct wl_registry;
struct wl_interface { const char *name; };
struct wl_registry_listener {
	void (*global)(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version);
	void (*global_remove)(void *data, struct wl_registry *reg, uint32_t name);
};
static inline wl_fixed_t wl_fixed_from_double(double d) { return (wl_fixed_t)(d * 256.0); }
struct wl_display *wl_display_connect(const char *name);
struct wl_registry *wl_display_get_registry(struct wl_display *dpy);
int wl_registry_add_listener(struct wl_registry *reg, const struct wl_registry_listener *l, void *data);
int wl_display_roundtrip(struct wl_display *dpy);
void *wl_registry_bind(struct wl_registry *reg, uint32_t name, const struct wl_interface *iface, uint32_t version);
#endif
EOF
cat > "$tmp/fake-input-client-protocol.h" <<'EOF'
struct org_kde_kwin_fake_input;
extern const struct wl_interface org_kde_kwin_fake_input_interface;
void org_kde_kwin_fake_input_authenticate(struct org_kde_kwin_fake_input *f, const char *app, const char *reason);
void org_kde_kwin_fake_input_pointer_motion_absolute(struct org_kde_kwin_fake_input *f, wl_fixed_t x, wl_fixed_t y);
void org_kde_kwin_fake_input_button(struct org_kde_kwin_fake_input *f, uint32_t button, uint32_t state);
void org_kde_kwin_fake_input_keyboard_key(struct org_kde_kwin_fake_input *f, uint32_t key, uint32_t state);
void org_kde_kwin_fake_input_axis(struct org_kde_kwin_fake_input *f, uint32_t axis, wl_fixed_t value);
EOF
cat > "$tmp/stub.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wayland-client.h"
#include "fake-input-client-protocol.h"

const struct wl_interface org_kde_kwin_fake_input_interface = { "org_kde_kwin_fake_input" };
static int handle;
static const struct wl_registry_listener *listener;
static int roundtrips;

static void say(const char *fmt, long a, long b)
{
	printf(fmt, a, b);
	fflush(stdout);
}

struct wl_display *wl_display_connect(const char *name)
{
	const char *d = getenv("STUB_DISPLAY");

	return d && !strcmp(d, "none") ? NULL : (struct wl_display *)&handle;
}

struct wl_registry *wl_display_get_registry(struct wl_display *dpy)
{
	return (struct wl_registry *)&handle;
}

int wl_registry_add_listener(struct wl_registry *reg, const struct wl_registry_listener *l, void *data)
{
	listener = l;
	return 0;
}

int wl_display_roundtrip(struct wl_display *dpy)
{
	const char *v = getenv("STUB_VERSION"), *f = getenv("STUB_FAIL_ROUNDTRIP");

	if (roundtrips++ == 0) {
		if (!v || atoi(v) > 0)
			listener->global(NULL, (struct wl_registry *)&handle, 7, "org_kde_kwin_fake_input", v ? atoi(v) : 6);
		return 0;
	}
	say("roundtrip\n", 0, 0);
	return f && atoi(f) == roundtrips - 1 ? -1 : 0;
}

void *wl_registry_bind(struct wl_registry *reg, uint32_t name, const struct wl_interface *iface, uint32_t version)
{
	return &handle;
}

void org_kde_kwin_fake_input_authenticate(struct org_kde_kwin_fake_input *f, const char *app, const char *reason)
{
}

void org_kde_kwin_fake_input_pointer_motion_absolute(struct org_kde_kwin_fake_input *f, wl_fixed_t x, wl_fixed_t y)
{
	say("apply motion %ld %ld\n", x, y);
}

void org_kde_kwin_fake_input_button(struct org_kde_kwin_fake_input *f, uint32_t button, uint32_t state)
{
	say("apply button %ld %ld\n", button, state);
}

void org_kde_kwin_fake_input_keyboard_key(struct org_kde_kwin_fake_input *f, uint32_t key, uint32_t state)
{
	say("apply key %ld %ld\n", key, state);
}

void org_kde_kwin_fake_input_axis(struct org_kde_kwin_fake_input *f, uint32_t axis, wl_fixed_t value)
{
	say("apply axis %ld %ld\n", axis, value);
}
EOF
if ! out=$(cc -std=gnu11 -O2 -Wall -Werror -I"$tmp" -o "$tmp/kde-inject" "$src" "$tmp/stub.c" 2>&1); then
  echo "FAIL check-kde-inject: $src did not build against the stub layer with -Wall -Werror:"
  echo "$out"
  exit 1
fi

fails=0 n=0
# run kde-inject and compare rc and output
expect() {
  local name="$1" want_rc="$2" want="$3" got rc
  shift 3
  got=$(env "$@" "$tmp/kde-inject" 2>/dev/null); rc=$?
  n=$(( n + 1 ))
  if [[ "$rc" != "$want_rc" || "$got" != "$want" ]]; then
    echo "FAIL $name: rc $rc, output:"
    sed 's/^/    /' <<<"$got"
    echo "  want rc $want_rc, output:"
    sed 's/^/    /' <<<"$want"
    fails=$(( fails + 1 ))
  fi
}
LONG=$(printf 'a%.0s' $(seq 1 200))
DIGITS=$(printf '9%.0s' $(seq 1 119))

expect accept.move 0 $'apply motion 256 512\nroundtrip\nok' <<<"move 1 2"
expect accept.move-negative 0 $'apply motion -1280 640\nroundtrip\nok' <<<"move -5 2.5"
expect accept.move-range-ends 0 $'apply motion 2147483647 -2147483648\nroundtrip\nok' <<<"move 8388607.99609375 -8388608"
expect accept.button 0 $'apply button 272 1\nroundtrip\nok' <<<"button 272 1"
expect accept.key 0 $'apply key 30 0\nroundtrip\nok' <<<"key 30 0"
expect accept.key-max 0 $'apply key 4294967295 1\nroundtrip\nok' <<<"key 4294967295 1"
expect accept.axis 0 $'apply axis 1 -3968\nroundtrip\nok' <<<"axis 1 -15.5"
expect accept.empty 0 $'roundtrip\nok' <<<""
expect accept.partial-last-line 0 $'apply key 30 1\nroundtrip\nok' < <(printf 'key 30 1')

expect refuse.negative-code 0 'err not a whole number from 0 to 4294967295: -1' <<<"key -1 1"
expect refuse.state 0 'err not a whole number from 0 to 1: 2' <<<"button 272 2"
expect refuse.fractional-code 0 'err not a whole number from 0 to 4294967295: 30.5' <<<"key 30.5 1"
expect refuse.axis 0 'err not a whole number from 0 to 1: 2' <<<"axis 2 1"
expect refuse.code-range 0 'err not a whole number from 0 to 4294967295: 4294967296' <<<"key 4294967296 1"
expect refuse.non-numeric 0 'err not a number: a' <<<"move a 2"
expect refuse.too-few 0 'err move takes exactly two arguments' <<<"move 1"
expect refuse.too-many 0 'err move takes exactly two arguments' <<<"move 1 2 3"
expect refuse.unknown 0 'err unknown event: jump' <<<"jump 1 2"
expect refuse.crlf 0 'err not a number: 2?' < <(printf 'move 1 2\r\n')
expect refuse.nan 0 'err not a number from -8388608 to 8388607.99609375: nan' <<<"move nan 0"
expect refuse.inf 0 'err not a number from -8388608 to 8388607.99609375: inf' <<<"move 1 inf"
expect refuse.huge 0 'err not a number from -8388608 to 8388607.99609375: 1e300' <<<"move 1e300 0"
expect refuse.digits 0 "err not a number from -8388608 to 8388607.99609375: $DIGITS" <<<"move 1 $DIGITS"
expect refuse.past-fixed 0 'err not a number from -8388608 to 8388607.99609375: 8388608' <<<"move 8388608 0"
expect refuse.partial-last-line 0 'err jump takes exactly two arguments' < <(printf 'jump')
expect refuse.long-then-next 0 $'err an event line is longer than 126 bytes\napply key 30 1\nroundtrip\nok' \
  < <(printf '%s\nkey 30 1\n' "$LONG")
expect refuse.nul-then-next 0 $'err an event line holds a NUL byte\napply key 31 1\nroundtrip\nok' \
  < <(printf 'key 30\0 1\nkey 31 1\n')
expect refuse.then-accept 0 $'err unknown event: jump\napply key 30 1\nroundtrip\nok' < <(printf 'jump 1 2\nkey 30 1\n')

expect exit.roundtrip 1 $'apply key 30 1\nroundtrip\nok\napply key 31 1\nroundtrip' STUB_FAIL_ROUNDTRIP=2 \
  < <(printf 'key 30 1\nkey 31 1\nkey 32 1\n')
expect exit.no-global 1 '' STUB_VERSION=0 <<<"key 30 1"
expect exit.old-version 1 '' STUB_VERSION=3 <<<"key 30 1"
expect exit.no-display 1 '' STUB_DISPLAY=none <<<"key 30 1"

if (( fails )); then
  echo "check-kde-inject: $fails of $n cases failed"
  exit 1
fi
echo "check-kde-inject: $n cases: each accepted line applied, round-tripped and answered ok in that order, each refused form answered err with nothing applied, only a round trip or startup failure exits"

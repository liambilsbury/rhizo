#include "pointer_observation.h"

#include <cstdio>

using rhizo::CanSendUnaccelerated;
using rhizo::ReconcileObservedAxis;

static int failures = 0;

// print the result of a named check and count failures
static void check(bool ok, const char* what, int got) {
  std::printf("%s %s (got %d)\n", ok ? "ok  " : "FAIL", what, got);
  if (!ok) failures++;
}

// run the pointer observation checks
int main() {
  int got = ReconcileObservedAxis(true, 480, 439, 82);
  check(got == 480, "a model inside the sprite's box is kept, not moved to the sprite origin", got);
  got = ReconcileObservedAxis(true, 439, 439, 82);
  check(got == 439, "a model on the box's first pixel is kept", got);
  got = ReconcileObservedAxis(true, 520, 439, 82);
  check(got == 520, "a model on the box's last pixel is kept", got);
  got = ReconcileObservedAxis(true, 315, 439, 82);
  check(got == 439, "a model before the box moves to its first pixel", got);
  got = ReconcileObservedAxis(true, 700, 439, 82);
  check(got == 520, "a model past the box moves to its last pixel", got);
  got = ReconcileObservedAxis(true, 315, 480, 0);
  check(got == 480, "an observation with no extent is taken as exact", got);
  got = ReconcileObservedAxis(false, 0, 439, 82);
  check(got == 439, "with no model the origin is taken", got);
  got = ReconcileObservedAxis(true, 12, 0, 82);
  check(got == 12, "a sprite clipped at the edge still bounds a model inside it", got);
  const int64_t ms = 1000000;
  got = CanSendUnaccelerated(45 * ms, 900, 0);
  check(got, "a move after the 40ms stop time is sent", got);
  got = CanSendUnaccelerated(8 * ms, 5, 0);
  check(got, "a slow move (625 counts/s) is sent at once", got);
  got = CanSendUnaccelerated(8 * ms, 6, 0);
  check(!got, "a move faster than the flat segment is held", got);
  got = CanSendUnaccelerated(8 * ms, 3, 4);
  check(got, "the speed is the length of the move, not one axis", got);
  got = CanSendUnaccelerated(8 * ms, -4, -4);
  check(!got, "a diagonal over the limit is held", got);
  got = CanSendUnaccelerated(0, 1, 0);
  check(!got, "a move in the same instant as the last one is held", got);
  if (failures) {
    std::printf("pointer_observation_test: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("pointer_observation_test: an observed sprite origin bounds the pointer, never names it\n");
  return 0;
}

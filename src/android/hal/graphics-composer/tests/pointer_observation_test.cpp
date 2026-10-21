#include "pointer_observation.h"

#include <cstdio>

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
  if (failures) {
    std::printf("pointer_observation_test: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("pointer_observation_test: an observed sprite origin bounds the pointer, never names it\n");
  return 0;
}

#include "pointer_icon.h"

#include <cstdio>

using namespace rhizo;

static int failures = 0;

// print the result of a named check with the value got and count failures
static void check(bool ok, const char* what, long long got) {
  std::printf("%s %s (got %lld)\n", ok ? "ok  " : "FAIL", what, got);
  if (!ok) failures++;
}

// run the pointer icon checks
int main() {
  struct Row { int32_t type; uint32_t shape; const char* what; };
  const Row rows[] = {
      {kPointerTypeArrow, kShapeDefault, "ARROW is the host's default cursor"},
      {kPointerTypeNotSpecified, kShapeDefault, "an unspecified type is the default cursor"},
      {kPointerTypeText, kShapeText, "TEXT is the host's I-beam"},
      {kPointerTypeCrosshair, kShapeCrosshair, "CROSSHAIR is the host's crosshair"},
      {kPointerTypeHand, kShapePointer, "HAND is the host's link pointer"},
      {kPointerTypeGrab, kShapeGrab, "GRAB is grab"},
      {kPointerTypeGrabbing, kShapeGrabbing, "GRABBING is grabbing"},
      {kPointerTypeAllScroll, kShapeAllScroll, "ALL_SCROLL is all_scroll"},
      {kPointerTypeHorizontalDoubleArrow, kShapeEwResize, "the horizontal arrow is ew_resize"},
      {kPointerTypeVerticalDoubleArrow, kShapeNsResize, "the vertical arrow is ns_resize"},
      {kPointerTypeTopRightDoubleArrow, kShapeNeswResize, "the top-right arrow is nesw_resize"},
      {kPointerTypeTopLeftDoubleArrow, kShapeNwseResize, "the top-left arrow is nwse_resize"},
      {kPointerTypeWait, kShapeWait, "WAIT is wait"},
      {kPointerTypeHelp, kShapeHelp, "HELP is help"},
      {kPointerTypeContextMenu, kShapeContextMenu, "CONTEXT_MENU is context_menu"},
      {kPointerTypeCopy, kShapeCopy, "COPY is copy"},
      {kPointerTypeNoDrop, kShapeNotAllowed, "NO_DROP is not_allowed"},
      {kPointerTypeZoomIn, kShapeZoomIn, "ZOOM_IN is zoom_in"},
      {kPointerTypeZoomOut, kShapeZoomOut, "ZOOM_OUT is zoom_out"},
      {kPointerTypeVerticalText, kShapeVerticalText, "VERTICAL_TEXT is vertical_text"},
      {kPointerTypeAlias, kShapeAlias, "ALIAS is alias"},
      {kPointerTypeCell, kShapeCell, "CELL is cell"},
      {kPointerTypeCustom, kShapeUseImage, "a custom bitmap shows Android's image"},
      {1022, kShapeDefault, "HANDWRITING is the default cursor"},
      {2000, kShapeDefault, "a spot type is the default cursor"},
  };
  for (const Row& r : rows) {
    const uint32_t got = CursorShapeForPointerType(r.type);
    check(got == r.shape, r.what, got);
  }

  const int64_t s = 1000000000LL;
  PointerTypeAsk ask;
  check(ShouldAskPointerType(ask, 10 * s, 0), "a new image is queried", 1);
  check(!ShouldAskPointerType(ask, 10 * s, kPointerTypeAskAttempts),
        "an image at the query limit is not queried", 0);
  ask = {true, 7, 3, 10 * s};
  check(!ShouldAskPointerType(ask, 11 * s, 0), "one query at a time", 0);
  check(ShouldAskPointerType(ask, 15 * s, 0), "a query past its timeout is dropped", 1);

  check(PointerTypeAnswerFits(ask, 7, 7, 3), "a reply for the unchanged image is kept", 1);
  check(!PointerTypeAnswerFits(ask, 7, 8, 4), "a reply after the image changed is dropped", 0);
  check(!PointerTypeAnswerFits(ask, 7, 7, 5),
        "an answer arriving after the image changed and changed back is not kept", 0);
  check(!PointerTypeAnswerFits(ask, 9, 9, 3), "an answer about another image is not kept", 0);
  PointerTypeAsk idle = ask;
  idle.outstanding = false;
  check(!PointerTypeAnswerFits(idle, 7, 7, 3), "an answer to an ask already given up is not kept", 0);

  if (failures) {
    std::printf("FAILED: %d pointer icon check(s)\n", failures);
    return 1;
  }
  std::printf("pointer types map to host cursor shapes and answers name images\n");
  return 0;
}

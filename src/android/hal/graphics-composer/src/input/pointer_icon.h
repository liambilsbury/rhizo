#ifndef RHIZO_POINTER_ICON_H_
#define RHIZO_POINTER_ICON_H_

#include <cstdint>

namespace rhizo {

// Android's pointer icon types (android.view.PointerIcon, frameworks/native PointerIconType.aidl)
constexpr int32_t kPointerTypeCustom = -1;
constexpr int32_t kPointerTypeNull = 0;
constexpr int32_t kPointerTypeNotSpecified = 1;
constexpr int32_t kPointerTypeArrow = 1000;
constexpr int32_t kPointerTypeContextMenu = 1001;
constexpr int32_t kPointerTypeHand = 1002;
constexpr int32_t kPointerTypeHelp = 1003;
constexpr int32_t kPointerTypeWait = 1004;
constexpr int32_t kPointerTypeCell = 1006;
constexpr int32_t kPointerTypeCrosshair = 1007;
constexpr int32_t kPointerTypeText = 1008;
constexpr int32_t kPointerTypeVerticalText = 1009;
constexpr int32_t kPointerTypeAlias = 1010;
constexpr int32_t kPointerTypeCopy = 1011;
constexpr int32_t kPointerTypeNoDrop = 1012;
constexpr int32_t kPointerTypeAllScroll = 1013;
constexpr int32_t kPointerTypeHorizontalDoubleArrow = 1014;
constexpr int32_t kPointerTypeVerticalDoubleArrow = 1015;
constexpr int32_t kPointerTypeTopRightDoubleArrow = 1016;
constexpr int32_t kPointerTypeTopLeftDoubleArrow = 1017;
constexpr int32_t kPointerTypeZoomIn = 1018;
constexpr int32_t kPointerTypeZoomOut = 1019;
constexpr int32_t kPointerTypeGrab = 1020;
constexpr int32_t kPointerTypeGrabbing = 1021;

// wp_cursor_shape_device_v1 version 1 shapes, asserted in wayland_backend.cpp
constexpr uint32_t kShapeUseImage = 0;
constexpr uint32_t kShapeDefault = 1;
constexpr uint32_t kShapeContextMenu = 2;
constexpr uint32_t kShapeHelp = 3;
constexpr uint32_t kShapePointer = 4;
constexpr uint32_t kShapeWait = 6;
constexpr uint32_t kShapeCell = 7;
constexpr uint32_t kShapeCrosshair = 8;
constexpr uint32_t kShapeText = 9;
constexpr uint32_t kShapeVerticalText = 10;
constexpr uint32_t kShapeAlias = 11;
constexpr uint32_t kShapeCopy = 12;
constexpr uint32_t kShapeNotAllowed = 15;
constexpr uint32_t kShapeGrab = 16;
constexpr uint32_t kShapeGrabbing = 17;
constexpr uint32_t kShapeEwResize = 26;
constexpr uint32_t kShapeNsResize = 27;
constexpr uint32_t kShapeNeswResize = 28;
constexpr uint32_t kShapeNwseResize = 29;
constexpr uint32_t kShapeAllScroll = 32;
constexpr uint32_t kShapeZoomIn = 33;
constexpr uint32_t kShapeZoomOut = 34;

// return the host cursor shape for an Android pointer type; kShapeUseImage means show Android's image
inline uint32_t CursorShapeForPointerType(int32_t type) {
  switch (type) {
    case kPointerTypeCustom: return kShapeUseImage;
    case kPointerTypeContextMenu: return kShapeContextMenu;
    case kPointerTypeHand: return kShapePointer;
    case kPointerTypeHelp: return kShapeHelp;
    case kPointerTypeWait: return kShapeWait;
    case kPointerTypeCell: return kShapeCell;
    case kPointerTypeCrosshair: return kShapeCrosshair;
    case kPointerTypeText: return kShapeText;
    case kPointerTypeVerticalText: return kShapeVerticalText;
    case kPointerTypeAlias: return kShapeAlias;
    case kPointerTypeCopy: return kShapeCopy;
    case kPointerTypeNoDrop: return kShapeNotAllowed;
    case kPointerTypeAllScroll: return kShapeAllScroll;
    case kPointerTypeHorizontalDoubleArrow: return kShapeEwResize;
    case kPointerTypeVerticalDoubleArrow: return kShapeNsResize;
    case kPointerTypeTopRightDoubleArrow: return kShapeNeswResize;
    case kPointerTypeTopLeftDoubleArrow: return kShapeNwseResize;
    case kPointerTypeZoomIn: return kShapeZoomIn;
    case kPointerTypeZoomOut: return kShapeZoomOut;
    case kPointerTypeGrab: return kShapeGrab;
    case kPointerTypeGrabbing: return kShapeGrabbing;
    default: return kShapeDefault;
  }
}

// a request to displayd for a cursor image's pointer type
struct PointerTypeAsk {
  bool outstanding = false;
  uint32_t digest = 0;
  uint64_t imageChanges = 0;
  int64_t sinceNs = 0;
};

// timeout of an unanswered request
constexpr int64_t kPointerTypeAskTimeoutNs = 5LL * 1000000000LL;
// maximum requests per image
constexpr int kPointerTypeAskAttempts = 3;

// return whether to request the shown image's type now
inline bool ShouldAskPointerType(const PointerTypeAsk& ask, int64_t nowNs, int attemptsForImage) {
  if (attemptsForImage >= kPointerTypeAskAttempts) return false;
  return !ask.outstanding || nowNs - ask.sinceNs >= kPointerTypeAskTimeoutNs;
}

// return whether a reply names the shown image
inline bool PointerTypeAnswerFits(const PointerTypeAsk& ask, uint32_t answeredDigest,
                                  uint32_t shownDigest, uint64_t shownImageChanges) {
  return ask.outstanding && ask.digest == answeredDigest && shownDigest == answeredDigest &&
         ask.imageChanges == shownImageChanges;
}

}

#endif

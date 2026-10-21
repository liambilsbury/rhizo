#!/bin/bash
# compile an xkb layout into a keymap file
set -uo pipefail

LAYOUT="${1:?layout required, e.g. fr}"
OUT="${2:?output path required}"

python3 - "$LAYOUT" "$OUT" <<'PY'
import ctypes
import ctypes.util
import sys


class RuleNames(ctypes.Structure):
    _fields_ = [("rules", ctypes.c_char_p), ("model", ctypes.c_char_p),
                ("layout", ctypes.c_char_p), ("variant", ctypes.c_char_p),
                ("options", ctypes.c_char_p)]


layout, out = sys.argv[1], sys.argv[2]
libname = ctypes.util.find_library("xkbcommon")
if not libname:
    sys.exit("make-xkb-keymap: libxkbcommon is not installed on this host")
xkb = ctypes.CDLL(libname)
xkb.xkb_context_new.restype = ctypes.c_void_p
xkb.xkb_keymap_new_from_names.restype = ctypes.c_void_p
xkb.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.POINTER(RuleNames), ctypes.c_int]
xkb.xkb_keymap_get_as_string.restype = ctypes.c_char_p
xkb.xkb_keymap_get_as_string.argtypes = [ctypes.c_void_p, ctypes.c_int]

ctx = xkb.xkb_context_new(0)
if not ctx:
    sys.exit("make-xkb-keymap: xkb_context_new failed")
keymap = xkb.xkb_keymap_new_from_names(ctx, ctypes.byref(RuleNames(None, None, layout.encode(), None, None)), 0)
if not keymap:
    sys.exit(f"make-xkb-keymap: no xkb keymap for layout '{layout}'")
text = xkb.xkb_keymap_get_as_string(keymap, 1)
if not text:
    sys.exit("make-xkb-keymap: xkb_keymap_get_as_string returned nothing")
with open(out, "wb") as f:
    f.write(text)
print(f"[make-xkb-keymap] {layout} -> {out} ({len(text)} bytes)")
PY

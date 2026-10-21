#!/bin/bash
# check vendor binaries load against another GSI
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit
source ../vm/common.sh

TARGET="" VERDICT=""
ARM64_OUR_DIR="$VAR_DIR/share/gfx_hal_arm64"

# test abi-arm64.py and abi.sh a16-arm64
selftest() {
  local fail=0 sp out rc
  sp=$(mktemp -d)
  mkdir -p "$sp/our_empty" "$sp/tgt_empty/lib64" "$sp/our" "$sp/tgt/lib64" "$sp/tgt/bin"

  out=$(python3 "$REPO/test/checks/build/abi-arm64.py" "$sp/our_empty" "$sp/tgt_empty" 2>&1); rc=$?
  [[ $rc -eq 0 && "$out" == SKIP:* ]] || { echo "SELFTEST FAILED: an empty our_dir must SKIP (rc 0) -- got (rc=$rc): $out"; fail=1; }

  if command -v cc >/dev/null; then
    echo 'int good_sym(void) { return 42; }' > "$sp/tgtlib.c"
    cc -shared -fPIC -o "$sp/tgt/lib64/libgood.so" "$sp/tgtlib.c" 2>/dev/null
    cat > "$sp/tgtbin.c" <<'FIXEOF'
extern int good_sym(void);
extern int also_apex_only(void);
int main(void) { return good_sym() + also_apex_only(); }
FIXEOF
    cc -shared -fPIC -Wl,--unresolved-symbols=ignore-all -o "$sp/tgt/bin/stockbin.so" "$sp/tgtbin.c" 2>/dev/null

    cat > "$sp/ourbin_clean.c" <<'FIXEOF'
extern int good_sym(void);
int main(void) { return good_sym(); }
FIXEOF
    cc -shared -fPIC -o "$sp/our/ourbin.so" "$sp/ourbin_clean.c" -L"$sp/tgt/lib64" -lgood 2>/dev/null
    out=$(python3 "$REPO/test/checks/build/abi-arm64.py" "$sp/our" "$sp/tgt" 2>&1); rc=$?
    [[ $rc -eq 0 && "$out" == *"CLEAN"* ]] || { echo "SELFTEST FAILED: a clean fixture must pass -- got (rc=$rc): $out"; fail=1; }

    rm -rf "$sp/our"; mkdir -p "$sp/our"
    cat > "$sp/ourbin_broken.c" <<'FIXEOF'
extern int good_sym(void);
extern int missing_sym(void);
extern int also_apex_only(void);
int main(void) { return good_sym() + missing_sym() + also_apex_only(); }
FIXEOF
    cc -shared -fPIC -Wl,--unresolved-symbols=ignore-all -o "$sp/our/ourbin.so" "$sp/ourbin_broken.c" -L"$sp/tgt/lib64" -lgood 2>/dev/null
    command -v patchelf >/dev/null && patchelf --add-needed libmissing.so "$sp/our/ourbin.so"
    out=$(python3 "$REPO/test/checks/build/abi-arm64.py" "$sp/our" "$sp/tgt" 2>&1); rc=$?
    [[ $rc -ne 0 && "$out" == *"missing_sym"* ]] || { echo "SELFTEST FAILED: a genuine gap must be caught -- got (rc=$rc): $out"; fail=1; }
    [[ "$out" != *"also_apex_only"* ]] || { echo "SELFTEST FAILED: a symbol the target's own stock binary also imports must be filtered, not reported -- got: $out"; fail=1; }
    if command -v patchelf >/dev/null; then
      [[ "$out" == *"libmissing.so"* ]] || { echo "SELFTEST FAILED: a missing NEEDED library must be caught -- got: $out"; fail=1; }
    fi
  else
    echo "SELFTEST SKIPPED: no host cc"
  fi
  rm -rf "$sp"

  local body cr
  body=$(sed -n '/^BODY=$(python3 - /,/^PY$/p' "$REPO/test/checks/build/abi.sh" | sed '1d;$d')
  cr=$(mktemp -d)
  mkdir -p "$cr/ref/system/lib64" "$cr/tgt/system/lib64" "$cr/share" "$cr/repo/test/checks/data"
  out=$(python3 - "$cr/ref" "$cr/tgt" "$cr/repo" "$cr/share" a15 <<<"$body" 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"FAIL: no binaries of ours under $cr/share"* ]] \
    || { echo "SELFTEST FAILED: a share holding none of our binaries must FAIL, never read CLEAN -- got (rc=$rc): $out"; fail=1; }
  if command -v cc >/dev/null; then
    echo 'int gone_sym(void) { return 1; }' > "$cr/ref.c"
    echo 'int kept_sym(void) { return 2; }' > "$cr/tgt.c"
    echo 'extern int gone_sym(void); int ours(void) { return gone_sym(); }' > "$cr/ours.c"
    mkdir -p "$cr/share/gfx_hal"
    cc -shared -fPIC -Wl,-soname,libref.so -o "$cr/ref/system/lib64/libref.so" "$cr/ref.c" 2>/dev/null
    cc -shared -fPIC -Wl,-soname,libref.so -o "$cr/tgt/system/lib64/libref.so" "$cr/tgt.c" 2>/dev/null
    cc -shared -fPIC -o "$cr/share/gfx_hal/libours.so" "$cr/ours.c" -L"$cr/ref/system/lib64" -lref 2>/dev/null
    printf 'a15\tgfx_hal/libours.so\tgone_sym\tfixture waiver\n' > "$cr/repo/test/checks/data/abi-waivers.tsv"
    out=$(python3 - "$cr/ref" "$cr/tgt" "$cr/repo" "$cr/share" a15 <<<"$body" 2>&1); rc=$?
    [[ "$out" == *"our ELFs checked      : 1"* ]] \
      || { echo "SELFTEST FAILED: the binary staged in the share it was given was not checked -- got (rc=$rc): $out"; fail=1; }
    [[ $rc -eq 1 && "$out" == *"gfx_hal/libours.so: gone_sym  [WAIVED: fixture waiver]"* ]] \
      || { echo "SELFTEST FAILED: a gap waived in test/checks/data/abi-waivers.tsv must read WAIVED -- got (rc=$rc): $out"; fail=1; }
  fi
  rm -rf "$cr"

  local img_moved=0 our_moved=0
  [[ -f "$VAR_DIR/share/gsi_a16-arm64.img" ]] && { img_moved=1; mv "$VAR_DIR/share/gsi_a16-arm64.img" "$VAR_DIR/share/gsi_a16-arm64.img.selftest-bak"; }
  [[ -d "$ARM64_OUR_DIR" ]] && { our_moved=1; mv "$ARM64_OUR_DIR" "$ARM64_OUR_DIR.selftest-bak"; }
  out=$(./build/abi.sh a16-arm64 2>&1); rc=$?
  (( img_moved )) && mv "$VAR_DIR/share/gsi_a16-arm64.img.selftest-bak" "$VAR_DIR/share/gsi_a16-arm64.img"
  (( our_moved )) && mv "$ARM64_OUR_DIR.selftest-bak" "$ARM64_OUR_DIR"
  [[ $rc -eq 0 && "$out" == *"SKIP"* ]] \
    || { echo "SELFTEST FAILED: abi.sh a16-arm64 on a tree with no arm64 GSI/binaries staged must SKIP (rc 0) -- got (rc=$rc): $out"; fail=1; }

  if (( fail )); then echo "abi.sh selftest: FAILED"; return 1; fi
  echo "abi.sh selftest: ok"
}
while (( $# )); do
  case "$1" in
    --verdict) VERDICT="$2"; shift 2 ;;
    --selftest) selftest; exit $? ;;
    *) TARGET="$1"; shift ;;
  esac
done
[[ -z "$TARGET" ]] && { echo "usage: $0 <a15|a17|userdebug|a16-arm64> [--verdict PATH] | --selftest" >&2; exit 2; }

# print the path of the staged image for a release
img_for() {
  local l="$1"
  if [[ -f "$VAR_DIR/share/gsi_$l.img" ]]; then echo "$VAR_DIR/share/gsi_$l.img"; return; fi
  if [[ "$l" == "a16" && -f "$VAR_DIR/gsi/system.img" ]]; then echo "$VAR_DIR/gsi/system.img"; return; fi
  echo ""
}

# mount or dump the arm64 GSI image
view_image_arm64() {
  local img="$1" dir="$2" d root=""
  if sudo -n mount -o ro,loop "$img" "$dir" 2>/dev/null; then MOUNTED_ARM64+=("$dir"); return 0; fi
  command -v debugfs >/dev/null || { log "FAIL: cannot mount $img and debugfs is not installed"; return 1; }
  log "  no loop mount on this host; reading $(basename "$img") with debugfs instead"
  debugfs -R "ls /system/lib64" "$img" >/dev/null 2>&1 && root="/system"
  for d in lib64 bin system_ext/lib64 product/lib64; do
    debugfs -R "ls $root/$d" "$img" >/dev/null 2>&1 || continue
    mkdir -p "$dir$root/$(dirname "$d")"
    debugfs -R "rdump $root/$d $dir$root/$(dirname "$d")" "$img" >/dev/null 2>&1 \
      || { log "FAIL: debugfs could not dump $root/$d from $img"; return 1; }
  done
  [[ -d "$dir$root/lib64" ]] || { log "FAIL: $img has no lib64 tree to check against"; return 1; }
}

# check the staged arm64 release image
check_arm64_release() {
  local img rc m
  img=$(img_for a16-arm64)
  if [[ -z "$img" ]]; then
    echo "SKIP: no arm64 GSI staged at var/share/gsi_a16-arm64.img -- run src/install/prepare/fetch-gsi.sh --release a16-arm64 (or gsi.sh a16-arm64) first"
    return 0
  fi
  if ! find "$ARM64_OUR_DIR" -maxdepth 1 -type f 2>/dev/null | grep -q .; then
    echo "SKIP: no arm64 binaries staged at var/share/gfx_hal_arm64 -- run tools/build/hal/hal.sh --abi arm64-v8a first"
    return 0
  fi
  local mt; mt=$(mktemp -d)
  MOUNTED_ARM64=()
  view_image_arm64 "$img" "$mt" || { rm -rf "$mt"; return 1; }
  python3 "$REPO/test/checks/build/abi-arm64.py" "$ARM64_OUR_DIR" "$mt"
  rc=$?
  for m in "${MOUNTED_ARM64[@]}"; do sudo umount "$m" 2>/dev/null; done
  rm -rf "$mt"
  return $rc
}

if [[ "$TARGET" == "a16-arm64" ]]; then
  [[ -z "$VERDICT" ]] || { echo "abi.sh a16-arm64 does not support --verdict yet" >&2; exit 2; }
  check_arm64_release
  exit $?
fi
REF_IMG=$(img_for "${REF_LABEL:-a16}"); TGT_IMG=$(img_for "$TARGET")
[[ -n "$REF_IMG" ]] || { log "FAIL: no A16 baseline image found"; exit 1; }
[[ -n "$TGT_IMG" ]] || { log "FAIL: no image for '$TARGET' -- run tools/fetch/images/gsi.sh $TARGET first"; exit 1; }

MR=$(mktemp -d); MT=$(mktemp -d)
MOUNTED=()
# unmount the mounted images and remove the temporary directories
cleanup() {
  local m
  for m in "${MOUNTED[@]}"; do sudo umount "$m" 2>/dev/null; done
  rm -rf "$MR" "$MT" 2>/dev/null
}
trap cleanup EXIT

# mount or dump an image's library trees
view_image() {
  local img="$1" dir="$2" d
  if sudo -n mount -o ro,loop "$img" "$dir" 2>/dev/null; then MOUNTED+=("$dir"); return 0; fi
  command -v debugfs >/dev/null || { log "FAIL: cannot mount $img and debugfs is not installed"; return 1; }
  log "  no loop mount on this host; reading $(basename "$img") with debugfs instead"
  local root=""
  debugfs -R "ls /system/lib64" "$img" >/dev/null 2>&1 && root="/system"
  for d in lib64 lib system_ext/lib64 product/lib64; do
    debugfs -R "ls $root/$d" "$img" >/dev/null 2>&1 || continue
    mkdir -p "$dir$root/$(dirname "$d")"
    debugfs -R "rdump $root/$d $dir$root/$(dirname "$d")" "$img" >/dev/null 2>&1 \
      || { log "FAIL: debugfs could not dump $root/$d from $img"; return 1; }
  done
  [[ -d "$dir$root/lib64" ]] || { log "FAIL: $img has no lib64 tree to check against"; return 1; }
}

log "reading a16 baseline + $TARGET target read-only ..."
view_image "$REF_IMG" "$MR" || exit 1
view_image "$TGT_IMG" "$MT" || exit 1

BODY=$(python3 - "$MR" "$MT" "$REPO" "$VAR_DIR/share" "$TARGET" <<'PY'
import os, subprocess, sys, glob

mr, mt, repo, share, target = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

def tree(m):
    return os.path.join(m, "system") if os.path.isdir(os.path.join(m, "system", "lib64")) else m

REF, TGT = tree(mr), tree(mt)

def is_elf(p):
    try:
        with open(p, "rb") as f: return f.read(4) == b"\x7fELF"
    except Exception: return False

OURS = []
OURS += glob.glob(os.path.join(share, "gfx_hal", "*"))
for n in ("rhizo-keymint-service", "rhizo-wayland-probe", "rhizo-host-delay"):
    OURS.append(os.path.join(share, n))
if target == "a15":
    a15_power = os.path.join(share, "rel", "a15", "rhizo-power-service")
    if os.path.isfile(a15_power):
        OURS = [p for p in OURS if os.path.basename(p) != "rhizo-power-service"]
        OURS.append(a15_power)
OURS += glob.glob(os.path.join(share, "gpu_driver", "**", "*.so"), recursive=True)
OURS += [p for p in glob.glob(os.path.join(share, "gpu_driver_*", "**", "*.so"), recursive=True)
         if "gpu_driver_32" not in p.split(os.sep)]
OURS += glob.glob(os.path.join(share, "gpu_driver_32", "**", "*.so"), recursive=True)
OURS += glob.glob(os.path.join(share, "gfx_hal_32", "*"))
OURS = sorted(p for p in OURS if os.path.isfile(p) and is_elf(p))
if not OURS:
    print(f"FAIL: no binaries of ours under {share} to check against {target} -- build them first (make payload)")
    sys.exit(1)

def readelf(args, path):
    try:
        return subprocess.run(["readelf", *args, path], capture_output=True,
                              text=True, timeout=180).stdout
    except Exception:
        return ""

def needed(path):
    return [l.split("[",1)[1].split("]",1)[0]
            for l in readelf(["-dW"], path).splitlines()
            if "(NEEDED)" in l and "[" in l]

def syms(path):
    und, dfn = set(), set()
    for line in readelf(["-sW", "--dyn-syms"], path).splitlines():
        f = line.split()
        if len(f) < 8 or not f[0].endswith(":"): continue
        n = f[7].split("@")[0]
        if n: (und if f[6] == "UND" else dfn).add(n)
    return und, dfn

def index(root):
    """soname -> path, for every .so the GSI tree ships."""
    prov = {}
    for sub in ("lib64", "system_ext/lib64", "product/lib64",
                "lib64/vndk-sp", "lib64/egl", "lib64/hw",
                "lib", "lib/egl", "lib/hw"):
        d = os.path.join(root, sub)
        if not os.path.isdir(d): continue
        for p in glob.glob(os.path.join(d, "*.so")):
            prov.setdefault(os.path.basename(p), p)
    return prov

print("indexing baseline (a16) ...", file=sys.stderr)
PREF = index(REF)
print(f"indexing target ({target}) ...", file=sys.stderr)
PTGT = index(TGT)

_cache = {}
def allsyms(prov, key):
    if key in _cache: return _cache[key]
    s = set()
    for p in prov.values():
        s |= syms(p)[1]
    _cache[key] = s
    return s

print("resolving symbol sets (this is the slow part) ...", file=sys.stderr)
SREF, STGT = allsyms(PREF, "ref"), allsyms(PTGT, "tgt")

print("indexing what the target's own binaries import ...", file=sys.stderr)
TGT_UND = set()
for d in ("lib64", "bin", "system_ext/lib64"):
    p = os.path.join(TGT, d)
    try:
        entries = sorted(os.listdir(p))
    except OSError:
        continue
    for f in entries[:500]:
        fp = os.path.join(p, f)
        try:
            if os.path.isfile(fp) and is_elf(fp):
                TGT_UND |= syms(fp)[0]
        except OSError:
            continue

lost_lib, lost_sym, blind = [], [], set()
for b in OURS:
    name = os.path.relpath(b, share)
    for so in needed(b):
        if so in PREF and so not in PTGT:
            lost_lib.append((name, so))
    und, _ = syms(b)
    for s in und:
        in_ref, in_tgt = s in SREF, s in STGT
        if in_ref and not in_tgt and s not in TGT_UND:
            lost_sym.append((name, s))
        elif not in_ref and not in_tgt:
            blind.add(s)

print(f"\n=== cross-release ABI check: a16 (baseline) -> {target} ===")
print(f"our ELFs checked      : {len(OURS)}")
print(f"libs indexed a16/{target:<4}: {len(PREF)} / {len(PTGT)}")
print(f"symbols exported      : {len(SREF)} / {len(STGT)}")
print(f"not indexed in either : {len(blind)} symbols (APEX-provided bionic/libc++)")
print(f"target's own UND set  : {len(TGT_UND)} symbols")

waivers = {}
waivers_path = os.path.join(repo, "test", "checks", "data", "abi-waivers.tsv")
if os.path.exists(waivers_path):
    for line in open(waivers_path):
        line = line.rstrip("\n")
        if not line or line.startswith("#"): continue
        parts = line.split("\t")
        if len(parts) < 4: continue
        rel, binary, sym, reason = parts[0], parts[1], parts[2], parts[3]
        waivers[(rel, binary, sym)] = reason

def waiver_for(name, thing):
    return waivers.get((target, name, thing))

ok = True
unwaived_count = waived_count = 0
if lost_lib:
    ok = False
    print(f"\nLIBRARIES PRESENT IN A16 BUT MISSING IN {target.upper()} ({len(lost_lib)}):")
    for n, so in sorted(set(lost_lib)):
        reason = waiver_for(n, so)
        if reason:
            waived_count += 1
            print(f"  {n}: needs {so}  [WAIVED: {reason}]")
        else:
            unwaived_count += 1
            print(f"  {n}: needs {so}  [UNWAIVED -- not in abi-waivers.tsv]")
if lost_sym:
    ok = False
    print(f"\nSYMBOLS EXPORTED BY A16 BUT NOT BY {target.upper()} ({len(lost_sym)}):")
    by = {}
    for n, s in lost_sym: by.setdefault(n, []).append(s)
    for n in sorted(by):
        for s in sorted(by[n])[:15]:
            reason = waiver_for(n, s)
            if reason:
                waived_count += 1
                print(f"  {n}: {s}  [WAIVED: {reason}]")
            else:
                unwaived_count += 1
                print(f"  {n}: {s}  [UNWAIVED]")
        if len(by[n]) > 15: print(f"  {n}: ... and {len(by[n])-15} more")

if ok:
    print(f"\nCLEAN: {target} exports everything a16 does that our binaries import,")
    print("and ships every library they name. Expect them to load unchanged.")
    sys.exit(0)
if unwaived_count == 0:
    print(f"\nNOT CLEAN by symbol count, but every one of the {waived_count} gap(s) above is "
          f"WAIVED in test/checks/data/abi-waivers.tsv against boot evidence.")
else:
    print(f"\nNOT CLEAN -- {unwaived_count} unwaived gap(s) above are real load failures; "
          f"{waived_count} other(s) are WAIVED, see test/checks/data/abi-waivers.tsv.")
sys.exit(1)
PY
)
RC=$?
echo "$BODY"

if [[ -n "$VERDICT" ]]; then
  RESULT="NOT-CLEAN"; (( RC == 0 )) && RESULT="CLEAN"
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! rig_verdict_write "$VERDICT" "$RESULT system test=abi-$TARGET $stamp" "REFUSED-DIRTY system test=abi-$TARGET $stamp" "$BODY"; then
    RESULT="REFUSED-DIRTY"; RC=3
  fi
  log "verdict written: $VERDICT ($RESULT)"
fi
exit $RC

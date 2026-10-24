#!/bin/bash
# compile and query the GSI SELinux policy offline
set -uo pipefail
_POLICY_LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
SELF="$PWD/$(basename "${BASH_SOURCE[0]}")"
source "$_POLICY_LAB_DIR/../../vm/common.sh"

CACHE_DIR="$VAR_DIR/share/policy-lab"
CTS_JAR="$VAR_DIR/suites/android-cts/testcases/CtsSecurityHostTestCases/CtsSecurityHostTestCases.jar"
GSI_IMG="${RHIZO_GSI_IMG:-$VAR_DIR/gsi/system.img}"

if [[ -n "${RHIZO_RELEASE:-}" && -z "${RHIZO_GSI_IMG:-}" ]]; then
  _rel_name=$(source "$_POLICY_LAB_DIR/../../vm/image/release-map.sh"; printf '%s' "${GSI_IMG[$RHIZO_RELEASE]:-}")
  if [[ -z "$_rel_name" ]]; then
    echo "policy-lab: RHIZO_RELEASE='$RHIZO_RELEASE' is not a known release" >&2
    exit 2
  fi
  _rel_img="$VAR_DIR/gsi/$_rel_name"
  if [[ ! -f "$_rel_img" ]]; then
    echo "policy-lab: RHIZO_RELEASE=$RHIZO_RELEASE needs $_rel_img, which does not exist" >&2
    echo "  Stage it first (test/vm/image/stage-gsi-trees.sh), or point RHIZO_GSI_IMG at an image directly." >&2
    echo "  refusing to compile a16 in its place" >&2
    exit 2
  fi
  GSI_IMG="$_rel_img"
  echo "policy-lab: RHIZO_RELEASE=$RHIZO_RELEASE -> $GSI_IMG" >&2
fi

SECILC="$CACHE_DIR/secilc"
SEPOLICY_ANALYZE="$CACHE_DIR/sepolicy-analyze"
# print the cache key of the GSI image
_gsi_img_key() {
  local st
  st=$(stat -c '%s-%Y' "$GSI_IMG" 2>/dev/null) || st="absent"
  echo "$(basename "$GSI_IMG" .img)-$st"
}
CIL_DIR="${RHIZO_POLICY_LAB_CIL_DIR:-$CACHE_DIR/cils-$(_gsi_img_key)}"
PLAT_CIL="$CIL_DIR/plat_sepolicy.cil"
SYSTEM_EXT_CIL="$CIL_DIR/system_ext_sepolicy.cil"
PRODUCT_CIL="$CIL_DIR/product_sepolicy.cil"
PLAT_PROP="$CIL_DIR/plat_property_contexts"
SYSTEM_EXT_PROP="$CIL_DIR/system_ext_property_contexts"
PRODUCT_PROP="$CIL_DIR/product_property_contexts"

fail() { log "FAIL: $*"; }
pass() { log "  ok: $*"; }

CURRENT_MOUNT=""
# unmount and remove the current mount directory
cleanup_mount() {
  [[ -n "$CURRENT_MOUNT" ]] || return 0
  sudo umount "$CURRENT_MOUNT" 2>/dev/null
  rmdir "$CURRENT_MOUNT" 2>/dev/null
  CURRENT_MOUNT=""
}
INTERNAL_SCRATCH=()
OWN_SCRATCH=""
# remove all of the scratch directories
cleanup_scratch() {
  local d
  for d in "${INTERNAL_SCRATCH[@]}"; do
    rm -rf "$d"
  done
}
trap 'cleanup_mount; cleanup_scratch' EXIT

# extract secilc and sepolicy-analyze from the CTS jar
ensure_cts_tools() {
  [[ -x "$SECILC" && -x "$SEPOLICY_ANALYZE" ]] && return 0
  [[ -f "$CTS_JAR" ]] || { fail "no CTS package at $CTS_JAR -- run tools/fetch/suites/suites.sh first"; return 1; }
  mkdir -p "$CACHE_DIR"
  local tmp; tmp=$(mktemp -d "$CACHE_DIR/.extract.XXXXXX")
  log "extracting host-native secilc/sepolicy-analyze from CtsSecurityHostTestCases.jar (one-time, cached at $CACHE_DIR) ..."
  if ! ( cd "$tmp" && unzip -o -q -j "$CTS_JAR" secilc sepolicy-analyze ); then
    fail "could not extract secilc/sepolicy-analyze from $CTS_JAR"; rm -rf "$tmp"; return 1
  fi
  chmod +x "$tmp/secilc" "$tmp/sepolicy-analyze"
  mv -f "$tmp/secilc" "$SECILC"
  mv -f "$tmp/sepolicy-analyze" "$SEPOLICY_ANALYZE"
  rmdir "$tmp" 2>/dev/null || rm -rf "$tmp"
}

# extract the GSI CILs and property_contexts files
ensure_gsi_cils() {
  [[ -f "$PLAT_CIL" && -f "$SYSTEM_EXT_CIL" && -f "$PRODUCT_CIL" \
     && -f "$PLAT_PROP" && -f "$SYSTEM_EXT_PROP" && -f "$PRODUCT_PROP" ]] && return 0
  [[ -f "$GSI_IMG" ]] || { fail "no GSI image at $GSI_IMG"; return 1; }
  mkdir -p "$CIL_DIR"
  local ok=1
  local mnt; mnt=$(mktemp -d "$VAR_DIR/policy-lab-mnt.XXXXXX")
  CURRENT_MOUNT="$mnt"
  log "loop-mounting $GSI_IMG read-only to extract the GSI's own plat/system_ext/product CILs and property_contexts (one-time, cached at $CIL_DIR) ..."
  if sudo mount -o ro,loop "$GSI_IMG" "$mnt" 2>/dev/null; then
    cp "$mnt/system/etc/selinux/plat_sepolicy.cil" "$PLAT_CIL.tmp" 2>/dev/null || ok=0
    cp "$mnt/system/system_ext/etc/selinux/system_ext_sepolicy.cil" "$SYSTEM_EXT_CIL.tmp" 2>/dev/null || ok=0
    cp "$mnt/system/product/etc/selinux/product_sepolicy.cil" "$PRODUCT_CIL.tmp" 2>/dev/null || ok=0
    cp "$mnt/system/etc/selinux/plat_property_contexts" "$PLAT_PROP.tmp" 2>/dev/null || ok=0
    cp "$mnt/system/system_ext/etc/selinux/system_ext_property_contexts" "$SYSTEM_EXT_PROP.tmp" 2>/dev/null || ok=0
    cp "$mnt/system/product/etc/selinux/product_property_contexts" "$PRODUCT_PROP.tmp" 2>/dev/null || ok=0
    sudo umount "$mnt"
    rmdir "$mnt"
    CURRENT_MOUNT=""
  else
    rmdir "$mnt" 2>/dev/null
    CURRENT_MOUNT=""
    command -v debugfs >/dev/null || { fail "could not loop-mount $GSI_IMG and debugfs is not installed"; return 1; }
    log "  no loop mount on this host; reading $(basename "$GSI_IMG") with debugfs instead"
    _debugfs_cat() {
      local path="$1" out="$2" err
      err=$(debugfs -R "cat $path" "$GSI_IMG" 2>&1 >"$out" | grep -v '^debugfs [0-9]')
      [[ -z "$err" ]]
    }
    _debugfs_cat /system/etc/selinux/plat_sepolicy.cil "$PLAT_CIL.tmp" || ok=0
    _debugfs_cat /system/system_ext/etc/selinux/system_ext_sepolicy.cil "$SYSTEM_EXT_CIL.tmp" || ok=0
    _debugfs_cat /system/product/etc/selinux/product_sepolicy.cil "$PRODUCT_CIL.tmp" || ok=0
    _debugfs_cat /system/etc/selinux/plat_property_contexts "$PLAT_PROP.tmp" || ok=0
    _debugfs_cat /system/system_ext/etc/selinux/system_ext_property_contexts "$SYSTEM_EXT_PROP.tmp" || ok=0
    _debugfs_cat /system/product/etc/selinux/product_property_contexts "$PRODUCT_PROP.tmp" || ok=0
    for f in "$PLAT_CIL.tmp" "$SYSTEM_EXT_CIL.tmp" "$PRODUCT_CIL.tmp" "$PLAT_PROP.tmp" "$SYSTEM_EXT_PROP.tmp" "$PRODUCT_PROP.tmp"; do
      [[ -s "$f" ]] || ok=0
    done
  fi
  if [[ "$ok" != 1 ]]; then
    fail "could not extract one or more GSI CILs/property_contexts from $GSI_IMG"
    rm -f "$PLAT_CIL.tmp" "$SYSTEM_EXT_CIL.tmp" "$PRODUCT_CIL.tmp" "$PLAT_PROP.tmp" "$SYSTEM_EXT_PROP.tmp" "$PRODUCT_PROP.tmp"
    return 1
  fi
  mv -f "$PLAT_CIL.tmp" "$PLAT_CIL"
  mv -f "$SYSTEM_EXT_CIL.tmp" "$SYSTEM_EXT_CIL"
  mv -f "$PRODUCT_CIL.tmp" "$PRODUCT_CIL"
  mv -f "$PLAT_PROP.tmp" "$PLAT_PROP"
  mv -f "$SYSTEM_EXT_PROP.tmp" "$SYSTEM_EXT_PROP"
  mv -f "$PRODUCT_PROP.tmp" "$PRODUCT_PROP"
}

# render rhizo-policy.cil to a file
emit_rhizo_cil() {
  local out="$1" strip="$2" plat_cil="$3" system_ext_cil="$4" product_cil="$5"
  python3 - "$REPO/src/androidd" "$out" "$strip" "$plat_cil" "$system_ext_cil" "$product_cil" <<'PY'
import os, sys

launcher_dir, out, strip, plat_cil, system_ext_cil, product_cil = sys.argv[1:7]
sys.path.insert(0, launcher_dir)
from sandbox import selinux_policy

cils = [c for c in (plat_cil, system_ext_cil, product_cil) if c and os.path.exists(c)]
text = selinux_policy.build(cils)

if strip == "1":
    drop = {"(typepermissive su)", "(typepermissive unlabeled)", "(typepermissive kernel)"}
    text = "".join(l for l in text.splitlines(keepends=True) if l.strip() not in drop)

open(out, "w").write(text)
PY
}

# resolve a property name to its SELinux type
property_resolve() {
  local name="$1"; shift
  python3 - "$name" "$@" <<'PY'
import sys

name = sys.argv[1]
files = sys.argv[2:]


class Node:
    __slots__ = ("children", "own", "prefixes", "exact")

    def __init__(self):
        self.children = {}
        self.own = None
        self.prefixes = []
        self.exact = {}


root = Node()


def add(prop, context, exact, source, raw):
    pieces = prop.split(".")
    ends_with_dot = pieces[-1] == ""
    if ends_with_dot:
        pieces = pieces[:-1]
    node = root
    while len(pieces) > 1:
        node = node.children.setdefault(pieces.pop(0), Node())
    last = pieces[0] if pieces else ""
    entry = (context, source, raw)
    if exact:
        node.exact[last] = entry
    elif not ends_with_dot:
        node.prefixes.append((last, entry))
    else:
        node.children.setdefault(last, Node()).own = entry


for path in files:
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        continue
    for lineno, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        prop, context = parts[0], parts[1]
        rest = parts[2:]
        exact = bool(rest) and rest[0] == "exact"
        add(prop, context, exact, f"{path}:{lineno}", line)

ret = None
kind = None
node = root
remaining = name
while True:
    if node.own is not None:
        ret, kind = node.own, "prefix"
    for pname, entry in sorted(node.prefixes, key=lambda p: -len(p[0])):
        if remaining.startswith(pname):
            ret, kind = entry, "prefix"
            break
    sep = remaining.find(".")
    if sep == -1:
        break
    seg = remaining[:sep]
    child = node.children.get(seg)
    if child is None:
        break
    node = child
    remaining = remaining[sep + 1:]

if remaining in node.exact:
    ret, kind = node.exact[remaining], "exact"

if ret is None:
    print("default_prop\tdefault\t-\t-")
else:
    context, source, raw = ret
    prop_type = context.split(":")[2] if context.count(":") >= 2 else context
    print(f"{prop_type}\t{kind}\t{source}\t{raw}")
PY
}

# print the platform CIL a compile takes, dropping the ashmem open neverallows when the vendor policy grants that open
compile_plat_cil() {
  python3 - "$REPO/src/androidd" "$PLAT_CIL" "$1" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from sandbox import selinux_policy

print(selinux_policy.compile_input(sys.argv[2], sys.argv[3]))
PY
}

# run secilc on the CILs into a directory
do_compile() {
  local out_dir="$1" strip="$2"; shift 2
  ensure_cts_tools || return 1
  ensure_gsi_cils || return 1
  mkdir -p "$out_dir"
  local rhizo_cil="$out_dir/rhizo_vendor_sepolicy.cil"
  if [[ -n "$RENDER_CIL" ]]; then
    cp "$RENDER_CIL" "$rhizo_cil" || return 1
  else
    emit_rhizo_cil "$rhizo_cil" "$strip" "$PLAT_CIL" "$SYSTEM_EXT_CIL" "$PRODUCT_CIL" || return 1
  fi
  local plat
  plat=$(compile_plat_cil "$out_dir") || return 1
  local cils=("$plat" "$SYSTEM_EXT_CIL" "$PRODUCT_CIL" "$rhizo_cil" "$@")
  local pc="$out_dir/precompiled_sepolicy"
  "$SECILC" -m -M true -G -c 30 "${cils[@]}" -o "$pc" -f /dev/null 2>"$out_dir/secilc.stderr"
  local rc=$?
  echo "$rc" > "$out_dir/rc"
  return $rc
}

RENDER_CIL=""
# create a scratch directory and print its path
new_scratch_dir() { mktemp -d "$VAR_DIR/scratch/policy-lab-scratch${SUFFIX}.XXXXXX"; }

# compile the policy from the CIL files into an output directory
cmd_compile() {
  local extra_cils=() strip=0 out_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cil) extra_cils+=("$2"); shift 2 ;;
      --render) RENDER_CIL="$2"; shift 2 ;;
      --strip-permissive) strip=1; shift ;;
      --out) out_dir="$2"; shift 2 ;;
      *) echo "compile: unknown arg: $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$out_dir" ]] || out_dir=$(new_scratch_dir)
  if do_compile "$out_dir" "$strip" "${extra_cils[@]}"; then
    pass "secilc compiled clean (rc=0)"
    echo "$out_dir/precompiled_sepolicy"
    return 0
  else
    local rc; rc=$(cat "$out_dir/rc" 2>/dev/null || echo "?")
    fail "secilc rc=$rc -- $out_dir/secilc.stderr:"
    cat "$out_dir/secilc.stderr" >&2
    return 1
  fi
}

# check the policy for permissive types
cmd_permissive() {
  local policyfile="" strip=0 expect=""
  local extra_cils=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cil) extra_cils+=("$2"); shift 2 ;;
      --render) RENDER_CIL="$2"; shift 2 ;;
      --strip-permissive) strip=1; shift ;;
      --expect)
        [[ $# -ge 2 ]] || { echo "$0: permissive --expect needs a comma-list argument (pass '' for the empty set)" >&2; return 2; }
        expect="$2"; shift 2 ;;
      *) policyfile="$1"; shift ;;
    esac
  done
  if [[ -z "$policyfile" ]]; then
    local scratch; scratch=$(new_scratch_dir)
    do_compile "$scratch" "$strip" "${extra_cils[@]}" || { fail "compile failed, cannot run permissive check ($scratch/secilc.stderr)"; cat "$scratch/secilc.stderr" >&2; return 1; }
    policyfile="$scratch/precompiled_sepolicy"
    OWN_SCRATCH="$scratch"
  fi
  ensure_cts_tools || return 1
  [[ -r "$policyfile" ]] || { fail "policy file not readable: $policyfile"; return 1; }
  local out rc
  out=$("$SEPOLICY_ANALYZE" "$policyfile" permissive); rc=$?
  (( rc == 0 )) || { fail "sepolicy-analyze failed on $policyfile (rc=$rc): $out"; return 1; }
  local have
  have=$(echo "$out" | tr -d '\r' | sed 's/^ *//; s/ *$//' | grep -v '^$' | sort -u | paste -sd, -)
  local want
  want=$(echo "$expect" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' | sort -u | paste -sd, -)
  if [[ "$have" == "$want" ]]; then
    if [[ -z "$want" ]]; then
      pass "no permissive types found in $policyfile"
    else
      pass "permissive types in $policyfile are exactly the expected set: $want"
    fi
    [[ -n "$OWN_SCRATCH" ]] && INTERNAL_SCRATCH+=("$OWN_SCRATCH")
    return 0
  fi
  fail "permissive set in $policyfile is '${have:-<none>}', expected '${want:-<none>}'"
  [[ -n "$out" ]] && echo "$out"
  return 1
}

# run sepolicy-analyze with a subcommand on the policy
cmd_query() {
  local policyfile="" args=() extra_cils=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --policy) policyfile="$2"; shift 2 ;;
      --cil) extra_cils+=("$2"); shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ ${#args[@]} -lt 1 ]]; then
    echo "usage: $0 query <dups|neverallow|permissive|typecmp|booleans|attribute> [args...] [--policy <file>]" >&2
    return 2
  fi
  if [[ -z "$policyfile" ]]; then
    local scratch; scratch=$(new_scratch_dir)
    do_compile "$scratch" 0 "${extra_cils[@]}" || { fail "compile failed, cannot run query ($scratch/secilc.stderr)"; cat "$scratch/secilc.stderr" >&2; return 1; }
    policyfile="$scratch/precompiled_sepolicy"
    OWN_SCRATCH="$scratch"
  fi
  ensure_cts_tools || return 1
  "$SEPOLICY_ANALYZE" "$policyfile" "${args[@]}" || return $?
  if [[ -n "$OWN_SCRATCH" ]]; then INTERNAL_SCRATCH+=("$OWN_SCRATCH"); fi
  return 0
}

# print the value of a policy property
cmd_property() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "usage: $0 property <name>" >&2
    return 2
  fi
  ensure_gsi_cils || return 1
  local result
  result=$(property_resolve "$name" "$PLAT_PROP" "$SYSTEM_EXT_PROP" "$PRODUCT_PROP") || {
    fail "property_resolve failed on '$name'"
    return 1
  }
  local type kind source raw
  IFS=$'\t' read -r type kind source raw <<<"$result"
  case "$kind" in
    exact)
      pass "$name -> $type (exact match, $source: $raw)" ;;
    prefix)
      pass "$name -> $type (prefix match, $source: $raw)" ;;
    default)
      pass "$name -> $type -- no property_contexts entry matches; init's trie-root default" ;;
    *)
      fail "unrecognized match kind '$kind' resolving $name"
      return 1 ;;
  esac
  echo "$type"
}

# print the usage text
usage() {
  cat <<'EOF'
Usage:
  test/checks/lib/policy-lab.sh compile [--cil <extra.cil>]... [--render <rhizo.cil>] [--strip-permissive]
                                        [--out <dir>]
      compile the GSI CILs and the launcher fragment (or --render's rendered one), print the policy path
  test/checks/lib/policy-lab.sh permissive [<policyfile>] [--strip-permissive] [--cil <extra.cil>]...
                                           [--render <rhizo.cil>] [--expect <t1,t2>]
      exit 1 unless the permissive types are exactly --expect's list (default: none), printing them;
      with no policyfile, compile the current policy first
  test/checks/lib/policy-lab.sh query <subcommand> [args...] [--policy <file>] [--cil <extra.cil>]...
      run sepolicy-analyze <policy> <subcommand>: dups, neverallow, permissive, typecmp, booleans or attribute;
      with no --policy, compile the current policy first
      e.g. test/checks/lib/policy-lab.sh query attribute hal_keymint_server
  test/checks/lib/policy-lab.sh property <name>
      print the SELinux type of a property name, resolved as init resolves it from the GSI's property_contexts
EOF
}

# test the permissive and property_resolve subcommands
cmd_selftest() {
  local failures=0 out rc
  out=$(timeout 5 "$SELF" permissive --expect 2>&1); rc=$?
  if [[ "$rc" == 124 ]]; then
    fail "'permissive --expect' with no value still hangs"; failures=$((failures + 1))
  elif [[ "$out" != *"--expect needs a comma-list"* ]]; then
    fail "'permissive --expect' with no value did not refuse as expected (rc=$rc): $out"; failures=$((failures + 1))
  else
    pass "'permissive --expect' with no value refuses fast (rc=$rc), does not hang"
  fi

  out=$(timeout 30 "$SELF" permissive --expect '' /nonexistent-policy-for-policy-lab-selftest 2>&1); rc=$?
  if [[ "$out" != *"policy file not readable"* ]]; then
    fail "'permissive --expect '' <file>' did not parse through to the compile stage (rc=$rc): $out"; failures=$((failures + 1))
  else
    pass "'permissive --expect ''' with a value still parses and reaches the body"
  fi

  local pt; pt=$(mktemp -d) || return 1
  cat > "$pt/plat_property_contexts" <<'EOF'
sys                      u:object_r:sys_prop:s0
system                   u:object_r:system_prop:s0
debug.                   u:object_r:debug_prop:s0
debug.special            u:object_r:debug_special_prop:s0 exact string
EOF

  local type kind
  out=$(property_resolve "systemd_test" "$pt/plat_property_contexts")
  type=$(cut -f1 <<<"$out")
  if [[ "$type" == "system_prop" ]]; then
    pass "property_resolve: same-node longest-prefix picks 'system' over 'sys' for systemd_test"
  else
    fail "property_resolve picked '$type' for 'systemd_test', wanted the LONGER same-node prefix 'system' (system_prop), not 'sys'"; failures=$((failures + 1))
  fi

  out=$(property_resolve "sysfoo" "$pt/plat_property_contexts")
  type=$(cut -f1 <<<"$out")
  if [[ "$type" == "sys_prop" ]]; then
    pass "property_resolve: falls back to the shorter 'sys' prefix when the longer 'system' does not match"
  else
    fail "property_resolve picked '$type' for 'sysfoo', wanted the shorter prefix 'sys' (sys_prop)"; failures=$((failures + 1))
  fi

  out=$(property_resolve "debug.special" "$pt/plat_property_contexts")
  type=$(cut -f1 <<<"$out"); kind=$(cut -f2 <<<"$out")
  if [[ "$type" == "debug_special_prop" && "$kind" == "exact" ]]; then
    pass "property_resolve: an exact entry overrides its own prefix's fallback"
  else
    fail "property_resolve got '$type' ($kind) for 'debug.special', wanted the exact entry debug_special_prop"; failures=$((failures + 1))
  fi

  out=$(property_resolve "debug.ordinary" "$pt/plat_property_contexts")
  type=$(cut -f1 <<<"$out")
  if [[ "$type" == "debug_prop" ]]; then
    pass "property_resolve: a name with no exact entry of its own still falls to its covering prefix"
  else
    fail "property_resolve got '$type' for 'debug.ordinary', wanted the 'debug.' prefix (debug_prop)"; failures=$((failures + 1))
  fi

  out=$(property_resolve "totally.unrelated.name" "$pt/plat_property_contexts")
  type=$(cut -f1 <<<"$out"); kind=$(cut -f2 <<<"$out")
  if [[ "$type" == "default_prop" && "$kind" == "default" ]]; then
    pass "property_resolve: a name matching nothing falls to default_prop, not silence"
  else
    fail "property_resolve got '$type' ($kind) for 'totally.unrelated.name', wanted the default_prop fallback"; failures=$((failures + 1))
  fi
  rm -rf "$pt"

  if [[ "$failures" == 0 ]]; then
    log "selftest: ok (7/7)"
    return 0
  fi
  log "selftest: $failures failure(s)"
  return 1
}

case "${1:-}" in
  compile) shift; cmd_compile "$@" ;;
  permissive) shift; cmd_permissive "$@" ;;
  query) shift; cmd_query "$@" ;;
  property) shift; cmd_property "$@" ;;
  selftest) shift; cmd_selftest "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

#!/bin/bash
# test the output of materialize-data-template.py
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

PROD_TEMPLATE_SCRIPT="$(pwd)/../../src/install/prepare/data-template.sh"
MATERIALIZE_SRC="$(pwd)/../../src/install/prepare/materialize-data-template.py"

if ! grep -qF -- '--apex-root-dir "$MOUNTPOINT/apex"' "$PROD_TEMPLATE_SCRIPT"; then
  echo "check-data-template: data-template.sh no longer passes --apex-root-dir \"\$MOUNTPOINT/apex\" to materialize-data-template.py" >&2
  exit 1
fi
echo "check-data-template: production caller wiring confirmed -- data-template.sh passes --apex-root-dir to materialize-data-template.py"
if ! grep -qF -- '--seed "$SEED"' "$PROD_TEMPLATE_SCRIPT"; then
  echo "check-data-template: data-template.sh no longer passes --seed \"\$SEED\" to materialize-data-template.py" >&2
  exit 1
fi
if ! grep -qF -- 'remote_flags+=" --seed $SEED"' "$(pwd)/../../tools/build/image/data-template.sh"; then
  echo "check-data-template: data-template.sh no longer forwards --seed to data-template.sh" >&2
  exit 1
fi
if ! grep -qF -- '--seed none' "$(pwd)/../../src/install/prepare/prepare.sh"; then
  echo "check-data-template: src/install/prepare/prepare.sh no longer builds the template with --seed none" >&2
  exit 1
fi
echo "check-data-template: --seed reaches the materializer from the guest builder, and both production callers ask for none"

if ! grep -qF 'builder_sha=$builder_sha' "$PROD_TEMPLATE_SCRIPT"; then
  echo "check-data-template: data-template.sh no longer folds builder_sha into key_input" >&2
  exit 1
fi
FLIPPED_BUILDER="$(mktemp /tmp/rhizo-check-data-template-flipped.XXXXXX)"
cp "$MATERIALIZE_SRC" "$FLIPPED_BUILDER"
printf '# one-byte-equivalent edit for the discrimination check\n' >> "$FLIPPED_BUILDER"
orig_key=$(CHECK_TEMPLATE_MATERIALIZE="$MATERIALIZE_SRC" bash "$PROD_TEMPLATE_SCRIPT" --print-key 2>/dev/null)
flipped_key=$(CHECK_TEMPLATE_MATERIALIZE="$FLIPPED_BUILDER" bash "$PROD_TEMPLATE_SCRIPT" --print-key 2>/dev/null)
rm -f "$FLIPPED_BUILDER"
if [[ -z "$orig_key" || -z "$flipped_key" ]]; then
  echo "check-data-template: data-template.sh --print-key printed nothing" >&2
  exit 1
fi
if [[ "$orig_key" == "$flipped_key" ]]; then
  echo "check-data-template: the template key did not change after editing materialize-data-template.py ($orig_key both times)" >&2
  exit 1
fi
echo "check-data-template: the script's own key computation discriminates a builder edit ($orig_key -> $flipped_key)"

MOVED_DIR="$(mktemp -d /tmp/rhizo-check-data-template-moved.XXXXXX)"
cp "$PROD_TEMPLATE_SCRIPT" "$MOVED_DIR/data-template.sh"
cp "$MATERIALIZE_SRC" "$MOVED_DIR/materialize-data-template.py"
moved_key=$(bash "$MOVED_DIR/data-template.sh" --print-key 2>/dev/null)
rm -rf "$MOVED_DIR"
if [[ "$moved_key" != "$orig_key" ]]; then
  echo "check-data-template: identical builder bytes at another path give key ${moved_key:-<none>}, not $orig_key" >&2
  exit 1
fi
echo "check-data-template: the key reads the builder's bytes, not its path ($orig_key at both paths)"

WRAPPER="$(pwd)/../../tools/build/image/data-template.sh"
if ! grep -qF 'builder_sha=$(bash ../../../src/install/prepare/data-template.sh --print-builder-sha)' "$WRAPPER" \
   || grep -qE 'builder_sha=\$\(sha256sum' "$WRAPPER"; then
  echo "check-data-template: data-template.sh computes builder_sha itself instead of asking data-template.sh --print-builder-sha" >&2
  exit 1
fi
wrapper_sha=$(bash "$PROD_TEMPLATE_SCRIPT" --print-builder-sha 2>/dev/null)
if [[ ! "$wrapper_sha" =~ ^[0-9a-f]{16}$ ]]; then
  echo "check-data-template: data-template.sh --print-builder-sha printed '${wrapper_sha}', not a 16-hex builder_sha" >&2
  exit 1
fi
echo "check-data-template: data-template.sh takes builder_sha ($wrapper_sha) from data-template.sh"

if ! grep -qF 'module_lines=$(bash ../../../src/install/prepare/data-template.sh --print-module-lines' "$WRAPPER" \
   || grep -qE "module_lines=\\$\\(grep '\\^MODULE'" "$WRAPPER"; then
  echo "check-data-template: data-template.sh orders the module lines itself instead of asking data-template.sh --print-module-lines" >&2
  exit 1
fi
manifest=$'MODULE com.android.media.swcodec@361099999 0ccd\nMODULE com.android.media@361099999 1aaa\nMODULE com.android.mediaprovider@361099999 2bbb\nMATERIALIZE_OK'
want_lines=$'com.android.media.swcodec@361099999\t0ccd\ncom.android.media@361099999\t1aaa\ncom.android.mediaprovider@361099999\t2bbb'
for loc in C C.UTF-8 en_US.UTF-8; do
  got_lines=$(LC_ALL="$loc" bash "$PROD_TEMPLATE_SCRIPT" --print-module-lines <<<"$manifest" 2>/dev/null)
  if [[ "$got_lines" != "$want_lines" ]]; then
    echo "check-data-template: data-template.sh --print-module-lines under LC_ALL=$loc printed '${got_lines//$'\n'/ | }', not the byte order '${want_lines//$'\n'/ | }'" >&2
    exit 1
  fi
done
echo "check-data-template: data-template.sh takes the module lines from data-template.sh, in byte order under C, C.UTF-8 and en_US.UTF-8"

seed_block=$(sed -n '/^if \[\[ "\${RHIZO_GUEST_OS:-ubuntu}" != cachyos \]\]; then$/,/^fi$/p' "$WRAPPER")
[[ "$seed_block" == *seed-modules-extra.sh* ]] \
  || { echo "check-data-template: no seed-modules-extra.sh block in data-template.sh" >&2; exit 1; }
# run data-template.sh's seed block with a fake ssh_vm
run_seed_block() {
  # shellcheck disable=SC2034
  ( SEED_OUT="$1" SEED_RC="$2" SHARE_DIR=/root/share RHIZO_VM=9
    ssh_vm() { printf '%s\n' "$SEED_OUT"; return "$SEED_RC"; }
    log() { echo "$*"; }
    eval "$seed_block"
    echo SEED_BLOCK_PASSED ) 2>&1
}
seed_out=$(run_seed_block "RHIZO_MODULES_EXTRA=failed step=depmod kernel=6.8.0-136-generic" 1)
if [[ "$seed_out" == *SEED_BLOCK_PASSED* || "$seed_out" != *"BUILD_TEMPLATE_FAILED reason=modules-extra-seed-failed"* \
      || "$seed_out" != *"step=depmod"* ]]; then
  echo "check-data-template: a seed-modules-extra.sh that exits 1 did not fail the build by name: ${seed_out//$'\n'/ | }" >&2
  exit 1
fi
seed_out=$(run_seed_block "RHIZO_MODULES_EXTRA=absent kernel=6.8.0-136-generic" 0)
if [[ "$seed_out" == *SEED_BLOCK_PASSED* || "$seed_out" != *"BUILD_TEMPLATE_FAILED reason=no-modules-extra"* ]]; then
  echo "check-data-template: a share with no linux-modules-extra did not fail the build as no-modules-extra: ${seed_out//$'\n'/ | }" >&2
  exit 1
fi
seed_out=$(run_seed_block "RHIZO_MODULES_EXTRA=seeded kernel=6.8.0-136-generic" 0)
if [[ "$seed_out" != *SEED_BLOCK_PASSED* ]]; then
  echo "check-data-template: a seeded kernel stopped the build: ${seed_out//$'\n'/ | }" >&2
  exit 1
fi
echo "check-data-template: data-template.sh fails a seed-modules-extra.sh error and an absent package by name and goes on after a seed"

SUP_DIR="$(mktemp -d /tmp/rhizo-check-data-template-superseded.XXXXXX)"
# write an empty image and its meta file
sup_meta() {
  : > "$SUP_DIR/data-template.$1.img"
  printf '{\n "key": "%s",\n "variant": "%s",\n "gsi_fingerprint": "%s",\n "format": "%s",\n "builder_sha": "%s"\n}\n' \
    "$1" "$3" "$2" "$4" "$5" > "$SUP_DIR/data-template.$1.img.meta"
}
CUR=1111111111111111
sup_meta aaaaaaaaaaaa fp-a16 user quota "$CUR"
sup_meta bbbbbbbbbbbb fp-a16 user quota "$CUR"
sup_meta cccccccccccc fp-a17 user quota "$CUR"
sup_meta dddddddddddd fp-a16 userdebug quota "$CUR"
sup_meta eeeeeeeeeeee fp-a16 user plain "$CUR"
sup_meta ffffffffffff fp-a15 user quota 2222222222222222
superseded=$(bash "$PROD_TEMPLATE_SCRIPT" --print-superseded "$SUP_DIR" aaaaaaaaaaaa fp-a16 user quota "$CUR" 2>&1)
no_builder=$(bash "$PROD_TEMPLATE_SCRIPT" --print-superseded "$SUP_DIR" aaaaaaaaaaaa fp-a16 user quota "" 2>&1)
rm -rf "$SUP_DIR"
want="$SUP_DIR/data-template.bbbbbbbbbbbb.img
$SUP_DIR/data-template.ffffffffffff.img"
if [[ "$superseded" != "$want" ]]; then
  echo "check-data-template: data-template.sh --print-superseded named '${superseded//$'\n'/ }', wanted the older same-release template and the older builder's" >&2
  exit 1
fi
if [[ "$no_builder" != "$SUP_DIR/data-template.bbbbbbbbbbbb.img" ]]; then
  echo "check-data-template: with no current builder_sha, --print-superseded named '${no_builder//$'\n'/ }'" >&2
  exit 1
fi
echo "check-data-template: a build supersedes the older template for its own fingerprint, variant and format, and every older builder's"

WORKDIR=$(mktemp -d /tmp/rhizo-check-data-template.XXXXXX)
IMG="$WORKDIR/scratch.img"

# remove the working directory
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

python3 - "$(pwd)/../../src/install/prepare/materialize-data-template.py" "$WORKDIR" "$IMG" "$SELFTEST" <<'PY'
import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import zipfile

MOD_PATH, WORKDIR, IMG, SELFTEST = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
STAGE = os.path.join(WORKDIR, "stage")
APEX_SRC = os.path.join(WORKDIR, "apex-src")
APEX_SUBDIR = "apex"
DECOMP_IMG = "/" + APEX_SUBDIR + "/decompressed"
ACTIVE_IMG = "/" + APEX_SUBDIR + "/active"
APEX_ROOT_IMG = "/" + APEX_SUBDIR

spec = importlib.util.spec_from_file_location("materialize_data_template", MOD_PATH)
mdt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mdt)

EXPECT_PAYLOAD_LABEL = b"u:object_r:staging_data_file:s0"
EXPECT_DIR_LABEL = b"u:object_r:apex_data_file:s0"
EXPECT_MODE = 0o644


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pb_manifest(name, version):
    nb = name.encode("utf-8")
    return (b"\x0a" + varint(len(nb)) + nb  # protobuf field 1 string
            + b"\x10" + varint(version))     # protobuf field 2 varint


def write_capex(path, name, version, payload):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("apex_manifest.pb", pb_manifest(name, version))
        zf.writestr("original_apex", payload)


FIXTURES = [
    ("one.capex", "com.android.checkone", 100, b"payload-one-" * 500),
    ("two.capex", "com.android.checktwo", 200, b"PAYLOAD-TWO-DIFFERENT-" * 300),
    ("excl.capex", "com.android.checkexcl", 1, b"must never be written"),
]
EXPECT_NAMES = {
    "com.android.checkone@100.decompressed.apex": b"payload-one-" * 500,
    "com.android.checktwo@200.decompressed.apex": b"PAYLOAD-TWO-DIFFERENT-" * 300,
}
EXCLUDE = {"excl.capex"}



def _debugfs(request, write=False):
    """run a debugfs request against the image"""
    cmd = ["debugfs"]
    if write:
        cmd.append("-w")
    cmd += ["-R", request, IMG]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    extra = [ln for ln in r.stderr.decode(errors="replace").splitlines()
             if ln and not ln.startswith("debugfs ")]
    if r.returncode != 0 or extra:
        raise RuntimeError("debugfs %r against %s failed: %s"
                           % (request, IMG, "\n".join(extra) or r.stderr.decode(errors="replace")))
    return r.stdout


def img_ls(path):
    """list the entries under a path in the image"""
    out = _debugfs("ls -p %s" % path).decode()
    entries = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split("/")
        name = parts[5]
        if name in (".", ".."):
            continue
        size = int(parts[6]) if parts[6] else 0
        entries.append((name, parts[2], size))
    return entries


def img_cat(path):
    return _debugfs("cat %s" % path)


def img_ea_set(path, name, value):
    valfile = os.path.join(WORKDIR, "ea_value.tmp")
    with open(valfile, "wb") as f:
        f.write(value)
    _debugfs("ea_set -f %s %s %s" % (valfile, path, name), write=True)
    os.remove(valfile)


def img_ea_get(path, name):
    """return an xattr's raw bytes from the image, or None"""
    valfile = os.path.join(WORKDIR, "ea_value.tmp")
    if os.path.exists(valfile):
        os.remove(valfile)
    subprocess.run(["debugfs", "-R", "ea_get -f %s %s %s" % (valfile, path, name), IMG],
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if not os.path.exists(valfile) or os.path.getsize(valfile) == 0:
        return None
    with open(valfile, "rb") as f:
        v = f.read()
    os.remove(valfile)
    return v


def img_ea_rm(path, name):
    _debugfs("ea_rm %s %s" % (path, name), write=True)



_xattr_queue = []


def _queue_setxattr(path, name, value, *a, **kw):
    _xattr_queue.append((path, name, bytes(value)))


os.setxattr = _queue_setxattr


def _img_path(abspath):
    return "/" + os.path.relpath(abspath, STAGE)


def repackage():
    """package the stage into a fresh image and replay queued xattrs"""
    subprocess.run(["mkfs.ext4", "-q", "-F", "-d", STAGE, IMG, "8M"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for abspath, name, value in _xattr_queue:
        img_ea_set(_img_path(abspath), name, value)


def run_build(seed="decompressed"):
    """rebuild the stage through materialize() and package it"""
    _xattr_queue.clear()
    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    if os.path.isdir(APEX_SRC):
        shutil.rmtree(APEX_SRC)
    os.makedirs(APEX_SRC)
    decomp_dir = os.path.join(STAGE, APEX_SUBDIR, "decompressed")
    active_dir = os.path.join(STAGE, APEX_SUBDIR, "active")
    apex_root_dir = os.path.join(STAGE, APEX_SUBDIR)
    for fname, name, version, payload in FIXTURES:
        write_capex(os.path.join(APEX_SRC, fname), name, version, payload)
    mdt.materialize(APEX_SRC, decomp_dir, EXCLUDE, active_dir=active_dir, set_labels=True,
                    apex_root_dir=apex_root_dir, seed=seed)
    repackage()


def verify_noseed(decomp_path, active_path, apex_root_path):
    """check the --seed none image"""
    fails = []
    stray = [name for name, _mode, _size in img_ls(decomp_path)]
    if stray:
        fails.append("a --seed none build holds payloads in decompressed/: %r" % (stray,))
    for label_path, tag in ((decomp_path, "decompressed"), (active_path, "active"),
                           (apex_root_path, "apex-root")):
        label = img_ea_get(label_path, "security.selinux")
        if label is None:
            fails.append("%s dir: could not read security.selinux xattr" % tag)
        elif label != EXPECT_DIR_LABEL:
            fails.append("%s dir: security.selinux=%r != expected %r" % (tag, label, EXPECT_DIR_LABEL))
    return fails


def verify(decomp_path, active_path, apex_root_path):
    """check the packaged image"""
    fails = []
    entries = img_ls(decomp_path)
    by_name = {name: (mode, size) for name, mode, size in entries}
    got_names = set(by_name)
    want_names = set(EXPECT_NAMES)
    if got_names != want_names:
        fails.append("output file set %r != expected %r" % (sorted(got_names), sorted(want_names)))
    for fname, want_payload in EXPECT_NAMES.items():
        if fname not in by_name:
            continue
        p = decomp_path + "/" + fname
        got_payload = img_cat(p)
        if got_payload != want_payload:
            fails.append("%s: content not byte-exact (got sha256=%s, want sha256=%s)"
                         % (fname, hashlib.sha256(got_payload).hexdigest(),
                            hashlib.sha256(want_payload).hexdigest()))
        mode = int(by_name[fname][0], 8) & 0o777
        if mode != EXPECT_MODE:
            fails.append("%s: mode %o != expected %o" % (fname, mode, EXPECT_MODE))
        label = img_ea_get(p, "security.selinux")
        if label is None:
            fails.append("%s: could not read security.selinux xattr" % fname)
        elif label != EXPECT_PAYLOAD_LABEL:
            fails.append("%s: security.selinux=%r != expected %r" % (fname, label, EXPECT_PAYLOAD_LABEL))
    for excl_name in ("com.android.checkexcl@1.decompressed.apex",):
        if excl_name in got_names:
            fails.append("excluded module was written anyway: %s" % excl_name)
    for label_path, tag in ((decomp_path, "decompressed"), (active_path, "active"),
                           (apex_root_path, "apex-root")):
        label = img_ea_get(label_path, "security.selinux")
        if label is None:
            fails.append("%s dir: could not read security.selinux xattr" % tag)
            continue
        if label != EXPECT_DIR_LABEL:
            fails.append("%s dir: security.selinux=%r != expected %r" % (tag, label, EXPECT_DIR_LABEL))
    return fails


run_build()
fails = verify(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
if fails:
    print("check-data-template: a CORRECT build failed its own verification -- "
          "the checker or the materializer disagrees with itself:")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("check-data-template: fixture replay clean -- byte-exact payloads, "
      "correct naming, 0644 mode, correct labels on %d modules (%d excluded)"
      % (len(EXPECT_NAMES), len(EXCLUDE)))

run_build(seed="none")
fails = verify_noseed(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
if fails:
    print("check-data-template: a CORRECT --seed none build failed its own verification:")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("check-data-template: --seed none replay clean -- no payload, all three directories labeled")

if not SELFTEST:
    sys.exit(0)

run_build()
n = 0
target_name = "com.android.checkone@100.decompressed.apex"
target_abspath = os.path.join(STAGE, APEX_SUBDIR, "decompressed", target_name)
target_imgpath = DECOMP_IMG + "/" + target_name

with open(target_abspath, "r+b") as f:
    f.seek(0)
    f.write(b"\x00")
repackage()
fails = verify(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
assert any("not byte-exact" in f for f in fails), \
    "content corruption was not detected: %r" % fails
n += 1

run_build()
img_ea_set(target_imgpath, "security.selinux", b"u:object_r:apex_data_file:s0")
fails = verify(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
assert any("security.selinux" in f and "checkone" in f for f in fails), \
    "label corruption was not detected: %r" % fails
n += 1

run_build()
img_ea_rm(APEX_ROOT_IMG, "security.selinux")
fails = verify(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
assert any("apex-root" in f for f in fails), \
    "an unlabeled apex-root directory was not detected: %r" % fails
n += 1

run_build()
fails = verify(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
assert not fails, "a genuinely clean build after three corruption rounds still failed: %r" % fails
n += 1

run_build(seed="none")
stray_abspath = os.path.join(STAGE, APEX_SUBDIR, "decompressed", target_name)
with open(stray_abspath, "wb") as f:
    f.write(b"a payload no seedless build may hold")
repackage()
fails = verify_noseed(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
assert any("holds payloads" in f for f in fails), \
    "a payload inside a --seed none build was not detected: %r" % fails
n += 1

run_build(seed="none")
img_ea_rm(DECOMP_IMG, "security.selinux")
fails = verify_noseed(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
assert any("decompressed dir" in f for f in fails), \
    "an unlabeled decompressed/ in a --seed none build was not detected: %r" % fails
n += 1

run_build(seed="none")
fails = verify_noseed(DECOMP_IMG, ACTIVE_IMG, APEX_ROOT_IMG)
assert not fails, "a genuinely clean --seed none build after two corruption rounds still failed: %r" % fails
n += 1

print("check-data-template selftest: %d assertions passed -- content corruption, "
      "a wrong payload label, an unlabeled apex-root directory, a payload inside a "
      "seedless build and an unlabeled seedless directory are all detected, and a "
      "clean build of either shape still passes" % n)
sys.exit(0)
PY
rc=$?
exit $rc

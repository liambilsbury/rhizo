#!/bin/bash
# test the keymint keystore sweep
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${RHIZO_CHECK_ROOT:-$REPO/src/androidd}" || exit

read -r -d '' REGRESSED_STUB <<'PY' || true
import os, hashlib
KEYMINT_MIGRATION_MARKER_NAME = ".rhizo_keymint_migrated"
_KEYMINT_WRAPPED_PREFIX = "persistent.sqlite"
_KEYMINT_NO_KEY_STAMP = "no-master-key"
def _keymint_key_generation(master_key_path):
    try:
        with open(master_key_path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return _KEYMINT_NO_KEY_STAMP
def migrate_keystore_for_keymint_persistence(mount_point, log=print):
    master_key = os.path.join(mount_point, "rhizo_keymint", "master.key")
    generation = _keymint_key_generation(master_key)
    marker = os.path.join(mount_point, KEYMINT_MIGRATION_MARKER_NAME)
    try:
        stamped = open(marker).read().strip()
    except FileNotFoundError:
        stamped = None
    if stamped == generation:
        return
    keystore_dir = os.path.join(mount_point, "misc", "keystore")
    try:
        entries = os.listdir(keystore_dir)
    except OSError:
        entries = []
    removed = []
    for name in sorted(entries):
        if name.startswith(_KEYMINT_WRAPPED_PREFIX):
            path = os.path.join(keystore_dir, name)
            try:
                os.remove(path)
                removed.append(name)
            except OSError:
                pass
    with open(marker, "w") as f:
        f.write(generation)
    if removed:
        log(f"RHIZO_MARKER keymint_migration=removed-{len(removed)}")
    else:
        log("RHIZO_MARKER keymint_migration=not-needed")
PY

read -r -d '' PARTIAL_STUB <<'PY' || true
import os, hashlib, shutil
KEYMINT_MIGRATION_MARKER_NAME = ".rhizo_keymint_migrated"
_KEYMINT_WRAPPED_PREFIX = "persistent.sqlite"
_KEYMINT_NO_KEY_STAMP = "no-master-key"
def _keymint_key_generation(master_key_path):
    try:
        with open(master_key_path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return _KEYMINT_NO_KEY_STAMP
def migrate_keystore_for_keymint_persistence(mount_point, log=print):
    master_key = os.path.join(mount_point, "rhizo_keymint", "master.key")
    generation = _keymint_key_generation(master_key)
    marker = os.path.join(mount_point, KEYMINT_MIGRATION_MARKER_NAME)
    try:
        stamped = open(marker).read().strip()
    except FileNotFoundError:
        stamped = None
    if stamped == generation:
        return
    keystore_dir = os.path.join(mount_point, "misc", "keystore")
    try:
        entries = os.listdir(keystore_dir)
    except OSError:
        entries = []
    removed = []
    for name in sorted(entries):
        if name.startswith(_KEYMINT_WRAPPED_PREFIX):
            path = os.path.join(keystore_dir, name)
            try:
                os.remove(path)
                removed.append(name)
            except OSError:
                pass
    system_de = os.path.join(mount_point, "system_de")
    try:
        users = os.listdir(system_de)
    except OSError:
        users = []
    for user in users:
        spblob_dir = os.path.join(system_de, user, "spblob")
        if os.path.isdir(spblob_dir):
            shutil.rmtree(spblob_dir, ignore_errors=True)
    with open(marker, "w") as f:
        f.write(generation)
    if removed:
        log(f"RHIZO_MARKER keymint_migration=removed-{len(removed)}")
    else:
        log("RHIZO_MARKER keymint_migration=not-needed")
PY

read -r -d '' USER0_ONLY_STUB <<'PY' || true
import os, hashlib, shutil
KEYMINT_MIGRATION_MARKER_NAME = ".rhizo_keymint_migrated"
_KEYMINT_WRAPPED_PREFIX = "persistent.sqlite"
_LOCKSETTINGS_DB_PREFIX = "locksettings.db"
_KEYMINT_NO_KEY_STAMP = "no-master-key"
def _keymint_key_generation(master_key_path):
    try:
        with open(master_key_path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return _KEYMINT_NO_KEY_STAMP
def migrate_keystore_for_keymint_persistence(mount_point, log=print):
    master_key = os.path.join(mount_point, "rhizo_keymint", "master.key")
    generation = _keymint_key_generation(master_key)
    marker = os.path.join(mount_point, KEYMINT_MIGRATION_MARKER_NAME)
    try:
        stamped = open(marker).read().strip()
    except FileNotFoundError:
        stamped = None
    if stamped == generation:
        return
    keystore_dir = os.path.join(mount_point, "misc", "keystore")
    try:
        entries = os.listdir(keystore_dir)
    except OSError:
        entries = []
    removed = []
    for name in sorted(entries):
        if name.startswith(_KEYMINT_WRAPPED_PREFIX):
            path = os.path.join(keystore_dir, name)
            try:
                os.remove(path)
                removed.append(name)
            except OSError:
                pass
    spblob_dir = os.path.join(mount_point, "system_de", "0", "spblob")
    if os.path.isdir(spblob_dir):
        shutil.rmtree(spblob_dir, ignore_errors=True)
    locksettings_dir = os.path.join(mount_point, "system")
    try:
        for name in os.listdir(locksettings_dir):
            if name.startswith(_LOCKSETTINGS_DB_PREFIX):
                os.remove(os.path.join(locksettings_dir, name))
    except OSError:
        pass
    with open(marker, "w") as f:
        f.write(generation)
    if removed:
        log(f"RHIZO_MARKER keymint_migration=removed-{len(removed)}")
    else:
        log("RHIZO_MARKER keymint_migration=not-needed")
PY

read -r -d '' BEHAVIOR_CHECK <<'PY' || true
import os, sys, tempfile
sys.path.insert(0, os.getcwd())
from sandbox import rootfs as rm

failures = []

def make_data():
    return tempfile.mkdtemp()

def write_key(d, key_bytes):
    os.makedirs(os.path.join(d, "rhizo_keymint"), exist_ok=True)
    open(os.path.join(d, "rhizo_keymint", "master.key"), "wb").write(key_bytes)

def write_marker(d, stamp):
    open(os.path.join(d, rm.KEYMINT_MIGRATION_MARKER_NAME), "w").write(stamp)

def write_keystore(d, names):
    ks = os.path.join(d, "misc", "keystore")
    os.makedirs(ks, exist_ok=True)
    for name in names:
        open(os.path.join(ks, name), "wb").write(b"blob")

def write_spblob(d, user, protector_hex):
    sb = os.path.join(d, "system_de", user, "spblob")
    os.makedirs(sb, exist_ok=True)
    open(os.path.join(sb, f"{protector_hex}.spblob"), "wb").write(b"ciphertext")
    open(os.path.join(sb, f"{protector_hex}.password_data"), "wb").write(b"pwd")

def write_locksettings_db(d):
    sysdir = os.path.join(d, "system")
    os.makedirs(sysdir, exist_ok=True)
    open(os.path.join(sysdir, "locksettings.db"), "wb").write(b"sqlite-bytes")
    open(os.path.join(sysdir, "netstats.db"), "wb").write(b"unrelated")

def present(*parts):
    return os.path.exists(os.path.join(*parts))

BLOBS = ["persistent.sqlite", "persistent.sqlite-wal", "vpnprofilestore.sqlite"]

d = make_data()
write_key(d, b"key-v1")
write_marker(d, rm._keymint_key_generation(os.path.join(d, "rhizo_keymint", "master.key")))
import sqlite3
os.makedirs(os.path.join(d, "misc", "keystore"), exist_ok=True)
_db = sqlite3.connect(os.path.join(d, "misc", "keystore", "persistent.sqlite"))
_db.execute("CREATE TABLE keyentry (id INTEGER UNIQUE, key_type INTEGER, domain INTEGER, "
            "namespace INTEGER, alias BLOB, state INTEGER, km_uuid BLOB)")
_db.execute("INSERT INTO keyentry VALUES (1, 0, 2, 103, 'synthetic_password_aaaa', 1, NULL)")
_db.commit()
_db.close()
write_spblob(d, "0", "aaaa")
write_locksettings_db(d)
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
if logs:
    failures.append(f"(a) matching stamp: expected a true no-op, got log output {logs!r}")
if not present(d, "system_de", "0", "spblob", "aaaa.spblob"):
    failures.append("(a) matching stamp: spblob was touched despite the stamp matching the current key")
if not present(d, "system", "locksettings.db"):
    failures.append("(a) matching stamp: locksettings.db was touched despite the stamp matching the current key")

d = make_data()
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
if not present(d, rm.KEYMINT_MIGRATION_MARKER_NAME):
    failures.append("(b) new data: no marker written")
if "RHIZO_MARKER keymint_migration=not-needed" not in "\n".join(logs):
    failures.append(f"(b) new data: expected the not-needed marker line -- {logs!r}")

d = make_data()
write_key(d, b"key-v1")
write_marker(d, "old-generation")
write_keystore(d, BLOBS)
write_spblob(d, "0", "11f4a36211e17143")
write_locksettings_db(d)
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
joined = "\n".join(logs)
if present(d, "misc", "keystore", "persistent.sqlite"):
    failures.append("(c) forced sweep: persistent.sqlite was not removed")
if present(d, "system_de", "0", "spblob"):
    failures.append("(c) forced sweep: user 0's spblob survived a keystore sweep that erased its "
                     "protector's key")
if present(d, "system", "locksettings.db"):
    failures.append("(c) forced sweep: locksettings.db survived")
if "keymint_migration=removed-2" not in joined:
    failures.append(f"(c) forced sweep: no machine-parseable keystore removal marker -- {logs!r}")
if "spblob=removed-1" not in joined:
    failures.append(f"(c) forced sweep: no machine-parseable spblob removal marker -- {logs!r}")
if "locksettings_db=removed-1" not in joined:
    failures.append(f"(c) forced sweep: no machine-parseable locksettings.db removal marker -- {logs!r}")

d = make_data()
write_key(d, b"key-v1")
write_marker(d, "old-generation")
write_keystore(d, BLOBS)
write_spblob(d, "0", "11f4a36211e17143")
write_spblob(d, "10", "aa11bb22cc33dd44")
write_locksettings_db(d)
rm.migrate_keystore_for_keymint_persistence(d, log=lambda *_: None)
if present(d, "system_de", "10", "spblob"):
    failures.append("(d) multi-user: user 10's spblob survived")

d = make_data()
write_key(d, b"key-v1")
write_marker(d, "old-generation")
write_keystore(d, BLOBS)
write_spblob(d, "0", "11f4a36211e17143")
write_locksettings_db(d)
rm.migrate_keystore_for_keymint_persistence(d, log=lambda *_: None)
if not present(d, "misc", "keystore", "vpnprofilestore.sqlite"):
    failures.append("(e) over-reach: vpnprofilestore.sqlite was removed")
if not present(d, "system", "netstats.db"):
    failures.append("(e) over-reach: an unrelated database next to locksettings.db was removed too")

if failures:
    print("FAIL: the keystore/LockSettings consistency sweep does not behave as the fix promises:")
    for f in failures:
        print(" ", f)
    sys.exit(1)
print("ok: keystore, every user's spblob and locksettings.db are swept together on a forced "
      "migration, an ordinary matching-marker boot is a true no-op, a /data with no state at "
      "all is not harmed, and neither vpnprofilestore.sqlite nor an unrelated database is touched")
PY

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  mkdir -p "$t/sandbox"
  trap 'rm -rf "$t"' EXIT
  fail_case() {
    printf '%s' "$2" > "$t/sandbox/rootfs.py"
    RHIZO_CHECK_ROOT="$t" "$SELF" >/tmp/check-keymint-locksettings-sync.selftest.out 2>&1
    local got=$?
    if (( got != 1 )); then
      echo "SELFTEST FAILED: $1 -- expected rc=1 (defect found), got rc=$got" >&2
      sed 's/^/  /' /tmp/check-keymint-locksettings-sync.selftest.out >&2
      exit 1
    fi
  }

  fail_case "today's keystore-only sweep (spblob and locksettings.db left naming a deleted alias)" \
    "$REGRESSED_STUB"
  fail_case "spblob cleared but locksettings.db's protector pointer left in place" \
    "$PARTIAL_STUB"
  fail_case "the sweep only ever looks at system_de/0, leaving a secondary user's old spblob in place" \
    "$USER0_ONLY_STUB"

  echo "selftest ok: detects a keystore-only sweep, a stranded-pointer partial fix, and a user-0-only sweep"
  exit 0
fi

py_out=$(python3 - <<PY
$BEHAVIOR_CHECK
PY
)
rc=$?
echo "$py_out"
exit $rc

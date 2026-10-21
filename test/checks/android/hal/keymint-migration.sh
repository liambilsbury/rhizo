#!/bin/bash
# test the KeyMint keystore migration
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${RHIZO_CHECK_ROOT:-$REPO/src/androidd}" || exit

read -r -d '' BROKEN_STUB <<'PY' || true
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
    if stamped != generation:
        return
    keystore_dir = os.path.join(mount_point, "misc", "keystore")
    try:
        entries = os.listdir(keystore_dir)
    except OSError:
        entries = []
    for name in entries:
        if name.startswith(_KEYMINT_WRAPPED_PREFIX):
            try:
                os.remove(os.path.join(keystore_dir, name))
            except OSError:
                pass
    with open(marker, "w") as f:
        f.write(generation)
    log("RHIZO_MARKER keymint_migration=removed-inverted")
PY

read -r -d '' REVERTED_STUB <<'PY' || true
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
    if os.path.exists(master_key):
        return
    marker = os.path.join(mount_point, KEYMINT_MIGRATION_MARKER_NAME)
    if os.path.exists(marker):
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
        f.write("1")
    if removed:
        log(f"RHIZO_MARKER keymint_migration=removed-{len(removed)}")
    else:
        log("RHIZO_MARKER keymint_migration=not-needed")
PY

WIRED_LAUNCHER='from sandbox.rootfs import migrate_keystore_for_keymint_persistence
def prepare_host_and_data():
    migrate_keystore_for_keymint_persistence("/run/rhizo/data")
'
UNWIRED_LAUNCHER='from sandbox.rootfs import migrate_keystore_for_keymint_persistence
def prepare_host_and_data():
    pass
'

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

def write_blobs(d, names):
    ks = os.path.join(d, "misc", "keystore")
    os.makedirs(ks, exist_ok=True)
    for name in names:
        open(os.path.join(ks, name), "wb").write(b"blob")

def present(d, *parts):
    return os.path.exists(os.path.join(d, *parts))

def marker_content(d):
    try:
        return open(os.path.join(d, rm.KEYMINT_MIGRATION_MARKER_NAME)).read()
    except FileNotFoundError:
        return None

BLOBS = ["persistent.sqlite", "persistent.sqlite-wal", "persistent.sqlite-shm",
         "vpnprofilestore.sqlite"]

d = make_data()
write_key(d, b"key-v1")
write_marker(d, rm._keymint_key_generation(os.path.join(d, "rhizo_keymint", "master.key")))
write_blobs(d, BLOBS)
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
if not all(present(d, "misc", "keystore", n) for n in BLOBS):
    failures.append("(a) matching stamp: a keystore file was removed despite the stamp matching the current key")
if logs:
    failures.append(f"(a) matching stamp: expected a true no-op, got log output {logs!r}")

d = make_data()
write_key(d, b"key-v1")
write_marker(d, rm._keymint_key_generation(os.path.join(d, "rhizo_keymint", "master.key")))
write_key(d, b"key-v2")
new_generation = rm._keymint_key_generation(os.path.join(d, "rhizo_keymint", "master.key"))
write_blobs(d, BLOBS)
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
if present(d, "misc", "keystore", "persistent.sqlite"):
    failures.append("(b) key changed since the stamp: persistent.sqlite was not swept")
if marker_content(d) != new_generation:
    failures.append("(b) key changed since the stamp: marker was not restamped to the current key's generation")
if "RHIZO_MARKER keymint_migration=removed-3" not in "\n".join(logs):
    failures.append(f"(b) key changed since the stamp: no machine-parseable removal marker -- {logs!r}")

d = make_data()
write_key(d, b"key-v1")
write_blobs(d, BLOBS)
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
if present(d, "misc", "keystore", "persistent.sqlite"):
    failures.append("(c) no stamp yet, key present: persistent.sqlite was not swept")
if not present(d, rm.KEYMINT_MIGRATION_MARKER_NAME):
    failures.append("(c) no stamp yet, key present: no marker written after the migration")
if "RHIZO_MARKER keymint_migration=removed-3" not in "\n".join(logs):
    failures.append(f"(c) no stamp yet, key present: no machine-parseable removal marker -- {logs!r}")

d = make_data()
write_blobs(d, BLOBS)
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
if present(d, "misc", "keystore", "persistent.sqlite"):
    failures.append("(d) pre-fix data: persistent.sqlite was not removed")
if present(d, "misc", "keystore", "persistent.sqlite-wal") or present(d, "misc", "keystore", "persistent.sqlite-shm"):
    failures.append("(d) pre-fix data: a persistent.sqlite sidecar was not removed")
if not present(d, "misc", "keystore", "vpnprofilestore.sqlite"):
    failures.append("(d) pre-fix data: vpnprofilestore.sqlite was removed")
if "RHIZO_MARKER keymint_migration=removed-3" not in "\n".join(logs):
    failures.append(f"(d) pre-fix data: no machine-parseable removal marker naming the 3 removed files -- {logs!r}")

d = make_data()
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
if not present(d, rm.KEYMINT_MIGRATION_MARKER_NAME):
    failures.append("(e) new data: no marker written")
if "RHIZO_MARKER keymint_migration=not-needed" not in "\n".join(logs):
    failures.append(f"(e) new data: expected the not-needed marker line -- {logs!r}")

d = make_data()
write_blobs(d, BLOBS)
rm.migrate_keystore_for_keymint_persistence(d, log=lambda *_: None)
logs = []
rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
if logs:
    failures.append(f"(f) repeat boot, still no key: expected a true no-op, got log output {logs!r}")

import hashlib, shutil, sqlite3

def sha(b):
    return hashlib.sha256(b).hexdigest()

PROT = "11f4a36211e17143"
ALIAS = "synthetic_password_" + PROT

def write_spblob(d, user, protector_hex):
    sb = os.path.join(d, "system_de", user, "spblob")
    os.makedirs(sb, exist_ok=True)
    for state in ("spblob", "pwd", "metrics"):
        open(os.path.join(sb, f"{protector_hex}.{state}"), "wb").write(b"state")
    open(os.path.join(sb, "0000000000000000.handle"), "wb").write(b"handle")

def write_locksettings_db(d):
    s = os.path.join(d, "system")
    os.makedirs(s, exist_ok=True)
    open(os.path.join(s, "locksettings.db"), "wb").write(b"sqlite-bytes")
    open(os.path.join(s, "netstats.db"), "wb").write(b"unrelated")

def write_keystore_db(d, rows):
    """rows of (alias, state) in keystore2's persistent.keyentry table
    (system/security/keystore2/src/database.rs): state 1 is KeyLifeCycle::Live,
    2 is Unreferenced. LockSettings keys its protectors in Domain::SELINUX (2),
    NAMESPACE_LOCKSETTINGS (103)."""
    ks = os.path.join(d, "misc", "keystore")
    os.makedirs(ks, exist_ok=True)
    db = sqlite3.connect(os.path.join(ks, "persistent.sqlite"))
    db.execute("CREATE TABLE keyentry (id INTEGER UNIQUE, key_type INTEGER, domain INTEGER, "
               "namespace INTEGER, alias BLOB, state INTEGER, km_uuid BLOB)")
    for i, (alias, state) in enumerate(rows):
        db.execute("INSERT INTO keyentry VALUES (?, 0, 2, 103, ?, ?, NULL)", (i + 1, alias, state))
    db.commit()
    db.close()
    open(os.path.join(ks, "vpnprofilestore.sqlite"), "wb").write(b"vpn")

class FixtureError(Exception):
    pass

def run_case(name, body):
    """body(d, deny): deny(path) makes path unreadable the way
    /data/rhizo_keymint (0700 nobody) and misc/keystore (0700 keystore) are to
    rhizo_host on a restart, which holds neither dac_override nor
    dac_read_search, and proves the denial took"""
    d = make_data()
    denied = []
    def deny(path):
        os.chmod(path, 0)
        denied.append(path)
        try:
            os.listdir(path) if os.path.isdir(path) else open(path, "rb").close()
        except PermissionError:
            return
        raise FixtureError(f"{path} stayed readable at mode 0 -- this process holds DAC override")
    try:
        body(d, deny)
    except FixtureError as e:
        failures.append(f"{name}: fixture could not reproduce the restart: {e}")
    except Exception as e:
        failures.append(f"{name}: raised {type(e).__name__}: {e}")
    finally:
        for p in denied:
            os.chmod(p, 0o700)
        shutil.rmtree(d)

def vm_with_protector(d, key, rows):
    write_key(d, key)
    write_marker(d, sha(key))
    write_keystore_db(d, rows)
    write_spblob(d, "0", PROT)
    write_locksettings_db(d)

def expect_untouched(name, d, stamp):
    for parts in (("misc", "keystore", "persistent.sqlite"), ("system_de", "0", "spblob", PROT + ".spblob"),
                  ("system", "locksettings.db")):
        if not present(d, *parts):
            failures.append(f"{name}: {os.path.join(*parts)} was removed")
    if marker_content(d) != stamp:
        failures.append(f"{name}: the marker was rewritten to {marker_content(d)!r}")

def expect_marker_line(name, logs, line):
    if line not in "\n".join(logs):
        failures.append(f"{name}: no '{line}' line -- {logs!r}")

def g(d, deny):
    vm_with_protector(d, b"key-v1", [(ALIAS, 1)])
    deny(os.path.join(d, "rhizo_keymint"))
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    expect_untouched("(g) master.key unreadable", d, sha(b"key-v1"))
    expect_marker_line("(g) master.key unreadable", logs, "RHIZO_MARKER keymint_migration=unverifiable")
run_case("(g) master.key unreadable", g)

def h(d, deny):
    vm_with_protector(d, b"key-v1", [(ALIAS, 1)])
    deny(os.path.join(d, rm.KEYMINT_MIGRATION_MARKER_NAME))
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    os.chmod(os.path.join(d, rm.KEYMINT_MIGRATION_MARKER_NAME), 0o600)
    expect_untouched("(h) stamp unreadable", d, sha(b"key-v1"))
    expect_marker_line("(h) stamp unreadable", logs, "RHIZO_MARKER keymint_migration=unverifiable")
run_case("(h) stamp unreadable", h)

def i(d, deny):
    rm.migrate_keystore_for_keymint_persistence(d, log=lambda *_: None)
    if marker_content(d) != rm._KEYMINT_NO_KEY_STAMP:
        failures.append(f"(i) boot 1 of a new /data stamped {marker_content(d)!r}, not the no-key stamp")
    write_key(d, b"created-by-boot-1")
    write_keystore_db(d, [(ALIAS, 1)])
    write_spblob(d, "0", PROT)
    write_locksettings_db(d)
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    expect_untouched("(i) second boot of a new /data", d, sha(b"created-by-boot-1"))
    if "keymint_migration=removed" in "\n".join(logs):
        failures.append(f"(i) second boot of a new /data swept the state its own first boot wrote -- {logs!r}")
    expect_marker_line("(i) second boot of a new /data", logs, "RHIZO_MARKER keymint_migration=key-recorded")
run_case("(i) second boot of a new /data", i)

def j(d, deny):
    vm_with_protector(d, b"key-v1", [("some_app_key", 1)])
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    if present(d, "system_de", "0", "spblob"):
        failures.append("(j) split vm: user 0's spblob survived though its protector's alias is gone from keystore2")
    if present(d, "system", "locksettings.db"):
        failures.append("(j) split vm: locksettings.db survived")
    for parts in (("misc", "keystore", "persistent.sqlite"), ("misc", "keystore", "vpnprofilestore.sqlite"),
                  ("system", "netstats.db")):
        if not present(d, *parts):
            failures.append(f"(j) split vm: {os.path.join(*parts)} was removed")
    if marker_content(d) != sha(b"key-v1"):
        failures.append("(j) split vm: the marker was rewritten")
    expect_marker_line("(j) split vm", logs,
                       "RHIZO_MARKER keymint_migration=lockstate-repaired spblob=removed-1 locksettings_db=removed-1")
run_case("(j) split vm", j)

def k(d, deny):
    vm_with_protector(d, b"key-v1", [(ALIAS, 1), ("some_app_key", 1)])
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    expect_untouched("(k) protector key live", d, sha(b"key-v1"))
    if logs:
        failures.append(f"(k) protector key live: expected a true no-op, got {logs!r}")
run_case("(k) protector key live", k)

def l(d, deny):
    vm_with_protector(d, b"key-v1", [(ALIAS, 2)])
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    if present(d, "system_de", "0", "spblob"):
        failures.append("(l) alias only Unreferenced: user 0's spblob survived")
    expect_marker_line("(l) alias only Unreferenced", logs, "RHIZO_MARKER keymint_migration=lockstate-repaired")
run_case("(l) alias only Unreferenced", l)

def m(d, deny):
    vm_with_protector(d, b"key-v1", [])
    deny(os.path.join(d, "misc", "keystore"))
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    os.chmod(os.path.join(d, "misc", "keystore"), 0o700)
    expect_untouched("(m) keystore unreadable", d, sha(b"key-v1"))
    expect_marker_line("(m) keystore unreadable", logs, "RHIZO_MARKER keymint_migration=unverifiable")
run_case("(m) keystore unreadable", m)

def n(d, deny):
    vm_with_protector(d, b"key-v1", [])
    open(os.path.join(d, "misc", "keystore", "persistent.sqlite"), "wb").write(b"not a database")
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    expect_untouched("(n) keystore database unreadable", d, sha(b"key-v1"))
    expect_marker_line("(n) keystore database unreadable", logs, "RHIZO_MARKER keymint_migration=unverifiable")
run_case("(n) keystore database unreadable", n)

def o(d, deny):
    vm_with_protector(d, b"key-v1", [])
    os.remove(os.path.join(d, "misc", "keystore", "persistent.sqlite"))
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    if present(d, "system_de", "0", "spblob") or present(d, "system", "locksettings.db"):
        failures.append("(o) keystore database gone: the lock state naming its aliases survived")
    expect_marker_line("(o) keystore database gone", logs, "RHIZO_MARKER keymint_migration=lockstate-repaired")
run_case("(o) keystore database gone", o)

def p(d, deny):
    vm_with_protector(d, b"key-v1", [(ALIAS, 1)])
    write_spblob(d, "0", "aa11bb22cc33dd44")
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    expect_untouched("(p) mixed protectors", d, sha(b"key-v1"))
    if not present(d, "system_de", "0", "spblob", "aa11bb22cc33dd44.spblob"):
        failures.append("(p) mixed protectors: the orphaned protector was removed from a directory holding a live one")
    expect_marker_line("(p) mixed protectors", logs, "RHIZO_MARKER keymint_migration=lockstate-mixed users=0")
run_case("(p) mixed protectors", p)

def q(d, deny):
    vm_with_protector(d, b"key-v1", [("synthetic_password_aa11bb22cc33dd44", 1)])
    write_spblob(d, "10", "aa11bb22cc33dd44")
    logs = []
    rm.migrate_keystore_for_keymint_persistence(d, log=logs.append)
    if present(d, "system_de", "0", "spblob"):
        failures.append("(q) two users: user 0's orphaned spblob survived")
    if not present(d, "system_de", "10", "spblob", "aa11bb22cc33dd44.spblob"):
        failures.append("(q) two users: user 10's live protector was removed")
    expect_marker_line("(q) two users", logs,
                       "RHIZO_MARKER keymint_migration=lockstate-repaired spblob=removed-1 locksettings_db=removed-1")
run_case("(q) two users", q)

if failures:
    print("FAIL: the KeyMint keystore migration does not behave as the fix promises:")
    for f in failures:
        print(" ", f)
    sys.exit(1)
print("ok: all seventeen /data states behave as the fix promises")
PY

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  mkdir -p "$t/sandbox"
  trap 'rm -rf "$t"' EXIT
  fail_case() {
    RHIZO_CHECK_ROOT="$t" PYTHONPATH="$REPO/src/androidd" "$SELF" >/tmp/check-keymint-migration.selftest.out 2>&1
    local got=$?
    if (( got != 1 )) || ! grep -qF -- "$2" /tmp/check-keymint-migration.selftest.out; then
      echo "SELFTEST FAILED: $1 -- expected rc=1 printing '$2', got rc=$got" >&2
      sed 's/^/  /' /tmp/check-keymint-migration.selftest.out >&2
      exit 1
    fi
  }
  revert() {
    OLD="$1" NEW="$2" SRC="$REPO/src/androidd/sandbox/rootfs.py" DST="$t/sandbox/rootfs.py" python3 -c '
import os, sys
src = open(os.environ["SRC"]).read()
if src.count(os.environ["OLD"]) != 1:
    sys.exit("SELFTEST FAILED: the fix to revert is not in sandbox/rootfs.py exactly once: %r" % os.environ["OLD"])
open(os.environ["DST"], "w").write(src.replace(os.environ["OLD"], os.environ["NEW"]))
' || exit 1
    printf '%s' "$WIRED_LAUNCHER" > "$t/boot.py"
  }

  printf '%s' "$BROKEN_STUB" > "$t/sandbox/rootfs.py"
  printf '%s' "$WIRED_LAUNCHER" > "$t/boot.py"
  fail_case "an inverted stamp comparison (sweeps on a match instead of a mismatch)" \
    "(a) matching stamp: a keystore file was removed"

  cp "$REPO/src/androidd/sandbox/rootfs.py" "$t/sandbox/rootfs.py"
  printf '%s' "$UNWIRED_LAUNCHER" > "$t/boot.py"
  fail_case "boot.py no longer calling the migration" \
    "boot.py no longer calls migrate_keystore_for_keymint_persistence()"

  printf '%s' "$REVERTED_STUB" > "$t/sandbox/rootfs.py"
  printf '%s' "$WIRED_LAUNCHER" > "$t/boot.py"
  fail_case "the stamp re-validation reverted to a plain master.key existence check" \
    "(c) no stamp yet, key present: persistent.sqlite was not swept"

  revert $'    except PermissionError as e:\n        _keymint_unverifiable(master_key, e, log)\n        return\n' \
         $'    except FileNotFoundError:\n        raise\n'
  fail_case "an unreadable master.key raising out of the migration, the restart's supervisor death" \
    "(g) master.key unreadable: raised PermissionError"

  revert $'        _keymint_unverifiable(marker, e, log)\n        return\n' $'        stamped = None\n'
  fail_case "an unreadable stamp taken as absent" \
    "(h) stamp unreadable: misc/keystore/persistent.sqlite was removed"

  revert $'    if stamped == _KEYMINT_NO_KEY_STAMP:\n' $'    if False:\n'
  fail_case "a key created after a no-key stamp swept instead of recorded" \
    "(i) second boot of a new /data swept the state its own first boot wrote"

  revert $'    if stamped == generation:\n        _repair_orphaned_lockstate(mount_point, log)\n        return\n' \
         $'    if stamped == generation:\n        return\n'
  fail_case "a matching stamp skipping the LockSettings check" \
    "(j) split vm: user 0's spblob survived"

  revert 'rows = db.execute("SELECT alias FROM keyentry WHERE state = ?", (_KEYENTRY_LIVE,)).fetchall()' 'rows = []'
  fail_case "every protector taken as orphaned" \
    "(k) protector key live: system_de/0/spblob/11f4a36211e17143.spblob was removed"

  revert 'WHERE state = ?", (_KEYENTRY_LIVE,)' 'WHERE state != ?", (-1,)'
  fail_case "a keyentry row scheduled for garbage collection taken as a live key" \
    "(l) alias only Unreferenced: user 0's spblob survived"

  revert $'        _keymint_unverifiable(os.path.join(mount_point, "misc", "keystore", "persistent.sqlite"), e, log)\n        return\n' \
         $'        live = set()\n'
  fail_case "an unreadable keystore taken as holding no key" \
    "(m) keystore unreadable: system_de/0/spblob/11f4a36211e17143.spblob was removed"

  revert '        if len(gone) == len(ids):' '        if gone:'
  fail_case "a user holding a live protector cleared for an orphaned one" \
    "(p) mixed protectors: system_de/0/spblob/11f4a36211e17143.spblob was removed"

  revert $'    for user in orphaned:\n' $'    for user in protectors:\n'
  fail_case "a live user's spblob cleared beside an orphaned user's" \
    "(q) two users: user 10's live protector was removed"

  echo "selftest ok: detects an inverted stamp comparison, a stripped-out call site, a revert to the plain existence check, and each restart, key-record and LockSettings-repair fix undone on its own"
  exit 0
fi

rc=0

if ! grep -q 'migrate_keystore_for_keymint_persistence(' boot.py 2>/dev/null; then
  echo "FAIL: boot.py no longer calls migrate_keystore_for_keymint_persistence() at all" >&2
  rc=1
else
  release_line=$(grep -n 'check_data_release_marker(' boot.py | head -1 | cut -d: -f1)
  migrate_line=$(grep -n 'migrate_keystore_for_keymint_persistence(' boot.py | tail -1 | cut -d: -f1)
  if [[ -n "$release_line" ]] && { [[ -z "$migrate_line" ]] || (( migrate_line <= release_line )) || (( migrate_line - release_line > 15 )); }; then
    echo "FAIL: migrate_keystore_for_keymint_persistence() is not called right after check_data_release_marker(), before Android starts" >&2
    rc=1
  fi
fi

PYRUN=(python3)
(( EUID == 0 )) && PYRUN=(setpriv --bounding-set "-dac_override,-dac_read_search" python3)
py_out=$("${PYRUN[@]}" - <<PY
$BEHAVIOR_CHECK
PY
)
py_rc=$?
echo "$py_out"
(( py_rc != 0 )) && rc=1

(( rc == 0 )) && echo "the KeyMint keystore migration is wired into boot.py and behaves correctly"
exit $rc

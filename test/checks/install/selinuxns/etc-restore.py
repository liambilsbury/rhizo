#!/usr/bin/env python3
import glob
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import install_dirs  # noqa: E402
DATABASES = ("passwd", "group", "shadow", "gshadow")
TEARDOWN_LIB = "src/install/teardown/teardown-lib.sh"
PKG_LIB = "src/install/lib/pkg-lib.sh"
ACCOUNT_FILE = r"/etc/(?:passwd|group|shadow|gshadow)\b"
TEXT_EDIT = re.compile(r"(?:sed\s+-i|>>?|\btee\b|\bcp\b|\bmv\b|\binstall\b|\bvipw\b|\bvigr\b)[^\n;|&]*" + ACCOUNT_FILE)

BASELINE = {
    "passwd": "root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
              "owner:x:1001:1001:Owner:/home/user:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n",
    "group": "root:x:0:\ndaemon:x:1:\nowner:x:1001:\nnogroup:x:65534:\n",
    "shadow": "root:*:19000:0:99999:7:::\ndaemon:*:19000:0:99999:7:::\nowner:!:19000:0:99999:7:::\n"
              "nobody:*:19000:0:99999:7:::\n",
    "gshadow": "root:*::\ndaemon:*::\nowner:!::\nnogroup:*::\n",
}
EXTRA = {"subuid": "owner:100000:65536\n", "subgid": "owner:100000:65536\n", "subuid-": "owner:100000:65535\n",
         "subgid-": "owner:100000:65535\n", "fstab": "LABEL=root / ext4 defaults 0 1\n"}
BASELINE_BACKUP = {name: text.replace("nobody", "nobody2").replace("nogroup", "nogroup2")
                   for name, text in BASELINE.items()}

HARNESS = r"""
set -u
ROOT=$1
LIB=$2
PKG_LIB=$3
mkdir -p "$ROOT/tmp"
RECORD=$ROOT/tmp/created-by-install
getent() {
  case $2 in
    ''|*[!0-9]*) grep -m1 "^$2:" "$ROOT/etc/$1" ;;
    *) awk -F: -v id="$2" '$3 == id { print; exit }' "$ROOT/etc/$1" ;;
  esac
}
userdel() { command userdel -R "$ROOT" "$@"; }
groupdel() { command groupdel -R "$ROOT" "$@"; }
groupadd() { command groupadd -R "$ROOT" "$@"; }
useradd() { command useradd -R "$ROOT" "$@"; }
usermod() { command usermod -R "$ROOT" "$@"; }
# run the adduser forms as useradd
adduser() {
  local uid=() name
  while [ $# -gt 0 ]; do
    case $1 in
      --uid) uid=(--uid "$2"); shift ;;
      --home|--shell) shift ;;
      --system|--no-create-home|--group) ;;
      *) name=$1 ;;
    esac
    shift
  done
  useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "${uid[@]}" "$name"
}
eval "$(awk '/^pkg_sys_account\(\) *\{/ { on = 1 } on { print } on && /^}/ { exit }' "$PKG_LIB")"
PKG_DEBIAN_VERSION=$LIB
source "$LIB"

install_rhizo() {
  getent group rhizo >/dev/null || echo group:rhizo >> "$RECORD"
  groupadd -f rhizo
  usermod -aG rhizo owner
  pkg_sys_account rhizo-netbridged && printf 'user:rhizo-netbridged\ngroup:rhizo-netbridged\n' >> "$RECORD"
  pkg_sys_account rhizo-uhid && printf 'user:rhizo-uhid\ngroup:rhizo-uhid\n' >> "$RECORD"
  if [ -n "${WITH_APPWATCH:-}" ]; then
    adduser --uid 1000 --system --no-create-home --group rhizo-appwatch
    printf 'user:rhizo-appwatch\ngroup:rhizo-appwatch\n' >> "$RECORD"
  fi
}

uninstall_rhizo() {
  groupdel rhizo
  teardown_remove_appwatch_account "$RECORD"
  teardown_remove_netbridged_account "$RECORD"
  teardown_remove_recorded_account "$RECORD" "$RHIZO_TEARDOWN_LIB_UHID_ACCOUNT"
}

install_rhizo
uninstall_rhizo
"""


def write_fixture(root, backups):
    """write the baseline files under a root"""
    os.makedirs(os.path.join(root, "etc"), exist_ok=True)
    open(os.path.join(root, "etc", ".pwd.lock"), "w").close()
    for name in DATABASES:
        with open(os.path.join(root, "etc", name), "w") as fh:
            fh.write(BASELINE[name])
        with open(os.path.join(root, "etc", name + "-"), "w") as fh:
            fh.write(BASELINE_BACKUP[name] if backups else BASELINE[name])
    for name, text in EXTRA.items():
        with open(os.path.join(root, "etc", name), "w") as fh:
            fh.write(text)


def file_bytes(root, name):
    """return a fixture file's bytes"""
    with open(os.path.join(root, "etc", name), "rb") as fh:
        return fh.read()


def run_lifecycle(root, harness=HARNESS, appwatch=True):
    """run the install and uninstall on a root"""
    script = os.path.join(os.path.dirname(root), "lifecycle.sh")
    with open(script, "w") as fh:
        fh.write(harness)
    env = dict(os.environ, WITH_APPWATCH="1" if appwatch else "", PATH="/usr/sbin:/usr/bin:/sbin:/bin")
    return subprocess.run(["unshare", "-Ur", "bash", script, root, os.path.join(REPO, TEARDOWN_LIB),
                           os.path.join(REPO, PKG_LIB)], capture_output=True, text=True, timeout=120, env=env)


def lifecycle_findings(harness=HARNESS):
    """return account files changed by uninstall"""
    bad = []
    with tempfile.TemporaryDirectory() as work:
        root = os.path.join(work, "root")
        write_fixture(root, backups=True)
        before = {name: file_bytes(root, name) for name in DATABASES}
        before_backups = {name: file_bytes(root, name + "-") for name in DATABASES}
        done = run_lifecycle(root, harness)
        if done.returncode != 0:
            return ["the install and uninstall exited %d: %s" % (done.returncode, done.stderr.strip())]
        for name in DATABASES:
            after = file_bytes(root, name)
            if after != before[name]:
                bad.append("/etc/%s differs after the uninstall: %r" % (name, after))
            if file_bytes(root, name + "-") == before_backups[name]:
                bad.append("/etc/%s- is unchanged" % name)
    return bad


def text_edit_findings(files):
    """return lines editing account files"""
    bad = []
    for rel, text in sorted(files.items()):
        for number, line in enumerate(text.splitlines(), 1):
            if not line.lstrip().startswith("#") and TEXT_EDIT.search(line):
                bad.append("%s:%d edits an account file by text: %s" % (rel, number, line.strip()))
    return bad


def tree_files():
    """return the install and maintainer scripts"""
    paths = [p for d in install_dirs(REPO) for p in glob.glob(os.path.join(REPO, d, "*.sh"))] + glob.glob(os.path.join(REPO, "debian/rhizo.p*"))
    return {os.path.relpath(p, REPO): open(p, encoding="utf-8").read() for p in paths}


def findings():
    """return every finding"""
    return lifecycle_findings() + text_edit_findings(tree_files())


def selftest():
    """check the tree passes and planted defects fail"""
    bad = []
    got = findings()
    if got:
        bad.append("the tree has findings: %r" % got)
    leaves_group = HARNESS.replace('teardown_remove_recorded_account "$RECORD" "$RHIZO_TEARDOWN_LIB_UHID_ACCOUNT"',
                                   'userdel rhizo-uhid')
    if leaves_group == HARNESS:
        bad.append("the planted harness did not change")
    got = lifecycle_findings(leaves_group)
    if not any("/etc/group differs" in g or "/etc/passwd differs" in g for g in got):
        bad.append("a removal that leaves an account behind was not named: %r" % got)
    got = text_edit_findings({"x.sh": "sed -i '/rhizo/d' /etc/passwd\n", "y.sh": "echo rhizo:x >> /etc/group\n",
                              "z.sh": "userdel rhizo-uhid\n", "w.sh": "getent passwd 1000 < /etc/passwd\n"})
    if sorted(g.split(":")[0] for g in got) != ["x.sh", "y.sh"]:
        bad.append("text edits of account files were not named by file: %r" % got)
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else findings()
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

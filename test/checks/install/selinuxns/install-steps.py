#!/usr/bin/env python3
# limit: the source scan misses a path or tool name assembled at run time
import os, re, shutil, subprocess, sys, tempfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import install_dirs  # noqa: E402
TESTS = os.path.join(REPO, "src", "install", "tests")
HOST_MODE = ("usr/lib/systemd/system/service.d/50-rhizo-private-users.conf",
             "usr/lib/systemd/system/avahi-daemon.service.d/50-rhizo-policy.conf",
             "usr/lib/systemd/system/accounts-daemon.service.d/rhizo-skel.conf",
             "usr/lib/systemd/system/user@.service.d/rhizo-user-prep.conf",
             "usr/lib/systemd/system/session-.scope.d/rhizo-session-vt.conf",
             "etc/profile.d/rhizo-console-vt.sh",
             "usr/share/fish/vendor_conf.d/rhizo-console-acl.fish",
             "etc/apt/apt.conf.d/50rhizo")
ARCH_HOST_MODE = ()
HOST_MODE_STEPS = ("pkg_pacman_downloaduser_off", "pkg_login_tty_on", "pkg_host_mode_links", "pkg_enter_host_mode")
LOGIN_DEFS = "TTYGROUP\ttty\nTTYPERM\t0600\n"
SELINUX_CONFIG = "SELINUX=disabled\nSELINUXTYPE=default\n"
PACMAN_CONF = "[options]\nDownloadUser = alpm\n"
SECURITY_TOKEN = re.compile(r"(^| )(lsm|security|selinux|enforcing)=")
FILE_TOKEN = re.compile(r"(^|[\s\"'])(lsm|security|selinux|enforcing)=")
SOURCE_GLOBS = tuple(os.path.join(d, ext) for d in install_dirs(REPO) for ext in ("*.sh", "*.py")) + (
    "debian/rhizo.preinst", "debian/rhizo.postinst", "debian/rhizo.prerm", "debian/rhizo.postrm.in",
    "archlinux/rhizo/rhizo.install")
SELINUX_TOOLS = "setenforce|load_policy|semodule|restorecon|fixfiles|setfiles|chcon|semanage|setsebool|selinux-activate"
TOOL_PATH = re.compile(r"/(?:usr/)?s?bin/(%s)\b" % SELINUX_TOOLS)
HOST_SELINUX = r"(?:/etc/selinux|/sys/fs/selinux)"
LITERAL_TARGET = r"[\"']?(?:\$\{?\w+\}?)?%s" % HOST_SELINUX
WRITE_TOOLS = re.compile(r"(?:^|[\s;&|(])(tee|touch|cp|mv|install|ln|truncate|dd|sed\s+-i\S*)\s")

INSTALL_HARNESS = r'''
set -uo pipefail
TREE=$1 TMP=$2 FLAVOR=$3 MODE=$4 LSM=${5:-stock}
. "$TREE/src/install/tests/fixtures/bootloader-fixtures.sh"
R=$TMP/root; mkdir -p "$R" "$TMP/tools" "$TMP/install"
export RHIZO_BL_ROOT=$R
link_bootstrap_tools "$TMP/tools"
ln -s "$BL_FIX_BASH" "$TMP/tools/bash"
if [[ "$FLAVOR" == ubuntu ]]; then
  add_ubuntu_host "$R"
  touch "$R/boot/vmlinuz-7.1.0-rc1-rhizo"
  run_stub "$R/bin/update-grub"
else
  add_cachyos_host "$R" limine
  echo binder > "$R/sys/module/binder/parameters/devices"
  touch "$R/boot/vmlinuz-linux-rhizo" "$R/boot/initramfs-linux-rhizo.img"
  run_stub "$R/bin/limine-update"
fi
: > "$R/calls"
echo "$MODE" > "$R/selinux-mode"
if [[ "$LSM" == selinux ]]; then
  echo capability,landlock,lockdown,yama,selinux,bpf > "$R/sys/kernel/security/lsm"
  mkdir -p "$R/sys/fs/selinux"
fi
mkdir -p "$R/etc/selinux"
printf 'SELINUX=disabled\nSELINUXTYPE=default\n' > "$R/etc/selinux/config"
for f in bootstrap/bootstrap.sh lib/host-flavor.sh bootstrap/bootloader.sh lib/pkg-lib.sh; do
  mkdir -p "$TMP/install/${f%/*}" "$TMP/install/teardown"
  cp "$TREE/src/install/$f" "$TMP/install/$f"
done
for t in ln cmp; do ln -s "$(type -P "$t")" "$TMP/tools/$t"; done
printf '#!/bin/sh\necho "chown $*" >> "%s/chowns"\n' "$R" > "$R/bin/chown"
printf '#!/bin/sh\necho "APT_LISTS='"'"'%s/apt/lists/'"'"'"\necho "APT_ARCHIVES='"'"'%s/apt/archives/'"'"'"\n' "$R" "$R" \
  > "$TMP/apt-config"
chmod +x "$R/bin/chown" "$TMP/apt-config"
mkdir -p "$R/apt/lists/partial" "$R/apt/lists/auxfiles" "$R/apt/archives/partial"
[[ "$FLAVOR" == ubuntu ]] && cp "$TMP/apt-config" "$R/bin/apt-config"
printf '#!/bin/bash\necho "teardown $*" >> "%s/steps"\necho RHIZO_TEARDOWN_HOST_LABELS_CLEARED=1\n' "$R" \
  > "$TMP/install/teardown/teardown.sh"
cat >> "$TMP/install/bootstrap/bootloader.sh" <<'SPY'
eval "spied_$(declare -f bootloader_write)"
eval "spied_$(declare -f bootloader_make_rhizo_default 2>/dev/null || echo 'bootloader_make_rhizo_default() { return 0; }')"
# log the call and run the library's own
bootloader_write() { echo "bootloader_write $*" >> "$RHIZO_BL_ROOT/spy"; spied_bootloader_write "$@"; }
# log the call and run the library's own
bootloader_make_rhizo_default() { echo "bootloader_make_rhizo_default $*" >> "$RHIZO_BL_ROOT/spy"; spied_bootloader_make_rhizo_default "$@"; }
SPY
chmod +x "$TMP/install/bootstrap/bootstrap.sh"
cat > "$TMP/run-install.sh" <<EOF
RHIZO_CLI_SOURCE_ONLY=1 RHIZO_LIB_DIR="$TMP/lib" source "$TREE/src/install/cli/rhizo.sh"
INSTALL_DIR="$TMP/install"
# record a step cmd_install takes
step() { echo "\$1" >> "$R/steps"; }
resolve_uid1000() { step resolve_uid1000; }
ensure_broker_group() { step ensure_broker_group; }
seed_apk_handler() { step seed_apk_handler; }
write_profile_key() { step write_profile_key; }
apply_profile() { step apply_profile; }
read_capability() { echo desktop; }
systemctl() { step "systemctl \$*"; }
cmd_install "\$@"
EOF
. "$TREE/src/install/tests/lib/host-write-guard.sh"
cp -a "$R" "$TMP/root-before"
env -i PATH="$(guard_path "$R/bin:$TMP/tools")" HOME="$R" RHIZO_BL_ROOT="$R" \
  RHIZO_OS_RELEASE="$R/etc/os-release" RHIZO_BOOT_DIR="$R/boot" RHIZO_PROC_CONFIG="$R/proc/config.gz" \
  RHIZO_LSM_FILE="$R/sys/kernel/security/lsm" RHIZO_BOOTSTRAP_CMDLINE="$R/proc/cmdline" \
  RHIZO_BOOTSTRAP_SWAPS="$R/proc/swaps" RHIZO_BOOTSTRAP_MEMINFO="$R/proc/meminfo" \
  RHIZO_BOOTSTRAP_SELINUXFS="$R/sys/fs/selinux" RHIZO_BOOTSTRAP_ZSWAP="$R/sys/module/zswap/parameters/enabled" \
  RHIZO_BOOTSTRAP_ATTR_CURRENT="$R/proc/self/attr/current" \
  RHIZO_BINDER_DEVICES_FILE="$R/sys/module/binder/parameters/devices" RHIZO_BOOTSTRAP_FSTAB="$R/etc/fstab" \
  RHIZO_BOOTSTRAP_SWAPFILE="$R/swapfile" RHIZO_STATE_DIR="$R/var/lib/rhizo" RHIZO_ETC_DIR="$R/etc/rhizo" \
  RHIZO_SELINUX_MODE_HELPER="$R/bin/rhizo-selinux-mode" RHIZO_SELINUX_MODE_FILE="$R/run/rhizo-selinux-mode" \
  RHIZO_PKG_ROOT="$R" RHIZO_CLI_TEST_NO_ROOT=1 "$BL_FIX_UNSHARE" -r "$BL_FIX_BASH" "$TMP/run-install.sh" > "$TMP/out" 2>&1
echo "rc=$?" >> "$TMP/out"
'''

CONFIGURE_HARNESS = r'''
TREE=$1 TMP=$2 SH=$3
LIB=$TREE/src/install/lib/pkg-lib.sh
. "$TREE/src/install/tests/lib/host-write-guard.sh"
PATH=$(guard_path "$TMP/bin:/usr/bin:/bin")
STEPS=$(sed -n 's/^ *pkg_step=\([a-z_]*\);.*/\1/p' "$LIB")
for s in $STEPS; do
  case $s in pkg_read_selinux_mode|pkg_host_mode_links) continue ;; esac
  printf '%s() { echo %s >> "%s/steps"; }\n' "$s" "$s" "$TMP"
done > "$TMP/stub-steps.sh"
RHIZO_INSTALL_FAILED="$TMP/install-failed" RHIZO_INSTALL_RECORD="$TMP/record" RHIZO_PKG_ROOT="$TMP/pkgroot" \
  RHIZO_SELINUX_MODE_HELPER="$TMP/bin/rhizo-selinux-mode" PATH="$PATH" "$SH" -c '
    . "$1"; . "$2"
    pkg_configure "" ""; echo "rc=$?"' configure "$LIB" "$TMP/stub-steps.sh" "$TMP" > "$TMP/out" 2>&1
report_escapes >> "$TMP/out"
'''

POSTINST_HARNESS = r'''
TREE=$1 TMP=$2
. "$TREE/src/install/tests/lib/host-write-guard.sh"
mkdir -p "$TMP/apt/lists/partial" "$TMP/apt/lists/auxfiles" "$TMP/apt/archives/partial"
printf '#!/bin/sh\necho "chown $*" >> "%s/steps"\n' "$TMP" > "$TMP/bin/chown"
printf '#!/bin/sh\necho "APT_LISTS='"'"'%s/apt/lists/'"'"'"\necho "APT_ARCHIVES='"'"'%s/apt/archives/'"'"'"\n' \
  "$TMP" "$TMP" > "$TMP/bin/apt-config"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/systemctl"; cp "$TMP/bin/systemctl" "$TMP/bin/deb-systemd-helper"
chmod +x "$TMP/bin/"*
{ cat "$TREE/src/install/lib/pkg-lib.sh"
  for s in pkg_state_dirs pkg_accounts pkg_install_and_grants pkg_enable_core_units pkg_user_units_and_desktop \
           pkg_stop_old_payload pkg_reboot_notice pkg_unit_policy; do
    printf '%s() { echo %s >> "%s/steps"; }\n' "$s" "$s" "$TMP"
  done
} > "$TMP/pkg-lib.sh"
sed -e "s|/usr/lib/rhizo/install/lib/pkg-lib.sh|$TMP/pkg-lib.sh|" -e "s|/etc/systemd/system/|$TMP/etc-systemd/|g" \
  "$TREE/debian/rhizo.postinst" > "$TMP/postinst"
PATH=$(guard_path "$TMP/bin:/usr/bin:/bin")
RHIZO_INSTALL_RECORD="$TMP/record" RHIZO_PKG_ROOT="$TMP/pkgroot" RHIZO_SELINUX_MODE_HELPER="$TMP/bin/rhizo-selinux-mode" \
  PATH="$PATH" sh "$TMP/postinst" configure > "$TMP/out" 2>&1
echo "rc=$?" >> "$TMP/out"
report_escapes >> "$TMP/out"
'''


def bash(script, *args, timeout=120):
    """run a harness script under bash and return its exit status"""
    return subprocess.run(["bash", "-c", script, "harness"] + list(args), timeout=timeout).returncode


def read(path):
    """return a file's text, or an empty string when it is absent"""
    try:
        with open(path) as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def mode_helper(tmp, mode):
    """write a rhizo-selinux-mode stand-in that answers mode"""
    os.makedirs(os.path.join(tmp, "bin"), exist_ok=True)
    p = os.path.join(tmp, "bin", "rhizo-selinux-mode")
    with open(p, "w") as fh:
        fh.write("#!/bin/sh\necho %s\n" % mode)
    os.chmod(p, 0o755)


def host_mode_tree(root, arch=False):
    """make the payload's host-mode tree under a package root"""
    for rel in HOST_MODE + (ARCH_HOST_MODE if arch else ()):
        p = os.path.join(root, "usr", "lib", "rhizo", "host-mode", rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write("# %s\n" % rel)


def links_made(root):
    """return the host-mode files linked into place under a package root"""
    return sorted(rel for rel in HOST_MODE + ARCH_HOST_MODE if os.path.islink(os.path.join(root, rel)))


def want_links(apt, arch=False):
    """return the host-mode files host mode links"""
    return sorted(rel for rel in HOST_MODE + (ARCH_HOST_MODE if arch else ()) if apt or not rel.startswith("etc/apt/"))


def host_files(root, flavor):
    """write the host files under a fixture root"""
    os.makedirs(os.path.join(root, "var", "lib", "rhizo"), exist_ok=True)
    os.makedirs(os.path.join(root, "etc"), exist_ok=True)
    with open(os.path.join(root, "etc", "login.defs"), "w") as fh:
        fh.write(LOGIN_DEFS)
    if flavor == "cachyos":
        with open(os.path.join(root, "etc", "pacman.conf"), "w") as fh:
            fh.write(PACMAN_CONF)
    else:
        os.makedirs(os.path.join(root, "etc", "apt", "apt.conf.d"), exist_ok=True)


def install_writes(root, flavor, mode, tag):
    """check the files and edits a rhizo install left"""
    bad = []
    linked = links_made(root)
    login = read(os.path.join(root, "etc", "login.defs"))
    pacman = read(os.path.join(root, "etc", "pacman.conf"))
    chowns = read(os.path.join(root, "chowns")).splitlines()
    record = read(os.path.join(root, "var", "lib", "rhizo", ".created-by-install")).splitlines()
    if mode == "namespace" or flavor == "ubuntu":
        if login != LOGIN_DEFS:
            bad.append((tag + ": login.defs as the host had it", LOGIN_DEFS, login))
    else:
        if "TTYGROUP\trhizo-no-tty-group" not in login or "login-defs-tty" not in record:
            bad.append((tag + ": login.defs gives ttys to the account's group, recorded", "the rhizo block", login))
        if "#DownloadUser = alpm  # rhizo" not in pacman or "pacman-downloaduser" not in record:
            bad.append((tag + ": pacman.conf's DownloadUser commented out, recorded", "#... # rhizo", pacman))
    if mode == "namespace":
        if linked:
            bad.append((tag + ": no host-mode file linked", [], linked))
        if chowns:
            bad.append((tag + ": no apt partial-dir chown", [], chowns))
        if flavor == "cachyos" and pacman != PACMAN_CONF:
            bad.append((tag + ": pacman.conf as the host had it", PACMAN_CONF, pacman))
        return bad
    want = want_links(flavor == "ubuntu", flavor == "cachyos")
    if linked != want or "host-mode-links" not in record:
        bad.append((tag + ": every host-mode file linked, recorded", want, linked))
    want_chowns = []
    if flavor == "ubuntu":
        for d in ("lists/partial", "lists/auxfiles", "archives/partial"):
            p = os.path.join(root, "apt", d)
            want_chowns += ["chown root:root " + p, "chown -R root:root " + p]
    if chowns != want_chowns:
        bad.append((tag + ": apt's partial dirs go to root on a dpkg host alone", want_chowns, chowns))
    return bad


def install_case(flavor, mode, lsm="stock", tree=REPO):
    """return the findings of one `rhizo install` run"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        host_mode_tree(os.path.join(tmp, "root"), flavor == "cachyos")
        host_files(os.path.join(tmp, "root"), flavor)
        bash(INSTALL_HARNESS, tree, tmp, flavor, mode, lsm)
        out = read(os.path.join(tmp, "out"))
        root = os.path.join(tmp, "root")
        spy = read(os.path.join(root, "spy")).splitlines()
        record = read(os.path.join(root, "var", "lib", "rhizo", ".created-by-install")).splitlines()
        tag = "%s %s %s" % (flavor, mode, lsm)
        bad += install_writes(root, flavor, mode, tag)
        escapes = read(os.path.join(tmp, "escapes")).splitlines()
        if escapes:
            bad.append((tag + ": no write outside the fixture root and no SELinux tool run", [], escapes))
        bad += root_writes(os.path.join(tmp, "root-before"), root, mode, tag)
        if mode == "namespace":
            config = read(os.path.join(root, "etc", "selinux", "config"))
            if config != SELINUX_CONFIG or sorted(os.listdir(os.path.join(root, "etc", "selinux"))) != ["config"]:
                bad.append((tag + ": /etc/selinux as the host had it", SELINUX_CONFIG,
                            [config] + sorted(os.listdir(os.path.join(root, "etc", "selinux")))))
            if os.path.lexists(os.path.join(root, ".autorelabel")):
                bad.append((tag + ": no /.autorelabel request", "absent", "present"))
        mounts = [l for l in read(os.path.join(root, "calls")).splitlines() if l.startswith("mount ")]
        if lsm == "selinux" and mode == "namespace" and mounts:
            bad.append((tag + ": no selinuxfs mount on a kernel with selinux active", [], mounts))
        if lsm == "selinux" and mode == "host" and not mounts:
            bad.append((tag + ": host mode mounts the empty selinuxfs, as the spy must see", "a mount", mounts))
        if not out.rstrip().endswith("rc=0"):
            bad.append((tag + ": rhizo install exits 0", "rc=0", out.strip().splitlines()[-3:]))
        writes = [l.split(" ", 2)[2] for l in spy if l.startswith("bootloader_write ") and len(l.split(" ", 2)) == 3]
        if len(writes) != 1:
            bad.append((tag + ": one bootloader_write", 1, len(writes)))
        tokens = writes[0] if writes else ""
        defaults = [l for l in spy if l.startswith("bootloader_make_rhizo_default ")]
        want = ["androidboot.hardware=rhizo", "loop.max_loop=64"] + (["binder.devices="] if flavor == "cachyos" else [])
        for w in want:
            if w not in tokens:
                bad.append((tag + ": tokens carry " + w, w, tokens))
        if len(defaults) != 1:
            bad.append((tag + ": bootloader_make_rhizo_default called once", 1, defaults))
        if not any(l.startswith("rhizo-kernel-default ") for l in record):
            bad.append((tag + ": install record keeps the previous default entry", "rhizo-kernel-default <id>",
                        record))
        if mode == "namespace":
            if SECURITY_TOKEN.search(tokens):
                bad.append((tag + ": no lsm=, security=, selinux= or enforcing= reaches bootloader_write", "none",
                            tokens))
            for line in ("selinux-mode namespace",):
                if line not in record:
                    bad.append((tag + ": install record line", line, record))
        else:
            if not SECURITY_TOKEN.search(tokens) or "enforcing=0" not in tokens:
                bad.append((tag + ": host mode writes today's security-module tokens", "lsm=/security= enforcing=0",
                            tokens))
            if any(l.startswith("selinux-mode ") for l in record):
                bad.append((tag + ": host mode writes no namespace record line", [], record))
    return bad


def changed_files(before, after):
    """return the files the run created or changed"""
    out = []
    for d, _, files in os.walk(after):
        for f in files:
            p = os.path.join(d, f)
            rel = os.path.relpath(p, after)
            if os.path.islink(p):
                continue
            old = os.path.join(before, rel)
            if not os.path.isfile(old) or open(old, "rb").read() != open(p, "rb").read():
                out.append(rel)
    return sorted(out)


def root_writes(before, after, mode, tag):
    """return the run's SELinux writes under root"""
    bad = []
    mounted = any(l.startswith("mount -t selinuxfs") for l in read(os.path.join(after, "calls")).splitlines())
    for rel in changed_files(before, after):
        if rel == "sys/fs/selinux/enforce" and mounted:
            continue
        if rel == ".autorelabel" or rel.startswith(("etc/selinux/", "sys/fs/selinux/")):
            bad.append((tag + ": no write to /%s" % rel, "untouched", "written"))
            continue
        if mode != "namespace":
            continue
        old = read(os.path.join(before, rel))
        added = [l for l in read(os.path.join(after, rel)).splitlines() if l not in old.splitlines()]
        tokens = [l for l in added if FILE_TOKEN.search(l)]
        if tokens:
            bad.append((tag + ": no security token written into /%s" % rel, "none", tokens[:3]))
    return bad


def source_findings(tree=REPO):
    """return the install scripts' host SELinux writes"""
    import glob
    bad = []
    files = sorted({p for g in SOURCE_GLOBS for p in glob.glob(os.path.join(tree, g))})
    texts = {os.path.relpath(p, tree): read(p) for p in files}
    held = set()
    for text in texts.values():
        held |= set(re.findall(r"^\s*(?:local\s+|readonly\s+)?(\w+)=\S*%s" % HOST_SELINUX, text, re.M))
    var_target = r"[\"']?\$\{?(?:%s)\}?" % "|".join(sorted(held)) if held else None
    targets = [LITERAL_TARGET] + ([var_target] if var_target else [])
    redirect = re.compile(r"(?<![<&])[0-9]?>>?\s*(?:%s)" % "|".join(targets))
    named = re.compile("|".join(targets))
    for rel, text in texts.items():
        for n, line in enumerate(text.splitlines(), 1):
            code = line.split(" #", 1)[0] if not rel.endswith(".py") else line.split("  #", 1)[0]
            if code.lstrip().startswith("#"):
                continue
            where = "%s:%d" % (rel, n)
            if "/.autorelabel" in code:
                bad.append((where + ": names /.autorelabel", "never", line.strip()))
            if TOOL_PATH.search(code):
                bad.append((where + ": runs a SELinux tool by full path", "never", line.strip()))
            if redirect.search(code) or (WRITE_TOOLS.search(code) and named.search(code)):
                bad.append((where + ": writes under /etc/selinux or /sys/fs/selinux", "never", line.strip()))
            if rel.endswith(".py") and re.search(r"open\(\s*[\"']%s[^\"']*[\"']\s*,\s*[\"'][wax]" % HOST_SELINUX,
                                                 code):
                bad.append((where + ": opens a host SELinux path to write", "never", line.strip()))
    return bad


def configure_case(sh, mode, tree=REPO):
    """return the findings of a pkg_configure run"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        mode_helper(tmp, mode)
        host_mode_tree(os.path.join(tmp, "pkgroot"))
        bash(CONFIGURE_HARNESS, tree, tmp, sh)
        out, steps = read(os.path.join(tmp, "out")), read(os.path.join(tmp, "steps")).split()
        tag = "%s pkg_configure %s" % (sh, mode)
        if "rc=0" not in out.split() or "ESCAPE" in out or "FAIL" in out:
            bad.append((tag + ": exits 0 with no host write", "rc=0", out.strip().splitlines()[-4:]))
        ran = [s for s in HOST_MODE_STEPS if s in steps]
        linked = links_made(os.path.join(tmp, "pkgroot"))
        if ran or linked:
            bad.append((tag + ": host mode's files and edits left to rhizo install", [], ran + linked))
        if "pkg_install_and_grants" not in steps:
            bad.append((tag + ": runs rhizo install through pkg_install_and_grants", "the step", steps))
    return bad


def postinst_case(mode):
    """return the findings of a postinst configure run"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        mode_helper(tmp, mode)
        host_mode_tree(os.path.join(tmp, "pkgroot"))
        os.makedirs(os.path.join(tmp, "pkgroot", "etc", "apt", "apt.conf.d"))
        bash(POSTINST_HARNESS, REPO, tmp)
        out, steps = read(os.path.join(tmp, "out")), read(os.path.join(tmp, "steps")).splitlines()
        tag = "postinst configure %s" % mode
        if "rc=0" not in out.split() or "ESCAPE" in out or "FAIL" in out:
            bad.append((tag + ": exits 0 with no host write", "rc=0", out.strip().splitlines()[-4:]))
        chowns = [s for s in steps if s.startswith("chown ")]
        linked = links_made(os.path.join(tmp, "pkgroot"))
        if linked:
            bad.append((tag + ": host-mode links left to rhizo install", [], linked))
        if mode == "namespace":
            if chowns:
                bad.append((tag + ": no apt partial-dir chown", [], chowns))
        elif not chowns:
            bad.append((tag + ": apt's partial dirs go to root", "chown calls", chowns))
    return bad


def host_mode_list_case():
    """return disagreements on the host-mode file list"""
    rules = read(os.path.join(REPO, "debian", "rules")).replace("\\\n", " ")
    shipped = sorted(set(m.strip('"') for m in re.findall(r'\$\(PAYLOAD\)/host-mode/(\S+)', rules)))
    lib = read(os.path.join(REPO, "src", "install", "lib", "pkg-lib.sh"))
    m = re.search(r'^PKG_HOST_MODE_FILES="([^"]*)"', lib, re.M)
    listed = sorted(m.group(1).split()) if m else []
    arch_root = os.path.join(REPO, "archlinux", "files")
    arch_tree = os.path.join(arch_root, "usr", "lib", "rhizo", "host-mode")
    arch_shipped = sorted(os.path.relpath(os.path.join(d, f), arch_tree) for d, _, fs in os.walk(arch_tree) for f in fs)
    bad = []
    if shipped != sorted(HOST_MODE):
        bad.append(("debian/rules ships the host-mode files", sorted(HOST_MODE), shipped))
    if arch_shipped != sorted(ARCH_HOST_MODE):
        bad.append(("archlinux/files ships the pacman-only host-mode files", sorted(ARCH_HOST_MODE), arch_shipped))
    for rel in ARCH_HOST_MODE:
        if os.path.exists(os.path.join(arch_root, rel)):
            bad.append(("archlinux/files ships %s only under the host-mode payload" % rel, "host-mode only", "also live"))
    if listed != sorted(HOST_MODE + ARCH_HOST_MODE):
        bad.append(("pkg-lib.sh's PKG_HOST_MODE_FILES", sorted(HOST_MODE + ARCH_HOST_MODE), listed))
    for rel in HOST_MODE:
        if re.search(r'\$\(UNITS\)/' + re.escape(rel.split("usr/lib/systemd/system/", 1)[-1]) + r'\b', rules) \
                or re.search(r'debian/rhizo/' + re.escape(rel) + r'\b', rules):
            bad.append(("debian/rules installs %s only under the host-mode payload" % rel, "host-mode only", "also live"))
    return bad


def env_file_case():
    """return the findings for the package's androidd.env"""
    lines = [l.strip() for l in read(os.path.join(REPO, "debian", "androidd.env")).splitlines()]
    if "RHIZO_SELINUX_MODE=namespace" not in lines:
        return [("debian/androidd.env sets RHIZO_SELINUX_MODE=namespace", "the line", "absent")]
    return []


BOOTSTRAP_TOP = "set -uo pipefail\n"
CONFIGURE_TOP = "    pkg_step=pkg_read_selinux_mode; pkg_read_selinux_mode\n"
MUTANTS = (
    ("src/install/bootstrap/bootstrap.sh", BOOTSTRAP_TOP, BOOTSTRAP_TOP + "setenforce 0\n", "install",
     "no write outside the fixture root and no SELinux tool run"),
    ("src/install/bootstrap/bootstrap.sh", BOOTSTRAP_TOP, BOOTSTRAP_TOP + ': > "${RHIZO_BL_ROOT}/.autorelabel"\n',
     "install", "no /.autorelabel request"),
    ("src/install/bootstrap/bootstrap.sh", BOOTSTRAP_TOP,
     BOOTSTRAP_TOP + 'echo SELINUX=permissive > "${RHIZO_BL_ROOT}/etc/selinux/config"\n', "install",
     "/etc/selinux as the host had it"),
    ("src/install/bootstrap/bootstrap.sh", 'ANDROIDBOOT_TOKENS="androidboot.hardware=rhizo ',
     'ANDROIDBOOT_TOKENS="androidboot.hardware=rhizo selinux=0 ', "install", "selinux= or enforcing= reaches"),
    ("src/install/lib/pkg-lib.sh", CONFIGURE_TOP, CONFIGURE_TOP + "    touch /.autorelabel\n", "configure",
     "exits 0 with no host write"),
    ("src/install/lib/pkg-lib.sh", CONFIGURE_TOP, CONFIGURE_TOP + "    restorecon -R /etc\n", "configure",
     "exits 0 with no host write"),
    ("src/install/bootstrap/bootstrap.sh", BOOTSTRAP_TOP, BOOTSTRAP_TOP + ": > /.autorelabel\n", "source",
     "names /.autorelabel"),
    ("src/install/bootstrap/bootstrap.sh", BOOTSTRAP_TOP,
     BOOTSTRAP_TOP + "echo SELINUX=permissive > /etc/selinux/config\n", "source", "writes under /etc/selinux"),
    ("src/install/bootstrap/bootstrap.sh", BOOTSTRAP_TOP, BOOTSTRAP_TOP + "/usr/sbin/setenforce 0\n", "source",
     "runs a SELinux tool by full path"),
    ("src/install/bootstrap/bootstrap.sh", BOOTSTRAP_TOP, BOOTSTRAP_TOP + "echo 0 > /sys/fs/selinux/enforce\n",
     "source", "writes under /etc/selinux or /sys/fs/selinux"),
    ("src/install/lib/pkg-lib.sh", CONFIGURE_TOP, CONFIGURE_TOP + '    echo 0 > "$PKG_SELINUXFS/enforce"\n',
     "source", "writes under /etc/selinux or /sys/fs/selinux"),
    ("src/install/cli/rhizo.sh", "cmd_install() {\n", "cmd_install() {\n  sed -i s/x/y/ \"$SELINUX_CONFIG\"\n",
     "source", "writes under /etc/selinux or /sys/fs/selinux"),
    ("src/install/bootstrap/bootstrap.sh", BOOTSTRAP_TOP,
     BOOTSTRAP_TOP + 'mkdir -p "${RHIZO_BL_ROOT}/etc/default/grub.d"\n'
     'echo \'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT selinux=0"\' '
     '> "${RHIZO_BL_ROOT}/etc/default/grub.d/99-x.cfg"\n', "install",
     "no security token written into /etc/default/grub.d/99-x.cfg"),
)


def selftest():
    """flag each planted host SELinux change"""
    bad = []
    with tempfile.TemporaryDirectory() as tree:
        for part in ("src/install", "debian", "archlinux"):
            shutil.copytree(os.path.join(REPO, part), os.path.join(tree, part), symlinks=True)
        runs = {"install": lambda: install_case("ubuntu", "namespace", tree=tree),
                "configure": lambda: configure_case("bash", "namespace", tree=tree),
                "source": lambda: source_findings(tree)}
        for name, run in runs.items():
            if run():
                bad.append(("the unchanged tree passes its %s run" % name, [], run()))
        for rel, anchor, planted, name, finding in MUTANTS:
            path = os.path.join(tree, rel)
            text = open(os.path.join(REPO, rel)).read()
            if text.count(anchor) != 1:
                bad.append(("the mutant's anchor is in %s once" % rel, 1, text.count(anchor)))
                continue
            with open(path, "w") as fh:
                fh.write(text.replace(anchor, planted, 1))
            got = runs[name]()
            with open(path, "w") as fh:
                fh.write(text)
            if not any(finding in str(b[0]) for b in got):
                bad.append(("%r in %s is flagged: %s" % (planted.splitlines()[-1].strip(), rel, finding), "flagged",
                            got))
    return bad


def main():
    """run every case and print PASS or each finding"""
    if not shutil.which("unshare") or subprocess.run(["unshare", "-r", "true"]).returncode != 0:
        print("FAIL unshare -r cannot run here")
        return 1
    if "--selftest" in sys.argv[1:]:
        bad = selftest()
        for b in bad:
            print("FAIL", b)
        print("PASS selftest" if not bad else "FAIL")
        return 1 if bad else 0
    bad = env_file_case() + host_mode_list_case() + source_findings()
    for flavor in ("ubuntu", "cachyos"):
        for mode in ("namespace", "host"):
            bad += install_case(flavor, mode)
            bad += install_case(flavor, mode, "selinux")
    for sh in ("dash", "bash"):
        for mode in ("namespace", "host"):
            bad += configure_case(sh, mode)
    for mode in ("namespace", "host"):
        bad += postinst_case(mode)
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

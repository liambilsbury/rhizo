#!/usr/bin/env python3
import fnmatch
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
STAGED = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "udev", "59-loop-unbound.rules")
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
FETCH = os.path.join(REPO, "tools", "fetch", "udev-rules.sh")
RULES_DIR = os.path.join(REPO, "var", "udev-rules", "rules.d")
DISTRO_RULES = ("60-persistent-storage.rules", "69-bcache.rules", "69-lvm.rules",
                "80-udisks2.rules", "95-kpartx.rules", "99-systemd.rules")

TOKEN_RE = re.compile(r'\s*([A-Z_]+)(?:\{([^}]*)\})?\s*(==|!=|\+=|-=|:=|=)\s*"((?:[^"\\]|\\.)*)"\s*')


class Refused(Exception):
    pass


def split_tokens(line):
    """return the tokens of a rule line"""
    tokens, pos = [], 0
    while pos < len(line):
        m = TOKEN_RE.match(line, pos)
        if not m:
            raise Refused("cannot parse %r at %r" % (line, line[pos:pos + 30]))
        tokens.append((m.group(1), m.group(2), m.group(3), m.group(4)))
        pos = m.end()
        if pos < len(line):
            if line[pos] != ",":
                raise Refused("expected a comma in %r at %r" % (line, line[pos:pos + 30]))
            pos += 1
    return tokens


def load_rules(paths):
    """parse rule files into logical rules"""
    rules = []
    for path in paths:
        with open(path) as f:
            pending, start = "", 0
            for n, raw in enumerate(f, 1):
                line = raw.rstrip("\n")
                if pending:
                    line = pending + line.lstrip()
                else:
                    start = n
                if line.rstrip().endswith("\\"):
                    pending = line.rstrip()[:-1]
                    continue
                pending = ""
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                rules.append((os.path.basename(path), start, split_tokens(line)))
            if pending:
                raise Refused("%s ends inside a continued line" % os.path.basename(path))
    return rules


def glob_any(pattern, value):
    """return whether a value matches any alternative of a glob pattern"""
    return any(fnmatch.fnmatchcase(value, alt) for alt in pattern.split("|"))


RHIZO_BACKING = ("/var/lib/rhizo/data.img", "/var/lib/rhizo/instances/2/data.img", "/srv/rhizo/gsi_system/system.img",
                 "/system/apex/com.android.art.apex", "/system/apex/com.android.vndk.v34.capex",
                 "/system_ext/apex/com.android.hotspot2.apex", "/product/apex/com.android.foo.apex",
                 "/vendor/apex/com.android.foo.apex",
                 "/var/lib/rhizo/templates/data-template.c03b907f0450.img.part",
                 "/var/lib/rhizo/fetch-gsi.PL7Ephm0gN/system.img", "/data/apex/active/com.android.art@340.apex",
                 "/data/apex/decompressed/com.android.art.decompressed.apex")
HOST_BACKING = ("/home/user/disk.img", "/var/lib/snapd/snaps/core22_1380.snap", "/var/lib/rhizo-backup/data.img",
                "/srv/rhizo-copy/system.img", "/var/lib/libvirt/images/guest.img", "/mnt/system/apexes/x.apex", "/mnt/apex-backup/x.apex", "/tmp/tmp.PL7Ephm0gN/system.img", "/apex/decompressed/x.apex", "/var/lib/data/apex/x.apex")


class Device:
    def __init__(self, bound, backing="/home/user/disk.img"):
        """create a loop7 device record"""
        self.subsystem = "block"
        self.kernel = "loop7"
        self.action = "add"
        self.env = {"DEVTYPE": "disk", "MAJOR": "7", "MINOR": "7", "DEVNAME": "/dev/loop7",
                    "SUBSYSTEM": "block", "DEVPATH": "/devices/virtual/block/loop7"}
        self.tests = {"loop/backing_file": bound}
        self.attrs = {"loop/backing_file": backing} if bound else {}
        self.reached = []
        self.jumps = []


def evaluate(rules, dev):
    """evaluate the rules for a device"""
    labels = {}
    for i, (fname, n, tokens) in enumerate(rules):
        for key, attr, op, value in tokens:
            if key == "LABEL":
                labels[value] = i
    i = 0
    while i < len(rules):
        fname, n, tokens = rules[i]
        jump = None
        for key, attr, op, value in tokens:
            match = op in ("==", "!=") or key in ("IMPORT", "PROGRAM")
            if key == "LABEL":
                continue
            if key == "GOTO":
                jump = value
                break
            if match:
                if key == "SUBSYSTEM":
                    ok = glob_any(value, dev.subsystem)
                elif key == "KERNEL":
                    ok = glob_any(value, dev.kernel)
                elif key == "ACTION":
                    ok = glob_any(value, dev.action)
                elif key == "DEVPATH":
                    ok = glob_any(value, dev.env["DEVPATH"])
                elif key == "ENV":
                    ok = glob_any(value, dev.env.get(attr, ""))
                elif key == "TEST":
                    if attr is not None:
                        raise Refused("%s:%d TEST with a mode is not modeled" % (fname, n))
                    ok = dev.tests.get(value, False)
                elif key == "ATTR":
                    ok = attr in dev.attrs and glob_any(value, dev.attrs[attr])
                elif key in ("ATTRS", "SUBSYSTEMS", "KERNELS", "DRIVERS", "DRIVER",
                             "TAG", "SYMLINK", "NAME", "RESULT", "CONST", "SYSCTL"):
                    ok = False
                elif key == "PROGRAM":
                    dev.reached.append((fname, n, "PROGRAM %s" % value))
                    ok = False
                elif key == "IMPORT":
                    if attr in ("program", "builtin"):
                        dev.reached.append((fname, n, "IMPORT{%s} %s" % (attr, value)))
                        ok = False
                    elif attr in ("db", "parent", "cmdline", "file"):
                        ok = False
                    else:
                        raise Refused("%s:%d IMPORT{%s} is not modeled" % (fname, n, attr))
                else:
                    raise Refused("%s:%d match key %s is not modeled" % (fname, n, key))
                if op == "!=":
                    ok = not ok
                if not ok:
                    break
            else:
                if key == "ENV":
                    if op in ("+=",):
                        dev.env[attr] = (dev.env.get(attr, "") + " " + value).strip()
                    else:
                        dev.env[attr] = value
                elif key == "RUN":
                    dev.reached.append((fname, n, "RUN %s" % value))
                elif key in ("OPTIONS", "TAG", "SYMLINK", "MODE", "OWNER", "GROUP", "NAME",
                             "SECLABEL", "ATTR", "SYSCTL"):
                    pass
                else:
                    raise Refused("%s:%d assignment key %s is not modeled" % (fname, n, key))
        if jump is not None:
            if jump not in labels:
                raise Refused("%s:%d GOTO %r has no LABEL" % (fname, n, jump))
            dev.jumps.append((fname, n, jump))
            i = labels[jump]
            continue
        i += 1
    return dev


def packaging_failures():
    """return packaging gaps in the rule's loading"""
    repo = os.path.join(HERE, "..", "..", "..", "..")
    failures = []
    rules = open(os.path.join(repo, "debian", "rules")).read()
    if "debian/rhizo/usr/lib/udev/rules.d/59-rhizo-loop-unbound.rules" not in rules:
        failures.append("RULE-NOT-PACKAGED: debian/rules does not install the staged rule")
    fetch = open(os.path.join(repo, "src", "install", "prepare", "fetch-gsi.sh")).read()
    if not re.search(r"^scratch_root\(\) \{ echo \"\$\{RHIZO_STATE_DIR:-/var/lib/rhizo\}/", fetch, re.M):
        failures.append("SCRATCH-OUTSIDE-RULE: fetch-gsi.sh makes its scratch image outside /var/lib/rhizo")
    return failures


def check(staged, rules_dir):
    """return the failures for the staged rules and the distribution rules"""
    failures = packaging_failures()
    paths = [staged]
    for name in DISTRO_RULES:
        path = os.path.join(rules_dir, name)
        if not os.path.exists(path):
            failures.append("MISSING-RULES: %s is not in %s" % (name, rules_dir))
        else:
            paths.append(path)
    if failures:
        return failures
    try:
        rules = load_rules(paths)
        unbound = evaluate(rules, Device(bound=False))
        bound = evaluate(rules, Device(bound=True))
        rhizo_bound = {path: evaluate(rules, Device(bound=True, backing=path)) for path in RHIZO_BACKING}
        host_bound = {path: evaluate(rules, Device(bound=True, backing=path)) for path in HOST_BACKING}
    except Refused as e:
        return ["REFUSED-TOKEN: %s" % e]
    for fname, n, what in unbound.reached:
        failures.append("PROBER-REACHED: %s:%d %s runs on an unbound loop device" % (fname, n, what))
    if unbound.env.get("SYSTEMD_READY") != "0":
        failures.append("UNBOUND-READY: an unbound loop device ends with SYSTEMD_READY=%r, not 0"
                        % unbound.env.get("SYSTEMD_READY"))
    for path, dev in rhizo_bound.items():
        for fname, n, what in dev.reached:
            failures.append("RHIZO-BOUND-PROBED: %s:%d %s runs on a loop device backed by %s" % (fname, n, what, path))
    for path, dev in [("/home/user/disk.img", bound)] + list(host_bound.items()):
        probers = [what for _, _, what in dev.reached if "blkid" in what or "probe-bcache" in what]
        if not any("blkid" in w for w in probers):
            failures.append("BOUND-NOT-PROBED: a loop device backed by %s never reaches the blkid builtin" % path)
        if not any("probe-bcache" in w for w in probers):
            failures.append("BOUND-NOT-PROBED: a loop device backed by %s never reaches probe-bcache" % path)
    return failures


ONE_FLAG = ('SUBSYSTEM=="block", KERNEL=="loop*", TEST!="loop/backing_file", '
            'ENV{UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG}="1"\n')
NO_TEST = ('SUBSYSTEM=="block", KERNEL=="loop*", '
           'ENV{UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG}="1", ENV{DM_UDEV_DISABLE_OTHER_RULES_FLAG}="1"\n')
UNKNOWN = 'SUBSYSTEM=="block", KERNEL=="loop*", IMPORT{frobnicate}="x"\n'
UNBOUND_ONLY = ('SUBSYSTEM=="block", KERNEL=="loop*", TEST!="loop/backing_file", '
                'ENV{UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG}="1", ENV{DM_UDEV_DISABLE_OTHER_RULES_FLAG}="1"\n')
ALL_LOOPS = UNBOUND_ONLY + ('SUBSYSTEM=="block", KERNEL=="loop*", ATTR{loop/backing_file}=="/*", '
                            'ENV{UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG}="1", ENV{DM_UDEV_DISABLE_OTHER_RULES_FLAG}="1"\n')


def selftest(rules_dir):
    """check each planted rule file against the failure codes it must produce"""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        def write(name, text):
            """write a rules file under the temporary directory and return its path"""
            path = os.path.join(tmp, name)
            with open(path, "w") as f:
                f.write(text)
            return path

        def codes(staged):
            """return the sorted failure codes for a staged rules file"""
            return sorted({f.split(":", 1)[0] for f in check(staged, rules_dir)})

        got = codes(STAGED)
        if got:
            failures.append("the staged rule fails: %s" % check(STAGED, rules_dir))
        got = codes(write("one-flag.rules", ONE_FLAG))
        if "PROBER-REACHED" not in got:
            failures.append("the pre-fix one-flag rule must let a prober reach an unbound loop: %s" % got)
        got = codes(write("no-test.rules", NO_TEST))
        if "BOUND-NOT-PROBED" not in got:
            failures.append("a rule without the backing_file TEST must starve a bound loop of its probers: %s" % got)
        got = codes(write("unbound-only.rules", UNBOUND_ONLY))
        if "RHIZO-BOUND-PROBED" not in got:
            failures.append("a rule for unbound loops only must leave Rhizo-backed loops probed: %s" % got)
        got = codes(write("all-loops.rules", ALL_LOOPS))
        if "BOUND-NOT-PROBED" not in got:
            failures.append("a rule matching every backing file must starve a host-backed loop of its probers: %s" % got)
        got = codes(write("unknown.rules", UNKNOWN))
        if got != ["REFUSED-TOKEN"]:
            failures.append("a token the evaluator does not model must be refused, got %s" % got)
        got = codes(write("empty.rules", "# nothing\n"))
        if "PROBER-REACHED" not in got:
            failures.append("with no rule at all a prober must reach an unbound loop: %s" % got)
    return failures


def fetch_rules():
    """fetch the pinned rules, or exit 77 naming why not"""
    if all(os.path.isfile(os.path.join(RULES_DIR, n)) for n in DISTRO_RULES):
        return
    done = subprocess.run([FETCH], capture_output=True, text=True, timeout=900)
    if done.returncode != 0:
        print("NOT RUN: loop-unbound rule check: tools/fetch/udev-rules.sh exited %d: %s"
              % (done.returncode, (done.stderr or done.stdout).strip()))
        sys.exit(77)


def main():
    """run the check or its selftest"""
    args = sys.argv[1:]
    rules_dir, staged = RULES_DIR, STAGED
    if "--rules-dir" in args:
        rules_dir = args[args.index("--rules-dir") + 1]
    else:
        fetch_rules()
    if "--staged" in args:
        staged = args[args.index("--staged") + 1]
    if "--selftest" in args:
        failures = selftest(rules_dir)
        for x in failures:
            print("check-loop-unbound-rule selftest: %s" % x)
        if failures:
            return 1
        print("check-loop-unbound-rule selftest ok: the staged rule passes; the one-flag rule, a rule "
              "without the TEST, an unbound-only rule, a rule for every backing file, an unmodeled token and "
              "no rule at all each fail by name")
        return 0
    failures = check(staged, rules_dir)
    for x in failures:
        print("check-loop-unbound-rule: %s" % x)
    if failures:
        return 1
    print("an unbound loop device and one backed by a Rhizo file reach no prober; a host-backed one reaches "
          "blkid and probe-bcache")
    return 0


if __name__ == "__main__":
    sys.exit(main())

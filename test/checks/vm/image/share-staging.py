#!/usr/bin/env python3
import re
import subprocess
import sys
import os
import tempfile


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import layout_paths as layout

DEST_SHARE = re.compile(r'(?<![\w-])(?:var/)?share(?:-\d+)?/')
TOP_VM = re.compile(r'(?<![\w-])var/bin/[^/\s]+$')
CP_LINE = re.compile(r'(?:^|[;&|]|\bthen\b|\bdo\b|\belse\b)\s*(cp\b[^;&|)]*)')
SAFE_FLAGS = ("--remove-destination", "-al", "-a ", "-la", "--link")
HEREDOC_OPEN = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')
ASSIGN = re.compile(r'^\s*(?:(?:local|export|readonly|declare(?:\s+-\w+)?)\s+)?'
                    r'([A-Za-z_][A-Za-z0-9_]*)=(\S*)')
VAR_REF = re.compile(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}?')
SHARE_END = re.compile(r'(?<![\w-])share(?:-\d+)?/?$')
NOT_DEVICE = ("/root/share", "/usr/share", "/usr/local/share")
COMMON = "test/vm/common.sh"


def code_lines(text):
    """yield the lines outside heredoc bodies"""
    pending = []
    in_body = None
    held = None
    for n, line in enumerate(text.splitlines(), 1):
        if in_body is not None:
            if line.strip() == in_body:
                in_body = None
            continue
        if held is not None:
            n, line = held[0], held[1] + " " + line.lstrip()
            held = None
        if line.endswith("\\"):
            held = (n, line[:-1])
            continue
        yield n, line
        pending = HEREDOC_OPEN.findall(line)
        if pending:
            in_body = pending[0]


def expand(s, known):
    """return the text with known variable references replaced"""
    return VAR_REF.sub(lambda m: known.get(m.group(1), m.group(0)), s)


def share_vars(text, known=None):
    """return the variables assigned share paths"""
    found = dict(known or {})
    for _ in range(2):
        for _, line in code_lines(text):
            m = ASSIGN.match(line)
            if not m:
                continue
            value = expand(m.group(2).strip("\"'"), found)
            if any(x in value for x in NOT_DEVICE):
                continue
            if DEST_SHARE.search(value) or SHARE_END.search(value):
                found[m.group(1)] = value
    return found


def read(path):
    """return the text of a file, or None when unreadable"""
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None


def in_layout(rel):
    """return whether a path is inside the approved layout"""
    return not layout.outside_layout(rel)


def offenders(root, scan=in_layout):
    """list cp commands with unsafe share destinations"""
    out = []
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    files = subprocess.run(["git", "-C", root, "ls-files", "*.sh"],
                           capture_output=True, text=True, env=env).stdout.split()
    common = share_vars(read(os.path.join(root, COMMON)) or "")
    for rel in files:
        if not scan(rel):
            continue
        text = read(os.path.join(root, rel))
        if text is None:
            continue
        known = share_vars(text, common)
        for n, line in code_lines(text):
            for cp in CP_LINE.findall(line):
                if "/root/share" in cp:
                    continue
                parts = cp.split()
                dest = expand(parts[-1].strip("\"'"), known) if len(parts) >= 3 else ""
                if not (DEST_SHARE.search(dest) or TOP_VM.search(dest)):
                    continue
                if any(f in cp for f in SAFE_FLAGS):
                    continue
                out.append((rel, n, cp.strip()))
    return out


def selftest():
    """run the checker on fixture scripts"""
    checks = 0
    every = lambda rel: True
    with tempfile.TemporaryDirectory() as t:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        subprocess.run(["git", "init", "-q", t], check=True, env=env)
        def write(name, body):
            """write a file in the fixture repo and stage it"""
            os.makedirs(os.path.dirname(os.path.join(t, name)), exist_ok=True)
            open(os.path.join(t, name), "w").write(body)
            subprocess.run(["git", "-C", t, "add", name], check=True, env=env)

        write("clean.sh", '#!/bin/bash\ncp --remove-destination "$a" share/x.ko\n'
                          'cp share/x.ko /tmp/out\ncp -al share/ share-1/\n')
        write("guest.sh", '#!/bin/bash\nssh_vm "cp /root/share/a /root/a"\n')
        write("fixture.sh", "#!/bin/bash\ncat > f <<'EOF'\ncp a share/b.ko\nEOF\n")
        bad = offenders(t, every)
        checks += 1
        if bad:
            print("FAIL selftest: the clean fixture was flagged: %s" % (bad,), file=sys.stderr)
            return 1

        write("dirty.sh", '#!/bin/bash\ncp "$OUT" "$ROOT/var/share/gfx/thing"\n')
        bad = offenders(t, every)
        checks += 1
        if not any(f == "dirty.sh" for f, _, _ in bad):
            print("FAIL selftest: a plain cp into var/share/ was NOT flagged", file=sys.stderr)
            return 1

        checks += 1
        if offenders(t):
            print("FAIL selftest: a root file was scanned, outside the layout", file=sys.stderr)
            return 1

        write("dirty2.sh", '#!/bin/bash\ncd x && cp a share-1/b\n')
        bad = offenders(t, every)
        checks += 1
        if not any(f == "dirty2.sh" for f, _, _ in bad):
            print("FAIL selftest: a cp into a vm share dir was NOT flagged", file=sys.stderr)
            return 1

        write("dirty3.sh", "#!/bin/bash\ncat > f <<'EOF'\nnothing\nEOF\ncp a share/c.ko\n")
        bad = offenders(t, every)
        checks += 1
        if not any(f == "dirty3.sh" for f, _, _ in bad):
            print("FAIL selftest: a cp AFTER a heredoc body was NOT flagged", file=sys.stderr)
            return 1

        write("top.sh", '#!/bin/bash\ncp "$OUT_DIR/${OUT_NAME}" "$ROOT/var/bin/${OUT_NAME}"\n')
        bad = offenders(t, every)
        checks += 1
        if not any(f == "top.sh" for f, _, _ in bad):
            print("FAIL selftest: a plain cp onto a top-level var/bin/<name> was NOT flagged",
                  file=sys.stderr)
            return 1

        write("cont.sh", '#!/bin/bash\ncp "$ROOT/out/x.so" \\\n   "$ROOT/var/share/gfx_hal/x.so"\n')
        bad = offenders(t, every)
        checks += 1
        if ("cont.sh", 2) not in [(f, n) for f, n, _ in bad]:
            print("FAIL selftest: a plain cp continued onto a second line was NOT flagged "
                  "at its first line: %s" % (bad,), file=sys.stderr)
            return 1

        write("top.sh", '#!/bin/bash\ncp --remove-destination "$OUT_DIR/${OUT_NAME}" '
                        '"$ROOT/var/bin/${OUT_NAME}"\n')
        write("cont.sh", '#!/bin/bash\ncp --remove-destination "$ROOT/out/x.so" \\\n'
                         '   "$ROOT/var/share/gfx_hal/x.so"\n')
        write("deep.sh", '#!/bin/bash\ncp a test/system/fixtures/b.txt\n')
        bad = [b for b in offenders(t, every) if b[0] in ("top.sh", "cont.sh", "deep.sh")]
        checks += 1
        if bad:
            print("FAIL selftest: an unlinking top-level or continued cp, or a cp into a "
                  "tracked subdirectory, was flagged: %s" % (bad,), file=sys.stderr)
            return 1

        write("test/vm/common.sh", '#!/bin/bash\nSHARE_DIR="$REPO/share"\n')
        write("var1.sh", '#!/bin/bash\nSHARE="$(pwd)/share"\ncp "$WORK/signed.apk" "$SHARE/x.apk"\n')
        write("var2.sh", '#!/bin/bash\nSHARE="$(pwd)/share"\nout="$SHARE/a.apk"\ncp b "$out"\n')
        write("var3.sh", '#!/bin/bash\ncp -f key.pub "$SHARE_DIR/adbkey.pub"\n')
        write("var4.sh", '#!/bin/bash\nSHARE_ROOT="$REPO/share"\ncp a "${SHARE_ROOT}/b"\n')
        bad = [(f, n) for f, n, _ in offenders(t, every)]
        for want, what in ((("var1.sh", 3), "a cp into $SHARE assigned in the script"),
                           (("var2.sh", 4), "a cp into a variable one hop from $SHARE"),
                           (("var3.sh", 2), "a cp into $SHARE_DIR from common.sh"),
                           (("var4.sh", 3), "a cp into a braced ${SHARE_ROOT}")):
            checks += 1
            if want not in bad:
                print("FAIL selftest: %s was NOT flagged at %s:%d: %s"
                      % (what, want[0], want[1], bad), file=sys.stderr)
                return 1

        write("var5.sh", '#!/bin/bash\nSHARE="$(pwd)/share"\n'
                         'cp --remove-destination a "$SHARE/y.apk"\n'
                         'cp "$SHARE/x" "$STAGE"\nOUT="$WORK/x"\ncp a "$OUT"\n')
        bad = [b for b in offenders(t, every) if b[0] == "var5.sh"]
        checks += 1
        if bad:
            print("FAIL selftest: an unlinking cp into $SHARE, a read out of it, or a cp "
                  "into a variable that is no share path was flagged: %s" % (bad,),
                  file=sys.stderr)
            return 1
    print("check-share-staging selftest: %d assertions passed" % checks)
    return 0


def main():
    """run the check on the repo or run the selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True).stdout.strip()
    bad = offenders(root)
    for rel, n, cp in bad:
        print("FAIL: share staging: %s:%d writes into a share dir or onto a top-level "
              "var/bin/<name> without --remove-destination: %s" % (rel, n, cp),
              file=sys.stderr)
    if bad:
        return 1
    print("share staging: every host-side copy into a share dir or onto var/bin/<name> unlinks first")
    return 0


if __name__ == "__main__":
    sys.exit(main())

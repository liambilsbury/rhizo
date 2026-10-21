#!/usr/bin/env python3
"""Check the restart path's accesses against the compiled policy"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

COLUMNS = ("domain", "path-or-object", "label", "class", "perms", "code-site")

_WEAKENED = re.compile(r"dropped guard \(neverallow \S+ (\S+) ")
_ALLOW = re.compile(r"^\s*allow\s+\S+\s+\S+:(\S+)\s+(?:\{([^}]*)\}|(\S+?));")


def repo_root(explicit=None):
    """return the path of the Rhizo checkout"""
    for cand in (explicit, os.environ.get("RHIZO_REPO"),
                 os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))))):
        if cand and os.path.isfile(os.path.join(cand, "test/checks/lib/avc-lab.sh")):
            return os.path.realpath(cand)
    sys.exit("check-restart-access: cannot find test/checks/lib/avc-lab.sh -- pass --repo")


def read_rows(path):
    """read the rows and errors from the TSV"""
    rows, errors, header_seen = [], [], False
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            fields = line.split("\t")
            if not header_seen:
                if tuple(fields) != COLUMNS:
                    errors.append(f"{path}:{n}: header is {fields!r}, expected {list(COLUMNS)!r}")
                    return rows, errors
                header_seen = True
                continue
            if len(fields) != len(COLUMNS):
                errors.append(f"{path}:{n}: {len(fields)} fields, expected {len(COLUMNS)}")
                continue
            row = dict(zip(COLUMNS, fields))
            row["line"] = n
            if not row["perms"].split():
                errors.append(f"{path}:{n}: no perms named")
                continue
            if any(p == "!" for p in row["perms"].split()):
                errors.append(f"{path}:{n}: a bare `!` names no perm to refuse")
                continue
            rows.append(row)
    if not header_seen:
        errors.append(f"{path}: no header line")
    return rows, errors


def build_lab(root, out_dir):
    """build the policy with avc-lab"""
    r = subprocess.run(["bash", "test/checks/lib/avc-lab.sh", "build", "--out", out_dir],
                       cwd=root, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(f"check-restart-access: avc-lab build failed rc={r.returncode}")
    policy = r.stdout.strip().splitlines()[-1].strip()
    if not os.path.isfile(policy):
        sys.stderr.write(r.stderr)
        sys.exit(f"check-restart-access: avc-lab build printed {policy!r}, which is not a file")
    return policy, set(_WEAKENED.findall(r.stderr))


def granted(root, policy, domain, label, cls):
    """return the perms the policy allows"""
    r = subprocess.run(["bash", "test/checks/lib/avc-lab.sh", "search", "--allow",
                        "-s", domain, "-t", label, "-c", cls, "--policy", policy],
                       cwd=root, capture_output=True, text=True)
    if r.returncode != 0:
        return None, (r.stderr.strip() or r.stdout.strip() or f"rc={r.returncode}")
    perms = set()
    for line in r.stdout.splitlines():
        m = _ALLOW.match(line)
        if not m or m.group(1) != cls:
            continue
        perms.update((m.group(2) or m.group(3) or "").split())
    return perms, None


def check(root, policy, weakened, rows, out=sys.stdout):
    """print a result line per row"""
    bad = 0
    for row in rows:
        what = f"{row['domain']} -> {row['label']}:{row['class']} [{row['path-or-object']}]"
        if row["label"] == "?":
            bad += 1
            out.write(f"UNKNOWN {what} -- label undetermined, see {row['code-site']}\n")
            continue
        if row["label"] in weakened:
            bad += 1
            out.write(f"WEAKENED {what} -- policy.lab drops the deny covering this "
                      f"target; ask the source CIL, not this policy\n")
            continue
        have, err = granted(root, policy, row["domain"], row["label"], row["class"])
        if have is None:
            bad += 1
            out.write(f"ERROR {what} -- sesearch: {err}\n")
            continue
        perms = row["perms"].split()
        want = {p for p in perms if not p.startswith("!")}
        refuse = {p[1:] for p in perms if p.startswith("!")}
        missing = sorted(want - have)
        wider = sorted(refuse & have)
        if missing:
            bad += 1
            out.write(f"MISSING {' '.join(missing)}\t{what}\t{row['code-site']}\n")
        elif wider:
            bad += 1
            out.write(f"WIDER {' '.join(wider)}\t{what}\t{row['code-site']}\n")
        else:
            out.write(f"ok\t{what}\n")
    return bad


def selftest(root, policy, weakened):
    """run check on four fixture rows"""
    scratch = tempfile.mkdtemp(prefix="check-restart-access-selftest.")
    try:
        tsv = os.path.join(scratch, "fixture.tsv")
        with open(tsv, "w") as f:
            f.write("\t".join(COLUMNS) + "\n")
            f.write("kernel\t/root/<fixture>\tunlabeled\tdir\tcreate\tselftest:negative\n")
            f.write("kernel\t/root/<fixture>\tunlabeled\tdir\tsearch\tselftest:positive\n")
            f.write("kernel\t/root/<fixture>\tunlabeled\tdir\t!search\tselftest:wider\n")
            f.write("kernel\t/root/<fixture>\tunlabeled\tdir\t!create\tselftest:refused\n")
        rows, errors = read_rows(tsv)
        for e in errors:
            print(f"selftest: {e}")
        if len(rows) != 4:
            print(f"selftest FAIL: fixture parsed to {len(rows)} row(s), expected 4")
            return 1
        import io
        buf = io.StringIO()
        bad = check(root, policy, weakened, rows, out=buf)
        lines = buf.getvalue().splitlines()
        for line in lines:
            print(f"  {line}")
        ok = len(lines) == 4
        if not (ok and lines[0].startswith("MISSING create\t")):
            print("selftest FAIL: the neverallowed perm was not reported MISSING")
            ok = False
        if not (len(lines) == 4 and lines[1].startswith("ok\t")):
            print("selftest FAIL: the granted perm was not reported ok")
            ok = False
        if not (len(lines) == 4 and lines[2].startswith("WIDER search\t")):
            print("selftest FAIL: a granted perm the row requires refused (!search) was not reported WIDER")
            ok = False
        if not (len(lines) == 4 and lines[3].startswith("ok\t")):
            print("selftest FAIL: a refused perm the row requires refused (!create) was not reported ok")
            ok = False
        if bad != 2:
            print(f"selftest FAIL: {bad} row(s) counted bad, expected exactly 2")
            ok = False
        print("selftest PASS: MISSING on a refused perm, ok on a granted one, WIDER on a granted "
              "!perm, ok on a refused one" if ok else "selftest FAILED")
        return 0 if ok else 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main():
    """run the inventory check or the fixture pair"""
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", help="the Rhizo checkout to run avc-lab.sh from")
    ap.add_argument("--tsv", help="the inventory (default <repo>/test/checks/policy/access/restart-access.tsv)")
    ap.add_argument("--lab-dir", help="where to build policy.lab (default a mktemp -d)")
    ap.add_argument("--selftest", action="store_true",
                    help="run the fixture pair instead of the inventory")
    args = ap.parse_args()

    root = repo_root(args.repo)
    tsv = args.tsv or os.path.join(root, "test", "checks", "policy", "access", "restart-access.tsv")

    lab_dir = args.lab_dir
    tmp_lab = None
    if not lab_dir:
        tmp_lab = tempfile.mkdtemp(prefix="check-restart-access-lab.")
        lab_dir = tmp_lab
    try:
        policy, weakened = build_lab(root, lab_dir)
        print(f"policy.lab: {policy}")
        print("deny-weakened targets this run refuses to vouch for: "
              + (", ".join(sorted(weakened)) or "<none>"))
        if args.selftest:
            return selftest(root, policy, weakened)
        if not os.path.isfile(tsv):
            sys.exit(f"check-restart-access: no inventory at {tsv}")
        rows, errors = read_rows(tsv)
        for e in errors:
            print(f"BAD ROW {e}")
        print(f"{len(rows)} row(s) from {tsv}")
        bad = check(root, policy, weakened, rows)
        bad += len(errors)
        print(f"{len(rows) - bad if bad <= len(rows) else 0} ok, {bad} not vouched for")
        return 1 if bad else 0
    finally:
        if tmp_lab:
            shutil.rmtree(tmp_lab, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

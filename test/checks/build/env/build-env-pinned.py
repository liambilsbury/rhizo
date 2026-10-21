#!/usr/bin/env python3

import os
import re
import shlex
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
ENV_DIR = os.path.join(REPO, "tools", "build", "env")
PACKAGE = re.compile(r"[a-z0-9][a-z0-9+.-]*")
SNAPSHOT_URL = "snapshot.ubuntu.com/ubuntu/${SNAPSHOT}"
RELEASE_POCKET = re.compile(r"a=[a-z]+")
APT_VALUE_OPTIONS = {"-t", "--target-release", "--default-release", "-o", "--option", "-c", "--config-file"}
APT_UPGRADES = {"dist-upgrade", "full-upgrade"}
APT_NEW = {"install", "reinstall", "build-dep"}
APT_INSTALLS = APT_NEW | APT_UPGRADES | {"upgrade"}


def shell_commands(cf):
    """return the commands of every RUN line in a container file"""
    cmds, problems = [], []
    for n, run in enumerate(re.findall(r"^RUN (?:[^\n]*\\\n)*[^\n]*", cf, re.M)):
        lex = shlex.shlex(run[4:].replace("\\\n", " "), posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        words = []
        try:
            for tok in lex:
                if set(tok) <= set(lex.punctuation_chars):
                    if words:
                        cmds.append((n, words))
                    words = []
                else:
                    words.append(tok)
        except ValueError as e:
            problems.append("Containerfile RUN cannot be split into shell words (%s): %s" % (e, run.splitlines()[0]))
            continue
        if words:
            cmds.append((n, words))
    return cmds, problems


def apt_call(words):
    """parse an apt command"""
    at = next((k for k, w in enumerate(words) if os.path.basename(w) in ("apt-get", "apt")), None)
    if at is None:
        return None
    sub, release, pkgs = None, None, []
    rest = iter(words[at + 1:])
    for w in rest:
        if w in APT_VALUE_OPTIONS:
            value = next(rest, "")
            if w in ("-t", "--target-release", "--default-release"):
                release = value
        elif w.startswith(("--target-release=", "--default-release=")):
            release = w.split("=", 1)[1]
        elif w.startswith("-t"):
            release = w[2:]
        elif w.startswith("-"):
            continue
        elif sub is None:
            sub = w
        else:
            pkgs.append(w)
    return sub, release, pkgs


def apt_findings(cf):
    """return the findings for apt installs the snapshot does not pin"""
    cmds, out = shell_commands(cf)
    switch = next((k for k, (n, words) in enumerate(cmds) if SNAPSHOT_URL in " ".join(words)), len(cmds))
    calls = [(k, n, apt_call(words)) for k, (n, words) in enumerate(cmds)]
    calls = [(k, n, c) for k, n, c in calls if c and c[0]]
    upgrades, updated = [], False
    for k, n, (sub, release, pkgs) in calls:
        what = "installs " + (" ".join(pkgs) or "the packages it reads") if sub in APT_NEW else "runs apt-get " + sub
        if k < switch:
            if sub not in APT_INSTALLS:
                continue
            if sub == "install" and pkgs == ["ca-certificates"]:
                if not RELEASE_POCKET.fullmatch(release or ""):
                    out.append("Containerfile installs ca-certificates before the snapshot switch with %s, not from "
                               "the frozen release pocket (-t a=noble)"
                               % ("-t " + release if release else "no -t"))
            else:
                out.append("Containerfile %s from the live archive before the snapshot switch"
                           % what)
        elif sub == "update":
            updated = True
        elif sub in APT_UPGRADES:
            if updated:
                upgrades.append((k, n))
            else:
                out.append("Containerfile runs apt-get %s after the snapshot switch without an apt-get update "
                           "first" % sub)
    if switch == len(cmds):
        return out
    if not any(c[0] in APT_UPGRADES for k, n, c in calls if k > switch):
        out.append("Containerfile runs no apt-get dist-upgrade after the snapshot switch")
        return out
    for k, n, (sub, release, pkgs) in calls:
        if k > switch and sub in APT_NEW and not any(uk < k or un == n for uk, un in upgrades):
            out.append("Containerfile installs %s after the snapshot switch before apt-get dist-upgrade has moved "
                       "what is already installed to the snapshot's versions" % (" ".join(pkgs) or "the packages it reads"))
    return out


def findings(env_dir):
    """return the findings for a build environment directory"""
    try:
        with open(os.path.join(env_dir, "Containerfile")) as f:
            cf = f.read()
        with open(os.path.join(env_dir, "packages.txt")) as f:
            pk = f.read()
    except OSError as e:
        return ["cannot read the build environment: %s" % e]
    out = []
    froms = re.findall(r"^FROM\s+(\S+)", cf, re.M)
    if not froms:
        out.append("Containerfile has no FROM line")
    for base in froms:
        if not re.search(r"@sha256:[0-9a-f]{64}$", base):
            out.append("Containerfile's base %s is not pinned by digest" % base)
    if not re.search(r"^ARG SNAPSHOT=\d{8}T\d{6}Z$", cf, re.M):
        out.append("Containerfile pins no Ubuntu archive snapshot (ARG SNAPSHOT=YYYYMMDDTHHMMSSZ)")
    if SNAPSHOT_URL not in cf:
        out.append("Containerfile never points apt at the snapshot it pins")
    out.extend(apt_findings(cf))
    args = dict(re.findall(r"^ARG (\w+)=(\S+)$", cf, re.M))
    for line in re.findall(r"pip3? install ([^\n\\&]*)", cf):
        for spec in shlex.split(line):
            if spec.startswith("-"):
                continue
            spec = re.sub(r"\$\{(\w+)\}", lambda m: args.get(m.group(1), ""), spec)
            if not re.fullmatch(r"[A-Za-z0-9_.-]+==\d[\w.]*", spec):
                out.append("Containerfile installs %s from pip without an exact version" % spec)
    for run in re.findall(r"^RUN (?:[^\n]*\\\n)*[^\n]*", cf, re.M):
        if re.search(r"\b(curl|wget)\b", run) and "sha256sum -c" not in run:
            out.append("Containerfile downloads with curl or wget without checking a sha256: %s" % run.splitlines()[0])
    pkgs = [line.split("#")[0].strip() for line in pk.splitlines()]
    pkgs = [p for p in pkgs if p]
    if not pkgs:
        out.append("packages.txt names no packages")
    for p in pkgs:
        if not PACKAGE.fullmatch(p):
            out.append("packages.txt line %r is not one package name" % p)
    dup = sorted({p for p in pkgs if pkgs.count(p) > 1})
    if dup:
        out.append("packages.txt names %s more than once" % ", ".join(dup))
    return out


GOOD_CF = """FROM docker.io/library/ubuntu:24.04@sha256:%s
ARG SNAPSHOT=20261008T000000Z
ARG MESON=1.5.2
RUN apt-get update \\
 && apt-get install -y --no-install-recommends -t a=noble ca-certificates \\
 && rm -rf /var/lib/apt/lists/*
RUN sed -i "s#x#https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT}/#" /etc/apt/sources.list.d/ubuntu.sources
RUN apt-get update \\
 && apt-get -y --no-install-recommends dist-upgrade \\
 && sed 's/#.*//' /tmp/packages.txt | xargs apt-get install -y --no-install-recommends
RUN pip3 install --break-system-packages --no-cache-dir "meson==${MESON}"
RUN curl -fsSL "https://example.invalid/tool" -o /usr/local/bin/tool \\
 && echo "${TOOL_SHA256}  /usr/local/bin/tool" | sha256sum -c -
""" % ("a" * 64)
GOOD_PK = "# build\nmake\ng++-14\nlibc6-dev-i386\n"


def run_fixture(cf, pk):
    """run the check on a fixture container file and package list"""
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "Containerfile"), "w") as f:
            f.write(cf)
        with open(os.path.join(tmp, "packages.txt"), "w") as f:
            f.write(pk)
        return findings(tmp)


def selftest():
    """check each finding on fixtures, flagged and clean"""
    fail = 0
    got = run_fixture(GOOD_CF, GOOD_PK)
    if got:
        print("SELFTEST FAIL: a pinned definition was flagged: %s" % got)
        fail = 1
    else:
        print("ok   selftest: a definition pinned by digest, snapshot, release-pocket bootstrap, dist-upgrade "
              "and exact pip version passes")
    bootstrap = "-t a=noble ca-certificates"
    switch = 'RUN sed -i "s#x#'
    upgrade = " && apt-get -y --no-install-recommends dist-upgrade \\\n"
    cases = [
        (GOOD_CF.replace(switch, "RUN apt-get update && apt-get install -y git\n" + switch), GOOD_PK,
         "installs git from the live archive before the snapshot switch"),
        (GOOD_CF.replace(bootstrap, "ca-certificates"), GOOD_PK,
         "installs ca-certificates before the snapshot switch with no -t"),
        (GOOD_CF.replace(bootstrap, "-t noble ca-certificates"), GOOD_PK,
         "installs ca-certificates before the snapshot switch with -t noble"),
        (GOOD_CF.replace(upgrade, ""), GOOD_PK, "runs no apt-get dist-upgrade after the snapshot switch"),
        (GOOD_CF.replace(upgrade, "") + "RUN apt-get update && apt-get -y dist-upgrade\n", GOOD_PK,
         "installs the packages it reads after the snapshot switch before apt-get dist-upgrade"),
        (GOOD_CF.replace(upgrade, "").replace("/ubuntu.sources\n", "/ubuntu.sources\nRUN apt-get -y dist-upgrade\n"),
         GOOD_PK,
         "runs apt-get dist-upgrade after the snapshot switch without an apt-get update"),
        (GOOD_CF.replace("@sha256:" + "a" * 64, ""), GOOD_PK, "not pinned by digest"),
        (GOOD_CF.replace("ARG SNAPSHOT=20261008T000000Z\n", ""), GOOD_PK, "pins no Ubuntu archive snapshot"),
        (GOOD_CF.replace("https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT}/", "http://archive.ubuntu.com/ubuntu/"),
         GOOD_PK, "never points apt at the snapshot"),
        (GOOD_CF.replace('"meson==${MESON}"', "meson"), GOOD_PK, "meson from pip without an exact version"),
        (GOOD_CF.replace('"meson==${MESON}"', '"meson>=1.4"'), GOOD_PK, "without an exact version"),
        (GOOD_CF, GOOD_PK + "make\n", "names make more than once"),
        (GOOD_CF, GOOD_PK + "make ninja-build\n", "is not one package name"),
        (GOOD_CF, "# nothing\n", "names no packages"),
        (GOOD_CF.replace(' \\\n && echo "${TOOL_SHA256}  /usr/local/bin/tool" | sha256sum -c -', ""), GOOD_PK,
         "without checking a sha256"),
    ]
    for cf, pk, want in cases:
        got = run_fixture(cf, pk)
        if not any(want in g for g in got):
            print("SELFTEST FAIL: wanted '%s', got %s" % (want, got))
            fail = 1
        else:
            print("ok   selftest: caught (%s)" % want)
    print("build-env-pinned.py selftest: %s" % ("FAILED" if fail else "ok"))
    return fail


def main(argv):
    """run the check on the build environment or run the selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    bad = findings(ENV_DIR)
    for b in bad:
        print("FAIL: " + b)
    if bad:
        return 1
    print("check-build-env-pinned: the build container's base, apt snapshot and pip versions are all pinned")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

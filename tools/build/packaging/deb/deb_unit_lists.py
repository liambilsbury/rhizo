#!/usr/bin/env python3
import os
import re
import sys
import tempfile

LIST_PATHS = {"enable": "/usr/lib/rhizo/install/units.enable", "start": "/usr/lib/rhizo/install/units.start"}
UNITS = r"((?:'[^'\s]+' ?)+)>/dev/null \|\| true"
PATTERNS = (
    ("enable", re.compile(r"^[ \t]*deb-systemd-helper enable %s$" % UNITS)),
    ("start", re.compile(r"^[ \t]*deb-systemd-invoke \$_dh_action %s$" % UNITS)),
    (None, re.compile(r"^[ \t]*deb-systemd-helper --user enable %s$" % UNITS)),
)
CANDIDATE = re.compile(r"\bdeb-systemd-invoke\b|\bdeb-systemd-helper(?:[ \t]+-\S+)*[ \t]+enable\b")


def unit_lists(postinst):
    """return the enable and start unit lists"""
    lists, problems = {"enable": set(), "start": set()}, []
    for n, line in enumerate(postinst.split("\n"), 1):
        if not CANDIDATE.search(line):
            continue
        for kind, rx in PATTERNS:
            m = rx.match(line)
            if m:
                if kind:
                    lists[kind].update(re.findall(r"'([^']+)'", m.group(1)))
                break
        else:
            problems.append("line %d matches CANDIDATE and no PATTERNS entry (%s)" % (n, line.strip()))
    for kind, units in lists.items():
        if not units:
            problems.append("no %s unit" % kind)
    return {k: sorted(v) for k, v in lists.items()}, problems


def selftest():
    """check the unit list parser"""
    good = ("deb-systemd-helper unmask 'a.socket' >/dev/null || true\n"
            "if deb-systemd-helper --quiet was-enabled 'a.socket'; then\n"
            "\tdeb-systemd-helper enable 'a.socket' >/dev/null || true\n"
            "\tdeb-systemd-helper enable 'b.path' >/dev/null || true\n"
            "\t\tdeb-systemd-helper --user enable 'c.path' >/dev/null || true\n"
            "\t\tdeb-systemd-invoke $_dh_action 'a.socket' 'd.service' >/dev/null || true\n")
    cases = [
        ("debhelper 13.14's lines", good, {"enable": ["a.socket", "b.path"], "start": ["a.socket", "d.service"]}, []),
        ("a start by a literal verb", good + "deb-systemd-invoke start 'e.service' >/dev/null || true\n", None,
         ["line 7 matches CANDIDATE and no PATTERNS entry (deb-systemd-invoke start 'e.service')"]),
        ("an enable with no redirect", good + "deb-systemd-helper enable 'e.service'\n", None,
         ["line 7 matches CANDIDATE and no PATTERNS entry (deb-systemd-helper enable 'e.service')"]),
        ("an enable under another option", good + "deb-systemd-helper --system enable 'e.service' >/dev/null || true\n",
         None, ["line 7 matches CANDIDATE"]),
        ("no start line", good.replace("\t\tdeb-systemd-invoke $_dh_action 'a.socket' 'd.service' >/dev/null || true\n",
                                       ""), None, ["no start unit"]),
    ]
    fails = []
    for name, text, want_lists, want_problems in cases:
        lists, problems = unit_lists(text)
        if want_lists is not None and lists != want_lists:
            fails.append("unit_lists(%s) %s == %s" % (name, lists, want_lists))
        for w in want_problems:
            if not any(p.startswith(w) for p in problems):
                fails.append("unit_lists(%s) has a problem starting with %r (%s)" % (name, w, problems))
        if not want_problems and problems:
            fails.append("unit_lists(%s) problems == [] (%s)" % (name, problems))
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "postinst")
        with open(src, "w") as fh:
            fh.write(good)
        if main(["deb_unit_lists.py", src, tmp]) != 0:
            fails.append("main(postinst) == 0")
        elif open(os.path.join(tmp, "units.start")).read() != "a.socket\nd.service\n":
            fails.append("units.start == a.socket d.service (%r)" % open(os.path.join(tmp, "units.start")).read())
        with open(src, "a") as fh:
            fh.write("deb-systemd-invoke start 'e.service'\n")
        os.remove(os.path.join(tmp, "units.start"))
        if main(["deb_unit_lists.py", src, tmp]) == 0 or os.path.exists(os.path.join(tmp, "units.start")):
            fails.append("main(postinst with deb-systemd-invoke start) != 0 and no units.start")
    if fails:
        for f in fails:
            print("FAIL " + f, file=sys.stderr)
        return 1
    print("ok deb_unit_lists.py --selftest cases=%d" % len(cases))
    return 0


def main(argv):
    """write the unit lists of a postinst to a folder"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) != 3:
        print("deb_unit_lists.py <postinst> <dir> | --selftest", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as fh:
        lists, problems = unit_lists(fh.read())
    for p in problems:
        print("%s %s" % (argv[1], p), file=sys.stderr)
    if problems:
        return 1
    for kind, units in lists.items():
        with open(os.path.join(argv[2], os.path.basename(LIST_PATHS[kind])), "w") as fh:
            fh.write("".join(u + "\n" for u in units))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

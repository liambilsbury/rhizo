#!/usr/bin/env python3
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
METER = os.path.join(REPO, "test", "system", "tools", "stack-meter.py")


def load():
    """return the footprint meter module loaded from its file"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("rhizo_meter", METER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


EXPECTED_SITES = {
    "launcher3.py": [
        ("test/vm/redeploy.sh", "python3 /root/launcher3.py"),
    ],
    "host-primer": [
        ("src/androidd/sandbox/core.py", 'HOST_PRIMER_PATH = "/run/rhizo-host-primer.py"'),
        ("src/androidd/boot.py", "_cmd = [sys.executable, HOST_PRIMER_PATH,"),
    ],
    "sway": [
        ("test/vm/start/start-sway.sh", "setsid sway -c"),
    ],
    "rhizo-audiod": [
        ("src/services/audiod/audiod.service", "/usr/lib/rhizo/audiod/rhizo-audiod"),
    ],
    "app-events.py": [
        ("src/services/appsync/app-events.service", "app-events.py"),
    ],
    "netbridged.py": [
        ("src/androidd/boot.py", 'beside("netbridged", "netbridged.py")'),
    ],
    "rhizo-hostfsd": [
        ("src/services/hostfs/hostfs.py", 'sibling, "rhizo-hostfsd")'),
    ],
}


def check_sites(patterns, expected_sites, vm_dir, problems):
    """check patterns against expected_sites"""
    for label, pattern in patterns.items():
        sites = expected_sites.get(label)
        if not sites:
            problems.append(
                "HOST_SIDE_PATTERNS[%r] = %r has no EXPECTED_SITES entry"
                % (label, pattern))
            continue
        for relpath, needle in sites:
            path = os.path.join(vm_dir, relpath)
            if not os.path.isfile(path):
                problems.append(
                    "HOST_SIDE_PATTERNS[%r]: expected site %s does not exist"
                    % (label, relpath))
                continue
            with open(path) as f:
                text = f.read()
            if needle not in text:
                problems.append(
                    "HOST_SIDE_PATTERNS[%r] (pattern %r): %s no longer "
                    "contains %r" % (label, pattern, relpath, needle))

    for label in expected_sites:
        if label not in patterns:
            problems.append(
                "EXPECTED_SITES names %r as a real host-side daemon but "
                "HOST_SIDE_PATTERNS has no entry for it at all" % (label,))


def check_wrapper_exclusion(is_shell_wrapper_argv, problems):
    """check _is_shell_wrapper_argv() against sample argv lists"""
    wrapper_cases = [
        ("bash -c wrapper (redeploy.sh's own launch chain)",
         ["bash", "-c",
          "cd /root && systemd-run --scope --collect --unit=rhizo-launcher-$$ "
          "--quiet --     sh -c 'setsid python3 /root/launcher3.py selinux_setup "
          "> /root/boot.log 2>&1 < /dev/null' & disown; sleep 1; echo launched"]),
        ("sh -c wrapper (the intermediate setsid shell)",
         ["/usr/bin/sh", "-c",
          "setsid python3 /root/launcher3.py selinux_setup > /root/boot.log 2>&1 < /dev/null"]),
    ]
    for name, argv in wrapper_cases:
        if not is_shell_wrapper_argv(argv):
            problems.append(
                "_is_shell_wrapper_argv() did not recognize %s as a shell "
                "wrapper: %r"
                % (name, argv))

    real_cases = [
        ("the real boot.py interpreter", ["python3", "/root/launcher3.py", "selinux_setup"]),
        ("sway itself", ["sway", "-c", "/root/sway-rhizo.conf", "-d"]),
        ("rhizo-hostfsd itself", ["/root/share/rhizo-hostfsd", "--fd", "9", "--foreground"]),
    ]
    for name, argv in real_cases:
        if is_shell_wrapper_argv(argv):
            problems.append(
                "_is_shell_wrapper_argv() called %s a shell wrapper: %r"
                % (name, argv))


def main():
    """run the pattern checks and print the problems"""
    mod = load()
    problems = []
    check_sites(mod.HOST_SIDE_PATTERNS, EXPECTED_SITES, REPO, problems)
    check_wrapper_exclusion(mod._is_shell_wrapper_argv, problems)
    if problems:
        for p in problems:
            print("check-hostside-patterns: %s" % p, file=sys.stderr)
        return 1
    print("check-hostside-patterns: every HOST_SIDE_PATTERNS entry resolves "
          "to a real host-side daemon invocation, and the shell-wrapper "
          "exclusion holds")
    return 0



def _broken_patterns_wrong_process(mod):
    """replace netbridged.py with serve-dns-http.py in the patterns"""
    broken = dict(mod.HOST_SIDE_PATTERNS)
    del broken["netbridged.py"]
    broken["serve-dns-http.py"] = "serve-dns-http.py"
    return broken


def _broken_patterns_missing_entirely(mod):
    """return patterns with rhizo-hostfsd removed"""
    broken = dict(mod.HOST_SIDE_PATTERNS)
    del broken["rhizo-hostfsd"]
    return broken


def _broken_sites_absent_text(mod):
    """replace the launcher3.py site text with absent text"""
    broken = dict(EXPECTED_SITES)
    broken["launcher3.py"] = [("test/vm/redeploy.sh",
                                "this exact text will never appear in redeploy.sh")]
    return broken


def _broken_sites_missing_file(mod):
    """point the sway site at a missing file"""
    broken = dict(EXPECTED_SITES)
    broken["sway"] = [("tools/this-file-does-not-exist.sh", "sway")]
    return broken


def _broken_is_shell_wrapper_argv(_argv):
    """return False for each argv"""
    return False


def selftest():
    """check that each broken pattern set is flagged"""
    mod = load()
    ok = True

    for name, patterns, sites in (
            ("a real file but the wrong process (serve-dns-http.py in place "
             "of netbridged.py)", _broken_patterns_wrong_process(mod), EXPECTED_SITES),
            ("a host-side daemon with no entry at all (rhizo-hostfsd dropped)",
             _broken_patterns_missing_entirely(mod), EXPECTED_SITES),
            ("a real pattern whose site text has rotted",
             mod.HOST_SIDE_PATTERNS, _broken_sites_absent_text(mod)),
            ("a real pattern whose site file is gone",
             mod.HOST_SIDE_PATTERNS, _broken_sites_missing_file(mod)),
    ):
        problems = []
        check_sites(patterns, sites, REPO, problems)
        if not problems:
            print("selftest FAIL: %s passed check_sites" % name, file=sys.stderr)
            ok = False

    problems = []
    check_wrapper_exclusion(_broken_is_shell_wrapper_argv, problems)
    if not problems:
        print("selftest FAIL: a wrapper-exclusion function that always says "
              "'not a wrapper' passed check_wrapper_exclusion",
              file=sys.stderr)
        ok = False

    if not ok:
        return 1
    print("selftest: all 5 reintroduced defects were caught")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())

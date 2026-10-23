#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

SWAY_LIB = "test/system/lib/sway-lib.sh"
DESKTOP_LIB = "test/system/lib/desktop-lib.sh"

FIXED_PATTERNS = [
    re.compile(r"\bswaymsg\b"),
    re.compile(r"\bgrim\b"),
    re.compile(r"wlr-inject"),
    re.compile(r"""\binject\s+['"$]"""),
    re.compile(r"\bSWAYSOCK\b"),
    re.compile(r"\bSWAY_ENV\b"),
    re.compile(r"gnome-harness\b"),
    re.compile(r"\bGNOME_ENV\b"),
    re.compile(r"\b_gnome_harness\b"),
    re.compile(r"\bgcmd_gnome\b"),
    re.compile(r"org\.gnome\.(Shell|Mutter)"),
    re.compile(r"org\.rhizo\.Harness"),
    re.compile(r"plasma-harness\b"),
    re.compile(r"\b_plasma_harness\b"),
    re.compile(r"\bgcmd_plasma\b"),
    re.compile(r"kde-inject\b"),
    re.compile(r"org\.kde\.KWin"),
]

DESK_DIRECT_CALL = re.compile(r"\b_desk_[a-z]+_[a-z_]+\b")

FUNC_DEF = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")

ALLOWLIST = {
    "test/checks/lib/tree_dirs.py": "names the gnome-harness-ext folder only to leave its extension metadata out of the script folder list; it runs nothing in a session",
    "test/system/run/system_tests.py": "names the gnome-harness-ext folder only to leave it out of the system test search; it runs nothing in a session",
    "test/system/lib/sway-lib.sh": "the sway profile's own desk_* implementation",
    "test/vm/start/start-sway.sh": "starts and configures the sway compositor itself",
    "test/checks/system/profiles/desktop-lib-dispatch.py": "this checker; every match is one of its own PATTERNS/regex literals, its ALLOWLIST reasons, or its selftest's planted fixtures, never an invocation",
    "test/checks/system/profiles/shell-ext-gi.py": "a desk-time checker that reads the harness extension's generator as text and looks its gi:// calls up in typelibs; it never runs, reaches or starts the harness",
    "test/vm/boot/adb-tunnel.sh": "closes a stray Rhizo window directly when a device stalls",
    "tools/build/test-tools/wlr-inject.sh": "the build script for wlr-inject.c; every match is the artifact's own filename, never an invocation",
    "test/checks/system/desktop/app-events-trigger-domain.py": "selftest fixtures are synthetic test-body strings containing 'gcmd' as example text, never a real call",
    "test/checks/system/desktop/display-toplevel-id.py": "checker's own fixture drives sway directly",
    "test/checks/system/desktop/display-windowinput-harness.py": "a regex literal searching display.sh's OWN text for display_window_mapped (unmigrated, expected there), never a call by this checker itself",
    "test/checks/services/deskbridge/desktop-session-consumers.py": "selftest fixture GOOD_LIB is a synthetic desktop-assert-lib.sh string whose notify_sink_start calls gcmd_user, never a real call",
    "test/checks/system/profiles/desk-user-paths.py": "names gcmd_root as a root-side runner it scans for, and its selftest fixture is synthetic harness text calling gcmd_root/swaymsg, never a real call",
    "test/checks/system/common/guest-read-decisions.py": "selftest fixture is a synthetic bash script string stubbing sway_windows, never a real call",
    "tools/fetch/pools/deb/deb-pool-lib.sh": "every 'grim' is the Debian package name in the sway pool's root list and its selftest's expected planner argv, never an invocation of the tool",
    "tools/build/packaging/deb/deb-pool-plan.py": "every 'grim' is a Debian package name in the planner's selftest fixtures, never an invocation of the tool",
    "tools/build/vm/cachyos-dev.sh": "'grim' is a pacman package name in the dev base's install list, never an invocation of the tool",
    "test/checks/build/host-elf-links.py": "'one-shot build tool' is prose distinguishing aapt2 from a daemon, not a call to shot()",
    "test/checks/vm/start/net-wait.sh": "'single-shot probe' is prose describing a retry policy, not a call to shot()",
    "test/system/cycle/cachyos-update-leg.sh": "'set-oneshot' is bootctl's one-shot boot entry, not a call to shot()",
    "test/checks/vm/image/share-mount.py": "docstring names wlr-inject's staged path as the motivating example, never invokes it",
    "test/checks/system/profiles/gnome-launch-lingering.sh": "an offline test of gnome-lib.sh's own launch wrapper: it runs it against a fake launcher with the guest runner on this host, never a guest or the shell",
    "test/checks/system/profiles/sway-launch-scope.sh": "an offline test of sway-lib.sh's own launch_entry: it records the swaymsg command text a stubbed guest runner is handed, never a guest or compositor",
    "test/checks/system/profiles/sway-shot-hang.sh": "an offline test of sway-lib.sh's own shot paths: it calls shot and desk_shot against stubbed ssh bodies that only match grim's command text, never a guest",
    "test/system/android/audio.sh": "leg 0a's regress_one and leg 9's reboot use sway-lib.sh helpers directly for setup",
    "test/system/desktop/desktop.sh": "clipboard/notification/deskd fixture driving (gcmd_user, wait_guest) and mapped_window_rect have no desk_* equivalent",
    "test/system/desktop/display-stress.sh": "display.sh's stress sibling; not on desk_* verbs",
    "test/system/desktop/display.sh": "display_window_mapped/sway_windows/wait_guest/gcmd_user/inject_start for setup and debugging; no desk_* equivalent",
    "test/system/desktop/launcher.sh": "wait_guest/gcmd_user for debugging; no desk_* equivalent",
    "test/system/measure/host-delay.sh": "wheel-scrolls Settings at 30 events a second through the profile's own injector (inject_start on sway, the plasma input FIFO) as one guest loop",
    "test/system/install/installer.sh": "installs the sway package stack directly on a new vm; runs only under RHIZO_DESKTOP_PROFILE=sway",
    "test/system/boot/multi-instance.sh": "drives sway directly across multiple instances",
    "test/system/android/network.sh": "not on desk_* verbs",
    "test/system/install/certified-pair.sh": "not on desk_* verbs",
    "test/system/boot/server.sh": "the server profile's own system test; assert_no_wayland_socket is its own probe",
    "test/system/measure/sleep.sh": "not on desk_* verbs",
    "tools/build/test-tools/gen-gnome-harness-ext.sh": "writes the (gitignored) GNOME harness extension from an embedded heredoc; every match is inside that JS source's own prose comments (naming gnome-harness.py, or comparing to sway's swaymsg health check), never an invocation this shell script makes itself",
    "test/system/guest/gnome-harness.py": "the GNOME profile's own harness; every match is its own filename, in its docstring/usage text or --selftest, never an invocation of some OTHER copy",
    "test/system/lib/gnome-lib.sh": "the gnome profile's own desk_* implementation",
    "test/vm/start/start-gnome.sh": "starts and configures the gnome-shell session itself, and stages/health-checks gnome-harness.py the way start-sway.sh does for wlr-inject",
    "test/system/lib/plasma-lib.sh": "the plasma profile's own desk_* implementation",
    "test/vm/start/start-plasma.sh": "starts kwin or stages the Plasma seat login itself, and stages/health-checks plasma-harness.py and builds kde-inject the way start-gnome.sh stages gnome-harness.py",
    "test/system/guest/plasma-harness.py": "the plasma profile's own harness: it owns org.rhizo.Harness for KWin's scripts and reaches org.kde.KWin itself; every gnome-harness or shot match is its docstring, comments or own function names",
    "test/system/inject/kde-inject.c": "the fake-input client's own C source; every match is a // comment naming itself, never an invocation",
    "tools/build/test-tools/kde-inject.sh": "the build script for kde-inject.c; every match is the artifact's own filename, never an invocation",
    "test/checks/system/profiles/kde-inject.sh": "an offline test of kde-inject.c's parser: it builds the source against a stub Wayland layer in a scratch directory and runs that build, never a guest or a compositor",
    "test/checks/system/profiles/plasma-inject.sh": "an offline test of plasma-lib.sh's own _plasma_inject: it runs the guest script with the guest runner on this host against a stubbed systemctl and a fake device, never a guest or kde-inject itself",
    "test/system/desktop/window-input.sh": "the injector's own two-phase pre/post-policy boot choreography (sway_injector_staged, inject_devices_up, inject_attach, inject_stop) and its composite gestures (inject_type, inject_chord, inject_axis_discrete) stay on sway-lib.sh's own harness functions; wait_guest/gcmd_user for pre-boot polling",
    "test/system/tools/pngstat.py": "comment compares its own PNG decoder against grim's output format, never invokes grim",
    "tools/build/stamps.py": "docstring names wlr-inject as the motivating example, never invokes it",
    "test/system/inject/wlr-inject.c": "the injector's own C source; every match is a /* */ doc comment naming itself or the swaymsg calls a caller makes around it, never an invocation (it is C, it execs nothing)",
}

FUNCTION_ALLOWLIST = {
    "test/system/lib/desktop-assert-lib.sh": {
        "clip_start", "clip_stop", "clip_wait_data",
        "clip_mark", "clip_await",
        "notify_sink_start", "notify_sink_stop",
        "desktop_assert_link_host_to_app", "desktop_assert_link_android_to_host",
        "desktop_link_recorder_undo",
        "desktop_assert_dnd_drop_onto_app", "desktop_assert_dnd_drag_out_of_app",
        "desktop_dnd_evidence",
        "notify_invoke_action",
    },
    "test/system/lib/installer-lib.sh": {
        "installer_assert_app_paints",
        "installer_stage_desktop_resemblance",
    },
}

SCOPE = ("test/vm/", "test/system/", "test/checks/", "tools/", "src/install/",
         "src/androidd/")


def in_scope(rel):
    """check a path against the scan scope"""
    return rel.startswith(SCOPE) or (rel.startswith("src/services/") and rel.count("/") == 2)

SESSION_OWNING_FILES = [
    SWAY_LIB,
    DESKTOP_LIB,
    "test/vm/start/start-sway.sh",
    "test/vm/start/start-deskd.sh",
    "test/vm/start/start-audio.sh",
    "test/system/desktop/window-input.sh",
    "test/system/desktop/launcher.sh",
    "test/system/desktop/desktop.sh",
    "test/system/desktop/display.sh",
    "test/system/install/install.sh",
    "test/system/lib/desktop-assert-lib.sh",
    "test/system/lib/installer-lib.sh",
    "test/system/lib/install-lib.sh",
    "test/system/lib/server-assert-lib.sh",
    "test/system/lib/gsi-update-lib.sh",
    "test/system/cycle/cycle.sh", "test/system/cycle/cycle-selftest.sh",
    "src/services/deskbridge/deskd.service",
    "src/services/units/session/desktop-session.service",
    "src/services/audiod/audiod.service",
    "src/services/displayd/displayd.service",
    "src/services/keymapd/keymapd.service",
]

RUN_USER_0 = re.compile(r"/run/user/\d+\b")


def hardcoded_root_runtime_dir_violations(root):
    """return hardcoded /run/user path matches"""
    found = []
    for rel in SESSION_OWNING_FILES:
        lines = _read_lines(root, rel)
        if lines is None:
            continue
        for i, line in enumerate(lines, start=1):
            if line.lstrip().startswith("#"):
                continue
            m = RUN_USER_0.search(line)
            if m:
                found.append((rel, i, m.group(0)))
    return found


DESKTOP_SESSION_SERVICE = "src/services/units/session/desktop-session.service"
WAYLAND_DISPLAY_WRITE = re.compile(r'printf\s+"WAYLAND_DISPLAY=')
DBUS_BUS_SOCKET_TEST = re.compile(r'-S\s+\S*RD/bus')


def session_env_gaps(root):
    """return the session.env wiring problems"""
    reasons = []
    svc_lines = _read_lines(root, DESKTOP_SESSION_SERVICE)
    if svc_lines is not None and not WAYLAND_DISPLAY_WRITE.search("".join(svc_lines)):
        reasons.append(
            f"{DESKTOP_SESSION_SERVICE} never writes a WAYLAND_DISPLAY= line into "
            f"session.env")
    deskd_lines = _read_lines(root, "test/vm/start/start-deskd.sh")
    if deskd_lines is not None and not DBUS_BUS_SOCKET_TEST.search("".join(deskd_lines)):
        reasons.append(
            "test/vm/start/start-deskd.sh no longer proves (or creates) a live "
            "socket at the desktop session's dbus bus path before enabling "
            "rhizo-desktop-session.path")
    return reasons


GCMD_USER_CALL = re.compile(r"\bgcmd_user\b")
ROOT_PATH = re.compile(r"/root/")


def _quote_close(line, q=None):
    """return the open quote character"""
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and q != "'":
            i += 2
            continue
        if q is None and c in "\"'":
            q = c
        elif q == c:
            q = None
        i += 1
    return q


def gcmd_user_root_path_violations(root):
    """return gcmd_user /root path references"""
    found = []
    for rel in tracked(root):
        if not in_scope(rel) or not rel.endswith(".sh"):
            continue
        lines = _read_lines(root, rel)
        if lines is None:
            continue
        in_body = None
        for i, line in enumerate(lines, start=1):
            if in_body is None:
                if line.lstrip().startswith("#"):
                    continue
                if GCMD_USER_CALL.search(line):
                    q = _quote_close(line)
                    if ROOT_PATH.search(line):
                        found.append((rel, i))
                    if q:
                        in_body = q
                continue
            if ROOT_PATH.search(line):
                found.append((rel, i))
            if _quote_close(line, in_body) is None:
                in_body = None
    return found


STDIN_PROBE = r'''
set -u
RHIZO_DESKTOP_PROFILE=server
source "$1" >/dev/null 2>&1 || { echo "PROBE_SOURCE_FAILED"; exit 0; }
rec=$(mktemp)
for verb in "${DESKTOP_VERBS[@]}"; do
  eval "_desk_server_${verb#desk_}() { cat >/dev/null; printf '%s\n' \"\$1\" >>'$rec'; }"
  : >"$rec"
  while IFS= read -r id; do "$verb" "$id"; done < <(printf '%s\n' one two three)
  printf 'PROBE_VERB %s %s\n' "$verb" "$(paste -sd, "$rec")"
done
rm -f "$rec"
echo PROBE_DONE
'''
STDIN_PROBE_IDS = "one,two,three"


def stdin_isolation_failures(desktop_lib):
    """return the stdin isolation failures"""
    try:
        out = subprocess.run(["bash", "-c", STDIN_PROBE, "stdin-probe", desktop_lib],
                             capture_output=True, text=True, timeout=60,
                             stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return [f"{desktop_lib}: the stdin probe did not finish within 60s"]
    lines = out.stdout.splitlines()
    if "PROBE_SOURCE_FAILED" in lines:
        return [f"{desktop_lib}: could not be sourced under RHIZO_DESKTOP_PROFILE=server"]
    if "PROBE_DONE" not in lines:
        return [f"{desktop_lib}: the stdin probe never printed PROBE_DONE "
                f"(rc={out.returncode}, stderr: {out.stderr.strip()[:300]!r})"]
    verbs = [l.split(" ", 2) for l in lines if l.startswith("PROBE_VERB ")]
    if not verbs:
        return [f"{desktop_lib}: DESKTOP_VERBS named no verb"]
    fails = []
    for parts in verbs:
        seen = parts[2] if len(parts) > 2 else ""
        if seen != STDIN_PROBE_IDS:
            fails.append(f"{desktop_lib}: {parts[1]} called from a `while read` loop over "
                         f"{STDIN_PROBE_IDS} ran for '{seen}'; "
                         f"_desk_dispatch must run it with stdin on /dev/null")
    return fails


RUNNER_RE = re.compile(r"\b(gcmd_[a-z]+|wait_guest)\b")
RUNNER_PROFILES = ("sway", "gnome", "plasma")
RUNNER_PROBE = r'''
cd "$1" || { echo PROBE_SOURCE_FAILED; exit 0; }
export RHIZO_DESKTOP_PROFILE="$2"
shift 2
source ./desktop-lib.sh >/dev/null 2>&1 </dev/null || { echo PROBE_SOURCE_FAILED; exit 0; }
source ./desktop-assert-lib.sh >/dev/null 2>&1 </dev/null || { echo PROBE_SOURCE_FAILED; exit 0; }
for f in "$@"; do declare -F "$f" >/dev/null || echo "PROBE_MISSING $f"; done
echo PROBE_DONE
'''


SHELL_FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", re.M)


def sway_helpers_called(tools_dir, code):
    """return the sway-lib.sh functions named in code"""
    try:
        with open(os.path.join(tools_dir, "sway-lib.sh"), encoding="utf-8") as fh:
            funcs = {f for f in SHELL_FUNC_RE.findall(fh.read()) if not f.startswith("_desk_sway_")}
    except OSError:
        return set()
    text = "\n".join(code)
    return {f for f in funcs if re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(f), text)}


def profile_runner_gaps(tools_dir):
    """return runners missing from desktop profiles"""
    lib = os.path.join(tools_dir, "desktop-assert-lib.sh")
    try:
        with open(lib, encoding="utf-8") as fh:
            code = [l for l in fh.read().splitlines() if not l.lstrip().startswith("#")]
    except OSError as exc:
        return [f"{lib}: unreadable ({exc})"]
    names = {m for l in code for m in RUNNER_RE.findall(l)}
    if not names:
        return [f"{lib}: calls no gcmd_*/wait_guest runner at all"]
    names |= sway_helpers_called(tools_dir, code)
    names = sorted(names)
    fails = []
    for profile in RUNNER_PROFILES:
        try:
            out = subprocess.run(["bash", "-c", RUNNER_PROBE, "runner-probe", tools_dir, profile] + names,
                                 capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            fails.append(f"{profile}: the runner probe did not finish within 60s")
            continue
        lines = out.stdout.splitlines()
        if "PROBE_SOURCE_FAILED" in lines or "PROBE_DONE" not in lines:
            fails.append(f"{profile}: desktop-lib.sh and desktop-assert-lib.sh did not source whole "
                         f"(rc={out.returncode}, stderr: {out.stderr.strip()[:300]!r})")
            continue
        missing = [l.split(" ", 1)[1] for l in lines if l.startswith("PROBE_MISSING ")]
        if missing:
            fails.append(f"the {profile} profile defines no {' '.join(missing)}, "
                         f"called by desktop-assert-lib.sh's shared legs")
    return fails


VERB_PROFILES = ("sway", "gnome", "plasma")
VERB_PROBE = r'''
cd "$1" || { echo PROBE_SOURCE_FAILED; exit 0; }
export RHIZO_DESKTOP_PROFILE="$2"
source ./desktop-lib.sh >/dev/null 2>&1 </dev/null || { echo PROBE_SOURCE_FAILED; exit 0; }
for v in "${DESKTOP_VERBS[@]}"; do
  declare -F "_desk_$2_${v#desk_}" >/dev/null || echo "PROBE_MISSING _desk_$2_${v#desk_}"
done
echo "PROBE_VERBS ${#DESKTOP_VERBS[@]}"
echo PROBE_DONE
'''


def profile_verb_gaps(tools_dir, profiles=VERB_PROFILES):
    """return desk_* verbs missing from profiles"""
    fails = []
    for profile in profiles:
        try:
            out = subprocess.run(["bash", "-c", VERB_PROBE, "verb-probe", tools_dir, profile],
                                 capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            fails.append(f"{profile}: the verb probe did not finish within 60s")
            continue
        lines = out.stdout.splitlines()
        if "PROBE_SOURCE_FAILED" in lines or "PROBE_DONE" not in lines:
            fails.append(f"{profile}: desktop-lib.sh did not source under RHIZO_DESKTOP_PROFILE={profile} "
                         f"(rc={out.returncode}, stderr: {out.stderr.strip()[:300]!r})")
            continue
        if "PROBE_VERBS 0" in lines:
            fails.append(f"{profile}: DESKTOP_VERBS named no verb")
            continue
        missing = [l.split(" ", 1)[1] for l in lines if l.startswith("PROBE_MISSING ")]
        if missing:
            fails.append(f"the {profile} profile defines {len(missing)} of desktop-lib.sh's verbs not at all: "
                         f"{' '.join(missing)}")
    return fails


def git_env():
    """return the environment without GIT_ variables"""
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def tracked(root):
    """return the files in the git index"""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                         capture_output=True, text=True, timeout=120, env=git_env())
    if out.returncode != 0:
        raise RuntimeError(f"git ls-files failed in {root}: {out.stderr.strip()}")
    return [p for p in out.stdout.split("\0") if p]


def _read_lines(root, rel):
    """return a file's lines, or None when it cannot be read"""
    full = os.path.join(root, rel)
    try:
        with open(full, encoding="utf-8", errors="ignore") as fh:
            return fh.readlines()
    except OSError:
        return None


def _defined_functions(lines):
    """return the shell function names defined in some lines"""
    names = set()
    for line in lines:
        m = FUNC_DEF.match(line)
        if m:
            names.add(m.group(1))
    return names


BARE_WORD_EXEMPT = {"inject"}


def banned_sway_functions(root):
    """return the banned sway-lib.sh function patterns"""
    sway_lines = _read_lines(root, SWAY_LIB) or []
    desktop_lines = _read_lines(root, DESKTOP_LIB) or []
    sway_funcs = _defined_functions(sway_lines)
    desktop_funcs = _defined_functions(desktop_lines)
    banned = (sway_funcs - desktop_funcs
              - {n for n in sway_funcs if n.startswith("_desk_sway_")}
              - BARE_WORD_EXEMPT)
    return {n: re.compile(r"\b" + re.escape(n) + r"\b") for n in banned}


def violations(root, rel, sway_bans):
    """return the banned uses found in a file"""
    lines = _read_lines(root, rel)
    if lines is None:
        return []
    found = []
    enclosing = None
    for i, line in enumerate(lines, start=1):
        if line.lstrip().startswith("#"):
            continue
        m = FUNC_DEF.match(line)
        if m:
            enclosing = m.group(1)
            continue
        for pat in FIXED_PATTERNS:
            m = pat.search(line)
            if m:
                found.append((i, m.group(0), enclosing))
        m = DESK_DIRECT_CALL.search(line)
        if m:
            found.append((i, m.group(0), enclosing))
        for name, pat in sway_bans.items():
            m = pat.search(line)
            if m:
                found.append((i, m.group(0), enclosing))
    return found


def check(root, verbose=True):
    """return the dispatch check failures"""
    fails = []
    scanned = 0
    sway_bans = banned_sway_functions(root)
    try:
        rels = tracked(root)
    except RuntimeError as exc:
        return [f"FAIL: {exc}"]
    for rel in rels:
        if not in_scope(rel):
            continue
        if not (rel.endswith(".sh") or rel.endswith(".py") or rel.endswith(".c")):
            continue
        if rel in ALLOWLIST:
            continue
        func_ok = FUNCTION_ALLOWLIST.get(rel)
        scanned += 1
        for line, token, enclosing in violations(root, rel, sway_bans):
            if func_ok is not None and enclosing in func_ok:
                continue
            where = f" (in {enclosing}())" if enclosing else ""
            fails.append(f"FAIL: {rel}:{line}{where} uses '{token}' outside sway-lib.sh/start-sway.sh "
                         f"(and no allowlist row); use desktop-lib.sh's desk_* verbs "
                         f"or add {rel} to ALLOWLIST/FUNCTION_ALLOWLIST in desktop-lib-dispatch.py")
    for rel, line, matched in hardcoded_root_runtime_dir_violations(root):
        fails.append(f"FAIL: {rel}:{line} hardcodes '{matched}'; "
                      f"resolve the uid at call time")
    if scanned == 0 and not fails:
        return [f"FAIL: 0 files scanned under {", ".join(SCOPE)} in {root}"]
    for reason in session_env_gaps(root):
        fails.append(f"FAIL: {reason}")
    for rel, line in gcmd_user_root_path_violations(root):
        fails.append(f"FAIL: {rel}:{line} a gcmd_user command references a path under /root/; "
                      f"stage the file into /tmp instead")
    if verbose and not fails:
        print(f"desktop-lib dispatch: {scanned} files in scope outside the allowlist, "
              f"none reach the compositor directly or a sway-lib.sh-only function "
              f"({len(sway_bans)} such functions banned, {len(ALLOWLIST)} files allowlisted, "
              f"{sum(len(v) for v in FUNCTION_ALLOWLIST.values())} functions individually allowlisted); "
              f"no session-owning file hardcodes a literal /run/user/<uid>; "
              f"session.env's WAYLAND_DISPLAY and dbus-bus guarantee are both still wired; "
              f"no gcmd_user command references a path under /root/")
    return fails


def selftest():
    """run the checks against fixture trees"""
    import tempfile
    asserts = 0
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "repo")
        os.makedirs(os.path.join(root, "test", "system"))
        subprocess.run(["git", "init", "-q", "-b", "main", root], check=True, env=git_env())

        def write(rel, text):
            """write a file under the fixture root"""
            full = os.path.join(root, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as fh:
                fh.write(text)

        write("test/system/lib/sway-lib.sh", (
            "#!/bin/bash\n"
            "gcmd() { ssh_vm \"$1\"; }\n"
            "pull() { scp \"$1\" \"$2\"; }\n"
            "_desk_sway_windows() { gcmd 'swaymsg -t get_tree'; }\n"
        ))
        write("test/system/lib/desktop-lib.sh", (
            "#!/bin/bash\n"
            "pull() { scp \"$1\" \"$2\"; }\n"
            "desk_windows() { _desk_sway_windows; }\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())

        write("test/system/clean.sh", "#!/bin/bash\ndesk_windows | grep -c .\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        assert check(root, verbose=False) == []
        asserts += 1

        write("test/system/dirty.sh", "#!/bin/bash\ngcmd \"swaymsg -t get_tree\"\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("dirty.sh:2 uses 'swaymsg'" in f for f in fails), fails
        asserts += 1

        write("test/system/ambiguous.sh", "#!/bin/bash\ngcmd \"echo hello\"\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("ambiguous.sh:2 uses 'gcmd'" in f for f in fails), fails
        asserts += 1
        write("test/system/ambiguous.sh", "#!/bin/bash\ndesk_windows | grep -c .\n")

        write("test/system/dirty.sh", "#!/bin/bash\ndesk_windows | grep -c .\n")

        write("test/system/comment.sh", "#!/bin/bash\n# this used to call swaymsg directly\ndesk_windows\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert not any("comment.sh" in f for f in fails), fails
        asserts += 1

        write("test/system/grim.sh", "#!/bin/bash\ngcmd \"grim /tmp/x.png\"\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("grim.sh:2 uses 'grim'" in f for f in fails), fails
        asserts += 1
        write("test/system/grim.sh", "#!/bin/bash\ndesk_shot /tmp/x.png\n")

        write("test/system/gnome-direct.sh", "#!/bin/bash\nssh_vm python3 gnome-harness.py ping\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("gnome-direct.sh:2 uses 'gnome-harness" in f for f in fails), fails
        asserts += 1
        write("test/system/gnome-direct.sh", "#!/bin/bash\ndesk_windows\n")

        write("test/system/gnome-env.sh", "#!/bin/bash\necho \"$GNOME_ENV foo\"\n")
        write("test/system/gnome-fn.sh", "#!/bin/bash\n_gnome_harness \"ping\"\n")
        write("test/system/gnome-gcmd.sh", "#!/bin/bash\ngcmd_gnome \"true\"\n")
        write("test/system/gnome-iface1.sh", "#!/bin/bash\nbusctl call org.gnome.Shell / Ping\n")
        write("test/system/gnome-iface2.sh", "#!/bin/bash\nbusctl call org.gnome.Mutter.DisplayConfig / X\n")
        write("test/system/gnome-iface3.sh", "#!/bin/bash\nbusctl call org.rhizo.Harness / Ping\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("gnome-env.sh:2 uses 'GNOME_ENV'" in f for f in fails), fails
        assert any("gnome-fn.sh:2 uses '_gnome_harness'" in f for f in fails), fails
        assert any("gnome-gcmd.sh:2 uses 'gcmd_gnome'" in f for f in fails), fails
        assert any("gnome-iface1.sh:2 uses 'org.gnome.Shell'" in f for f in fails), fails
        assert any("gnome-iface2.sh:2 uses 'org.gnome.Mutter'" in f for f in fails), fails
        assert any("gnome-iface3.sh:2 uses 'org.rhizo.Harness'" in f for f in fails), fails
        asserts += 1
        for f in ("gnome-env.sh", "gnome-fn.sh", "gnome-gcmd.sh",
                  "gnome-iface1.sh", "gnome-iface2.sh", "gnome-iface3.sh"):
            write(f"test/system/{f}", "#!/bin/bash\ndesk_windows\n")

        plasma_plants = {
            "plasma-harness.sh": ("ssh_vm python3 /tmp/plasma-harness.py windows", "plasma-harness"),
            "plasma-fn.sh": ("_plasma_harness \"windows\"", "_plasma_harness"),
            "plasma-gcmd.sh": ("gcmd_plasma \"true\"", "gcmd_plasma"),
            "plasma-inject.sh": ("echo 'key 30 1' | ssh_vm /usr/local/bin/kde-inject", "kde-inject"),
            "plasma-iface.sh": ("busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure", "org.kde.KWin"),
        }
        for f, (line, _token) in plasma_plants.items():
            write(f"test/system/{f}", f"#!/bin/bash\n{line}\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        for f, (_line, token) in plasma_plants.items():
            assert any(f"{f}:2 uses '{token}'" in x for x in fails), (f, fails)
        asserts += 1
        for f in plasma_plants:
            write(f"test/system/{f}", "#!/bin/bash\ndesk_windows\n")

        write("test/system/sock.sh", "#!/bin/bash\ngcmd \"SWAYSOCK=\\$x true\"\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("sock.sh:2 uses 'SWAYSOCK'" in f for f in fails), fails
        asserts += 1
        write("test/system/sock.sh", "#!/bin/bash\ndesk_env\n")

        write("test/system/inject.sh",
              "#!/bin/bash\ninject \"abs 1 2\"\ninject 'abs 1 2 1920 1080'\ninject $CMD\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("inject.sh:2 uses" in f for f in fails), fails
        assert any("inject.sh:3 uses" in f for f in fails), fails
        assert any("inject.sh:4 uses" in f for f in fails), fails
        asserts += 1
        write("test/system/inject.sh", "#!/bin/bash\ndesk_inject_pointer abs 1 2\n")

        write("test/system/desktop/display-stress.sh", "#!/bin/bash\ngcmd \"swaymsg -t get_tree\"\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert not any("display-stress.sh" in f for f in fails), fails
        asserts += 1
        write("test/system/desktop/display-stress.sh", "#!/bin/bash\ndesk_windows\n")

        write("test/system/lib/sway-lib.sh", (
            "#!/bin/bash\n"
            "gcmd() { ssh_vm \"$1\"; }\n"
            "pull() { scp \"$1\" \"$2\"; }\n"
            "swaycmd() { gcmd \"swaymsg $1\"; }\n"
            "shot() { gcmd \"grim $1\"; }\n"
            "sway_windows() { gcmd 'swaymsg -t get_tree'; }\n"
            "_desk_sway_windows() { sway_windows; }\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())

        write("test/system/swaycmd.sh", "#!/bin/bash\nswaycmd \"-t get_tree\"\n")
        write("test/system/windows.sh", "#!/bin/bash\nsway_windows\n")
        write("test/system/shot.sh", "#!/bin/bash\nshot /tmp/x.png \"-o HEADLESS-2\"\n")
        write("test/system/injectvar.sh", "#!/bin/bash\ninject 'abs 1 2 1920 1080'\n")
        write("test/system/directcall.sh", "#!/bin/bash\n_desk_sway_windows\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("swaycmd.sh:2 uses 'swaycmd'" in f for f in fails), fails
        assert any("windows.sh:2 uses 'sway_windows'" in f for f in fails), fails
        assert any("shot.sh:2 uses 'shot'" in f for f in fails), fails
        assert any("injectvar.sh:2 uses" in f for f in fails), fails
        assert any("directcall.sh:2 uses '_desk_sway_windows'" in f for f in fails), fails
        asserts += 1
        for f in ("swaycmd.sh", "windows.sh", "shot.sh", "injectvar.sh", "directcall.sh"):
            write(f"test/system/{f}", "#!/bin/bash\ndesk_windows\n")

        write("test/system/pull.sh", "#!/bin/bash\npull /tmp/a /tmp/b\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert not any("pull.sh" in f for f in fails), fails
        asserts += 1

        write("test/vm/start/start-deskd.sh", (
            "#!/bin/bash\n"
            "# historically this used /run/user/0, no longer\n"
            "export XDG_RUNTIME_DIR=/run/user/0\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("start-deskd.sh:3 hardcodes '/run/user/0'" in f for f in fails), fails
        assert not any("start-deskd.sh:2" in f for f in fails), fails
        asserts += 1
        write("src/services/units/session/desktop-session.service", (
            "# historically this used /run/user/1000, no longer\n"
            "RUNTIME_DIR=/run/user/1000\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("desktop-session.service:2 hardcodes '/run/user/1000'" in f for f in fails), fails
        asserts += 1
        write("src/services/units/session/desktop-session.service", (
            "# historically this used /run/user/1000, no longer\n"
            "RUNTIME_DIR=/run/user/$(id -u)\n"
            'printf "WAYLAND_DISPLAY=%s\\n" "$(basename "$SOCK")"\n'
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        assert not any("FAIL: src/services/units/session/desktop-session.service:" in f for f in check(root, verbose=False)), \
            "a resolved uid must not be flagged"
        asserts += 1

        write("src/services/units/session/desktop-session.service", (
            "# no WAYLAND_DISPLAY= line at all\n"
            "RUNTIME_DIR=/run/user/$(id -u)\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("never writes a WAYLAND_DISPLAY=" in f for f in fails), fails
        asserts += 1
        write("src/services/units/session/desktop-session.service", (
            "# historically this used /run/user/1000, no longer\n"
            "RUNTIME_DIR=/run/user/$(id -u)\n"
            'printf "WAYLAND_DISPLAY=%s\\n" "$(basename "$SOCK")"\n'
        ))
        write("test/vm/start/start-deskd.sh", (
            "#!/bin/bash\n"
            "# no dbus-bus existence check at all\n"
            "DESKTOP_UID=$(id -u \"$DESKTOP_USER\")\n"
            "export XDG_RUNTIME_DIR=/run/user/$DESKTOP_UID\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("no longer proves (or creates) a live" in f for f in fails), fails
        asserts += 1
        write("test/vm/start/start-deskd.sh", (
            "#!/bin/bash\n"
            "# historically this used /run/user/0, no longer\n"
            "DESKTOP_UID=$(id -u \"$DESKTOP_USER\")\n"
            "export XDG_RUNTIME_DIR=/run/user/$DESKTOP_UID\n"
            'if [ ! -S "$RD/bus" ]; then echo missing; fi\n'
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        assert not any("start-deskd.sh" in f for f in check(root, verbose=False)), \
            "a resolved uid must not be flagged"
        asserts += 1

        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        assert check(root, verbose=False) == [], "the clean fixture tree must pass"
        asserts += 1

        write("test/system/lib/desktop-assert-lib.sh", (
            "#!/bin/bash\n"
            "clip_start() {\n"
            "  gcmd \"true\"\n"
            "}\n"
            "some_other_function() {\n"
            "  gcmd \"true\"\n"
            "}\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert not any("desktop-assert-lib.sh:3" in f for f in fails), \
            "a violation inside an allowlisted function must pass: %r" % fails
        assert any("desktop-assert-lib.sh:6" in f and "some_other_function" in f for f in fails), \
            "the SAME violation outside the allowlisted function must still fail: %r" % fails
        asserts += 1
        write("test/system/lib/desktop-assert-lib.sh", "#!/bin/bash\n# nothing here anymore\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())

        write("test/system/rootpath.sh", (
            "#!/bin/bash\n"
            "gcmd_user \"setsid /root/share/somebin --listen x\" 25\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("rootpath.sh:2" in f and "/root/" in f for f in fails), fails
        asserts += 1
        write("test/system/rootpath.sh", (
            "#!/bin/bash\n"
            "gcmd_user \"rm -f /tmp/x\n"
            "setsid /root/share/somebin --listen x\n"
            "true\" 25\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("rootpath.sh:3" in f and "/root/" in f for f in fails), fails
        asserts += 1
        write("test/system/rootpath.sh", (
            "#!/bin/bash\n"
            "# see gcmd_user's own comment on why this stages through /tmp\n"
            "# not /root/share\n"
            "gcmd_root \"cp -f /root/share/somebin /tmp/x\" 25\n"
            "gcmd_user \"setsid /tmp/x --listen x\" 25\n"
        ))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        assert not any("rootpath.sh" in f for f in check(root, verbose=False)), \
            "gcmd_root, and a comment merely naming gcmd_user, must not be flagged"
        asserts += 1
        os.remove(os.path.join(root, "test", "system", "rootpath.sh"))
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())

        assert check(root, verbose=False) == [], "the clean fixture tree must pass"
        asserts += 1

    with tempfile.TemporaryDirectory() as empty_tmp:
        fails = check(empty_tmp, verbose=False)
        assert fails and any("git ls-files failed" in f for f in fails), \
            "a non-git root must fail by name, not read as clean: %r" % fails
        asserts += 1

    with tempfile.TemporaryDirectory() as lib_tmp:
        def lib(name, dispatch_tail, verbs="desk_windows desk_window_op"):
            """write a fixture desktop-lib"""
            path = os.path.join(lib_tmp, name)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/bin/bash\n"
                    f"DESKTOP_VERBS=({verbs})\n"
                    "_desk_dispatch() {\n"
                    "  local fn=\"$1\"; shift\n"
                    f"  \"_desk_${{RHIZO_DESKTOP_PROFILE}}_${{fn}}\" \"$@\"{dispatch_tail}\n"
                    "}\n"
                    "desk_windows() { _desk_dispatch windows \"$@\"; }\n"
                    "desk_window_op() { _desk_dispatch window_op \"$@\"; }\n")
            return path

        fails = stdin_isolation_failures(lib("leaky.sh", ""))
        assert any("desk_window_op called from" in f and "ran for 'one'" in f for f in fails), fails
        assert any("desk_windows called from" in f and "ran for 'one'" in f for f in fails), fails
        asserts += 2
        assert stdin_isolation_failures(lib("isolated.sh", " </dev/null")) == []
        asserts += 1
        fails = stdin_isolation_failures(lib("noverbs.sh", " </dev/null", verbs=""))
        assert any("named no verb" in f for f in fails), fails
        asserts += 1
        broken = os.path.join(lib_tmp, "broken.sh")
        with open(broken, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/bash\nreturn 1\n")
        fails = stdin_isolation_failures(broken)
        assert any("could not be sourced" in f for f in fails), fails
        asserts += 1

    import shutil
    with tempfile.TemporaryDirectory() as tmp:
        for name in ("desktop-lib.sh", "sway-lib.sh", "gnome-lib.sh", "plasma-lib.sh", "desk-user-lib.sh",
                     "desktop-assert-lib.sh"):
            shutil.copy(os.path.join(HERE, "..", "..", "..", "system", "lib", name), os.path.join(tmp, name))
        assert profile_runner_gaps(tmp) == [], profile_runner_gaps(tmp)
        asserts += 1
        assert profile_verb_gaps(tmp) == [], profile_verb_gaps(tmp)
        asserts += 1
        plasma = os.path.join(tmp, "plasma-lib.sh")
        with open(plasma, encoding="utf-8") as fh:
            text = fh.read()
        with open(plasma, "w", encoding="utf-8") as fh:
            fh.write(text.replace("_desk_plasma_seat_devices() {", "_plasma_seat_devices_gone() {"))
        fails = profile_verb_gaps(tmp)
        assert any("plasma profile defines 1 of" in f and "_desk_plasma_seat_devices" in f for f in fails), fails
        assert not any("gnome profile" in f or "sway profile" in f for f in fails), fails
        asserts += 2
        shutil.copy(os.path.join(REPO, "test", "system", "lib", "plasma-lib.sh"), plasma)
        desktop = os.path.join(tmp, "desktop-lib.sh")
        with open(desktop, encoding="utf-8") as fh:
            text = fh.read()
        with open(desktop, "w", encoding="utf-8") as fh:
            fh.write(text.replace("  plasma)\n", "  plasma-retired)\n"))
        fails = profile_verb_gaps(tmp)
        assert any("plasma: desktop-lib.sh did not source" in f for f in fails), fails
        asserts += 1
        shutil.copy(os.path.join(REPO, "test", "system", "lib", "desktop-lib.sh"), desktop)
        gnome = os.path.join(tmp, "gnome-lib.sh")
        with open(gnome, encoding="utf-8") as fh:
            text = fh.read()
        start = text.index("\ngcmd_root() {") + 1
        end = text.index("\n}\n", text.index("wait_guest() {", start)) + 3
        with open(gnome, "w", encoding="utf-8") as fh:
            fh.write(text[:start] + text[end:])
        fails = profile_runner_gaps(tmp)
        assert any("gnome profile defines no gcmd_root gcmd_user wait_guest" in f for f in fails), fails
        assert not any("sway profile" in f for f in fails), fails
        asserts += 2
        shutil.copy(os.path.join(REPO, "test", "system", "lib", "gnome-lib.sh"), gnome)
        with open(os.path.join(tmp, "desktop-assert-lib.sh"), "a", encoding="utf-8") as fh:
            fh.write("\nplanted_leg() { gcmd_nowhere 'true' 5; }\n")
        fails = profile_runner_gaps(tmp)
        assert any("sway profile defines no gcmd_nowhere" in f for f in fails), fails
        assert any("gnome profile defines no gcmd_nowhere" in f for f in fails), fails
        asserts += 2
        shutil.copy(os.path.join(REPO, "test", "system", "lib", "desktop-assert-lib.sh"), os.path.join(tmp, "desktop-assert-lib.sh"))
        with open(os.path.join(tmp, "sway-lib.sh"), "a", encoding="utf-8") as fh:
            fh.write("\nplanted_sway_rect() {  # sway only\n  swaymsg -t get_tree\n}\n")
        with open(os.path.join(tmp, "desktop-assert-lib.sh"), "a", encoding="utf-8") as fh:
            fh.write("\nplanted_drag_leg() { local r; r=$(planted_sway_rect 3); }\n")
        fails = profile_runner_gaps(tmp)
        assert any("gnome profile defines no planted_sway_rect" in f for f in fails), fails
        assert not any("sway profile" in f for f in fails), fails
        asserts += 2
        os.remove(os.path.join(tmp, "desktop-lib.sh"))
        fails = profile_runner_gaps(tmp)
        assert any("did not source whole" in f for f in fails), fails
        asserts += 1

    print(f"check-desktop-lib-dispatch selftest: {asserts} assertions, every planted defect named")
    return 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=REPO)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    fails = check(args.root)
    stdin_fails = stdin_isolation_failures(os.path.join(args.root, DESKTOP_LIB))
    fails += [f"FAIL: {reason}" for reason in stdin_fails]
    if not stdin_fails:
        print("desktop-lib dispatch: every desk_* verb, called once per line from a "
              "`while read` loop, ran once per line -- none reads the loop's stdin")
    runner_fails = profile_runner_gaps(os.path.join(args.root, "test", "system", "lib"))
    fails += [f"FAIL: {reason}" for reason in runner_fails]
    if not runner_fails:
        print(f"desktop-lib dispatch: {', '.join(RUNNER_PROFILES)} each define every guest runner "
              "desktop-assert-lib.sh's shared legs call")
    verb_fails = profile_verb_gaps(os.path.join(args.root, "test", "system", "lib"))
    fails += [f"FAIL: {reason}" for reason in verb_fails]
    if not verb_fails:
        print(f"desktop-lib dispatch: {', '.join(VERB_PROFILES)} each define every desk_* verb "
              "desktop-lib.sh dispatches")
    for line in fails:
        print(line, file=sys.stderr)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

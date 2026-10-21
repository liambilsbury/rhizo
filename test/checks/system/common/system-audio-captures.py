#!/usr/bin/env python3
import functools
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.join(HERE, "..", "..", "..", "system", "android", "audio.sh")

POLICY_FIXTURE = """\
- Output 1 dump:
  1. Port ID: 2; I/O handle: 13; IOProfile name:primary output; Latency: 20; 0x0002 (AUDIO_OUTPUT_FLAG_PRIMARY)
     AUDIO_FORMAT_PCM_16_BIT; 48000; Channel mask: 0x3
     Devices: {AUDIO_DEVICE_OUT_SPEAKER, @:}
  2. Port ID: 4; I/O handle: 21; IOProfile name:bus0 output; Latency: 20; 0x0000 (AUDIO_OUTPUT_FLAG_NONE)
     AUDIO_FORMAT_PCM_16_BIT; 48000; Channel mask: 0x3
     Devices: {AUDIO_DEVICE_OUT_BUS, @:bus0}
  3. Port ID: 7; I/O handle: 29; IOProfile name:bus1 output; Latency: 20; 0x0000 (AUDIO_OUTPUT_FLAG_NONE)
     AUDIO_FORMAT_PCM_16_BIT; 48000; Channel mask: 0x3
     Devices: {AUDIO_DEVICE_OUT_BUS, @:bus1}
"""

TRACK_HEADER = ("    Type     Id Active Client(pid/uid) Session Port Id S  Flags   Format Chn mask  SRate ST Usg CT"
                "  G db  L dB  R dB  VS dB  PortVol dB  PortMuted   Server FrmCnt  FrmRdy F Underruns  Flushed\n")


def thread(handle, device, frames, rows, local_rows=()):
    """return a fixture output thread dump with the given tracks"""
    return ("Output thread 0x7f13a1b9%04d, name AudioOut_%d, tid 210, type 0 (MIXER):\n"
            "  I/O handle: %d\n"
            "  Output devices: %s\n"
            "  Frames written: %d\n"
            "Bluetooth latency modes are not enabled\n"
            "  %d Tracks of which %d are active\n" % (handle, handle, handle, device, frames, len(rows),
                                                      sum(1 for r in rows if r[1] == "yes"))
            + TRACK_HEADER
            + "".join("             %d    %s    %d/  %d     841      17 A  0x000 00000001 00000003  48000\n" % r
                      for r in rows)
            + "  0 Effect Chains\n  Local log:\n"
            + "".join("   09-12 01:19:02.684 AT::add       (0x7f1226810008)          %d     %s    %d/  %d     841\n" % r
                      for r in local_rows)
            + "\n")


FLINGER_FIXTURE = (thread(13, "0x2 (AUDIO_DEVICE_OUT_SPEAKER)", 0, [])
                   + thread(21, "0x1000000 (AUDIO_DEVICE_OUT_BUS)", 20160, [(56, "yes", 8085, 10111)])
                   + thread(29, "0x1000000 (AUDIO_DEVICE_OUT_BUS)", 58560,
                            [(40, "yes", 7001, 10050), (57, "no", 8953, 10112)],
                            local_rows=[(58, "yes", 8953, 10112)]))

STATE_CASES = [
    ("21", "10111", "20160 1 1", "misses the app's own active track on its bus"),
    ("29", "10112", "58560 1 0", "counts a track that is not the app's own active track in the thread's table"),
    ("13", "10111", "0 0 0", "calls a speaker thread a BUS device"),
    ("99", "10111", "none 0 0", "reports a thread for an I/O handle no thread has"),
]


def steps(text):
    """split the text into numbered step blocks"""
    out, cur, buf = {}, None, []
    for line in text.splitlines(keepends=True):
        m = re.match(r'step "(\d+)\.', line)
        if m:
            if cur is not None:
                out[cur] = "".join(buf)
            cur, buf = int(m.group(1)), []
        buf.append(line)
    if cur is not None:
        out[cur] = "".join(buf)
    return out


def logical_lines(block):
    """join backslash-continued lines in the block"""
    return re.sub(r"\\\n\s*", " ", block).splitlines()


def function_body(text, name):
    """return the text of a shell function, or None"""
    m = re.search(r"^%s\(\) \{.*?^\}\n" % re.escape(name), text, re.S | re.M)
    return m.group(0) if m else None


def run_bash(script, env=None):
    """run a bash script and return its exit code, output and errors"""
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60, env=env)
    return p.returncode, p.stdout, p.stderr


def sh_quote(s):
    """return a text quoted for a shell"""
    return "'" + s.replace("'", "'\"'\"'") + "'"


def capture_legs(n, block):
    """return the problems in how a step records its captures"""
    bad = []
    lines = logical_lines(block)
    first_capture = next((i for i, l in enumerate(lines) if l.lstrip().startswith("pw_capture")), None)
    if first_capture is None:
        return ["step %d records nothing with pw_capture" % n]
    before = lines[:first_capture]
    if not any("rm -f" in l and "/tmp/test-audio-" in l and "|| fail" in l for l in before):
        bad.append("step %d does not clear the guest's earlier wavs, failing when it cannot, before recording" % n)
    if not any(l.lstrip().startswith("rm -f") and "$EV/test-audio-" in l for l in before):
        bad.append("step %d does not clear the earlier local copies before recording" % n)
    for i, l in enumerate(lines):
        s = l.strip()
        nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if re.search(r"\bscp\b", l) and "test-audio" in l and "|| fail" not in l:
            bad.append("step %d copies its captures back without failing on a failed scp: %s" % (n, s[:90]))
        if s.startswith("pw_capture") and not s.endswith("&") and "|| fail" not in s \
                and not re.match(r"capture_\w+_rc=\$\?$", nxt):
            bad.append("step %d ignores a capture's exit status: %s" % (n, s[:90]))
        if s.startswith("wait ") and "capture_" in s and "|| fail" not in s \
                and not re.match(r"capture_\w+_rc=\$\?$", nxt):
            bad.append("step %d waits on a background capture without reading its exit status" % n)
        if "wavstat_get" in s and "=$(" in s and "|| fail" not in s:
            bad.append("step %d ignores wavstat's exit status: %s" % (n, s[:90]))
        if "wavstat.py" in s and "|| {" not in s and "|| fail" not in s:
            bad.append("step %d ignores wavstat's exit status: %s" % (n, s[:90]))
        m = re.search(r'awk -v v="\$(\w+)"', l)
        if m and not any(re.search(r'"\$%s" =~' % m.group(1), g) for g in lines[:i]):
            bad.append("step %d compares $%s with awk before checking it is a number" % (n, m.group(1)))
    for var in re.findall(r"^\s*(capture_\w+_rc)=\$\?", block, re.M):
        if not re.search(r"\(\( %s == 0 \)\) \|\| fail" % var, block):
            bad.append("step %d reads $%s but never fails on it" % (n, var))
    return bad


def restore_leg(block):
    """check step 7 restores the muted node's volume"""
    lines = logical_lines(block)
    at = next((i for i, l in enumerate(lines) if "wpctl set-volume" in l and " 1.0" in l), None)
    if at is None:
        return ["step 7 never restores the muted node's volume"]
    bad = []
    if "|| fail" not in lines[at]:
        bad.append("step 7 does not fail when restoring the muted node's volume fails")
    after = lines[at + 1:]
    cap = next((l for l in after if l.lstrip().startswith('pw_capture "rhizo_sink_$BUS_A"')), None)
    heard = False
    if cap and len(cap.split()) > 3:
        wav = os.path.basename(cap.split()[3])
        names = [m.group(1) for m in (re.match(r'\s*(\w+)=\$\(wavstat_get "\$EV/%s" rms\)' % re.escape(wav), l)
                                      for l in after) if m]
        heard = any("awk -v v=\"$%s\" 'BEGIN{exit !(v > 0.001)}'" % v in l for v in names for l in after)
    if not heard:
        bad.append("step 7 never shows app A audible again after its volume is restored")
    return bad


def launch_leg(block):
    """return the problems in how step 3 launches the app"""
    bad = []
    lines = logical_lines(block)
    launch_at = next((i for i, l in enumerate(lines) if "rhizo-launch.sh" in l and "ssh_vm" in l), None)
    if launch_at is None:
        return ["step 3 launches nothing through rhizo-launch.sh"]
    before = "\n".join(lines[:launch_at])
    if "stat -c %s /run/rhizo-launch/rhizo-launch.log" not in before:
        bad.append("step 3 does not mark the launcher's log before launching")
    if 'date "+%m-%d %H:%M:%S.000"' not in before:
        bad.append("step 3 does not read the guest clock before launching")
    named = set()
    for l in lines:
        s = l.strip()
        if s.startswith("#"):
            continue
        if "/run/rhizo-launch/rhizo-launch.log" in l and "stat -c" not in l and "tail -c +" not in l:
            bad.append("step 3 reads the launcher's whole boot log: %s" % s[:90])
        if "registered=true" in l and "grep" in l and "pkg=$pkg bus=$bus" not in l:
            bad.append("step 3 accepts a registration without naming this package and its bus: %s" % s[:90])
        if "logcat" in l and not re.search(r'-t \\?"\$play_since', l):
            bad.append("step 3 reads logcat without the since-launch mark: %s" % s[:90])
        for suffix in re.findall(r'grep -[qc]F? "RHIZO_AUDIO_PLAYING([^"]*)"', l):
            m = re.match(r" pkg=\$(PKG_[AB]) ", suffix)
            if m:
                named.add(m.group(1))
            else:
                bad.append("step 3 takes a RHIZO_AUDIO_PLAYING line without naming the package: %s" % s[:90])
    if named != {"PKG_A", "PKG_B"}:
        bad.append("step 3 does not wait for both packages' own RHIZO_AUDIO_PLAYING line (named: %s)" % sorted(named))
    return bad


def routing_leg(text, block):
    """return the problems in how the audio routing is read"""
    bad = []
    fns = {name: function_body(text, name) for name in ("bus_output_handle", "bus_thread_state")}
    for name, fn in fns.items():
        if fn is None:
            bad.append("audio.sh has no %s()" % name)
    if not bad:
        d = tempfile.mkdtemp(prefix="audio-routing-")
        try:
            policy, flinger = os.path.join(d, "policy.txt"), os.path.join(d, "flinger.txt")
            open(policy, "w").write(POLICY_FIXTURE)
            open(flinger, "w").write(FLINGER_FIXTURE)
            prelude = fns["bus_output_handle"] + fns["bus_thread_state"]
            for bus, want in (("bus0", "21"), ("bus1", "29"), ("bus3", "")):
                rc, out, err = run_bash(prelude + "bus_output_handle %s %s\n" % (sh_quote(policy), bus))
                if out.strip() != want:
                    bad.append("bus_output_handle gave %r for %s, wanted %r %s" % (out.strip(), bus, want, err.strip()[:80]))
            for handle, uid, want, meaning in STATE_CASES:
                rc, out, err = run_bash(prelude + "bus_thread_state %s %s %s\n" % (sh_quote(flinger), handle, uid))
                if out.strip() != want:
                    bad.append("bus_thread_state %s for handle %s uid %s: gave %r, wanted %r %s"
                               % (meaning, handle, uid, out.strip(), want, err.strip()[:80]))
        finally:
            shutil.rmtree(d)
    flat = "\n".join(logical_lines(block))
    for call in ("bus_output_handle", "bus_thread_state"):
        if call + " " not in flat:
            bad.append("step 4 does not resolve its threads with %s" % call)
    if not re.search(r"\(\( tracks >= 1 \)\) \|\| fail", flat):
        bad.append("step 4 does not fail when a bus's thread holds no active track from its own app")
    if not re.search(r"\(\( frames > 0 \)\) \|\| fail", flat):
        bad.append("step 4 does not fail when a bus's thread has written no frames")
    if "count++" in flat:
        bad.append("step 4 still counts BUS threads regardless of which app wrote them")
    return bad


def exit_statuses(text):
    """check the exit statuses of the capture and wav helpers"""
    bad = []
    cap = function_body(text, "pw_capture")
    if cap is None:
        bad.append("audio.sh has no pw_capture()")
    else:
        bad += capture_statuses(cap)
    get = function_body(text, "wavstat_get")
    if get is None:
        bad.append("audio.sh has no wavstat_get()")
    else:
        bad += wavstat_statuses(get)
    return bad


@functools.lru_cache(maxsize=None)
def capture_statuses(cap):
    """return the problems in the exit statuses of the capture function"""
    bad = []
    d = tempfile.mkdtemp(prefix="audio-capture-")
    try:
        fake = os.path.join(d, "pw-record")
        open(fake, "w").write('#!/bin/sh\ncase "$FAKE_PW" in hang) exec sleep 30 ;; early) exit 0 ;; '
                              '*) exit 1 ;; esac\n')
        os.chmod(fake, 0o755)
        env = dict(os.environ, PATH=d + ":" + os.environ["PATH"])
        stub = 'PW_AS_UBUNTU=""\nssh_vm() { shift 2; bash -c "$1"; }\n' + cap
        for mode, ok, meaning in (("hang", True, "a capture that ran to its deadline"),
                                  ("early", False, "a pw-record that left before its deadline"),
                                  ("fail", False, "a pw-record that failed")):
            env["FAKE_PW"] = mode
            rc, out, err = run_bash(stub + "pw_capture sink 1 %s\n" % sh_quote(os.path.join(d, "x.wav")), env)
            if (rc == 0) != ok:
                bad.append("pw_capture returns %d for %s" % (rc, meaning))
    finally:
        shutil.rmtree(d)
    return tuple(bad)


@functools.lru_cache(maxsize=None)
def wavstat_statuses(get):
    """check the exit statuses of the wav statistics helper"""
    bad = []
    d = tempfile.mkdtemp(prefix="audio-wavstat-")
    try:
        os.makedirs(os.path.join(d, "test", "system", "tools"))
        open(os.path.join(d, "test", "system", "tools", "wavstat.py"), "w").write(
            'import sys\nprint("rms %s" % ("0.250000" if sys.argv[1] == "good" else "0.000000"))\n'
            'sys.exit(0 if sys.argv[1] == "good" else 1)\n')
        for wav, ok, meaning in (("good", True, "a wav wavstat read"), ("bad", False, "a wav wavstat could not read")):
            rc, out, err = run_bash("REPO=%s\n%sv=$(wavstat_get %s rms)\n" % (sh_quote(d), get, wav))
            if (rc == 0) != ok:
                bad.append("wavstat_get returns %d for %s" % (rc, meaning))
    finally:
        shutil.rmtree(d)
    return tuple(bad)


def check(text):
    """return the problems from every audio capture check"""
    bad = []
    blocks = steps(text)
    for n in (3, 4, 6, 7):
        if n not in blocks:
            bad.append("step %d not found" % n)
    if bad:
        return bad
    bad += launch_leg(blocks[3])
    bad += routing_leg(text, blocks[4])
    for n in (6, 7):
        bad += capture_legs(n, blocks[n])
    bad += restore_leg(blocks[7])
    bad += exit_statuses(text)
    lines8 = logical_lines(blocks.get(8, ""))
    cmp_at = next((i for i, l in enumerate(lines8) if "SS_PID_START" in l and "SS_PID_END" in l
                   and ("!=" in l or "==" in l)), None)
    if cmp_at is None:
        bad.append("step 8 never compares the system_server pids")
    else:
        head = "\n".join(lines8[:cmp_at + 1])
        if '-z "$SS_PID_START"' not in head or '-z "$SS_PID_END"' not in head:
            bad.append("step 8 compares the system_server pids without refusing an empty one")
    return bad


def selftest():
    """check the live system test and each planted-defect copy"""
    real = open(TEST).read()
    problems = check(real)
    assert not problems, "the live system test must pass: %s" % problems

    def mutate(old, new):
        """return the live test with a text replaced"""
        assert real.count(old) == 1, "fixture anchor must occur once: %r" % old[:60]
        return real.replace(old, new, 1)

    cases = [
        ("guest clear dropped, step 6",
         mutate('ssh_vm -t 15 "rm -f /tmp/test-audio-a.wav /tmp/test-audio-b.wav" >/dev/null 2>&1 \\\n'
                '  || fail "could not clear the guest\'s earlier step-6 captures"\n', ""),
         "step 6 does not clear the guest's"),
        ("local clear dropped, step 7",
         mutate('rm -f "$EV/test-audio-a-muted.wav" "$EV/test-audio-b-muted.wav"\n', ""),
         "step 7 does not clear the earlier local copies"),
        ("muted scp unchecked",
         mutate(' "$EV/" \\\n  || fail "could not retrieve the muted captures"\n', ' "$EV/"\n'),
         "step 7 copies its captures back without failing"),
        ("muted rms unguarded",
         mutate('if [[ "$muted_rms" =~', 'if [[ "$muted" =~'),
         "compares $muted_rms with awk before checking"),
        ("step 6 share unguarded",
         mutate('&& "$theirs_share" =~', '&& "$theirs" =~'),
         "compares $theirs_share with awk before checking"),
        ("empty pid compared equal",
         mutate('if [[ -z "$SS_PID_START" || -z "$SS_PID_END" ]]; then', 'if false; then'),
         "without refusing an empty one"),
        ("launcher log unmarked",
         mutate('launch_log_mark=$(ssh_vm -t 10 "stat -c %s /run/rhizo-launch/rhizo-launch.log 2>/dev/null || echo 0"'
                ' | tr -d \'\\r\')', 'launch_log_mark=0'),
         "does not mark the launcher's log"),
        ("launcher log read whole",
         mutate('"tail -c +$(( launch_log_mark + 1 )) /run/rhizo-launch/rhizo-launch.log | grep audio"',
                '"grep audio /run/rhizo-launch/rhizo-launch.log"'),
         "reads the launcher's whole boot log"),
        ("any package's registration",
         mutate('grep -qF "audio pkg=$pkg bus=$bus -> ok registered=true"', 'grep -q "ok registered=true"'),
         "accepts a registration without naming"),
        ("logcat ring read whole",
         mutate('logcat -d -b all -t \\"$play_since\\"', 'logcat -d -b all'),
         "reads logcat without the since-launch mark"),
        ("one app's line counted for both",
         mutate('grep -qF "RHIZO_AUDIO_PLAYING pkg=$PKG_B hz=$HZ_B "', 'grep -qF "RHIZO_AUDIO_PLAYING"'),
         "without naming the package"),
        ("own track not required",
         mutate('  (( tracks >= 1 )) || fail', '  true ||'),
         "holds no active track from its own app"),
        ("inactive tracks counted",
         mutate('/[0-9]+ +yes +[0-9]+\\/ *[0-9]+/', '/[0-9]+ +[a-z]+ +[0-9]+\\/ *[0-9]+/'),
         "counts a track that is not the app's own active track"),
        ("local log rows counted",
         mutate('    mine && /Effect Chains|Local log:/ { table = 0 }\n', ''),
         "counts a track that is not the app's own active track"),
        ("step 6 capture status ignored",
         mutate('(( capture_a_rc == 0 )) || fail "the capture of rhizo_sink_$BUS_A did not run to its deadline'
                ' (exit $capture_a_rc)"\n', ''),
         "step 6 reads $capture_a_rc but never fails on it"),
        ("step 7 wait status ignored",
         mutate('capture_b_rc=$?\n(( capture_a_rc == 0 )) || fail "the muted capture',
                '(( capture_a_rc == 0 )) || fail "the muted capture'),
         "step 7 waits on a background capture without reading its exit status"),
        ("timeout's 124 not mapped",
         mutate('rc=\\$?; case \\$rc in 124) exit 0 ;; 0) exit 90 ;; *) exit \\$rc ;; esac"',
                'rc=\\$?; exit \\$rc"'),
         "pw_capture returns 124 for a capture that ran to its deadline"),
        ("early exit passes",
         mutate(' 0) exit 90 ;;', ''),
         "pw_capture returns 0 for a pw-record that left before its deadline"),
        ("wavstat status lost in a pipe",
         mutate('  out=$(python3 "$REPO/test/system/tools/wavstat.py" "$wav" "$@" 2>&1) || return 1\n'
                '  awk -v k="$key" \'$1==k {print $2}\' <<<"$out"\n',
                '  python3 "$REPO/test/system/tools/wavstat.py" "$wav" "$@" | awk -v k="$key" \'$1==k {print $2}\'\n'),
         "wavstat_get returns 0 for a wav wavstat could not read"),
        ("step 7 wavstat status ignored",
         mutate('restored_rms=$(wavstat_get "$EV/test-audio-a-restored.wav" rms) \\\n'
                '  || fail "wavstat could not read $EV/test-audio-a-restored.wav"\n',
                'restored_rms=$(wavstat_get "$EV/test-audio-a-restored.wav" rms)\n'),
         "step 7 ignores wavstat's exit status"),
        ("step 6 wavstat status ignored",
         mutate('> "$EV/wavstat-$s.txt" 2>&1 \\\n    || { fail "wavstat could not read capture $s (see $EV/wavstat-$s.txt)";'
                ' continue; }\n', '> "$EV/wavstat-$s.txt"\n'),
         "step 6 ignores wavstat's exit status"),
        ("volume restore unchecked",
         mutate('wpctl set-volume $node_a 1.0" >/dev/null 2>&1 \\\n  || fail "wpctl could not restore node $node_a\'s volume"\n',
                'wpctl set-volume $node_a 1.0" >/dev/null 2>&1\n'),
         "does not fail when restoring the muted node's volume fails"),
        ("restored audibility not asserted",
         mutate('awk -v v="$restored_rms" \'BEGIN{exit !(v > 0.001)}\'', 'awk -v v="$restored_rms" \'BEGIN{exit 0}\''),
         "never shows app A audible again"),
    ]
    for name, text, want in cases:
        got = check(text)
        assert any(want in g for g in got), "%s: expected a problem naming %r, got %s" % (name, want, got)

    head = subprocess.run(["git", "-C", HERE, "show", "HEAD:test/system/android/audio.sh"],
                          capture_output=True, text=True)
    if head.returncode == 0 and "wpctl could not restore node" not in head.stdout:
        assert check(head.stdout), "the pre-fix system test at HEAD must fail"
    print("check-test-audio-captures selftest: the live system test passes; %d single regressions each fail by name" % len(cases))


def main():
    """run the check or its selftest"""
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    path = sys.argv[1] if len(sys.argv) > 1 else TEST
    problems = check(open(path).read())
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        return 1
    print("check-test-audio-captures: steps 3, 4, 6 and 7 fail on a reading they never got, and step 8 on an empty pid")
    return 0


if __name__ == "__main__":
    sys.exit(main())

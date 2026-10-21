#!/usr/bin/env python3
import bisect
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
REDEPLOY = os.path.join(REPO, "test", "vm", "redeploy.sh")

START_MARK = "stage_cmd='set -e"
END_MARK = 'ssh_vm -t 45 "$stage_cmd"'

DANGER_WORDS = frozenset([
    "install", "mkdir", "cp", "rm", "chmod", "chown",
    "udevadm", "systemctl", "mount", "mountpoint", "insmod", "modprobe",
    "sysctl", "adduser", "getent", "journalctl", "truncate", "python3",
    "groupadd", "dpkg", "runuser", "pkill", "depmod",
    "swapon", "mkswap", "fallocate", "rsync", "umount", "rmdir", "networkctl",
])

_METACHARS = frozenset(" \t;&|<>()")


def first_violation_pos(text, pos):
    """return the offset of the first unquoted metacharacter"""
    state = "NONE"
    i, n = pos, len(text)
    while i < n:
        c = text[i]
        if state == "NONE":
            if c == "\n":
                return None
            if c in _METACHARS:
                j = i
                while j < n and text[j] in " \t":
                    j += 1
                if j >= n or text[j] == "\n":
                    return None
                if text[j] == "#" and (j == 0 or text[j - 1] in " \t\n"):
                    return None
                return i
            if c == "$" and i + 1 < n and text[i + 1] == "'":
                state, i = "DSINGLE", i + 2
                continue
            if c == "'":
                state, i = "SINGLE", i + 1
                continue
            if c == '"':
                state, i = "DOUBLE", i + 1
                continue
            if c == "\\":
                i += 2
                continue
            i += 1
        elif state == "SINGLE":
            if c == "'":
                state = "NONE"
            i += 1
        elif state == "DOUBLE":
            if c == "\\":
                i += 2
                continue
            if c == '"':
                state = "NONE"
            i += 1
        elif state == "DSINGLE":
            if c == "\\":
                i += 2
                continue
            if c == "'":
                state = "NONE"
            i += 1
    return None


def _is_word_char(c):
    """return whether a character is a letter, digit or underscore"""
    return c.isalnum() or c == "_"


def _at_word_start(text, idx):
    """return whether an index is at the start of a word"""
    if idx == 0:
        return True
    return text[idx - 1] in " \t\n;|&(){}"


def leaked_words(text):
    """return the DANGER_WORDS tokens outside quotes"""
    state = "NONE"
    out = []
    i, n, line = 0, len(text), 1
    while i < n:
        c = text[i]
        if state == "NONE":
            if c == "#" and _at_word_start(text, i):
                j = text.find("\n", i)
                i = n if j == -1 else j
                continue
            if c == "\n":
                line += 1
            if c == "$" and i + 1 < n and text[i + 1] == "'":
                state, i = "DSINGLE", i + 2
                continue
            if c == "'":
                state, i = "SINGLE", i + 1
                continue
            if c == '"':
                state, i = "DOUBLE", i + 1
                continue
            if c == "\\":
                i += 2
                continue
            if _is_word_char(c) and _at_word_start(text, i):
                j = i
                while j < n and _is_word_char(text[j]):
                    j += 1
                word = text[i:j]
                if word in DANGER_WORDS:
                    out.append((word, line))
                i = j
                continue
            i += 1
        elif state == "SINGLE":
            if c == "\n":
                line += 1
            if c == "'":
                state = "NONE"
            i += 1
        elif state == "DOUBLE":
            if c == "\n":
                line += 1
            if c == "\\":
                i += 2
                continue
            if c == '"':
                state = "NONE"
            i += 1
        elif state == "DSINGLE":
            if c == "\n":
                line += 1
            if c == "\\":
                i += 2
                continue
            if c == "'":
                state = "NONE"
            i += 1
    return out, state


def stage_cmd_span(text):
    """return the text between the stage_cmd markers"""
    start = text.find(START_MARK)
    end = text.find(END_MARK)
    if start == -1 or end == -1 or end < start:
        return None
    return text[start:end]


def assign_positions(text, var, lo, hi):
    """return the offsets past each var= token"""
    pat = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(var) + r"\+?=(?=['\"]|\$')")
    return [m.end() for m in pat.finditer(text, lo, hi)]


def structural_violations(text, var, lo, hi, starts):
    """return the line numbers of split statements"""
    lines = []
    for apos in assign_positions(text, var, lo, hi):
        vpos = first_violation_pos(text, apos)
        if vpos is not None:
            lines.append(_line_of(starts, vpos))
    return sorted(set(lines))


def main_redeploy():
    """check the staged command spans in the redeploy script"""
    if not os.path.isfile(REDEPLOY):
        print("check-stage-cmd-quoting: FAIL -- no %s" % REDEPLOY, file=sys.stderr)
        return 1
    text = open(REDEPLOY).read()
    start = text.find(START_MARK)
    end = text.find(END_MARK)
    if start == -1 or end == -1 or end < start:
        print("check-stage-cmd-quoting: FAIL -- redeploy.sh no longer has both "
              "%r and %r; update this check's markers" % (START_MARK, END_MARK),
              file=sys.stderr)
        return 1
    starts = _line_starts(text)
    bad_lines = structural_violations(text, "stage_cmd", start, end, starts)
    leaks, _ = leaked_words(text[start:end])
    if bad_lines or leaks:
        for ln in bad_lines:
            print("check-stage-cmd-quoting: FAIL -- redeploy.sh:%d -- this "
                  "stage_cmd+= statement splits into more than one shell "
                  "word before its own terminating newline" % ln, file=sys.stderr)
        offset = text[:start].count("\n") + 1
        for word, ln in leaks:
            print("check-stage-cmd-quoting: FAIL -- %r at redeploy.sh:%d runs "
                  "locally instead of staying inside stage_cmd" % (word, offset + ln - 1),
                  file=sys.stderr)
        return 1
    print("check-stage-cmd-quoting: ok -- stage_cmd's build-up stays quoted end to end")
    return 0


CONSUME_RE = re.compile(r'ssh_vm\s+(?:-t\s+\S+\s+)?"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"')

SKIP_FILES = frozenset()
INSTALL_SCRIPTS = ("src/install/prepare/derive-patches.sh", "src/install/prepare/detect-gpu-driver.sh",
                   "src/install/prepare/data-template.sh")


def _line_starts(text):
    """return the start offset of each line"""
    starts = [0]
    for m in re.finditer("\n", text):
        starts.append(m.end())
    return starts


def _line_of(starts, pos):
    """return the line number of an offset"""
    return bisect.bisect_right(starts, pos)


def discover_spans(path, text):
    """return the command build-up spans for ssh_vm calls"""
    starts = _line_starts(text)
    consumes = sorted(
        (_line_of(starts, m.start()), m.group(1), m.start())
        for m in CONSUME_RE.finditer(text)
    )
    out = []
    last_by_var = {}
    for ln, var, cpos in consumes:
        prev_line = last_by_var.get(var, 0)
        last_by_var[var] = ln
        assign_re = re.compile(r"^[ \t]*" + re.escape(var) + r"\+?=(?:'|\"|\$')", re.M)
        candidates = [
            _line_of(starts, am.start()) for am in assign_re.finditer(text)
            if prev_line < _line_of(starts, am.start()) <= ln
        ]
        if not candidates:
            continue
        start_line = min(candidates)
        start_byte = starts[start_line - 1]
        out.append((var, start_line, ln, text[start_byte:cpos], start_byte, cpos))
    return out


def tree_targets(root):
    """return the paths of the shell scripts"""
    found = []
    for top in ("test", "tools", os.path.join("src", "androidd")):
        for base, dirs, files in os.walk(os.path.join(root, top)):
            dirs.sort()
            for f in sorted(files):
                if f.endswith(".sh") and f not in SKIP_FILES:
                    found.append(os.path.join(base, f))
    services = os.path.join(root, "src", "services")
    found += [os.path.join(services, f) for f in sorted(os.listdir(services))
              if f.endswith(".sh") and f not in SKIP_FILES] if os.path.isdir(services) else []
    found += [os.path.join(root, f) for f in INSTALL_SCRIPTS if os.path.isfile(os.path.join(root, f))]
    return found


def main_tree():
    """check the staged command spans in the tracked scripts"""
    problems = []
    for path in tree_targets(REPO):
        text = open(path, errors="replace").read()
        starts = _line_starts(text)
        rel = os.path.relpath(path, REPO)
        for var, start_line, end_line, span, start_byte, end_byte in discover_spans(path, text):
            for ln in structural_violations(text, var, start_byte, end_byte, starts):
                problems.append(
                    "%s:%d -- this %s+= statement in %s's build-up (%s:%d-%d) splits into "
                    "more than one shell word before its own terminating newline; the rest "
                    "never reaches %s"
                    % (rel, ln, var, var, rel, start_line, end_line, var)
                )
            leaks, _ = leaked_words(span)
            for word, ln in leaks:
                problems.append(
                    "%r at %s:%d runs locally instead of staying inside "
                    "%s's build-up (%s:%d-%d)"
                    % (word, rel, start_line + ln - 1, var, rel, start_line, end_line)
                )
    if problems:
        for p in problems:
            print("check-stage-cmd-quoting: FAIL -- %s" % p, file=sys.stderr)
        return 1
    print("check-stage-cmd-quoting: ok -- every ssh_vm \"$VAR\" build-up under test/ and tools/ stays quoted end to end and never splits a word")
    return 0


ARRAY_RE = re.compile(r"EXPECTED_STAGE_CHUNKS=\((.*?)\)", re.S)
MARKER_RE = re.compile(r"RHIZO_STAGE_CHUNK=([A-Za-z0-9_-]+)")


def declared_chunks(text):
    """return the names in EXPECTED_STAGE_CHUNKS"""
    m = ARRAY_RE.search(text)
    if not m:
        return None
    return m.group(1).split()


def marker_chunks(text, lo, hi):
    """return the RHIZO_STAGE_CHUNK names in a span"""
    return [mo.group(1) for mo in MARKER_RE.finditer(text, lo, hi)]


_CLOSER = {"SINGLE": "'", "DSINGLE": "'", "DOUBLE": '"'}


def marker_violations(text):
    """return the misplaced RHIZO_STAGE_CHUNK markers"""
    out = []
    state, i, n, qstart = "NONE", 0, len(text), 0
    while i < n:
        c = text[i]
        if text.startswith("RHIZO_STAGE_CHUNK=", i):
            m = MARKER_RE.match(text, i)
            name = m.group(1) if m else "?"
            after = m.end() if m else i + len("RHIZO_STAGE_CHUNK=")
            line_start = text.rfind("\n", 0, i) + 1
            if state == "NONE":
                out.append((name, i, "sits outside every quote"))
            elif after < n and text[after] not in ("\n", _CLOSER[state]):
                out.append((name, i, "does not end its own line inside the quoted body"))
            elif not text[qstart:max(qstart, line_start)].strip():
                out.append((name, i, "is a statement of its own, not the last line of the "
                                     "body it vouches for"))
            i = after
            continue
        if state == "NONE":
            if c == "#" and _at_word_start(text, i):
                j = text.find("\n", i)
                i = n if j == -1 else j
                continue
            if c == "$" and i + 1 < n and text[i + 1] == "'":
                state, i, qstart = "DSINGLE", i + 2, i + 2
                continue
            if c == "'":
                state, i, qstart = "SINGLE", i + 1, i + 1
                continue
            if c == '"':
                state, i, qstart = "DOUBLE", i + 1, i + 1
                continue
            if c == "\\":
                i += 2
                continue
            i += 1
        elif state == "SINGLE":
            if c == "'":
                state = "NONE"
            i += 1
        else:
            if c == "\\":
                i += 2
                continue
            if c == _CLOSER[state]:
                state = "NONE"
            i += 1
    return out


def span_problems(text, lo, hi):
    """return the problems in the stage_cmd span"""
    starts = _line_starts(text)
    offset = text[:lo].count("\n") + 1
    probs = ["redeploy.sh:%d -- this stage_cmd+= statement splits into more than one "
             "shell word before its own terminating newline" % ln
             for ln in structural_violations(text, "stage_cmd", lo, hi, starts)]
    leaks, _ = leaked_words(text[lo:hi])
    probs += ["%r at redeploy.sh:%d runs locally instead of staying inside stage_cmd"
              % (w, offset + ln - 1) for w, ln in leaks]
    probs += ["chunk marker %s at redeploy.sh:%d %s" % (name, _line_of(starts, lo + pos), why)
              for name, pos, why in marker_violations(text[lo:hi])]
    return probs


def main_markers():
    """check the chunk markers of the redeploy script"""
    text = open(REDEPLOY).read()
    lo, hi = text.find(START_MARK), text.find(END_MARK)
    bad = [p for p in span_problems(text, lo, hi) if p.startswith("chunk marker")]
    for p in bad:
        print("check-stage-cmd-quoting: FAIL -- " + p, file=sys.stderr)
    if bad:
        return 1
    print("check-stage-cmd-quoting: ok -- every chunk marker closes its own quoted body")
    return 0


def main_chunks():
    """check the declared chunks of the redeploy script"""
    if not os.path.isfile(REDEPLOY):
        print("check-stage-cmd-quoting: FAIL -- no %s" % REDEPLOY, file=sys.stderr)
        return 1
    text = open(REDEPLOY).read()
    declared = declared_chunks(text)
    if declared is None:
        print("check-stage-cmd-quoting: FAIL -- redeploy.sh no longer declares "
              "EXPECTED_STAGE_CHUNKS=(...); update this check", file=sys.stderr)
        return 1
    start = text.find(START_MARK)
    end = text.find(END_MARK)
    if start == -1 or end == -1 or end < start:
        print("check-stage-cmd-quoting: FAIL -- redeploy.sh no longer has both "
              "%r and %r; update this check's markers" % (START_MARK, END_MARK),
              file=sys.stderr)
        return 1
    present = marker_chunks(text, start, end)
    declared_set, present_set = set(declared), set(present)
    problems = []
    dup = [n for n in declared if declared.count(n) > 1]
    if dup:
        problems.append("EXPECTED_STAGE_CHUNKS repeats: %s" % ", ".join(sorted(set(dup))))
    dup = [n for n in present if present.count(n) > 1]
    if dup:
        problems.append("stage_cmd's build-up echoes a chunk marker more than once: %s"
                         % ", ".join(sorted(set(dup))))
    missing = declared_set - present_set
    if missing:
        problems.append("EXPECTED_STAGE_CHUNKS names %s, which no `echo "
                         "RHIZO_STAGE_CHUNK=` in stage_cmd's own build-up ever "
                         "carries" % ", ".join(sorted(missing)))
    extra = present_set - declared_set
    if extra:
        problems.append("stage_cmd's build-up echoes %s, which "
                         "EXPECTED_STAGE_CHUNKS does not name"
                         % ", ".join(sorted(extra)))
    if problems:
        for p in problems:
            print("check-stage-cmd-quoting: FAIL -- %s" % p, file=sys.stderr)
        return 1
    print("check-stage-cmd-quoting: ok -- EXPECTED_STAGE_CHUNKS names exactly "
          "the %d chunk marker(s) stage_cmd's build-up carries" % len(declared))
    return 0


def main():
    """run the redeploy, tree, marker and chunk checks in turn"""
    return main_redeploy() or main_tree() or main_markers() or main_chunks()


def selftest():
    """run the quoting checks on fixture scripts"""
    bad = []

    broken = (
        "stage_cmd='set -e'\n"
        "stage_cmd+=$'\\n''install -d -m 0755 /usr/lib/rhizo\n"
        "# the composer's own uinput devices need a rule file\n"
        "install -m 0644 /root/share/x.rules /usr/lib/udev/rules.d/x.rules'\n"
        "ssh_vm -t 45 \"$stage_cmd\"\n"
    )
    leaks, _ = leaked_words(stage_cmd_span(broken))
    if not any(w == "install" for w, _ in leaks):
        bad.append("a comment apostrophe that breaks the string was not flagged")

    fixed = (
        "stage_cmd='set -e'\n"
        "stage_cmd+=$'\\n''install -d -m 0755 /usr/lib/rhizo\n"
        "# the composer own uinput devices need a rule file\n"
        "install -m 0644 /root/share/x.rules /usr/lib/udev/rules.d/x.rules'\n"
        "ssh_vm -t 45 \"$stage_cmd\"\n"
    )
    leaks, _ = leaked_words(stage_cmd_span(fixed))
    if leaks:
        bad.append("the apostrophe-free form was flagged anyway")

    starts_b = _line_starts(broken)
    bad_lines = structural_violations(broken, "stage_cmd", 0, len(broken), starts_b)
    if not bad_lines:
        bad.append("the structural check did not flag a possessive apostrophe splitting the word")

    starts_f = _line_starts(fixed)
    if structural_violations(fixed, "stage_cmd", 0, len(fixed), starts_f):
        bad.append("the structural check flagged the apostrophe-free form anyway")

    broken_printf = (
        "stage_cmd='set -e'\n"
        "stage_cmd+=$'\\n''mkdir -p /etc/systemd/system/x.d\n"
        "printf '%s\\n' 'ExecStart=/usr/bin/python3 /root/launcher3.py selinux_setup --policy-only'\n"
        "echo done'\n"
        'ssh_vm -t 45 "$stage_cmd"\n'
    )
    leaks, _ = leaked_words(stage_cmd_span(broken_printf))
    if leaks:
        bad.append("the printf-with-a-space fixture was flagged by the denylist")
    starts_p = _line_starts(broken_printf)
    bad_lines = structural_violations(broken_printf, "stage_cmd", 0, len(broken_printf), starts_p)
    if not bad_lines:
        bad.append("the structural check did not flag printf '%s\\n' '<value with "
                   "a space>' splitting the word")

    fixed_printf = (
        "stage_cmd='set -e'\n"
        "stage_cmd+=$'\\n''mkdir -p /etc/systemd/system/x.d\n"
        'echo "ExecStart=/usr/bin/python3 /root/launcher3.py selinux_setup --policy-only" >> x.conf\n'
        "echo done'\n"
        'ssh_vm -t 45 "$stage_cmd"\n'
    )
    starts_fp = _line_starts(fixed_printf)
    if structural_violations(fixed_printf, "stage_cmd", 0, len(fixed_printf), starts_fp):
        bad.append("the echo-based fixed printf form was flagged anyway")

    trailing_comment = (
        "stage_cmd='set -e'\n"
        "stage_cmd+=$'\\n'\"rm -f /root/x\"   # must not linger\n"
        'ssh_vm -t 45 "$stage_cmd"\n'
    )
    starts_tc = _line_starts(trailing_comment)
    if structural_violations(trailing_comment, "stage_cmd", 0, len(trailing_comment), starts_tc):
        bad.append("a clean single-line append with a trailing '   # comment' was flagged")

    commented = (
        "stage_cmd='set -e'\n"
        "# this repo's own convention still allows an apostrophe in a REAL\n"
        "# comment -- install, cp and chmod appear right here as plain words\n"
        "ssh_vm -t 45 \"$stage_cmd\"\n"
    )
    leaks, _ = leaked_words(stage_cmd_span(commented))
    if leaks:
        bad.append("a danger word inside a genuine unquoted comment was flagged")

    if stage_cmd_span("no markers here") is not None:
        bad.append("a span with no markers was not reported as absent")

    broken_tree = (
        'log "starting"\n'
        'start_cmd="mkdir -p /var/log/rhizo\n'
        'systemctl daemon-reload\n'
        '# the "primary unit restarts here\n'
        'systemctl restart $UNIT"\n'
        'out=$(ssh_vm -t 20 "$start_cmd" 2>&1)\n'
    )
    spans = discover_spans("fixture.sh", broken_tree)
    if len(spans) != 1 or spans[0][0] != "start_cmd":
        bad.append("discover_spans did not find the one $start_cmd build-up")
    else:
        leaks, _ = leaked_words(spans[0][3])
        if not any(w == "systemctl" for w, _ in leaks):
            bad.append("a double-quote inside a comment that breaks a "
                       "double-quoted build-up was not flagged")
        starts_dq = _line_starts(broken_tree)
        if not structural_violations(broken_tree, "start_cmd", spans[0][4], spans[0][5], starts_dq):
            bad.append("the structural check did not flag the double-quoted form either")

    fixed_tree = (
        'log "starting"\n'
        'start_cmd="mkdir -p /var/log/rhizo\n'
        'systemctl daemon-reload\n'
        "# the primary unit restarts here\n"
        'systemctl restart $UNIT"\n'
        'out=$(ssh_vm -t 20 "$start_cmd" 2>&1)\n'
    )
    spans = discover_spans("fixture.sh", fixed_tree)
    if spans:
        leaks, _ = leaked_words(spans[0][3])
        if leaks:
            bad.append("the quote-clean double-quoted form was flagged anyway")

    no_assign = 'out=$(ssh_vm -t 20 "$UNRELATED_VAR" 2>&1)\n'
    if discover_spans("fixture.sh", no_assign):
        bad.append("a $VAR with no reachable assignment produced a span anyway")

    two_blocks = (
        'cmd="echo one"\n'
        'out=$(ssh_vm -t 5 "$cmd" 2>&1)\n'
        'cmd="mkdir -p /tmp/x\n'
        '# a literal quote breaks this one: "\n'
        'chmod 0700 /tmp/x"\n'
        'out=$(ssh_vm -t 5 "$cmd" 2>&1)\n'
    )
    spans = discover_spans("fixture.sh", two_blocks)
    if len(spans) != 2:
        bad.append("two independent same-name build-ups did not produce two spans")
    elif spans[1][1] <= spans[0][2]:
        bad.append("the second build-up's span started before the first call ended")

    heredoc = (
        "PROBE_SCRIPT=$(cat <<'PROBE'\n"
        "modprobe uinput\n"
        "rm -f /tmp/x\n"
        "PROBE\n"
        ")\n"
        'out=$(ssh_vm -t 20 "$PROBE_SCRIPT" 2>&1)\n'
    )
    if discover_spans("fixture.sh", heredoc):
        bad.append("a heredoc assignment (VAR=$(cat <<'EOF' ...)) was treated as a quoted span")

    real_total = sum(
        len(discover_spans(p, open(p, errors="replace").read()))
        for p in tree_targets(REPO)
    )
    if real_total < 20:
        bad.append("the real tree sweep found only %d span(s)" % real_total)

    matched = (
        "EXPECTED_STAGE_CHUNKS=(\n  prep stage-dirs\n)\n"
        "stage_cmd='set -e'\n"
        "stage_cmd+=$'\\n''echo RHIZO_STAGE_CHUNK=prep'\n"
        "stage_cmd+=$'\\n''echo RHIZO_STAGE_CHUNK=stage-dirs'\n"
        'ssh_vm -t 45 "$stage_cmd"\n'
    )
    declared = declared_chunks(matched)
    if declared != ["prep", "stage-dirs"]:
        bad.append("declared_chunks did not parse EXPECTED_STAGE_CHUNKS=(...) correctly")
    start, end = matched.find(START_MARK), matched.find(END_MARK)
    present = marker_chunks(matched, start, end)
    if sorted(present) != ["prep", "stage-dirs"]:
        bad.append("marker_chunks did not find both echo RHIZO_STAGE_CHUNK= literals")

    missing_marker = (
        "EXPECTED_STAGE_CHUNKS=(\n  prep stage-dirs\n)\n"
        "stage_cmd='set -e'\n"
        "stage_cmd+=$'\\n''echo RHIZO_STAGE_CHUNK=prep'\n"
        'ssh_vm -t 45 "$stage_cmd"\n'
    )
    start, end = missing_marker.find(START_MARK), missing_marker.find(END_MARK)
    present = set(marker_chunks(missing_marker, start, end))
    if "stage-dirs" not in (set(declared_chunks(missing_marker)) - present):
        bad.append("a chunk EXPECTED_STAGE_CHUNKS names with no matching echo "
                   "was not caught as missing")

    orphan_marker = (
        "EXPECTED_STAGE_CHUNKS=(\n  prep\n)\n"
        "stage_cmd='set -e'\n"
        "stage_cmd+=$'\\n''echo RHIZO_STAGE_CHUNK=prep'\n"
        "stage_cmd+=$'\\n''echo RHIZO_STAGE_CHUNK=stage-dirs'\n"
        'ssh_vm -t 45 "$stage_cmd"\n'
    )
    start, end = orphan_marker.find(START_MARK), orphan_marker.find(END_MARK)
    present = set(marker_chunks(orphan_marker, start, end))
    if "stage-dirs" not in (present - set(declared_chunks(orphan_marker))):
        bad.append("a real echo RHIZO_STAGE_CHUNK= with no matching "
                   "EXPECTED_STAGE_CHUNKS entry was not caught as orphaned")

    real_text = open(REDEPLOY).read()
    real_declared = declared_chunks(real_text)
    if not real_declared:
        bad.append("redeploy.sh's own EXPECTED_STAGE_CHUNKS did not parse")
    else:
        rs, re_ = real_text.find(START_MARK), real_text.find(END_MARK)
        real_present = marker_chunks(real_text, rs, re_)
        if set(real_declared) != set(real_present):
            bad.append("redeploy.sh's EXPECTED_STAGE_CHUNKS and its own echo "
                       "RHIZO_STAGE_CHUNK= literals have drifted apart")

    folded = ("stage_cmd='set -e\nmkdir -p /x\necho RHIZO_STAGE_CHUNK=prep'\n"
              "stage_cmd+=$'\\n''modprobe uinput\necho RHIZO_STAGE_CHUNK=uinput'\n")
    if marker_violations(folded):
        bad.append("a marker closing its own body was flagged: %r" % marker_violations(folded))
    separate = ("stage_cmd='set -e\nmkdir -p /x'\n"
                "stage_cmd+=$'\\n''echo RHIZO_STAGE_CHUNK=prep'\n")
    if not marker_violations(separate[:separate.index("stage_cmd+=")] + "echo RHIZO_STAGE_CHUNK=prep\n"):
        bad.append("an unquoted marker line was not flagged")
    if not marker_violations(separate):
        bad.append("a marker appended as a statement of its own (vouching for no body) "
                   "was not flagged")
    multi = ("stage_cmd+=$'\\n''cp a b\necho RHIZO_STAGE_CHUNK=one\n# guest comment\n"
             "cp c d\necho RHIZO_STAGE_CHUNK=two'\n")
    if marker_violations(multi):
        bad.append("two chunks sharing one quoted body were flagged: %r" % marker_violations(multi))
    early = ("stage_cmd+=$'\\n''swapon /swapfile'\nnetworkctl reload\n"
             "echo RHIZO_STAGE_CHUNK=swap'\n")
    if not marker_violations(early):
        bad.append("a body closed early at a line end (next line runs on the host) "
                   "was not flagged by its marker")

    rs, re_ = real_text.find(START_MARK), real_text.find(END_MARK)
    if span_problems(real_text, rs, re_):
        bad.append("the real redeploy.sh span is not clean: %s" % span_problems(real_text, rs, re_)[:3])
    else:
        body_line_ends, state, i = [], "NONE", rs
        while i < re_:
            c = real_text[i]
            if state == "NONE":
                if c == "#" and _at_word_start(real_text, i):
                    j = real_text.find("\n", i)
                    i = re_ if j == -1 else j
                    continue
                if c == "$" and real_text[i + 1:i + 2] == "'":
                    state, i = "DSINGLE", i + 2
                    continue
                if c in "'\"":
                    state, i = ("SINGLE" if c == "'" else "DOUBLE"), i + 1
                    continue
                if c == "\\":
                    i += 2
                    continue
            elif state == "SINGLE":
                if c == "\n":
                    body_line_ends.append(i)
                if c == "'":
                    state = "NONE"
            else:
                if c == "\\":
                    i += 2
                    continue
                if c == _CLOSER[state]:
                    state = "NONE"
            i += 1
        sites = []
        for pos in body_line_ends:
            sites.append(pos)
            line_start = real_text.rfind("\n", 0, pos) + 1
            sp = real_text.find(" ", line_start, pos)
            if sp != -1:
                sites.append(sp)
        misses = []
        for pos in sites:
            mutant = real_text[:pos] + "'" + real_text[pos:]
            if not span_problems(mutant, rs, re_ + 1):
                misses.append(real_text[:pos].count("\n") + 1)
        if not body_line_ends:
            bad.append("the fuzz found no single-quoted body lines in redeploy.sh's span")
        elif misses:
            bad.append("%d of %d planted stray quotes went uncaught, first at redeploy.sh:%s"
                       % (len(misses), len(sites), misses[:5]))
        else:
            print("  fuzz: %d stray quotes planted (line ends and mid-line), all caught" % len(sites))

    if bad:
        for b in bad:
            print("check-stage-cmd-quoting selftest: FAILED -- %s" % b, file=sys.stderr)
        return 1
    print("check-stage-cmd-quoting selftest: ok")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else main())

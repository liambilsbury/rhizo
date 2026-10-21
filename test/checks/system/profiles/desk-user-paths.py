#!/usr/bin/env python3
import argparse
import glob
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

HARNESS = [
    "test/system/cycle/cycle.sh", "test/system/cycle/cycle-selftest.sh",
    "test/system/cycle/ubuntu-update-leg.sh", "test/system/lib/desktop-lib.sh",
    "test/system/lib/sway-lib.sh", "test/system/lib/gnome-lib.sh", "test/vm/start/start-sway.sh",
    "test/vm/start/start-gnome.sh", "test/vm/start/render-node-relabel.sh",
    "test/system/lib/desktop-assert-lib.sh", "test/system/lib/installer-lib.sh",
    "test/system/lib/install-lib.sh", "test/system/lib/server-assert-lib.sh",
    "test/system/lib/gsi-update-lib.sh", "test/system/lib/desk-user-lib.sh", "test/system/lib/lib.sh",
]
HARNESS_GLOB = "test/system/cycle/claims-*.sh"

RUNNERS = {"ssh_vm": "ssh_vm", "probe_ssh": 1, "gcmd_root": 0, "pull": 0, "ssh": "target"}
RUNNER_RE = re.compile(r"(?<![\w-])(ssh_vm|probe_ssh|gcmd_root|pull|ssh)(?![\w-])")
JOINS_ARGS = {"ssh_vm", "ssh"}
SSH_TARGET_WORDS = {"$SSH_TARGET", "${SSH_TARGET}"}
STDIN_SHELL = re.compile(r"^\s*(?:exec\s+)?(?:\S*/)?(?:(?:ba|da)?sh(?:\s+-[abd-zA-Z]+)*|python3?\s+-)\s*$")
VAR_REF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
ASSIGN_KEYWORDS = {"local", "readonly", "declare", "typeset"}
EXPAND_DEPTH = 3
FUNC_DEF = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
SCP_PUSH_RE = re.compile(r"\$\{?SSH_TARGET\}?:([^\s\"']+)")
SEED_VARS = {"DESK_HOME", "DOWNLOADS", "DESK_RUNTIME_DIR", "RUNTIME_DIR", "EXT_DST",
             "_rd", "_rhizo_rd", "_drd"}
ASSIGN_RE = re.compile(r"(?:^|[\s;(])(?:local\s+|export\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=")
ASSIGN_WORD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
OK_MARK = "desk-user-ok:"


def _skip_cmdsub(text, i):
    """return the index past the closing paren"""
    depth, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = text.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            i = _skip_dquote(text, i)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _skip_dquote(text, i):
    """return the index past the closing quote"""
    i, n = i + 1, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i + 1
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            i = _skip_cmdsub(text, i + 1)
            continue
        i += 1
    return n


def words(text, pos=0, host=True):
    """return the shell words of a command"""
    return words_at(text, pos, host)[0]


def words_at(text, pos=0, host=True):
    """return the shell words and the end index"""
    out, cur, have, i, n = [], [], False, pos, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n and text[i + 1] == "\n":
            i += 2
            continue
        if c in " \t":
            if have:
                out.append("".join(cur))
                cur, have = [], False
            i += 1
            continue
        if c in "\n;|&<>)":
            if have:
                out.append("".join(cur))
            return out, i
        have = True
        if c == "'":
            j = text.find("'", i + 1)
            j = n if j < 0 else j
            cur.append(text[i + 1:j])
            i = j + 1
        elif c == "$" and i + 1 < n and text[i + 1] == "'":
            j = text.find("'", i + 2)
            j = n if j < 0 else j
            cur.append(text[i + 2:j])
            i = j + 1
        elif c == '"':
            end = _skip_dquote(text, i)
            inner = text[i + 1:end - 1] if end - 1 > i else ""
            if host:
                inner = re.sub(r"\\\n", "", inner)
                inner = re.sub(r"\\([\"$`\\])", r"\1", inner)
            cur.append(inner)
            i = end
        elif c == "$" and i + 1 < n and text[i + 1] == "(":
            end = _skip_cmdsub(text, i + 1)
            cur.append(text[i:end])
            i = end
        elif c == "\\" and i + 1 < n:
            cur.append(text[i + 1])
            i += 2
        else:
            cur.append(c)
            i += 1
    if have:
        out.append("".join(cur))
    return out, n


def user_path_re(uservars):
    """return the regex matching a user home or run path or a user variable"""
    names = "|".join(sorted(re.escape(v) for v in uservars))
    return re.compile(r"^(?:/home/[^/\s]+|/run/user(?=/|$)|\$\{?(?:%s)\}?(?![A-Za-z0-9_]))" % names)


def names_user_path(word, rx):
    """return the user path a word names"""
    if rx.match(word):
        return word
    for m in re.finditer(r"[=:]", word):
        rest = word[m.end():]
        if rx.match(rest):
            return rest
    return None


def derived_vars(text):
    """return the seed variables and derived variables"""
    uservars = set(SEED_VARS)
    for _ in range(6):
        rx, grew = user_path_re(uservars), False
        for line in text.splitlines():
            if line.lstrip().startswith("#"):
                continue
            for m in ASSIGN_RE.finditer(line):
                name = m.group(1)
                if name in uservars:
                    continue
                value = words(line, m.end(), host=True)
                value = value[0] if value else ""
                looked_up = value.startswith("$(") and (
                    "XDG_RUNTIME_DIR=" in value or "cut -d: -f6" in value)
                if rx.match(value.lstrip("'\"")) or looked_up:
                    uservars.add(name)
                    grew = True
        if not grew:
            break
    return uservars


def cmdsubs(text):
    """return the text inside each $( )"""
    out, i = [], 0
    while True:
        i = text.find("$(", i)
        if i < 0:
            return out
        end = _skip_cmdsub(text, i + 1)
        inner = text[i + 2:end - 1]
        out.append(inner)
        out.extend(cmdsubs(inner))
        i = end


def _command_end(text, i):
    """return the index of the command end"""
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = text.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            i = _skip_dquote(text, i)
            continue
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            i = _skip_cmdsub(text, i + 1)
            continue
        if c in ";&|\n)":
            return i
        i += 1
    return n


def root_side(body):
    """return the guest body minus runuser commands"""
    body = body.replace("\\\n", "")
    out, i = [], 0
    for m in re.finditer(r"(?<![\w-])runuser(?![\w-])", body):
        if m.start() < i:
            continue
        out.append(body[i:m.start()])
        i = _command_end(body, m.end())
    out.append(body[i:])
    return "".join(out)


def assignment_only(ws):
    """return true for a variable assignment command"""
    rest = ws[1:] if ws and ws[0] in ASSIGN_KEYWORDS else ws
    return all(ASSIGN_WORD.match(w) or w.startswith("-") for w in rest)


def body_hits(body, rx):
    """return the body words naming user paths"""
    text = root_side(body)
    hits = []
    for part in [text] + cmdsubs(text):
        for line in re.split(r"[\n;|&]", part):
            ws = words(line, 0, host=False)
            plain_set = assignment_only(ws)
            for w in ws:
                if w.startswith("$("):
                    continue
                if ASSIGN_WORD.match(w):
                    value = w.split("=", 1)[1]
                    hit = None if plain_set or value.startswith("$(") else names_user_path(value, rx)
                else:
                    hit = names_user_path(w, rx)
                if hit and hit not in hits:
                    hits.append(hit)
            for m in re.finditer(r"[<>]+\s*", line):
                for w in words(line, m.end(), host=False)[:1]:
                    if rx.match(w) and w not in hits:
                        hits.append(w)
    return hits


def in_comment(pre):
    """check for an unquoted # comment"""
    q = None
    for i, c in enumerate(pre):
        if q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or pre[i - 1] in " \t"):
            return True
    return False


def annotated(lines, idx):
    """return whether a line carries the allow mark"""
    if OK_MARK in lines[idx]:
        return True
    j = idx - 1
    while j >= 0 and not lines[j].strip():
        j -= 1
    return j >= 0 and OK_MARK in lines[j]


def host_refs(text, start, end):
    """return the variable names the host expands"""
    refs, i, dq = [], start, False
    while i < end:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'" and not dq:
            j = text.find("'", i + 1)
            i = end if j < 0 else j + 1
            continue
        if c == '"':
            dq = not dq
            i += 1
            continue
        if c == "$" and i + 1 < end and text[i + 1] == "(":
            i = _skip_cmdsub(text, i + 1)
            continue
        m = VAR_REF.match(text, i) if c == "$" else None
        if m:
            refs.append(m.group(1))
            i = m.end()
            continue
        i += 1
    return refs


STATEMENT_START = re.compile(r"(?:^|;|&&|\|\||[{(]|\b(?:then|do|else|local|export|readonly|declare|"
                             r"typeset)|[A-Za-z_]\w*=\S*)\s*$")


def _unquoted(prefix):
    """return true for an unquoted prefix end"""
    q, i = None, 0
    while i < len(prefix):
        c = prefix[i]
        if c == "\\" and q != "'":
            i += 2
            continue
        if q:
            q = None if c == q else q
        elif c in "'\"":
            q = c
        i += 1
    return q is None


def assignments(text):
    """return each variable assignment in the file"""
    out, off = {}, 0
    for line in text.split("\n"):
        if not line.lstrip().startswith("#"):
            for m in ASSIGN_RE.finditer(line):
                prefix = line[:m.start(1)]
                if not (_unquoted(prefix) and STATEMENT_START.search(prefix)):
                    continue
                value, end = words_at(text, off + m.end(), host=True)
                if value:
                    out.setdefault(m.group(1), []).append((value[0], off + m.end(), end))
        off += len(line) + 1
    return out


def expanded_bodies(refs, text, assigned, uservars, depth=EXPAND_DEPTH, seen=None):
    """return the values assigned to named variables"""
    seen = set() if seen is None else seen
    out = []
    for name in refs:
        if name in seen or name in uservars or name not in assigned:
            continue
        seen.add(name)
        for value, vstart, vend in assigned[name]:
            out.append(value)
            if depth > 1:
                out.extend(expanded_bodies(host_refs(text, vstart, vend), text, assigned,
                                           uservars, depth - 1, seen))
    return out


def heredoc_body(text, end):
    """return the here-document a command reads"""
    eol = text.find("\n", end)
    eol = len(text) if eol < 0 else eol
    rest = text[end:eol]
    m = re.search(r"(?<!<)<<<\s*", rest)
    if m:
        w = words(text, end + m.end(), host=True)
        return w[0] if w else None
    m = re.search(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2", rest)
    if not m:
        return None
    body = []
    for line in text[eol + 1:].split("\n"):
        if (line.lstrip("\t") if m.group(1) else line) == m.group(3):
            break
        body.append(line)
    return "\n".join(body)


def scan_file(rel, text):
    """return the findings for a harness file"""
    uservars = derived_vars(text)
    rx = user_path_re(uservars)
    assigned = assignments(text)
    lines = text.split("\n")
    offsets, acc = [], 0
    for line in lines:
        offsets.append(acc)
        acc += len(line) + 1
    found = []
    for idx, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue
        fd = FUNC_DEF.match(line)
        for m in RUNNER_RE.finditer(line):
            if fd and fd.group(1) == m.group(1) and m.start() == line.index(fd.group(1)):
                continue
            if in_comment(line[:m.start()]):
                continue
            runner = m.group(1)
            start = offsets[idx] + m.end()
            args, end = words_at(text, start, host=True)
            skip = RUNNERS[runner]
            if skip == "ssh_vm":
                skip = 2 if args[:1] == ["-t"] else 0
            elif skip == "target":
                tgt = [k for k, a in enumerate(args) if a in SSH_TARGET_WORDS]
                if not tgt:
                    continue
                skip = tgt[0] + 1
            if len(args) <= skip:
                continue
            if runner == "pull":
                hit = names_user_path(args[skip], rx)
                hits = [hit] if hit else []
            else:
                body = " ".join(args[skip:]) if runner in JOINS_ARGS else args[skip]
                bodies = [body] + expanded_bodies(host_refs(text, start, end), text, assigned, uservars)
                if STDIN_SHELL.match(body):
                    fed = heredoc_body(text, end)
                    if fed is not None:
                        bodies.append(fed)
                        bodies.extend(expanded_bodies(host_refs(fed, 0, len(fed)), text, assigned,
                                                      uservars))
                hits = [h for b in bodies for h in body_hits(b, rx)]
            if hits and not annotated(lines, idx):
                found.extend((idx + 1, runner, h) for h in dict.fromkeys(hits))
        for m in SCP_PUSH_RE.finditer(line):
            if rx.match(m.group(1)) and not annotated(lines, idx):
                found.append((idx + 1, "scp", m.group(1)))
    return found


def harness_files(root):
    """return the harness files and missing entries"""
    globbed = sorted(os.path.relpath(p, root) for p in glob.glob(os.path.join(root, HARNESS_GLOB)))
    missing = [f"{r}: listed in HARNESS but missing; update HARNESS"
               for r in HARNESS if not os.path.isfile(os.path.join(root, r))]
    if not globbed:
        missing.append(f"{HARNESS_GLOB}: matched no file")
    return [r for r in HARNESS if os.path.isfile(os.path.join(root, r))] + globbed, missing


def run(root):
    """scan the harness files for user paths named as root"""
    files, bad = harness_files(root)
    for rel in files:
        with open(os.path.join(root, rel), encoding="utf-8") as fh:
            for line, runner, word in scan_file(rel, fh.read()):
                bad.append(f"{rel}:{line}: {runner} names {word} as root -- run it through desk_user_sh")
    return files, bad


FIXTURE = r'''#!/bin/bash
f_bad_rm() {
  ssh_vm -t 15 "rm -f $RUNTIME_DIR/wayland-* /tmp/x; true"
}
f_bad_ls() {
  out=$(ssh_vm -t 8 'ls /run/user/*/wayland-* 2>/dev/null')
}
f_bad_derived() {
  local host_path="$DOWNLOADS/f.txt" other=/tmp/y
  raw=$(probe_ssh 15 "test -e '$host_path' && echo P")
}
f_bad_redirect() {
  ssh_vm -t 20 "printf x > '$DOWNLOADS/n'"
}
f_bad_cmdsub() {
  ssh_vm -t 10 "XDG_RUNTIME_DIR=$RUNTIME_DIR SWAYSOCK=\$(ls $RUNTIME_DIR/sway-ipc.* | head -1) swaymsg -t get_version"
}
f_bad_scp() {
  timeout 30 scp -q a b "$SSH_TARGET:$EXT_DST/"
}
f_bad_gcmd() {
  gcmd_root "install -d -m 0755 /home/u/.local/share/x" 20
}
f_bad_before_runuser() {
  ssh_vm -t 5 "rm -f $DESK_HOME/old
runuser -u u -- true"
}
f_bad_fuser() {
  local rd sock
  rd=$(grep -o 'XDG_RUNTIME_DIR=[^ ]*' <<<"$env" | cut -d= -f2)
  sock="$rd/wayland-1"
  pid=$(ssh_vm -t 10 "fuser $sock 2>/dev/null")
}
f_bad_after_runuser() {
  ssh_vm -t 5 "runuser -u $DESK_USER -- true; rm -f $RUNTIME_DIR/after"
}
f_bad_after_quoted_runuser() {
  ssh_vm -t 5 "runuser -u $DESK_USER -- sh -c 'true; true' && ls $DESK_HOME/after"
}
f_bad_var_body() {
  local cmd="rm -f $DESK_HOME/from-var"
  ssh_vm -t 20 "$cmd"
}
f_bad_var_body_nested() {
  local inner="ls $RUNTIME_DIR/nested" outer
  outer="echo start; $inner"
  ssh_vm -t 20 "$outer; echo done"
}
f_bad_heredoc() {
  ssh_vm -t 10 bash -s <<EOF
rm -f $RUNTIME_DIR/from-heredoc
EOF
}
f_bad_herestring() {
  ssh_vm -t 10 "bash -s" <<<"rm -f $DOWNLOADS/from-herestring"
}
f_bad_raw_ssh() {
  timeout 20 ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_TARGET" "rm -f $DESK_HOME/raw-ssh"
}
f_bad_env_prefix() {
  ssh_vm -t 10 "XDG_RUNTIME_DIR=/run/user/1000 swaymsg -t get_version"
}
f_bad_env_word() {
  ssh_vm -t 10 "env WAYLAND_DISPLAY=x XDG_RUNTIME_DIR=/run/user/1001 wayland-info"
}
f_bad_export() {
  ssh_vm -t 10 "export XDG_RUNTIME_DIR=/run/user/1002; swaymsg -t get_tree"
}
f_bad_bus_address() {
  ssh_vm -t 10 "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1003/bus gdbus call --session"
}
f_bad_bare_run_user() {
  ssh_vm -t 10 "find /run/user -name 'wayland-*' -delete"
}
f_bad_unquoted_words() {
  ssh_vm -t 10 rm -f /run/user/1004/x
}
f_good_helper() {
  desk_user_sh 15 "rm -f '$DOWNLOADS/f'"
}
f_good_runuser() {
  ssh_vm -t 60 "runuser -u $DESK_USER -- sh -c 'base64 -d > $DOWNLOADS/x'" < f.b64
}
f_good_data() {
  ssh_vm -t 15 "printf '[Download]\ndir = /home/$u/Downloads\n' > /etc/rhizo/hostfs.conf"
}
f_good_annotated() {
  # desk-user-ok: rig mode only, no policy enforced
  ssh_vm -t 10 "test -d $RUNTIME_DIR || mkdir -p $RUNTIME_DIR"
}
f_good_comment() {
  # ssh_vm -t 5 "rm -f /run/user/1000/x"
  :
}
f_good_assign() {
  ssh_vm -t 5 "_rd=/run/user/\$uid; echo ok"
}
ssh_vm() { timeout 5 ssh -p 1 host "$@"; }
f_good_listeners() {
  ssh_vm -t 10 "$DESK_WAYLAND_LISTENERS; ls /run/rhizo-wayland/* 2>/dev/null"
}
f_good_quoted_runuser() {
  ssh_vm -t 5 "runuser -u $DESK_USER -- sh -c 'rm -f $RUNTIME_DIR/x; ls $DESK_HOME'; echo done"
}
f_good_var_body() {
  local gbody="systemctl restart rhizo-deskd"
  ssh_vm -t 20 "$gbody"
}
f_good_guest_side_ref() {
  local tmpl="rm -f $RUNTIME_DIR/x"
  ssh_vm -t 5 "echo \$tmpl"
  ssh_vm -t 5 'echo $tmpl'
}
f_good_heredoc_data() {
  ssh_vm -t 10 "cat > /tmp/rhizo-conf" <<EOF
socket /run/user/1000/wayland-0
EOF
}
f_good_raw_ssh_elsewhere() {
  timeout 20 ssh -p 22 otherhost "rm -f /run/user/1000/x"
}
f_good_run_user_prefix() {
  ssh_vm -t 10 "ls /run/users-db /run/userdb"
}
f_good_assign_in_string() {
  log "the old qcmd=$(ls $RUNTIME_DIR/x) is gone"
  local qcmd="systemctl status rhizo-deskd"
  ssh_vm -t 5 "$qcmd"
}
'''

WANT_BAD = {
    "f_bad_rm": "$RUNTIME_DIR/wayland-*",
    "f_bad_ls": "/run/user/*/wayland-*",
    "f_bad_derived": "$host_path",
    "f_bad_redirect": "$DOWNLOADS/n",
    "f_bad_cmdsub": "$RUNTIME_DIR/sway-ipc.*",
    "f_bad_scp": "$EXT_DST/",
    "f_bad_gcmd": "/home/u/.local/share/x",
    "f_bad_before_runuser": "$DESK_HOME/old",
    "f_bad_fuser": "$sock",
    "f_bad_after_runuser": "$RUNTIME_DIR/after",
    "f_bad_after_quoted_runuser": "$DESK_HOME/after",
    "f_bad_var_body": "$DESK_HOME/from-var",
    "f_bad_var_body_nested": "$RUNTIME_DIR/nested",
    "f_bad_heredoc": "$RUNTIME_DIR/from-heredoc",
    "f_bad_herestring": "$DOWNLOADS/from-herestring",
    "f_bad_raw_ssh": "$DESK_HOME/raw-ssh",
    "f_bad_env_prefix": "/run/user/1000",
    "f_bad_env_word": "/run/user/1001",
    "f_bad_export": "/run/user/1002",
    "f_bad_bus_address": "/run/user/1003/bus",
    "f_bad_bare_run_user": "/run/user",
    "f_bad_unquoted_words": "/run/user/1004/x",
}


def write_harness(root, fixture):
    """write the HARNESS files and a claims library"""
    for rel in HARNESS + [HARNESS_GLOB.replace("*", "fixture")]:
        os.makedirs(os.path.join(root, os.path.dirname(rel)), exist_ok=True)
        with open(os.path.join(root, rel), "w") as fh:
            fh.write(fixture if rel == HARNESS[0] else "#!/bin/bash\n")


def selftest_harness_list():
    """test the HARNESS list findings"""
    bad = 0
    with tempfile.TemporaryDirectory() as root:
        write_harness(root, "#!/bin/bash\n")
        files, found = run(root)
        if found or len(files) != len(HARNESS) + 1:
            print(f"SELFTEST FAIL: a complete harness reported {found} over {len(files)} files")
            bad += 1
        gone = HARNESS[3]
        os.unlink(os.path.join(root, gone))
        os.unlink(os.path.join(root, HARNESS_GLOB.replace("*", "fixture")))
        _, found = run(root)
        for want in (f"{gone}: listed in HARNESS but missing", f"{HARNESS_GLOB}: matched no file"):
            if any(f.startswith(want) for f in found):
                print(f"SELFTEST OK: {want.split(':')[0]} missing is a finding")
            else:
                print(f"SELFTEST FAIL: {want.split(':')[0]} missing was not reported: {found}")
                bad += 1
    return bad


def selftest():
    """check the harness list and each planted-defect fixture"""
    bad = selftest_harness_list()
    with tempfile.TemporaryDirectory() as root:
        write_harness(root, FIXTURE)
        _, found = run(root)
    lines = FIXTURE.split("\n")
    owner = {}
    fn = None
    for i, line in enumerate(lines, 1):
        m = FUNC_DEF.match(line)
        if m:
            fn = m.group(1)
        owner[i] = fn
    got = {}
    for f in found:
        ln = int(f.split(":")[1])
        got.setdefault(owner.get(ln), []).append(f)
    for fname, word in WANT_BAD.items():
        hit = [f for f in got.get(fname, []) if f" names {word} as root" in f]
        if hit:
            print(f"SELFTEST OK: {fname} is flagged naming {word}")
        else:
            print(f"SELFTEST FAIL: {fname} was not flagged naming {word}: {got.get(fname)}")
            bad += 1
    for fname in sorted({o for o in owner.values() if o and o.startswith("f_good")} | {"ssh_vm"}):
        if got.get(fname):
            print(f"SELFTEST FAIL: {fname} is flagged but runs nothing as root on a user path: {got[fname]}")
            bad += 1
        else:
            print(f"SELFTEST OK: {fname} is not flagged")
    print(f"check-desk-user-paths selftest: {'FAIL' if bad else 'OK'} ({bad} failed)")
    return 1 if bad else 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=REPO)
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    files, bad = run(a.root)
    for b in bad:
        print(f"FAIL: {b}")
    if bad:
        return 1
    print(f"desk-user paths: {len(files)} harness files, no root-side guest command names a path "
          f"in the desktop user's runtime dir or home outside desk_user_sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())

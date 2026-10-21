#!/bin/bash
# define host census diff functions

HOST_CENSUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST_CENSUS_PKGWIN_TAG="# rhizo-pkgwin"
# print the paths of the package logs
host_census_pkg_logs() {
  if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then echo "/var/log/pacman.log /var/log/pacman.log"
  else echo "/var/log/apt/history.log /var/log/dpkg.log"; fi
}
# run a command and record the package log lines it added, tagged with a sequence number
host_census_pkgwin() {
  local out="$1" kind="$2" label="$3"; shift 3
  local seq mark rc hi hs di ds cmd hlog dlog
  read -r hlog dlog <<<"$(host_census_pkg_logs)"
  seq=$(date +%s%N)
  mark=$(ssh_vm -t 20 "stat -c '%i %s' $hlog $dlog; echo DONE")
  "$@"; rc=$?
  read -r hi hs di ds <<<"$(head -2 <<<"$mark" | tr '\n' ' ')"
  if [[ "$mark" != *$'\n'DONE || ! "$hi $hs $di $ds" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    printf '%s %s %s %s incomplete no log position read before it ran: %s\n' \
      "$HOST_CENSUS_PKGWIN_TAG" "$seq" "$kind" "$label" "$(tr '\n' ' ' <<<"$mark")" >> "$out"
    fail "pkgwin: could not read the guest's package log positions before $label"
    return $rc
  fi
  printf -v cmd 'h=%s; d=%s; t="%s %s %s %s"; set -- $(stat -c "%%i %%s" $h $d); if [ "$1" != %s ] || [ "${2:-0}" -lt %s ] || [ "$3" != %s ] || [ "${4:-0}" -lt %s ]; then echo "$t incomplete a package log rotated or shrank under it: %s %s %s %s -> $*"; exit 0; fi; echo "$t history"; tail -c +%s $h; [ -z "$(tail -c 1 $h)" ] || echo; echo "$t dpkg"; tail -c +%s $d; [ -z "$(tail -c 1 $d)" ] || echo; echo "$t end"' \
    "$hlog" "$dlog" "$HOST_CENSUS_PKGWIN_TAG" "$seq" "$kind" "$label" "$hi" "$hs" "$di" "$ds" "$hi" "$hs" "$di" "$ds" $((hs + 1)) $((ds + 1))
  ssh_vm -t 60 "$cmd" >> "$out"
  [[ "$(tail -1 "$out")" == "$HOST_CENSUS_PKGWIN_TAG $seq $kind $label end" ]] \
    || fail "pkgwin: the guest's package logs around $label were not captured whole ($(tail -1 "$out"))"
  return $rc
}

# print the allowlist path for the guest OS
host_census_allowlist() {
  if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then echo "${HOST_CENSUS_ALLOW_DIR:-$HOST_CENSUS_DIR/../../checks/data}/host-snapshot-allow-cachyos.tsv"
  else echo "${HOST_CENSUS_ALLOW_DIR:-$HOST_CENSUS_DIR/../../checks/data}/host-snapshot-allow.tsv"; fi
}

# diff the census snapshots of a phase
host_census_snapshot_diff() {
  local prefix="$1" phase="$2" caller="$3" kind f names cmd owned="$EV/$1-owned-$2.tsv" out rc
  local -a expect=()
  for kind in rhizo-install ubuntu-update host-update test-staged; do
    f="$EV/$prefix-pkgwin-$kind.log"
    [[ -s "$f" ]] && expect+=(--expect "$kind=$f")
  done
  if (( ${#expect[@]} )); then
    [[ "$phase" == purge && -s "$EV/$prefix-apt-kept-purge.log" ]] && expect+=(--apt-kept "$EV/$prefix-apt-kept-purge.log")
    names=$(python3 "${HOST_CENSUS_DIFF:-$HOST_CENSUS_DIR/host-snapshot-diff.py}" --list-expected --phase "$phase" "${expect[@]}" 2>&1) \
      || { echo "host-snapshot-diff.py --list-expected: $names" > "$EV/$prefix-snapshot-diff-$phase.txt"; return 1; }
    if [[ -n "$names" ]] && grep -qvE '^[a-z0-9][a-z0-9.+-]*$' <<<"$names"; then
      echo "not a package name list: $names" > "$EV/$prefix-snapshot-diff-$phase.txt"
      return 1
    fi
    if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then
      cmd='for p in '"$(tr '\n' ' ' <<<"$names")"'; do pacman -Qlq "$p" | awk -v p="$p" '\''/^\//{ sub(/\/$/, ""); if ($0 != "") print p "\t" $0 }'\''; done; echo DONE'
    else
      cmd='for p in '"$(tr '\n' ' ' <<<"$names")"'; do dpkg-query -L "$p" | awk -v p="$p" '\''/^\//{print p "\t" $0}'\''; done; echo DONE'
    fi
    ssh_vm -t 120 "$cmd" > "$owned"
    if [[ "$(tail -1 "$owned")" != DONE ]]; then
      echo "the dpkg -L read of the expected packages was cut short (last line: $(tail -1 "$owned"))" > "$EV/$prefix-snapshot-diff-$phase.txt"
      return 1
    fi
    sed -i '$d' "$owned"
    expect+=(--owned "$owned")
  fi
  out=$(python3 "${HOST_CENSUS_DIFF:-$HOST_CENSUS_DIR/host-snapshot-diff.py}" "$EV/$prefix-snapshot-before.tsv" "$EV/$prefix-snapshot-after-$phase.tsv" \
    --phase "$phase" --allow "$(host_census_allowlist)" --caller "$caller" "${expect[@]}" 2>&1)
  rc=$?
  { echo "inputs: ${expect[*]:-none}"; echo "$out"; } > "$EV/$prefix-snapshot-diff-$phase.txt"
  if (( rc != 0 )); then
    host_census_provenance "$prefix" "$phase" "$out"
    echo "provenance of each unexplained path: $prefix-snapshot-provenance-$phase.txt" >> "$EV/$prefix-snapshot-diff-$phase.txt"
  fi
  return $rc
}

# record the birth and journal of each path
host_census_provenance() {
  local prefix="$1" phase="$2" diff="$3" out="$EV/$1-snapshot-provenance-$2.txt" line key b64s="" cmd res
  while IFS= read -r line; do
    [[ "$line" == *"unallowlisted difference ($phase): "[+~]" "* ]] || continue
    key=$(cut -f2 <<<"${line#*): }")
    [[ "$key" == /* ]] && b64s+=" $(printf '%s' "$key" | base64 -w0)"
  done <<<"$diff"
  if [[ -z "$b64s" ]]; then
    echo "PROVENANCE_NONE no unexplained path in the $phase diff" > "$out"
    return 0
  fi
  cmd='for b in'"$b64s"'; do
  p=$(printf %s "$b" | base64 -d)
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then echo "PROVENANCE $p gone"; continue; fi
  set -- $(stat -c "%W %Y %U:%G %a %s" -- "$p")
  t=$1; [ "$t" -gt 0 ] || t=$2
  echo "PROVENANCE $p birth=$1 mtime=$2 owner=$3 mode=$4 size=$5 at=$(date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ)"
  bb=$(journalctl --until "@$t" -n 1 -o export 2>/dev/null | sed -n "s/^_BOOT_ID=//p")
  ba=$(journalctl --since "@$t" -o export --output-fields=_BOOT_ID 2>/dev/null | sed -n "s/^_BOOT_ID=//p" | head -1)
  if [ -n "$bb" ] && [ -n "$ba" ] && [ "$bb" != "$ba" ]; then
    echo "VERDICT $p born after its boot'"'"'s journal ended (boot $bb): the shutdown'"'"'s kill phase, a process no unit owned"
  fi
  echo "journal before:"; journalctl --no-pager -q -o short-iso-precise --until "@$t" -n 25 2>&1 | sed "s/^/  /"
  echo "journal after:"; journalctl --no-pager -q -o short-iso-precise --since "@$t" 2>&1 | head -10 | sed "s/^/  /"
done; echo DONE'
  res=$(ssh_vm -t 60 "$cmd" 2>&1)
  if [[ "$res" != *$'\n'DONE && "$res" != DONE ]]; then
    { echo "PROVENANCE_INCOMPLETE the guest read did not complete"; printf '%s\n' "$res"; } > "$out"
  else
    printf '%s\n' "${res%DONE}" > "$out"
  fi
  local -a paths=()
  for key in $b64s; do paths+=("$(printf '%s' "$key" | base64 -d)"); done
  python3 -c "$HOST_CENSUS_AUDIT_PULL_PY" "$EV/$prefix-shutdown-audit-$phase.txt" "${paths[@]}" >> "$out" 2>&1 \
    || echo "AVC_UNREAD the console pull exited $?" >> "$out"
}

# arm the shutdown create audit on the guest
host_census_shutdown_audit_arm() {
  local prefix="$1" phase="$2" rec="$EV/$1-shutdown-audit-$2.txt" console nonce res
  console="${HOST_CENSUS_CONSOLE_LOG:-$VAR_DIR/vm-boot${SUFFIX:-}.log}"
  nonce="$(date +%s%N)-$RANDOM"
  {
    echo "ARM_AT $(date -u +%Y-%m-%dT%H:%M:%SZ) prefix=$prefix phase=$phase nonce=$nonce"
    if [[ -f "$console" ]]; then
      echo "CONSOLE $(stat -c '%i %s' -- "$console") $console"
    else
      echo "CONSOLE_ABSENT $console"
    fi
  } > "$rec"
  res=$(ssh_vm -t 120 "python3 -c \"\$(echo $(base64 -w0 <<<"$HOST_CENSUS_AUDIT_ARM_PY") | base64 -d)\" $nonce $phase" 2>&1)
  printf '%s\n' "$res" >> "$rec"
  [[ "$res" == *$'\n'DONE || "$res" == DONE ]] || echo "ARM_INCOMPLETE the guest arm did not complete" >> "$rec"
  return 0
}

# restore the directory labels from the arm record
host_census_shutdown_audit_disarm() {
  local rec="$EV/$1-shutdown-audit-$2.txt" rows res nonce
  [[ -s "$rec" ]] || return 0
  rows=$(awk '$1 == "DIR" { print $2 " " $3 }' "$rec")
  nonce=$(sed -n '1s/^ARM_AT .* nonce=\([0-9]*-[0-9]*\)$/\1/p' "$rec")
  if [[ -z "$rows" ]]; then
    echo "DISARM_NONE no directory was labeled" >> "$rec"
    [[ -n "$nonce" ]] || return 0
  fi
  res=$(ssh_vm -t 120 "python3 -c \"\$(echo $(base64 -w0 <<<"$HOST_CENSUS_AUDIT_DISARM_PY") | base64 -d)\" $(gzip -c <<<"$rows" | base64 -w0) $nonce" 2>&1)
  printf '%s\n' "$res" >> "$rec"
  [[ "$res" == *$'\n'DONE || "$res" == DONE ]] || echo "DISARM_INCOMPLETE the guest disarm did not complete" >> "$rec"
  return 0
}

HOST_CENSUS_AUDIT_ARM_PY='
import base64, os, stat, sys
LABEL = "u:object_r:rhizo_census_audit_dir:s0"
UNLABELED = "u:object_r:unlabeled:s0"
MAX_DIRS = 2000
CANARY = ".rhizo_census_canary_"
ROOT = os.environ.get("HC_ROOT", "/root")
XATTR = os.environ.get("HC_XATTR", "security.selinux")
PROC = os.environ.get("HC_PROC", "/proc/sys/kernel")
KMSG = os.environ.get("HC_KMSG", "/dev/kmsg")
ENFORCE = os.environ.get("HC_ENFORCE", "/sys/fs/selinux/enforce")
nonce, phase = sys.argv[1], sys.argv[2]
def say(*a):
    print(*a, flush=True)
def b64(s):
    return base64.b64encode(s.encode("utf-8", "surrogateescape")).decode()
def label(p):
    try:
        return os.getxattr(p, XATTR, follow_symlinks=False).decode("utf-8", "replace").rstrip("\0")
    except OSError:
        return "<none>"
def is_dir_here(p, dev):
    try:
        st = os.lstat(p)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and st.st_dev == dev
def raise_to(path, want):
    try:
        old = open(path).read().split()[0]
        if int(old) < want:
            with open(path, "w") as f:
                f.write(str(want))
        return old + "->" + open(path).read().split()[0]
    except (OSError, ValueError, IndexError) as e:
        return "unwritable:" + type(e).__name__
if not os.path.exists(ENFORCE):
    say("ARM_SKIP SELinux is not the active LSM")
    say("DONE")
    sys.exit(0)
dev = int(os.environ["HC_DEV"]) if os.environ.get("HC_DEV") else os.lstat(ROOT).st_dev
dirs = []
def unread(e):
    say("DIRUNREAD", b64(e.filename or "?"), type(e).__name__)
for top, subs, _ in os.walk(ROOT, onerror=unread):
    keep = []
    for d in sorted(subs):
        q = os.path.join(top, d)
        if is_dir_here(q, dev):
            keep.append(d)
        else:
            say("DIRFOREIGN", b64(q), "link" if os.path.islink(q) else "dev" if os.path.lexists(q) else "gone")
    subs[:] = keep
    dirs.append(top)
armed = 0
for p in dirs[:MAX_DIRS]:
    old = label(p)
    if old == LABEL:
        old = "<none>"
    elif old not in ("<none>", UNLABELED):
        say("DIRSKIP", b64(p), b64(old))
        continue
    try:
        os.setxattr(p, XATTR, LABEL.encode(), follow_symlinks=False)
    except OSError as e:
        if p == ROOT:
            say("ARM_SKIP the relabel of /root was refused (" + (e.strerror or str(e)) + "): the loaded policy may lack rhizo_census_audit_dir")
            say("DONE")
            sys.exit(0)
        say("DIRFAIL", b64(p), (e.strerror or str(e)).replace(" ", "_"))
        continue
    if label(p) != LABEL:
        say("DIRFAIL", b64(p), "label_did_not_take")
        continue
    say("DIR", b64(p), b64(old))
    armed += 1
if len(dirs) > MAX_DIRS:
    say("DIRCAP", len(dirs), MAX_DIRS)
say("PRINTK console_loglevel", raise_to(os.path.join(PROC, "printk"), 6))
say("BURST printk_ratelimit_burst", raise_to(os.path.join(PROC, "printk_ratelimit_burst"), 200))
try:
    with open(KMSG, "w") as f:
        f.write("<5>RHIZO_CENSUS_AUDIT armed nonce=%s phase=%s dirs=%d\n" % (nonce, phase, armed))
    say("MARKER written")
except OSError as e:
    say("MARKER_FAIL", (e.strerror or str(e)).replace(" ", "_"))
canary = os.path.join(ROOT, CANARY + nonce)
try:
    os.mkdir(canary)
except OSError as e:
    say("CANARY_FAIL mkdir", (e.strerror or str(e)).replace(" ", "_"))
else:
    try:
        os.rmdir(canary)
        say("CANARY", CANARY + nonce)
    except OSError as e:
        say("CANARY_FAIL rmdir", (e.strerror or str(e)).replace(" ", "_"))
say("ARMED", nonce, armed)
say("DONE")
'

HOST_CENSUS_AUDIT_DISARM_PY='
import base64, gzip, os, re, sys
LABEL = "u:object_r:rhizo_census_audit_dir:s0"
UNLABELED = "u:object_r:unlabeled:s0"
CANARY = ".rhizo_census_canary_"
ROOT = os.environ.get("HC_ROOT", "/root")
XATTR = os.environ.get("HC_XATTR", "security.selinux")
ENFORCE = os.environ.get("HC_ENFORCE", "/sys/fs/selinux/enforce")
def say(*a):
    print(*a, flush=True)
def label(p):
    try:
        return os.getxattr(p, XATTR, follow_symlinks=False).decode("utf-8", "replace").rstrip("\0")
    except OSError:
        return "<none>"
selinux_active = os.path.exists(ENFORCE)
done = failed = 0
for row in gzip.decompress(base64.b64decode(sys.argv[1])).decode().splitlines():
    if not row.strip():
        continue
    bp, bo = row.split()
    p = base64.b64decode(bp).decode("utf-8", "surrogateescape")
    old = base64.b64decode(bo).decode()
    if label(p) != LABEL:
        say("NOTARMED", bp)
        continue
    try:
        if old == "<none>" and not selinux_active:
            os.removexattr(p, XATTR, follow_symlinks=False)
        elif old == "<none>":
            os.setxattr(p, XATTR, UNLABELED.encode(), follow_symlinks=False)
        else:
            os.setxattr(p, XATTR, old.encode(), follow_symlinks=False)
        say("RESTORED", bp)
        done += 1
    except OSError as e:
        say("RESTOREFAIL", bp, (e.strerror or str(e)).replace(" ", "_"))
        failed += 1
nonce = sys.argv[2] if len(sys.argv) > 2 else ""
if re.fullmatch(r"[0-9]+-[0-9]+", nonce):
    canary = os.path.join(ROOT, CANARY + nonce)
    if os.path.lexists(canary):
        try:
            os.rmdir(canary)
            say("CANARY_REMOVED", CANARY + nonce)
        except OSError as e:
            say("CANARY_REMOVEFAIL", CANARY + nonce, (e.strerror or str(e)).replace(" ", "_"))
say("DISARMED", done, failed)
say("DONE")
'

HOST_CENSUS_AUDIT_PULL_PY='
import base64, os, re, sys
rec, paths = sys.argv[1], sys.argv[2:]
AUDIT_TYPE = "rhizo_census_audit_dir"
CANARY = ".rhizo_census_canary_"
LOST = re.compile(r"printk limit exceeded|audit_lost=|backlog limit exceeded|callbacks suppressed|kauditd hold queue overflow")
NAME = re.compile(r"\bname=(\"([^\"]*)\"|([0-9A-F]+))")
PIDCOMM = re.compile(r"\bpid=(\d+) comm=(\"[^\"]*\"|[0-9A-F]+)")
PERMS = re.compile(r"avc: +\w+ +\{ ([^}]*) \}")
BANNER = "Linux version "
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
def out(*a):
    print(*a)
if not os.path.isfile(rec):
    out("SHUTDOWN_AUDIT_UNARMED no arm record (%s): this phase ran with no create audit" % os.path.basename(rec))
    sys.exit(0)
fields = {}
armed = set()
unarmed = {}
for line in open(rec, errors="replace"):
    w = line.rstrip("\n").split(" ", 1)
    fields.setdefault(w[0], w[1] if len(w) > 1 else "")
    a = line.split()
    if len(a) >= 2 and a[0] in ("DIR", "DIRSKIP", "DIRFAIL", "DIRFOREIGN", "DIRUNREAD"):
        try:
            d = base64.b64decode(a[1], validate=True).decode("utf-8", "surrogateescape")
        except ValueError:
            continue
        if a[0] == "DIR":
            armed.add(d)
        else:
            unarmed[d] = a[0]
capped = "DIRCAP" in fields
arm_nonce = re.search(r"\bnonce=(\S+)", fields.get("ARM_AT", ""))
arm_nonce = arm_nonce.group(1) if arm_nonce else None
canaries = [p for p in paths if os.path.dirname(p) == "/root" and os.path.basename(p).startswith(CANARY)]
for p in canaries:
    if os.path.basename(p) != CANARY + str(arm_nonce):
        out("CANARY_LEFT %s a census canary from another arm (this one is nonce=%s), not Rhizo state" % (p, arm_nonce))
        continue
    how = ("CANARY_FAIL " + fields["CANARY_FAIL"]) if "CANARY_FAIL" in fields \
        else "the arm did not complete (ARM_INCOMPLETE)" if "ARM_INCOMPLETE" in fields \
        else "no CANARY_FAIL recorded"
    out("CANARY_LEFT %s the canary of this arm survived it: %s; residue of the census, not Rhizo state" % (p, how))
paths = [p for p in paths if p not in canaries]
if "ARMED" not in fields:
    why = fields.get("ARM_SKIP") or ("the arm did not complete" if "ARM_INCOMPLETE" in fields else "no ARMED line")
    out("SHUTDOWN_AUDIT_UNARMED " + why)
    sys.exit(0)
nonce = fields["ARMED"].split()[0]
out("SHUTDOWN_AUDIT armed nonce=%s dirs=%s %s" % (nonce, fields["ARMED"].split()[1], fields.get("PRINTK", "")))
if "CONSOLE" not in fields:
    out("AVC_UNREAD the arm found no console log (%s)" % fields.get("CONSOLE_ABSENT", "?"))
    sys.exit(0)
ino, size, console = fields["CONSOLE"].split(" ", 2)
text = None
for cand in (console, console[:-4] + ".prev.log" if console.endswith(".log") else None):
    if cand and os.path.isfile(cand) and str(os.stat(cand).st_ino) == ino:
        text = open(cand, "rb").read().decode("utf-8", "replace")
        break
if text is None:
    out("AVC_UNREAD the console the arm recorded (inode %s, %s) is gone: a later boot rotated it twice" % (ino, console))
    sys.exit(0)
lines = [ANSI.sub("", l).replace("\r", "") for l in text.split("\n")]
start = next((i for i, l in enumerate(lines) if "RHIZO_CENSUS_AUDIT armed nonce=" + nonce + " " in l), None)
if start is None:
    out("AVC_UNREAD the arm marker nonce=%s never reached the console" % nonce)
    sys.exit(0)
end = next((i for i in range(start + 1, len(lines)) if BANNER in lines[i]), None)
window = lines[start:end]
out("AVC_WINDOW %d console lines from the marker to %s" % (len(window), "the next kernel banner" if end is not None else "the end of the console (no later boot)"))
lost = [l.strip() for l in window if LOST.search(l)]
for l in lost:
    out("AVC_LOST " + l)
avcs = [l.strip() for l in window if "avc:" in l and AUDIT_TYPE in l]
def named(l):
    m = NAME.search(l)
    if m is None:
        return None
    return m.group(2) if m.group(2) is not None else bytes.fromhex(m.group(3)).decode("utf-8", "replace")
def perms(l):
    m = PERMS.search(l)
    return set(m.group(1).split()) if m else set()
canary = any(named(l) == CANARY + nonce and "add_name" in perms(l) for l in avcs)
closed = end is not None or any(re.search(r"reboot: (Power down|Restarting system|System halted)", l) for l in window)
blind = []
if not closed:
    blind.append("window_unclosed")
if not avcs:
    blind.append("no_census_avc")
if lost:
    blind.append("lost_lines")
if not canary:
    blind.append("canary_absent")
out("AVC_CONTROL canary=%s census_avcs=%d lost=%d" % ("seen" if canary else "absent", len(avcs), len(lost)))
def who(l):
    pc = PIDCOMM.search(l)
    return "pid=%s comm=%s" % pc.groups() if pc else "pid=?"
for p in paths:
    if p != "/root" and not p.startswith("/root/"):
        out("AVC_OUTSIDE %s is not under /root" % p)
        continue
    if p in armed:
        out("AVC_PREDATES %s was a directory the arm labeled" % p)
        continue
    anc, q = None, p
    while q not in ("/root", "/"):
        q = os.path.dirname(q)
        if q in armed:
            anc = q
            break
    if anc is None:
        out("AVC_UNARMED %s no ancestor of it was labeled at the arm" % p)
        continue
    comp = p[len(anc) + 1:].split("/")[0]
    child = anc + "/" + comp
    chain = anc[len("/root") + 1:].split("/") if anc != "/root" else []
    swapped = [l for l in avcs if named(l) in chain and perms(l) & {"add_name", "remove_name"}]
    for l in swapped:
        out("ANCESTOR_REPLACED %s %s name=%s" % (p, who(l), named(l)))
    steps, q = [], anc
    while q not in ("/root", "/"):
        steps.append(q)
        q = os.path.dirname(q)
    unwatched = [s for s in steps if os.path.dirname(s) not in armed]
    if child in unarmed:
        out("AVC_UNARMED %s %s existed at the arm unlabeled (%s)" % (p, child, unarmed[child]))
        continue
    mine = [l for l in avcs if named(l) == comp]
    adds = [l for l in mine if "add_name" in perms(l)]
    for l in adds:
        out("WRITER %s %s name=%s" % (p, who(l), comp))
        out("AVC %s %s" % (p, l))
    for l in mine:
        if "remove_name" in perms(l):
            out("UNLINK %s %s name=%s" % (p, who(l), comp))
            out("AVC %s %s" % (p, l))
    if adds:
        continue
    if capped:
        out("AVC_UNARMED %s the arm stopped at its directory cap (%s), so %s may have existed unlabeled" % (p, fields["DIRCAP"], child))
    elif blind or swapped or unwatched:
        out("AVC_NONE_UNPROVEN %s census_avcs=%d lost=%d canary=%s why=%s" % (p, len(avcs), len(lost), "seen" if canary else "absent", ",".join(blind + (["ancestor_replaced"] if swapped else []) + (["ancestor_parent_unarmed"] if unwatched else []))))
    else:
        out("AVC_NONE %s no add_name of %s in %s between the marker and the next kernel banner" % (p, comp, anc))
'

# record why apt kept each package
host_census_apt_kept_record() {
  local prefix="$1" label="$2" win="$EV/$1-pkgwin-rhizo-install.log" out="$EV/$1-apt-kept-purge.log" names cmd
  rm -f "$out"
  [[ -s "$win" ]] || return 0
  names=$(python3 "${HOST_CENSUS_DIFF:-$HOST_CENSUS_DIR/host-snapshot-diff.py}" --list-expected --phase remove --expect "rhizo-install=$win" 2>&1) \
    || { fail "$label: host-snapshot-diff.py --list-expected: $names"; return 1; }
  if [[ -n "$names" ]] && grep -qvE '^[a-z0-9][a-z0-9.+-]*$' <<<"$names"; then
    fail "$label: not a package name list: $names"
    return 1
  fi
  cmd='for p in '"$(tr '\n' ' ' <<<"$names")"'; do
  dpkg -s "$p" 2>/dev/null | grep -qx "Status: install ok installed" || continue
  echo "'"$HOST_CENSUS_APTKEPT_TAG"' kept $p"
  echo "AUTO $(apt-mark showauto "$p")"
  provs=$(dpkg -s "$p" | sed -n "s/^Provides: //p" | tr "," "\n" | sed "s/^ *//; s/[ (].*//" | tr "\n" " ")
  echo "PROVIDES $provs"
  rd=$(for n in "$p" $provs; do
    apt-cache rdepends --installed --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances "$n"
  done
  for n in $provs; do
    dpkg-query -W -f="\${db:Status-Abbrev}\t\${binary:Package}\t\${Depends}, \${Pre-Depends}, \${Recommends}\n" 2>/dev/null \
      | awk -F "\t" -v n="$n" "\$1 == \"ii \" { m = split(\$3, a, /[ ,|]+/); for (i = 1; i <= m; i++) { sub(/:.*/, \"\", a[i]); if (a[i] == n) { print \"  \" \$2; break } } }"
  done)
  printf "%s\n" "$rd"
  for k in $(printf "%s\n" "$rd" | sed -n "/^ /{s/^ *//; s/^|//; s/:.*//; p}" | sort -u); do
    d=$(dpkg-query -W -f='\''DEPS ${binary:Package}\t${Status}\t${Depends}, ${Pre-Depends}, ${Recommends}\n'\'' "$k" 2>/dev/null)
    if [ -n "$d" ]; then printf "%s\n" "$d"; else printf "DEPS %s\t<none>\t\n" "$k"; fi
  done
done
echo "'"$HOST_CENSUS_APTKEPT_TAG"' autoremove-sim"
apt-get -s autoremove 2>&1
echo "SIM_RC=$?"
echo "'"$HOST_CENSUS_APTKEPT_TAG"' end"'
  ssh_vm -t 300 "$cmd" > "$out" 2>&1
  [[ "$(tail -1 "$out")" == "$HOST_CENSUS_APTKEPT_TAG end" ]] \
    || { fail "$label: apt's record of what the autoremove kept was cut short ($(tail -1 "$out"))"; return 1; }
}
HOST_CENSUS_APTKEPT_TAG="# rhizo-aptkept"

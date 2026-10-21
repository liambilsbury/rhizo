#!/bin/bash
# check the launcher directory binds into /dev/socket
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")/../.." || exit
REPO_ROOT="$(cd ../.. && pwd)"
MOUNTS="$REPO_ROOT/src/androidd/sandbox/rootfs.py"
PUBLISHER_ROOTS=("$REPO_ROOT/tools" "$REPO_ROOT/test" "$REPO_ROOT/src")

# print a check message
say()  { printf 'check-socket-bridge-carry: %s\n' "$1"; }
# print a failure message to stderr
fail() { printf 'check-socket-bridge-carry: FAIL: %s\n' "$1" >&2; }


# print the directory binds into /dev/socket
dir_binds() {
  local f="${1:-$MOUNTS}"
  grep -oE 'mount\([a-z_]+, f"\{NEWROOT\}/dev/socket/[a-z_]+", None, MS_BIND( \| MS_REC)?\)' "$f" \
    | sed -E 's/^mount\(([a-z_]+), f"\{NEWROOT\}\/dev\/socket\/([a-z_]+)".*MS_BIND \| MS_REC\)$/\1 \2 recursive/; s/^mount\(([a-z_]+), f"\{NEWROOT\}\/dev\/socket\/([a-z_]+)".*MS_BIND\)$/\1 \2 plain/'
}

# print the default host path of a variable
source_path_of() {
  local var="$1" f="${2:-$MOUNTS}" line inner
  line=$(grep -E "^[[:space:]]*${var} = " "$f" | head -1) || return 1
  [[ -n "$line" ]] || return 1
  inner=$(sed -nE 's/.*os\.path\.dirname\(([a-z_]+)\).*/\1/p' <<<"$line")
  if [[ -n "$inner" ]]; then
    local p; p=$(source_path_of "$inner" "$f") || return 1
    dirname "$p"
    return 0
  fi
  local got; got=$(grep -oE '"/[^"]+"' <<<"$line" | tail -1 | tr -d '"')
  [[ -n "$got" ]] || return 1
  printf '%s\n' "$got"
}

# print the mount --bind destination directories
publish_dest_dirs() {
  local f="$1" dest var val
  while read -r dest; do
    [[ -n "$dest" ]] || continue
    dest="${dest%/*}"
    if [[ "$dest" == \$* ]]; then
      var="${dest#\$}"; var="${var#\{}"; var="${var%\}}"
      val=$(sed -nE "s/^[[:space:]]*${var}=.*:-([^\"}]+)\}.*/\1/p;s/^[[:space:]]*${var}=\"?(\/[^\"]+)\"?$/\1/p" "$f" | head -1)
      [[ -n "$val" ]] && printf '%s\n' "$val"
    else
      printf '%s\n' "$dest"
    fi
  done < <(grep -oE 'mount --bind [^ ]+ [^ ]+' "$f" 2>/dev/null | awk '{print $4}')
}

# print the publisher files for a directory
mount_publisher_of() {
  local dir="$1"; shift
  local roots=("$@"); [[ ${#roots[@]} -eq 0 ]] && roots=("${PUBLISHER_ROOTS[@]}")
  local d f
  for d in "${roots[@]}"; do
    [[ -d "$d" ]] || continue
    while read -r f; do
      [[ "$f" == "$SELF" ]] && continue
      if publish_dest_dirs "$f" | grep -qxF "$dir"; then printf '%s\n' "$f"; fi
    done < <(grep -rlE 'mount --bind ' "$d" 2>/dev/null)
  done | sort -u
  return 0
}

# check each socket directory bind against its publisher
check_tree() {
  local rc=0 subjects=0 var name kind dir pubs
  while read -r var name kind; do
    [[ -n "${var:-}" ]] || continue
    dir=$(source_path_of "$var") || dir=""
    [[ -n "$dir" ]] || { fail "cannot read the host path behind $var"; rc=1; continue; }
    subjects=$((subjects + 1))
    pubs=$(mount_publisher_of "$dir")
    if [[ -n "$pubs" && "$kind" == plain ]]; then
      fail "/dev/socket/$name is a PLAIN directory bind of $dir, and that directory is published into by MOUNT:"
      printf '  %s\n' $pubs >&2
      say "  a plain bind carries none of the mounts under it: bind the socket FILE, or make" >&2
      say "  this bind MS_BIND|MS_REC, or have the publisher CREATE rather than mount." >&2
      rc=1
    elif [[ -n "$pubs" ]]; then
      say "/dev/socket/$name: recursive bind of $dir, published into by mount -- carries"
    else
      say "/dev/socket/$name: $kind bind of $dir, no mount-publisher -- carries"
    fi
  done < <(dir_binds)
  if (( subjects == 0 )); then
    fail "no directory socket bind found in sandbox/rootfs.py at all"
    return 1
  fi
  (( rc == 0 )) && say "every socket bridge can carry what its publisher provides ($subjects checked)"
  return $rc
}

NS_BODY='
set -u
R=$(mktemp -d); mkdir -p "$R/hostdir" "$R/payload" "$R/dst"
echo LIVE-SOCKET > "$R/payload/wayland-0"
mount --bind "$R/hostdir" "$R/hostdir" 2>/dev/null || { echo NOPRIV; exit 0; }
mount --make-shared "$R/hostdir"
if [ "$PUB" = mount ]; then
  : > "$R/hostdir/wayland-0"
  mount --bind "$R/payload/wayland-0" "$R/hostdir/wayland-0"
else
  cp "$R/payload/wayland-0" "$R/hostdir/wayland-0"
fi
unshare -m --propagation unchanged sh -c "
  mount --make-rprivate /
  if [ \"$KIND\" = recursive ]; then mount --rbind \"$R/hostdir\" \"$R/dst\"
  else mount --bind \"$R/hostdir\" \"$R/dst\"; fi
  if [ \"\$(cat \"$R/dst/wayland-0\" 2>/dev/null)\" = LIVE-SOCKET ]; then echo ARRIVED
  elif [ -e \"$R/dst/wayland-0\" ]; then echo PLACEHOLDER-ONLY
  else echo NOTHING; fi
"
rm -rf "$R"
'
# print the result of a bind measurement
measure() {
  KIND="$1" PUB="$2" unshare --user --map-root-user --mount --propagation unchanged \
    bash -c "$NS_BODY" 2>/dev/null | tail -1
}

# run the bind measurements and parsing checks
selftest() {
  local bad=0 got tmp
  got=$(measure plain mount)
  if [[ "$got" == NOPRIV ]]; then
    echo "check-socket-bridge-carry selftest: SKIPPED (this host grants no mount namespace)"
  else
    [[ "$got" == PLACEHOLDER-ONLY ]] || { echo "SELFTEST FAILED: the rule says a plain bind cannot carry a mount-published socket, and the kernel delivered: $got"; bad=1; }
    got=$(measure recursive mount)
    [[ "$got" == ARRIVED ]] || { echo "SELFTEST FAILED: a recursive bind must carry a mount-published socket, got: $got"; bad=1; }
    got=$(measure plain create)
    [[ "$got" == ARRIVED ]] || { echo "SELFTEST FAILED: a plain bind must carry a CREATED socket, got: $got"; bad=1; }
  fi

  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  cat > "$tmp/m.py" <<'PY'
    host_audio_dir = os.path.dirname(os.environ.get("RHIZO_AUDIO_HOST_SOCKET", "/run/rhizo-audio/audiod"))
    host_wl_dir = os.environ.get("RHIZO_WAYLAND_HOST_DIR", "/run/rhizo-wayland")
    elif mount(host_audio_dir, f"{NEWROOT}/dev/socket/rhizo_audio", None, MS_BIND):
    elif mount(host_wl_dir, f"{NEWROOT}/dev/socket/rhizo_wayland", None, MS_BIND | MS_REC):
PY
  got=$(dir_binds "$tmp/m.py" | tr '\n' ';')
  [[ "$got" == *"host_audio_dir rhizo_audio plain;"* ]] \
    || { echo "SELFTEST FAILED: a plain directory bind was not read as plain -- got: $got"; bad=1; }
  [[ "$got" == *"host_wl_dir rhizo_wayland recursive;"* ]] \
    || { echo "SELFTEST FAILED: a recursive directory bind was not read as recursive -- got: $got"; bad=1; }
  [[ "$(source_path_of host_audio_dir "$tmp/m.py")" == "/run/rhizo-audio/audiod" ]] \
    || { echo "SELFTEST FAILED: the audio source default was misread as '$(source_path_of host_audio_dir "$tmp/m.py")'"; bad=1; }
  printf '        if mount(host_wayland_socket, dst, None, MS_BIND):\n' > "$tmp/f.py"
  [[ -z "$(dir_binds "$tmp/f.py")" ]] \
    || { echo "SELFTEST FAILED: a socket-file bind was read as a directory bind"; bad=1; }

  mkdir -p "$tmp/pub"
  cat > "$tmp/pub/start-x.sh" <<'SH'
WAYLAND_SHARE_DIR="${RHIZO_WAYLAND_HOST_DIR:-/run/rhizo-wayland}"
mount --bind /run/user/0/$real_sock $WAYLAND_SHARE_DIR/wayland-0
SH
  [[ -n "$(mount_publisher_of /run/rhizo-wayland "$tmp/pub")" ]] \
    || { echo "SELFTEST FAILED: a mount publish through a variable was not detected"; bad=1; }
  [[ -z "$(mount_publisher_of /run/rhizo-audio "$tmp/pub")" ]] \
    || { echo "SELFTEST FAILED: the wayland publisher was attributed to the audio directory"; bad=1; }
  cat > "$tmp/pub/start-x.sh" <<'SH'
WAYLAND_SHARE_DIR="${RHIZO_WAYLAND_HOST_DIR:-/run/rhizo-wayland}"
ln -sf /run/user/0/$real_sock $WAYLAND_SHARE_DIR/wayland-0
SH
  [[ -z "$(mount_publisher_of /run/rhizo-wayland "$tmp/pub")" ]] \
    || { echo "SELFTEST FAILED: a non-mount publish was read as a mount publish"; bad=1; }
  printf 'mount --bind /tmp/s /run/rhizo-audio/audiod\n' > "$tmp/pub/start-x.sh"
  [[ -n "$(mount_publisher_of /run/rhizo-audio "$tmp/pub")" ]] \
    || { echo "SELFTEST FAILED: a literal-path mount publish was not detected"; bad=1; }

  (( bad )) && { echo "check-socket-bridge-carry selftest: FAILED"; return 1; }
  echo "check-socket-bridge-carry selftest: ok"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") check_tree; exit $? ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac

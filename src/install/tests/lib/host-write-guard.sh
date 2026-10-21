#!/bin/sh
# refuse host-changing tool calls from the install test suites
GUARD_TOOLS="btrfs chattr mv mkdir rm sed useradd usermod adduser udevadm systemd-tmpfiles runuser chown chmod ln
             touch cp tee install"
GUARD_POLICY_TOOLS="setenforce load_policy semodule restorecon fixfiles setfiles chcon semanage setsebool"

# write the refusing stub all of the guarded tool names link to
write_guard_stub() {
  mkdir -p "$TMP/guard"
  { printf "#!/bin/bash\ntmp='%s'\n" "$TMP"; cat <<'EOF'
# log and refuse a call that would change the host, else run the next tool of this name on PATH
tool=${0##*/} here=${0%/*} bad=
case $tool in
  useradd|usermod|adduser|udevadm|systemd-tmpfiles|runuser) bad="every real $tool call changes the host" ;;
  setenforce|load_policy|semodule|restorecon|fixfiles|setfiles|chcon|semanage|setsebool)
    bad="every real $tool call changes the host's SELinux state" ;;
  sed) for a in "$@"; do case $a in -i*|--in-place*|-[a-zA-Z]*i*) bad=check ;; esac; done ;;
  *) bad=check ;;
esac
checked=("$@")
case $tool in
  ln) checked=("${@: -1}") ;;
  cp|install)
    checked=("${@: -1}")
    for ((i = 1; i < $#; i++)); do
      case ${!i} in -t) j=$((i + 1)); checked+=("${!j}") ;; --target-directory=*) checked+=("${!i}") ;; esac
    done ;;
esac
if [ "$bad" = check ]; then
  bad=
  for a in "${checked[@]}"; do
    p=$a
    case $p in -*=*) p=${p#*=} ;; esac
    case $p in "$tmp"|"$tmp"/*) continue ;; esac
    case $p in /etc|/etc/*|/var|/var/*|/usr|/usr/*|/run|/run/*|/boot|/boot/*|/srv|/srv/*|/.autorelabel)
      bad="$p is a host path outside $tmp"; break ;;
    esac
  done
fi
if [ -n "$bad" ]; then
  echo "ESCAPE $tool $*" >> "$tmp/escapes"
  echo "$tool: refused by the test guard: $bad" >&2
  exit 99
fi
seen=
case ":$PATH:" in *":$here:"*) ;; *) seen=1 ;; esac
IFS=:; set -f
for d in $PATH; do
  if [ "$d" = "$here" ]; then seen=1; continue; fi
  if [ -n "$seen" ] && [ -n "$d" ] && [ -f "$d/$tool" ] && [ -x "$d/$tool" ]; then exec -a "$tool" "$d/$tool" "$@"; fi
done
echo "$tool: no $tool on PATH after the test guard's $here" >&2
exit 127
EOF
  } > "$TMP/guard/stub"
  chmod +x "$TMP/guard/stub"
}

# put the guard stubs first on a PATH
guard_path() {
  [ -x "$TMP/guard/stub" ] || write_guard_stub
  dir="$TMP/guard/$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  if [ ! -d "$dir" ]; then
    mkdir "$dir"
    for t in $GUARD_TOOLS; do
      if PATH="$1" command -v "$t" >/dev/null 2>&1; then ln -s ../stub "$dir/$t"; fi
    done
    for t in $GUARD_POLICY_TOOLS; do ln -s ../stub "$dir/$t"; done
  fi
  printf '%s:%s' "$dir" "$1"
}

# print each logged escape
report_escapes() {
  [ -s "$TMP/escapes" ] || return 0
  echo "FAIL a tool call named a host path outside $TMP, or ran a tool that changes the host:"
  sed 's/^/       /' "$TMP/escapes"
  return 1
}

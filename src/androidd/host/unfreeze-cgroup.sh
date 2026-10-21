# shellcheck shell=sh
# unfreeze the Android stack cgroup

# print the cgroup path of the stack
rhizo_stack_cgroup() {
  _ipath=$(sed -n 's|^0::||p' "/proc/$1/cgroup" 2>/dev/null)
  [ -n "$_ipath" ] || return 1
  _level="$_ipath"
  while :; do
    [ -d "/sys/fs/cgroup${_level}/system" ] && { printf '%s' "/sys/fs/cgroup${_level%/}"; return 0; }
    [ "$_level" = / ] && break
    _level=${_level%/*}
    [ -z "$_level" ] && _level=/
  done
  return 1
}

# return success for a frozen cgroup
rhizo_stack_frozen() {
  [ "$(cat "$1/cgroup.freeze" 2>/dev/null)" = "1" ]
}

# match a pid_* path under uid_*
rhizo_is_stock_freeze_leaf() {
  _leaf="${1##*/}"
  _parent="${1%/*}"
  _parent_leaf="${_parent##*/}"
  case "$_leaf" in
    pid_*) case "$_parent_leaf" in uid_*) return 0 ;; esac ;;
  esac
  return 1
}

# print the frozen non-stock cgroups under the root
rhizo_foreign_frozen() {
  _root="$1"
  for _p1 in "$_root"/*/ "$_root"/*/*/ "$_root"/*/*/*/ "$_root"/*/*/*/*/ "$_root"/*/*/*/*/*/ "$_root"/*/*/*/*/*/*/; do
    [ -d "$_p1" ] || continue
    _cgp="${_p1%/}"
    [ -f "$_cgp/cgroup.freeze" ] || continue
    rhizo_is_stock_freeze_leaf "$_cgp" && continue
    [ "$(cat "$_cgp/cgroup.freeze" 2>/dev/null)" = "1" ] && printf '%s\n' "$_cgp"
  done
}

_RHIZO_POLL_FAST_S=0.01
_RHIZO_POLL_SLOW_S=0.05
_RHIZO_POLL_FAST_ITERS=100

# wait a poll interval
rhizo_poll_tick() {
  if [ "$1" -lt "$_RHIZO_POLL_FAST_ITERS" ]; then
    sleep "$_RHIZO_POLL_FAST_S"
  else
    sleep "$_RHIZO_POLL_SLOW_S"
  fi
}

# check cgroup.events for frozen 0
_rhizo_frozen_clear() {
  [ -r "$1/cgroup.events" ] || return 1
  while read -r _fk _fv; do
    [ "$_fk" = frozen ] && [ "$_fv" = 0 ] && return 0
  done < "$1/cgroup.events"
  return 1
}

# unfreeze the cgroup
rhizo_unfreeze() {
  _cg="$1"; _deadline="${2:-30}"
  _unit=""
  case "$_cg" in
    */system.slice/*.service) _unit="${_cg##*/}" ;;
    */system.slice/*.service/*) _unit="${_cg%/*}"; _unit="${_unit##*/}" ;;
  esac
  if [ -n "$_unit" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl thaw "$_unit" >/dev/null 2>&1 || echo 0 > "$_cg/cgroup.freeze" 2>/dev/null
  else
    echo 0 > "$_cg/cgroup.freeze" 2>/dev/null
  fi
  _total=$((_RHIZO_POLL_FAST_ITERS + (_deadline - 1) * 20))
  _i=0
  while [ "$_i" -lt "$_total" ]; do
    if _rhizo_frozen_clear "$_cg"; then
      return 0
    fi
    rhizo_poll_tick "$_i"
    _i=$((_i + 1))
  done
  return 1
}

# poll the servicemanager process state
rhizo_wait_servicemanager() {
  _deadline="${1:-20}"
  _total=$((_RHIZO_POLL_FAST_ITERS + (_deadline - 1) * 20))
  _pid=""
  for _d in /proc/[0-9]*; do
    [ -r "$_d/cmdline" ] || continue
    _cl=""
    read -r _cl < "$_d/cmdline" 2>/dev/null
    case "$_cl" in
      /system/bin/servicemanager) _pid="${_d#/proc/}"; break ;;
    esac
  done
  [ -n "$_pid" ] || return 0
  _i=0
  while [ "$_i" -lt "$_total" ]; do
    _st=""
    [ -r "/proc/$_pid/stat" ] && read -r _sp _sc _st _srest < "/proc/$_pid/stat" 2>/dev/null
    [ -n "$_st" ] || return 0
    case "$_st" in
      R|S) return 0 ;;
    esac
    rhizo_poll_tick "$_i"
    _i=$((_i + 1))
  done
  return 1
}

# unfreeze the stack cgroup
rhizo_unfreeze_gate() {
  _cg=$(rhizo_stack_cgroup "$1") || return 0
  rhizo_stack_frozen "$_cg" || return 0
  rhizo_unfreeze "$_cg" 30 || return 1
  rhizo_wait_servicemanager 20 || return 1
  for _fcg in $(rhizo_foreign_frozen "$_cg"); do
    rhizo_unfreeze "$_fcg" 10 || { echo "rhizo_unfreeze_gate: $_fcg would not unfreeze" >&2; return 1; }
  done
  return 0
}

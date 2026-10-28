#!/bin/sh
# point an instance's NAT chains at netbridged's default-route uplinks
set -u
export LC_ALL=C

TAG=rhizo-nat-uplinks
ID="${1:?usage: rhizo-nat-uplinks SANDBOX_ID UPLINKS_FILE}"
FILE="${2:?usage: rhizo-nat-uplinks SANDBOX_ID UPLINKS_FILE}"
MAX_IFS=8
case "$ID" in ''|*[!0-9]*) echo "$TAG: sandbox id '$ID' is not a number" >&2; exit 2 ;; esac
FWD="RHIZO-FWD-$ID"
NAT="RHIZO-NAT-$ID"

# write a line to the log
log() {
  echo "$TAG: $*" >&2
}

# return whether the argument names an allowed uplink
valid_if() {
  case "$1" in
    ''|-*|.|..|lo|vethrhz*) return 1 ;;
    *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  [ "${#1}" -le 15 ]
}

# replace a family's chain contents with the named uplinks
apply() {
  _bin=$1
  shift
  "$_bin" -w -S "$FWD" >/dev/null 2>&1 || { log "$_bin has no $FWD -- the launcher did not set instance $ID up"; return 1; }
  "$_bin" -w -F "$FWD" || return 1
  "$_bin" -w -A "$FWD" -j DROP || return 1
  "$_bin" -w -t nat -F "$NAT" || return 1
  _pos=1
  for _if in "$@"; do
    "$_bin" -w -I "$FWD" "$_pos" -o "$_if" -j ACCEPT && "$_bin" -w -t nat -A "$NAT" -o "$_if" -j MASQUERADE || return 1
    _pos=$((_pos + 1))
  done
}

[ -e "$FILE" ] || { log "no $FILE yet -- the chains keep the launcher's uplinks"; exit 0; }
{ [ -f "$FILE" ] && [ ! -L "$FILE" ]; } || { log "$FILE is not a regular file -- refused"; exit 1; }

have4=0 have6=0 v4="" v6=""
lines=$(head -c 512 "$FILE" | head -n 4)
while IFS=' ' read -r fam rest; do
  case "$fam" in
    v4|v6) ;;
    '') continue ;;
    *) log "unknown line in $FILE -- refused"; exit 1 ;;
  esac
  n=0
  for name in $rest; do
    valid_if "$name" || { log "$fam names an interface outside [A-Za-z0-9_.-]{1,15}, lo or vethrhz* -- refused"; exit 1; }
    n=$((n + 1))
  done
  [ "$n" -le "$MAX_IFS" ] || { log "$fam names more than $MAX_IFS interfaces -- refused"; exit 1; }
  if [ "$fam" = v4 ]; then have4=1 v4=$rest; else have6=1 v6=$rest; fi
done <<EOF
$lines
EOF

rc=0
# shellcheck disable=SC2086
if [ "$have4" = 1 ]; then apply iptables $v4 || { log "iptables rewrite FAILED"; rc=1; }; fi
# shellcheck disable=SC2086
if [ "$have6" = 1 ]; then apply ip6tables $v6 || { log "ip6tables rewrite FAILED"; rc=1; }; fi
# print a family's uplinks
shown() {
  if [ "$1" = 1 ]; then echo "${2:-none}"; else echo unchanged; fi
}
log "instance $ID uplinks: v4=$(shown "$have4" "$v4") v6=$(shown "$have6" "$v6")"
exit "$rc"

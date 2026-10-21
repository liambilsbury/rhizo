#!/bin/sh
# fill this account's empty home from /etc/skel
set -u
PROG=rhizo-skel-fill
SKEL=/etc/skel
LOGIN_DEFS=/etc/login.defs

# print a login.defs value
login_def() {
  v=$(awk -v k="$1" '$1 == k { v = $2 } END { print v }' "$LOGIN_DEFS")
  case $v in
    ''|*[!0-9]*) echo "$2" ;;
    *) echo "$v" ;;
  esac
}

uid=$(id -u)
[ "$uid" -ge "$(login_def UID_MIN 1000)" ] && [ "$uid" -le "$(login_def UID_MAX 60000)" ] || exit 0

home=$(getent passwd "$uid" | cut -d: -f6)
# shellcheck disable=SC3067
[ -n "$home" ] && [ -d "$home" ] && [ -O "$home" ] && [ -d "$SKEL" ] || exit 0
entries=$(ls -A -- "$home") || exit 1
[ -z "$entries" ] || exit 0

if ! find "$SKEL" -mindepth 1 -maxdepth 1 \
     -exec cp -RP --preserve=mode,timestamps --update=none -t "$home" -- {} +; then
  echo "$PROG: copying $SKEL into $home failed" >&2
  exit 1
fi
echo "$PROG: filled $home from $SKEL"

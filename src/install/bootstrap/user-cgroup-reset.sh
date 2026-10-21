#!/bin/sh
# remove the empty user@UID.service cgroup
set -u
PROG=rhizo-user-cgroup-reset

uid=${1:-}
case $uid in
  ''|*[!0-9]*) echo "$PROG: want a numeric uid, got '$uid'" >&2; exit 2 ;;
esac
cg=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service
[ -d "$cg" ] || exit 0
events=$(cat "$cg/cgroup.events") || exit 1
case $events in
  *"populated 0"*) ;;
  *) exit 0 ;;
esac

if ! chown -R 0:0 "$cg" || ! find "$cg" -depth -type d -exec rmdir {} +; then
  echo "$PROG: could not remove $cg" >&2
  exit 1
fi
echo "$PROG: removed the cgroup user@$uid.service left behind"

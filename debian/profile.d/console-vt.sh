# shellcheck shell=sh
if [ -n "${XDG_VTNR:-}" ] && [ -x /usr/lib/rhizo/install/bootstrap/console-vt.py ]; then
  case $XDG_VTNR in
    *[!0-9]*) ;;
    *) /usr/lib/rhizo/install/bootstrap/console-vt.py "/dev/tty$XDG_VTNR" ;;
  esac
fi

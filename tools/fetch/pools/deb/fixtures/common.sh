# shellcheck shell=bash disable=SC2034  # the stub settings are read by the deb pool library under test
SUFFIX="-deb-pool-selftest-$$"
SSH_OPTS=(); SSH_PORT=22; SSH_TARGET=stub
log() { echo "$*" >&2; }
wait_for_ssh() { return 0; }
guest_refuse_install_if_enforcing() { return 0; }
guest_mount_share() { return 0; }
ssh_vm() {
  local body="${*: -1}"
  printf '%s\n---\n' "$body" >> "$STUB_SSH_LOG"
  case "$body" in
    *"id -u "*) echo 1000 ;;
    *"pacman -Qq"*) if [ -n "${STUB_SSH_FAIL:-}" ]; then return 255; fi; echo sway ;;
    *"for p in sway swaybg"*)
      if [ -e "$STUB_SSH_LOG.installed" ]; then :; else echo sway; fi ;;
    *"for p in pipewire "*)
      if [ -n "${STUB_SSH_FAIL:-}" ]; then return 255; fi
      if [ -e "$STUB_SSH_LOG.installed" ]; then :; else echo pipewire; fi ;;
    *"deb-pool-plan.py --pool"*)
      printf 'INSTALL\t/pool/sway_1.9_amd64.deb\tsway\t1.9\nKEEP\tsystemd\t255.4-1ubuntu8.16\t255.4-1ubuntu8.17\nDEB_POOL_PLAN_RC=0\n' ;;
    *"deb-pool-plan.py --verify"*)
      : > "$STUB_SSH_LOG.installed"
      printf -- '--- dpkg --configure -a ---\nDEB_POOL_VERIFIED\nDEB_POOL_APT_CHECK_RC=0\n' ;;
  esac
  return 0
}

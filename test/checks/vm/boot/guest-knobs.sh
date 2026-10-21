#!/bin/bash
# check redeploy.sh forwards all of the guest RHIZO_* knobs
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "${RHIZO_CHECK_ROOT:-$(dirname "$SELF")/../../../..}" || exit

LAUNCHER_FILES=(src/androidd/boot.py src/androidd/sandbox/core.py src/androidd/sandbox/hals.py src/androidd/sandbox/rootfs.py
                src/androidd/sandbox/selinux_policy.py src/androidd/sandbox/selinux_labels.py src/androidd/sandbox/guest_files.py)
DEPLOY=test/vm/redeploy.sh

# print RHIZO_* names from environ.get and getenv calls
guest_knobs() {
  grep -hoE 'environ\.get\("RHIZO_[A-Z_]+"|getenv\("RHIZO_[A-Z_]+"' "${LAUNCHER_FILES[@]}" 2>/dev/null \
    | grep -oE 'RHIZO_[A-Z_]+' | sort -u
}

# print the RHIZO_* names on the deny list
deny_knobs() {
  sed -n '/^LAUNCH_ENV_DENY=/,/"$/p' "$DEPLOY" 2>/dev/null \
    | grep -oE 'RHIZO_[A-Z_]+' | sort -u
}

EXPLICIT=" RHIZO_GSI RHIZO_RELEASE RHIZO_VM "

TEMPLATE_GUEST=src/install/prepare/data-template.sh
TEMPLATE_CALLER=tools/build/image/data-template.sh

# print RHIZO_* names from template parameter expansions
template_guest_knobs() {
  grep -hoE '\$\{RHIZO_[A-Z_]+(:-[^}]*)?\}' "$TEMPLATE_GUEST" 2>/dev/null \
    | grep -oE 'RHIZO_[A-Z_]+' | sort -u
}

FOREIGN_OK=" ACCEPT DROP FORWARD INPUT MASQUERADE POSTROUTING DNAT PREROUTING
  ACTION DEVPATH SUBSYSTEM MAJOR MINOR DEVNAME PHYS
  ANDROID_ART_ROOT ANDROID_DATA ANDROID_I18N_ROOT ANDROID_ROOT
  ANDROID_RUNTIME_ROOT ANDROID_STORAGE ANDROID_TZDATA_ROOT EXTERNAL_STORAGE
  ASEC_MOUNTPOINT PATH NOTIFY_SOCKET LOWER UPPER NETBPFLOAD_PRELOAD_PATH
  XDG_RUNTIME_DIR WAYLAND_DISPLAY
  SC_PAGE_SIZE INVOCATION_ID "
PRINTED_OK=" STAGE_GSI_LABELED_OK "
# print the non-RHIZO_ upper case names in the launcher files
foreign_names() {
  grep -hoE '"[A-Z][A-Z0-9_]{3,}"' "${LAUNCHER_FILES[@]}" 2>/dev/null \
    | tr -d '"' | grep -v '^RHIZO_' | sort -u
}

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/src/androidd/sandbox" "$t/src/install/prepare" "$t/test/vm" "$t/tools/build/image"
  printf 'x = os.environ.get("RHIZO_MADE_UP_KNOB")\n' > "$t/src/androidd/boot.py"
  printf 'y = os.environ.get("RHIZO_HALS_ONLY_KNOB")\n' > "$t/src/androidd/sandbox/hals.py"
  printf 'for _e, _p in (("MADE_UP_FOREIGN_KNOB", "some.prop"),):\n    v = os.environ.get(_e)\n' >> "$t/src/androidd/sandbox/hals.py"
  printf 'LAUNCH_ENV_DENY=" RHIZO_MADE_UP_KNOB RHIZO_HALS_ONLY_KNOB "\n' > "$t/test/vm/redeploy.sh"
  printf '[[ "${RHIZO_TEMPLATE_MADE_UP_KNOB:-0}" == 1 ]] && force=1\n' > "$t/src/install/prepare/data-template.sh"
  printf 'ssh_vm -t 240 "bash /root/share/data-template.sh $remote_flags"\n' > "$t/tools/build/image/data-template.sh"
  out=$(RHIZO_CHECK_ROOT="$t" "$SELF" 2>&1)
  if ! grep -q 'RHIZO_MADE_UP_KNOB' <<<"$out" || ! grep -q 'RHIZO_HALS_ONLY_KNOB' <<<"$out"; then
    echo "SELFTEST FAILED: a guest-read knob on the deny list was not reported (boot.py or sandbox/hals.py)" >&2
    echo "  the check produced:" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  if ! grep -q 'RHIZO_TEMPLATE_MADE_UP_KNOB' <<<"$out"; then
    echo "SELFTEST FAILED: a knob data-template.sh reads but data-template.sh never forwards was not reported" >&2
    echo "  the check produced:" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  if ! grep -q 'MADE_UP_FOREIGN_KNOB' <<<"$out"; then
    echo "SELFTEST FAILED: a guest-read knob outside the RHIZO_* namespace was not reported" >&2
    echo "  the check produced:" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  echo "selftest ok: detects a guest-read knob the deploy path denies, a knob outside the forwarded namespace, and a template knob its ssh caller never forwards"
  exit 0
fi

read_knobs=$(guest_knobs)
if [[ -z "$read_knobs" ]]; then
  echo "could not read any RHIZO_* knob out of ${LAUNCHER_FILES[*]}" >&2
  exit 1
fi

rc=0
while read -r k; do
  [[ -n "$k" ]] || continue
  [[ " $EXPLICIT " == *" $k "* ]] && continue
  if grep -qx "$k" <<<"$(deny_knobs)"; then
    echo "FAIL: ${LAUNCHER_FILES[*]} reads $k but $DEPLOY's deny list stops it being forwarded" >&2
    echo "      setting $k would do nothing, silently" >&2
    rc=1
  fi
done <<<"$read_knobs"

template_read_knobs=$(template_guest_knobs)
while read -r k; do
  [[ -n "$k" ]] || continue
  if ! grep -qE "${k}=\\\$\\{?${k}" "$TEMPLATE_CALLER" 2>/dev/null; then
    echo "FAIL: $TEMPLATE_GUEST reads $k but $TEMPLATE_CALLER never forwards it to the guest" >&2
    echo "      setting $k would do nothing, silently, on a build routed through $TEMPLATE_CALLER" >&2
    rc=1
  fi
done <<<"$template_read_knobs"

while read -r k; do
  [[ -n "$k" ]] || continue
  [[ " ${FOREIGN_OK//[$'\n\t']/ } " == *" $k "* || "$PRINTED_OK" == *" $k "* ]] && continue
  echo "FAIL: ${LAUNCHER_FILES[*]} names $k, which is outside the RHIZO_* namespace $DEPLOY forwards" >&2
  echo "      if the guest reads it as an environment knob it never arrives, silently; rename it RHIZO_$k or add it to FOREIGN_OK with a reason" >&2
  rc=1
done <<<"$(foreign_names)"

(( rc == 0 )) && echo "every RHIZO_* knob the guest reads reaches it, and it names no knob outside that namespace"
exit $rc

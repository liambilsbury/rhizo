#!/bin/bash
# test _desk_gnome_launch_entry against a lingering launcher
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FX=$(mktemp -d) || exit 1
# kill the fixture launcher and remove the fixture directory
cleanup() { pkill -KILL -f "$FX/gnome-launcher[.]py" 2>/dev/null; rm -rf "$FX"; }
trap cleanup EXIT

cat > "$FX/gnome-launcher.py" <<'EOF'
import os, signal, sys, time
args = sys.argv[1:]
nonce = None
if args[:1] == ["--nonce"]:
    nonce, args = args[1], args[2:]
if args[:1] == ["--no-token"]:
    args = args[1:]
fx = os.path.dirname(os.path.abspath(__file__))
tag = "nonce=%s " % nonce if nonce else ""
if os.environ.get("FAKE_LINGERING"):
    def late(_s, _f):
        time.sleep(1.5)
        print("ready %s" % tag.strip() if tag else "ready", flush=True)
        print("launched %stoken=lingering pid=1" % tag, flush=True)
        sys.exit(0)
    signal.signal(signal.SIGTERM, late)
    open(os.path.join(fx, "lingering.up"), "w").close()
    while True:
        time.sleep(0.1)
title = "rhizo-harness-launcher" + ("-" + nonce if nonce else "")
with open(os.path.join(fx, "window"), "w") as f:
    f.write('{"id": 42, "title": "%s", "x": 10, "y": 20, "w": 100, "h": 50}\n' % title)
print("ready %s" % tag.strip() if tag else "ready", flush=True)
while not os.path.exists(os.path.join(fx, "clicked")):
    time.sleep(0.05)
print("launched %stoken=new pid=2" % tag, flush=True)
while True:
    time.sleep(0.1)
EOF

mkdir -p "$FX/bin"
cat > "$FX/bin/gsettings" <<EOF
#!/bin/sh
case "\$1" in get) echo "'smart'"; exit 0 ;; esac
echo "gsettings \$*" >> "$FX/ops"
EOF
chmod +x "$FX/bin/gsettings"

out=$(
  cd "$HERE/../system/lib" || exit 1
  PATH="$FX/bin:$PATH"
  # shellcheck disable=SC2034
  RHIZO_DESKTOP_PROFILE=gnome
  source ./desktop-lib.sh >/dev/null 2>&1
  # shellcheck disable=SC2034
  GNOME_HARNESS_DIR="$FX"
  gcmd_user() { bash -c "$1"; }
  desk_windows() {
    echo '{"id": 7, "title": "rhizo-harness-launcher", "x": 500, "y": 500, "w": 10, "h": 10}'
    cat "$FX/window" 2>/dev/null
  }
  desk_window_op() { echo "$*" >> "$FX/ops"; }
  _gnome_harness() { echo "$*" >> "$FX/ops"; }
  _gnome_pointer_up() { return 0; }
  _gnome_pointer() {
    echo "$1" >> "$FX/ops"
    [[ "$1" == release ]] && touch "$FX/clicked"
    return 0
  }
  FAKE_LINGERING=1 setsid python3 "$FX/gnome-launcher.py" /x/rhizo-com.x.desktop >> "$FX/launcher.out" 2>&1 < /dev/null &
  for _ in $(seq 1 100); do [[ -e "$FX/lingering.up" ]] && break; sleep 0.05; done
  _desk_gnome_launch_entry /x/rhizo-com.x.desktop
  echo "RC=$?"
  _desk_gnome_launch_entry "done" >/dev/null
  echo "DONE_RC=$?"
)
bad=""
[[ "$out" == *"RC=0"* ]] || bad+=" the wrapper failed: $out;"
[[ "$out" == *"token=new"* && "$out" != *"token=lingering"* ]] || bad+=" the wrapper answered '$(head -1 <<<"$out")', want the new launcher's token=new;"
grep -q "^42 activate" "$FX/ops" 2>/dev/null || bad+=" the wrapper raised window '$(head -1 "$FX/ops" 2>/dev/null)', want the new launcher's own window 42;"
grep -q "^press 60 45" "$FX/ops" 2>/dev/null || bad+=" the wrapper pressed '$(grep press "$FX/ops" 2>/dev/null)', want the center of window 42;"
strict=$(grep -n -m1 '^gsettings set org.gnome.desktop.wm.preferences focus-new-windows strict$' "$FX/ops" 2>/dev/null | cut -d: -f1)
press=$(grep -n -m1 '^press ' "$FX/ops" 2>/dev/null | cut -d: -f1)
above=$(grep -n -m1 '^window-op 42 above$' "$FX/ops" 2>/dev/null | cut -d: -f1)
[[ -n "$above" && -n "$press" ]] && (( above < press )) \
  || bad+=" the wrapper did not keep the launcher's window 42 above before its click (ops: $(tr '\n' '|' < "$FX/ops" 2>/dev/null));"
[[ -n "$strict" && -n "$press" ]] && (( strict < press )) \
  || bad+=" the wrapper did not set mutter's focus-new-windows to strict before its click (ops: $(tr '\n' '|' < "$FX/ops" 2>/dev/null));"
[[ "$out" == *"DONE_RC=0"* ]] && [[ "$(grep '^gsettings ' "$FX/ops" 2>/dev/null | tail -1)" == "gsettings set org.gnome.desktop.wm.preferences focus-new-windows smart" ]] \
  || bad+=" done left focus-new-windows as the launch set it (last: '$(grep '^gsettings ' "$FX/ops" 2>/dev/null | tail -1)'), want the user's 'smart' back;"
if [[ -n "$bad" ]]; then
  echo "check-gnome-launch-lingering: FAIL:$bad"
  exit 1
fi
echo "check-gnome-launch-lingering: a lingering launcher's late lines and window never answer for the new one, and the launch runs under focus-new-windows=strict, restored by done"

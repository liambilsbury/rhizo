#!/bin/bash
# test that a logged HOME makes task-bounds.sh minimize all of the windows, and that a cold HOME key is logged
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HELPER="${RHIZO_CHECK_TASK_BOUNDS:-$REPO/src/androidd/guest/bin/task-bounds.sh}"
HOME_SRC="${RHIZO_CHECK_HOME_SRC:-$REPO/src/android/apps/home/src/com/rhizo/home/HomeActivity.java}"
COMPOSER="$REPO/src/android/hal/graphics-composer/src/composer.cpp"

# print the log tag the home app writes
home_tag() {
  sed -n 's/^ *private static final String TAG = "\([^"]*\)";$/\1/p' "$HOME_SRC"
}

# print why a HOME key that creates the home activity logs nothing
cold_home_key() {
  local src="$1" body
  body=$(awk '/ void onCreate\(/ { on = 1 } on && $1 !~ /^\/\// { print } on && /^    }$/ { exit }' "$src")
  [[ -n "$body" ]] || { echo "the home activity has no onCreate"; return; }
  if ! grep -q '"android.intent.extra.FROM_HOME_KEY"' "$src" || ! grep -q 'getBooleanExtra(.*FROM_HOME_KEY' <<<"$body"; then
    echo "a HOME key that creates the home activity logs nothing: onCreate never reads android.intent.extra.FROM_HOME_KEY"
    return
  fi
  grep -q 'Log\.i(TAG, "home key")' <<<"$body" || echo "onCreate reads the home key's extra but logs no 'home key' line"
}

# run a copy of the helper on fixture logcat lines
run_helper() {
  local script="$1" t="$2" tag="$3" n
  mkdir -p "$t/ctl" "$t/tasks" "$t/bin"
  for v in 'D=/data/rhizo_control' 'M=/data/local/tmp/rhizo-tasks'; do
    n=$(grep -c "^$v\$" "$script")
    [[ "$n" == 1 ]] || { echo "HARNESS: $script has $n '$v' lines, want 1"; return 2; }
  done
  sed -e "s#^D=/data/rhizo_control\$#D=$t/ctl#" -e "s#^M=/data/local/tmp/rhizo-tasks\$#M=$t/tasks#" "$script" > "$t/task-bounds.sh"
  printf 'main\t10-23 14:28:20.100   634   634 I %s: home key\n' "$tag" > "$t/fixture"
  printf 'main\t10-23 14:28:20.200   634   634 I OtherTag: home key\n' >> "$t/fixture"
  printf 'events\t10-23 14:28:21.000   232   247 I wm_task_removed: [12,removeTask]\n' >> "$t/fixture"
  # fake logcat: print the fixture lines matching -b and the TAG:PRI specs
  cat > "$t/bin/logcat" <<EOF
#!/bin/bash
bufs=main; tags=" "
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -b) bufs=\$2; shift 2 ;;
    -T) shift 2 ;;
    -s) shift ;;
    *:*) tags+="\${1%%:*} "; shift ;;
    *) shift ;;
  esac
done
while IFS=\$'\t' read -r buf line; do
  [[ ",\$bufs," == *",\$buf,"* ]] || continue
  tag=\${line#* [VDIWEF] }; tag=\${tag%%:*}
  [[ "\$tags" == *" \$tag "* ]] && printf '%s\n' "\$line"
done < "$t/fixture"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$t/bin/inotifyd"
  printf '#!/bin/sh\nexit 0\n' > "$t/bin/dumpsys"
  chmod +x "$t/bin/"*
  echo 12 > "$t/tasks/task-3"
  echo 3 > "$t/tasks/display-3"
  mkfifo "$t/ctl/control"
  exec 3<>"$t/ctl/control"
  # returns once the helper and its logcat reader close stdout
  local out
  out=$(PATH="$t/bin:$PATH" sh "$t/task-bounds.sh" 2>&1)
  [[ -z "$out" ]] || printf '%s\n' "$out" | sed 's/^/  | /' > "$t/run.log"
  dd bs=65536 count=1 iflag=nonblock <&3 2>/dev/null
  exec 3<&-
}

# print why the helper's control writes fall short
verdict() {
  local wrote="$1" noun
  grep -qx 'display minimize-all' <<<"$wrote" || { echo "HOME left the windows: no 'display minimize-all' written (wrote: ${wrote:-nothing})"; return; }
  [[ $(grep -cx 'display minimize-all' <<<"$wrote") == 1 ]] || { echo "a log line from another tag also minimized the windows (wrote: $wrote)"; return; }
  grep -qx 'display remove 3' <<<"$wrote" || { echo "a removed task did not remove its display (wrote: $wrote)"; return; }
  noun=minimize-all
  grep -q "!strcmp(noun, \"$noun\")" "$COMPOSER" || echo "the composer handles no 'display $noun' command"
}

tag=$(home_tag)
[[ -n "$tag" ]] || { echo "check-home-minimizes-windows: no TAG constant in $HOME_SRC"; exit 1; }
for f in onNewIntent HomeKeyReceiver; do
  grep -q "$f" "$HOME_SRC" || { echo "check-home-minimizes-windows: $HOME_SRC has no $f"; exit 1; }
done

if [[ "${1:-}" == "--selftest" ]]; then
  work=$(mktemp -d) || exit 1
  trap 'rm -rf "$work"' EXIT
  sed 's/-b main,events/-b events/' "$HELPER" > "$work/events-only.sh"
  cmp -s "$work/events-only.sh" "$HELPER" && { echo "SELFTEST FAILED: could not seed an events-only reader into a copy of $HELPER" >&2; exit 1; }
  mkdir "$work/a"
  why=$(verdict "$(run_helper "$work/events-only.sh" "$work/a" "$tag")")
  [[ "$why" == "HOME left the windows"* ]] || { echo "SELFTEST FAILED: a helper reading only the events buffer passed ($why)" >&2; exit 1; }
  echo "selftest ok: a helper reading only the events buffer fails ($why)"
  mkdir "$work/b"
  why=$(verdict "$(run_helper "$HELPER" "$work/b" "Not$tag")")
  [[ "$why" == "HOME left the windows"* ]] || { echo "SELFTEST FAILED: a home app logging under another tag passed ($why)" >&2; exit 1; }
  echo "selftest ok: a home app logging under a tag the helper does not read fails ($why)"
  grep -v 'FROM_HOME_KEY' "$HOME_SRC" > "$work/HomeActivity.java"
  why=$(cold_home_key "$work/HomeActivity.java")
  [[ "$why" == "a HOME key that creates"* ]] || { echo "SELFTEST FAILED: a home app whose onCreate ignores the home key's extra passed ($why)" >&2; exit 1; }
  echo "selftest ok: a home app whose onCreate ignores the home key's extra fails ($why)"
  exit 0
fi

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
wrote=$(run_helper "$HELPER" "$work" "$tag")
[[ "$wrote" == HARNESS:* ]] && { echo "check-home-minimizes-windows: $wrote"; exit 1; }
why=$(verdict "$wrote")
[[ -n "$why" ]] || why=$(cold_home_key "$HOME_SRC")
if [[ -n "$why" ]]; then
  echo "check-home-minimizes-windows: $why"
  [[ -s "$work/run.log" ]] && tail -5 "$work/run.log"
  exit 1
fi
echo "check-home-minimizes-windows: a $tag line writes 'display minimize-all', the composer handles it, and a cold HOME key logs one"
exit 0

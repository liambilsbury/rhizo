#!/bin/bash
# fetch the noble packages with the udev rules
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="${RHIZO_UDEV_RULES_DIR:-$REPO/var/udev-rules}"
POOL="http://archive.ubuntu.com/ubuntu/pool/main"
PINS=(
  "udev_255.4-1ubuntu8_amd64.deb s/systemd 7958d57390c3fe122ecd58ad353f3f0dea4233cbc53da2434ec8fa0396f9df89"
  "systemd_255.4-1ubuntu8_amd64.deb s/systemd 2c5932214476d783f27df85cc866b8859232dfbd38a73f780fc4693ea9886e70"
  "bcache-tools_1.0.8-5build1_amd64.deb b/bcache-tools c809f3ecaefb3495f864cea87f1ee26b47abcc626977a4ab19aa9f3ec6a82489"
  "lvm2_2.03.16-3ubuntu3_amd64.deb l/lvm2 a5a53398b410bd32b4c235729fb0cff4504d88f829c255b1cba1d4fc6a895d41"
  "udisks2_2.10.1-6build1_amd64.deb u/udisks2 64a3146521b40eb0f276e52f49f626500458fbd765f165e4b3bc568c6ebdb2b6"
  "kpartx_0.9.4-5ubuntu8_amd64.deb m/multipath-tools ef7f14e1c1131d6bbf88a213fb02fd8a5f068f30bbc995de53f94e39c4f4898f"
)
RULES=(60-persistent-storage.rules 69-bcache.rules 69-lvm.rules 80-udisks2.rules 95-kpartx.rules 99-systemd.rules)

complete() {
  local r
  for r in "${RULES[@]}"; do [[ -s "$DEST/rules.d/$r" ]] || return 1; done
}
mkdir -p "$DEST/debs" "$DEST/rules.d" || exit 1
exec 9>"$DEST/.lock"
flock 9 || { echo "udev-rules: could not lock $DEST" >&2; exit 1; }
if complete; then
  echo "udev-rules: $DEST/rules.d is present"
  exit 0
fi
command -v dpkg-deb >/dev/null 2>&1 || { echo "udev-rules: dpkg-deb is missing" >&2; exit 2; }
for pin in "${PINS[@]}"; do
  read -r file dir sha <<<"$pin"
  deb="$DEST/debs/$file"
  if ! { [[ -f "$deb" ]] && sha256sum -c --status <<<"$sha  $deb"; }; then
    if ! timeout 300 curl -fsSL -o "$deb.part" "$POOL/$dir/$file"; then
      echo "udev-rules: could not download $POOL/$dir/$file" >&2
      exit 1
    fi
    if ! sha256sum -c --status <<<"$sha  $deb.part"; then
      echo "udev-rules: $file does not match its pinned sha256 $sha" >&2
      mv "$deb.part" "$deb.rejected"
      exit 1
    fi
    mv "$deb.part" "$deb" || exit 1
  fi
  work=$(mktemp -d "$DEST/x.XXXXXX") || exit 1
  dpkg-deb -x "$deb" "$work" || { echo "udev-rules: cannot unpack $file" >&2; exit 1; }
  for r in "${RULES[@]}"; do
    [[ -f "$work/usr/lib/udev/rules.d/$r" ]] && cp "$work/usr/lib/udev/rules.d/$r" "$DEST/rules.d/$r"
  done
  rm -rf "$work"
done
complete || { echo "udev-rules: the pinned packages lack one of ${RULES[*]}" >&2; exit 1; }
echo "udev-rules: fetched $DEST/rules.d"

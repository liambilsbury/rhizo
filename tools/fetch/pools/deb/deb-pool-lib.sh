#!/bin/bash
# derive and install the compositor deb pools

DEB_POOL_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEB_POOL_TABLE="$DEB_POOL_TOOLS/pools.tsv"

# print each malformed row of a pool table
deb_pool_table_problems() {
  local table="$1"
  [[ -r "$table" ]] || { echo "$table: no such pool table"; return 1; }
  awk -F'\t' -v t="$table" '
    BEGIN { q = "\047"; word = "^[a-z0-9][a-z0-9.+-]*( [a-z0-9][a-z0-9.+-]*)*$" }
    /^#/ || /^[[:space:]]*$/ { next }
    {
      at = t ":" FNR ": "
      if (NF != 4) { print at NF " column(s), not 4 (pool method packages allow-upgrade)"; bad = 1; next }
      if ($1 !~ /^[a-z0-9][a-z0-9.+-]*$/) { print at "pool name " q $1 q " is not a plain name"; bad = 1; next }
      if ($1 in first) { print at "pool " $1 " is named twice (first on line " first[$1] ")"; bad = 1; next }
      first[$1] = FNR
      if ($2 != "derived" && $2 != "listed" && $2 != "closure") {
        print at "pool " $1 ": unknown method " q $2 q " (derived, listed or closure)"; bad = 1
      }
      if ($3 !~ word) { print at "pool " $1 ": packages " q $3 q " is not a space-separated package list"; bad = 1 }
      if ($4 != "-" && $4 !~ word) {
        print at "pool " $1 ": allow-upgrade " q $4 q " is neither - nor a space-separated package list"; bad = 1
      } else if ($4 != "-" && $2 != "derived") {
        print at "pool " $1 ": allow-upgrade is the derived method" q "s; a " $2 " pool takes -"; bad = 1
      }
    }
    END { exit bad }' "$table"
}

# print a pool's row from the table
deb_pool_row() {
  local pool="$1" table="${2:-$DEB_POOL_TABLE}" problems row
  if ! problems=$(deb_pool_table_problems "$table"); then
    echo "[deb-pool] $table is malformed:" >&2
    sed 's/^/  /' <<<"$problems" >&2
    return 2
  fi
  row=$(awk -F'\t' -v p="$pool" '!/^#/ && $1 == p { print $2 "\t" $3 "\t" $4 }' "$table")
  if [[ -z "$row" ]]; then
    echo "[deb-pool] unknown pool '$pool': $table names $(awk -F'\t' '!/^#/ && NF == 4 { printf "%s%s", s, $1; s = " " }' "$table")" >&2
    return 2
  fi
  printf '%s\n' "$row"
}

# load the pool roots from the table
deb_pool_load_roots() {
  local table="${1:-$DEB_POOL_TABLE}" v row method roots allow
  unset DEB_POOL_SWAY_ROOTS DEB_POOL_SWAY_ALLOW_UPGRADE DEB_POOL_GNOME_ROOTS DEB_POOL_GNOME_ALLOW_UPGRADE
  for v in SWAY:sway-debs GNOME:gnome-debs; do
    row=$(deb_pool_row "${v#*:}" "$table") || return 2
    IFS=$'\t' read -r method roots allow <<<"$row"
    [[ "$method" == derived ]] \
      || { echo "[deb-pool] $table: ${v#*:} is $method; a staged compositor pool is derived" >&2; return 2; }
    [[ "$allow" == - ]] && allow=""
    printf -v "DEB_POOL_${v%%:*}_ROOTS" '%s' "$roots"
    printf -v "DEB_POOL_${v%%:*}_ALLOW_UPGRADE" '%s' "$allow"
  done
}

# print the pinned image sha256 from ubuntu-base.sh
deb_pool_image_pin() {
  local pin
  pin=$(sed -n 's/^BASE_SHA="\([0-9a-f]\{64\}\)"$/\1/p' "$DEB_POOL_TOOLS/../../images/ubuntu-base.sh" 2>/dev/null)
  [[ "$pin" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "[deb-pool] ubuntu-base.sh holds no single BASE_SHA pin" >&2; return 2; }
  printf '%s\n' "$pin"
}

# compare an image sha256 with the pin
deb_pool_image_matches_pin() {
  local have
  have=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
  if [[ -z "$have" || "$have" != "$2" ]]; then
    echo "[deb-pool] $1 has sha256 ${have:-<unreadable>}, not the pin $2 ubuntu-base.sh fetches: its dpkg status is another image's" >&2
    return 2
  fi
  printf '%s\n' "$have"
}

# extract dpkg status from the pristine image
deb_pool_pristine_admindir() {
  local w="$1" img="${DEB_POOL_PRISTINE_IMG:-$DEB_POOL_TOOLS/../../../../var/pristine-dl/noble-server-cloudimg-amd64.img}" pin sha
  [[ -f "$img" ]] || { echo "[deb-pool] no $img (ubuntu-base.sh)" >&2; return 2; }
  pin=$(deb_pool_image_pin) || return 2
  sha=$(deb_pool_image_matches_pin "$img" "$pin") || return 2
  sudo -n true 2>/dev/null || { echo "[deb-pool] the derivation needs sudo -n" >&2; return 2; }
  mkdir -p "$w/admin" "$w/m"
  echo "$sha" > "$w/image.sha256"
  qemu-img convert -O raw "$img" "$w/raw" || return 2
  local part_json start size sectorsize
  part_json=$(sudo -n /sbin/sfdisk -J "$w/raw") || return 2
  read -r start size sectorsize <<<"$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])["partitiontable"]
p = max(d["partitions"], key=lambda x: x["size"])
print(p["start"], p["size"], d.get("sectorsize", 512))
' "$part_json")"
  if sudo -n mount -o loop,ro,offset=$((start * sectorsize)) "$w/raw" "$w/m" 2>/dev/null; then
    cp "$w/m/var/lib/dpkg/status" "$w/admin/status"
    sudo -n umount "$w/m"
  else
    dd if="$w/raw" of="$w/part.raw" bs=512 skip="$start" count="$size" status=none
    debugfs -R "cat /var/lib/dpkg/status" "$w/part.raw" >"$w/admin/status" 2>"$w/debugfs.err" \
      || { echo "[deb-pool] debugfs could not read dpkg status off the pristine image:" >&2; cat "$w/debugfs.err" >&2; return 2; }
    rm -f "$w/part.raw"
  fi
  rm -f "$w/raw"
  grep -q '^Package: ' "$w/admin/status" \
    || { echo "[deb-pool] $w/admin/status names no package -- not the image's dpkg status" >&2; return 2; }
}

# print the packages apt adds for the roots
deb_pool_derive() {
  local admin="$1" allow=" $2 " have r sim bad want=()
  shift 2
  have=$(dpkg-query --admindir="$admin" -W -f='${Package}\t${db:Status-Abbrev}\n' 2>/dev/null \
    | awk -F'\t' 'substr($2, 2, 1) !~ /[nc]/ { print $1 }')
  [[ -n "$have" ]] || { echo "[deb-pool] $admin/status lists no installed package" >&2; return 2; }
  for r in "$@"; do
    grep -qxF -- "$r" <<<"$have" || want+=("$r")
  done
  (( ${#want[@]} )) || return 0
  sim=$(apt-get -o Dir::State::status="$admin/status" install --dry-run --no-install-recommends "${want[@]}" 2>&1) \
    || { echo "[deb-pool] apt could not resolve ${want[*]} against $admin/status:" >&2; tail -20 <<<"$sim" >&2; return 2; }
  bad=$(awk -v allow="$allow" '/^Inst [^ ]+ \[/ && index(allow, " " $2 " ") == 0 { print "  " $2 " " $3 " -> " $4 }' <<<"$sim")
  if [[ -n "$bad" ]]; then
    echo "[deb-pool] apt upgrades packages the pristine image already has, which no pool may carry undeclared:" >&2
    echo "$bad" >&2
    echo "[deb-pool] declare a lockstep set in pools.tsv's allow-upgrade column, with why, or pin the root" >&2
    return 3
  fi
  awk '/^Inst /{print $2}' <<<"$sim" | sort -u
}

# download the derived pool into var/share
deb_pool_fetch() {
  local name="$1" roots="$2" allow="$3" mode="${4:-}"
  local pool="$DEB_POOL_TOOLS/../../../../var/share/$name" w derived rc
  w=$(mktemp -d) || return 2
  # shellcheck disable=SC2086
  if ! deb_pool_pristine_admindir "$w"; then rm -rf "$w"; return 2; fi
  # shellcheck disable=SC2086
  if derived=$(deb_pool_derive "$w/admin" "$allow" $roots); then rc=0; else rc=$?; fi
  rm -rf "$w"
  (( rc == 0 )) || return "$rc"
  echo "[deb-pool] $name: the pristine image lacks $(grep -c . <<<"$derived") package(s) for: $roots"
  mkdir -p "$pool"
  if [[ "$mode" != --check ]]; then
    local work f p base rest arch missing=()
    work=$(mktemp -d) || return 2
    # shellcheck disable=SC2046
    ( cd "$work" && apt-get download $(tr '\n' ' ' <<<"$derived") ) || { rm -rf "$work"; return 2; }
    printf 'package\tversion\tarch\tsha256\tfile\n' > "$pool/MANIFEST.tsv.new"
    while IFS= read -r p; do
      f=$(compgen -G "$work/${p}_*.deb" | head -1) || true
      [[ -n "${f:-}" ]] || { missing+=("$p"); continue; }
      base=$(basename "$f")
      rest="${base%_*.deb}"; rest="${rest#"${p}"_}"
      arch="${base##*_}"; arch="${arch%.deb}"
      cp --remove-destination "$f" "$pool/"
      printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$rest" "$arch" "$(sha256sum "$pool/$base" | cut -d' ' -f1)" "$base" \
        >> "$pool/MANIFEST.tsv.new"
    done <<<"$derived"
    rm -rf "$work"
    mv "$pool/MANIFEST.tsv.new" "$pool/MANIFEST.tsv"
    (( ${#missing[@]} == 0 )) || { echo "[deb-pool] apt-get download produced no .deb for: ${missing[*]}" >&2; return 1; }
  fi
  local drop="" add f pkg held=""
  for f in "$pool"/*.deb; do
    [[ -e "$f" ]] || continue
    pkg=$(dpkg-deb -f "$f" Package)
    held+="$pkg"$'\n'
    grep -qxF -- "$pkg" <<<"$derived" || drop+="  $(basename "$f")"$'\n'
  done
  add=$(comm -23 <(sort -u <<<"$derived") <(grep . <<<"$held" | sort -u) | sed 's/^/  /')
  [[ -z "$drop" ]] || printf '[deb-pool] %s holds file(s) the derivation does not want (remove them by hand):\n%s' "$name" "$drop"
  [[ -z "$add" ]] || printf '[deb-pool] %s lacks package(s) the derivation wants:\n%s\n' "$name" "$add"
  [[ -z "$drop" && -z "$add" ]] && echo "[deb-pool] $name matches the derivation"
  [[ -z "$drop" && -z "$add" ]]
}


# print package and version for each Inst line
deb_pool_sim_inst() {
  awk '/^Inst / { v = ($3 ~ /^\[/) ? $4 : $3; sub(/^\(/, "", v); print $2 "\t" v }' "$1"
}

# print the recommended packages
deb_pool_unmet_recommends() {
  awk '/^Recommended packages:/ { on = 1; next }
       on && /^  / { for (i = 1; i <= NF; i++) if ($i != "|") print $i; next }
       { on = 0 }' "$1" | sort -u
}

# print each problem found in an apt log
deb_pool_apt_log_problems() {
  local log="$1" allowed="$2" remote errs extra rcs
  if grep -qx 'APT_RC=NOCONF' "$log" 2>/dev/null; then
    echo "the guest had no offline apt config (APT_RC=NOCONF): apt never ran against the pool"
    return 0
  fi
  if ! grep -q '^Reading package lists' "$log" 2>/dev/null; then
    echo "no apt output in $log"
    return 0
  fi
  errs=$(grep -m1 '^W: Unable to read' "$log")
  [[ -z "$errs" ]] || echo "apt could not read its config and fell back to the guest's own sources: $errs"
  rcs=$(sed -n 's/^APT_RC=//p' "$log" | tr '\n' ' ')
  if [[ -z "$rcs" ]]; then
    echo "apt never reported finishing (no APT_RC= line): the log was cut short"
  elif [[ "$rcs" != "0 " ]]; then
    echo "apt exited APT_RC=${rcs% }"
  fi
  remote=$(grep -E '^(Get|Hit|Ign|Err):[0-9]+ [a-z0-9+.-]+://|^E: Failed to fetch [a-z0-9+.-]+://' "$log" | head -3)
  [[ -z "$remote" ]] || echo "apt reached a remote source: $(tr '\n' '|' <<<"$remote")"
  errs=$(grep -E '^E: |but it is not installable' "$log" | grep -v '^E: Failed to fetch' | head -4)
  [[ -z "$errs" ]] || echo "apt did not resolve the install: $(tr -s ' ' <<<"$errs" | tr '\n' '|')"
  extra=$(comm -23 <(deb_pool_unmet_recommends "$log") <(grep -v '^#' "$allowed" 2>/dev/null | awk 'NF { print $1 }' | sort -u))
  [[ -z "$extra" ]] || echo "apt left Recommends uninstalled that a connected host installs (the pool lacks them): $(tr '\n' ' ' <<<"$extra")"
  return 0
}

# print a .deb's package and version
deb_pool_package_version() {
  local fields
  if ! fields=$(dpkg-deb -f "$1" Package Version 2>&1); then
    echo "[deb-pool] skipping $1, which dpkg-deb cannot read: $(tr '\n' ' ' <<<"$fields")" >&2
    return 2
  fi
  printf '%s %s\n' "$(sed -n 's/^Package: //p' <<<"$fields")" "$(sed -n 's/^Version: //p' <<<"$fields")"
}

# print a package's highest version .deb
deb_pool_newest_deb() {
  local best="" best_ver="" f pv pkg ver
  for f in "$1/$2"_*.deb; do
    [[ -f "$f" ]] || continue
    pv=$(deb_pool_package_version "$f") || continue
    read -r pkg ver <<<"$pv"
    [[ "$pkg" == "$2" ]] || continue
    if [[ -z "$best" ]] || dpkg --compare-versions "$ver" gt "$best_ver"; then
      best="$f" best_ver="$ver"
    fi
  done
  printf '%s' "$best"
}

# print a meta .deb and its pinned .deb
deb_pool_kernel_meta_debs() {
  local meta="$1" dir="$2" m dep pkg ver f pv found=""
  m=$(deb_pool_newest_deb "$dir" "$meta")
  [[ -n "$m" ]] || { echo "[deb-pool] $dir holds no ${meta}_*.deb: copy the Rhizo kernel's four .debs there" >&2; return 2; }
  dep=$(dpkg-deb -f "$m" Depends) || { echo "[deb-pool] dpkg-deb cannot read the Depends of $m" >&2; return 2; }
  read -r pkg ver < <(sed -n 's/^ *\(linux-\(image\|headers\)-[^ ,|]*\) *(= *\([^ )]*\) *) *$/\1 \3/p' <<<"$dep")
  if [[ -z "$pkg" || -z "$ver" || "$pkg" == "$meta" ]]; then
    echo "[deb-pool] $(basename "$m") depends on '$dep', not on one versioned linux-image or linux-headers package at an exact version" >&2
    return 2
  fi
  for f in "$dir/${pkg}_${ver}"_*.deb; do
    [[ -f "$f" ]] || continue
    pv=$(deb_pool_package_version "$f") || continue
    [[ "$pv" == "$pkg $ver" ]] && found="$f"
  done
  [[ -n "$found" ]] || { echo "[deb-pool] $(basename "$m") pins $pkg (= $ver), and $dir holds no ${pkg}_${ver}_*.deb" >&2; return 2; }
  printf '%s\n%s\n' "$m" "$found"
}

# print the kernel .debs a rhizo .deb needs
deb_pool_kernel_debs() {
  local dep meta
  dep=$(dpkg-deb -f "$1" Depends) || { echo "[deb-pool] dpkg-deb cannot read the Depends of $1" >&2; return 2; }
  for meta in $(tr ',|' '\n\n' <<<"$dep" | sed -n 's/^ *\(linux-\(image\|headers\)-rhizo\)\( .*\)\{0,1\}$/\1/p' | sort -u); do
    deb_pool_kernel_meta_debs "$meta" "$2" || return 2
  done
}


DEB_POOL_STAMP=CHECKED

# print a sha256 row for each pool file
deb_pool_stamp_files() {
  local f
  for f in "$1"/*; do
    [[ -f "$f" && "${f##*/}" != "$DEB_POOL_STAMP" ]] || continue
    printf 'pool\t%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${f##*/}"
  done | sort -t$'\t' -k3
}

# write the CHECKED stamp file
deb_pool_stamp_write() {
  { echo "# runtime-debs.sh's check passed on exactly these bytes; installer-lib.sh"
    echo "# stages this pool, and transfers a .deb, only when every one is named here"
    printf 'checked\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'image\t%s\n' "$2"
    cat "$3"
    printf 'end\tok\n'; } > "$1/$DEB_POOL_STAMP.new" && mv "$1/$DEB_POOL_STAMP.new" "$1/$DEB_POOL_STAMP"
}

# print each mismatch between pool and stamp
deb_pool_stamp_problems() {
  local pool="$1" stamp="$1/$DEB_POOL_STAMP" pin d sha out=""
  shift
  if [[ ! -f "$stamp" ]]; then
    echo "$pool has no $DEB_POOL_STAMP stamp: runtime-debs.sh's check never passed on it"
    return 1
  fi
  if [[ "$(tail -1 "$stamp")" != $'end\tok' ]]; then
    echo "$stamp is incomplete (its last row is not 'end ok')"
    return 1
  fi
  pin=$(deb_pool_image_pin 2>/dev/null)
  d=$(awk -F'\t' '$1 == "image" { print $2 }' "$stamp")
  [[ -n "$pin" && "$d" == "$pin" ]] \
    || out+="$stamp was checked against image ${d:-<none>}, not the pin ${pin:-<none>} a vm boots"$'\n'
  for d in N N-1; do
    awk -F'\t' -v l="$d" '$1 == "deb" && $2 == l { f = 1 } END { exit !f }' "$stamp" \
      || out+="$stamp names no $d .deb: the check judged no $d closure"$'\n'
  done
  out+=$(awk -F'\t' '
    NR == FNR { if ($1 == "pool") then_[$3] = $2; next }
    { now[$3] = $2 }
    END {
      for (f in then_) {
        if (!(f in now)) print "the pool no longer holds " f ", which the check passed"
        else if (now[f] != then_[f]) print "the pool'"'"'s " f " is not the file the check passed (sha256 " now[f] ", checked " then_[f] ")"
      }
      for (f in now) if (!(f in then_)) print "the pool holds " f ", which the check never saw"
    }' "$stamp" <(deb_pool_stamp_files "$pool") | sort)
  [[ -z "$out" || "$out" == *$'\n' ]] || out+=$'\n'
  for d in "$@"; do
    sha=$(sha256sum "$d" 2>/dev/null | cut -d' ' -f1)
    awk -F'\t' -v s="$sha" '$1 == "deb" && $3 == s { f = 1 } END { exit !f }' "$stamp" \
      || out+="the check never judged $(basename "$d") (sha256 ${sha:-<unreadable>}): the stamp names other .debs"$'\n'
  done
  [[ -z "$out" ]] && return 0
  printf '%s' "$out"
  return 1
}


# copy files to the vm with scp
_deb_pool_scp() { timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$@"; }
# run the planner on a guest pool folder
deb_pool_stage() {
  local label="$1" dir="$2" roots="$3" allow="$4" plan_out="$5" log_out="$6"
  local plan="/root/deb-pool-$label.tsv" args="" r rc
  for r in $roots; do args+=" --root $r"; done
  [[ -z "$allow" ]] || args+=" --allow-upgrade ${allow// /,}"
  _deb_pool_scp "$DEB_POOL_TOOLS/../../../build/packaging/deb/deb-pool-plan.py" "$SSH_TARGET:/root/deb-pool-plan.py" \
    || { echo "$label: could not stage deb-pool-plan.py onto the guest"; return 1; }
  ssh_vm -t 300 "python3 /root/deb-pool-plan.py --pool $dir$args > $plan 2> $plan.err; echo DEB_POOL_PLAN_RC=\$?; cat $plan $plan.err" \
    > "$plan_out" 2>&1
  rc=$(sed -n 's/^DEB_POOL_PLAN_RC=//p' "$plan_out" | head -1)
  case "$rc" in
    0) ;;
    1) echo "$label: the plan needs what this host cannot give without moving its own packages --$(awk -F'\t' '$1=="NEED"{printf " %s: %s;", $2, $3}' "$plan_out") (plan in $plan_out)"
       return 1 ;;
    *) echo "$label: deb-pool-plan.py did not answer (rc=${rc:-none}): $(tail -3 "$plan_out" | tr '\n' ' ')"
       return 1 ;;
  esac
  ssh_vm -t 1800 "grep -E '^(INSTALL|UPGRADE)[[:space:]]' $plan | cut -f2 > $plan.files
    verified=0
    for round in 1 2 3; do
      if [ -s $plan.files ]; then
        echo \"--- round \$round: dpkg -i \$(wc -l < $plan.files) planned file(s)\"
        DEBIAN_FRONTEND=noninteractive xargs -a $plan.files dpkg -i 2>&1 | tail -40
        echo '--- dpkg --configure -a ---'
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>&1 | tail -20
      fi
      if python3 /root/deb-pool-plan.py --verify $plan > $plan.verify 2>&1; then verified=1; break; fi
    done
    cat $plan.verify
    [ \$verified = 1 ] && echo DEB_POOL_VERIFIED || echo DEB_POOL_NOT_VERIFIED
    apt-get check > $plan.check 2>&1; echo DEB_POOL_APT_CHECK_RC=\$?; cat $plan.check" \
    > "$log_out" 2>&1
  if ! grep -qx DEB_POOL_VERIFIED "$log_out"; then
    echo "$label: the host does not hold what the plan installed --$(awk -F'\t' '$1=="VERIFY-FAIL"{printf " %s: %s;", $2, $3}' "$log_out") (log in $log_out)"
    return 1
  fi
  rc=$(sed -n 's/^DEB_POOL_APT_CHECK_RC=//p' "$log_out" | head -1)
  if [[ "$rc" != 0 ]]; then
    echo "$label: apt-get check exits ${rc:-nothing} after staging, a broken dependency state: $(sed -n '/^DEB_POOL_APT_CHECK_RC=/,$p' "$log_out" | tail -n +2 | tail -6 | tr '\n' ' ')"
    return 1
  fi
  awk -F'\t' -v label="$label" '
    $1 == "UPGRADE" { ups = ups " " $3 " " $4 "->" $5 }
    { c[$1]++ }
    END {
      printf "%s: installed %d new package(s), upgraded %d%s, left %d the host already had in place, %d unused; apt-get check clean\n",
        label, c["INSTALL"], c["UPGRADE"], (ups == "" ? "" : " (declared:" ups ")"), c["KEEP"], c["UNUSED"]
    }' "$plan_out"
}

deb_pool_load_roots || { [[ "${BASH_SOURCE[0]}" == "$0" ]] || return 2; }

if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--selftest" ]]; then
  set -uo pipefail
  BAD=0
  ok() { echo "SELFTEST OK: $1"; }
  bad() { echo "SELFTEST FAIL: $1"; BAD=$((BAD + 1)); }
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
  SSH_TARGET=stub
  _deb_pool_scp() { return 0; }
  STUB_PLAN_RC=0 STUB_PLAN="" STUB_VERIFY="" STUB_VERIFIED=DEB_POOL_VERIFIED STUB_APT_RC=0
  ssh_vm() {
    local body="${*: -1}"
    case "$body" in
      *"deb-pool-plan.py --pool"*) printf '%s\nDEB_POOL_PLAN_RC=%s\n' "$STUB_PLAN" "$STUB_PLAN_RC" ;;
      *"dpkg -i"*) printf -- '--- round 1\n%s\n%s\nDEB_POOL_APT_CHECK_RC=%s\n' "$STUB_VERIFY" "$STUB_VERIFIED" "$STUB_APT_RC" ;;
      *) return 255 ;;
    esac
  }
  stage_case() {
    local out rc
    out=$(deb_pool_stage t /pool "sway" "" "$T/plan.tsv" "$T/install.log")
    rc=$?
    if [[ "$1" == pass ]]; then
      if (( rc == 0 )) && [[ "$out" == *"$2"* ]]; then ok "deb_pool_stage passes: $3"
      else bad "deb_pool_stage refused '$3': $out"; fi
    elif (( rc == 0 )); then
      bad "deb_pool_stage returned 0 on a planted defect ($3): $out"
    elif [[ "$out" != *"$2"* ]]; then
      bad "deb_pool_stage refused '$3' but not by name (want '$2'): $out"
    else
      ok "deb_pool_stage refuses by name: $3"
    fi
  }
  STUB_PLAN=$'INSTALL\t/pool/sway_1.9_amd64.deb\tsway\t1.9\nKEEP\tsystemd\t255.4-1ubuntu8.16\t255.4-1ubuntu8.17\nUNUSED\t/pool/dbus-broker_35_amd64.deb\tdbus-broker\tnothing the roots reach needs it'
  stage_case pass "installed 1 new package(s), upgraded 0, left 1 the host already had in place, 1 unused" \
    "a plan that adds sway and leaves the host's systemd alone"
  STUB_PLAN_RC=1
  STUB_PLAN+=$'\nNEED\tgir1.2-polkit-1.0\tDepends libpolkit-agent-1-0 (= 124-2ubuntu1.24.04.4), but this host has libpolkit-agent-1-0 124-2ubuntu1.24.04.3'
  stage_case fail "gir1.2-polkit-1.0: Depends libpolkit-agent-1-0" "a plan with a real version need"
  STUB_PLAN_RC=""
  stage_case fail "deb-pool-plan.py did not answer (rc=none)" "a planner that never answered"
  STUB_PLAN_RC=0 STUB_VERIFIED=DEB_POOL_NOT_VERIFIED
  STUB_VERIFY=$'VERIFY-FAIL\tlibudev1\thad 255.4-1ubuntu8.16 before staging and has 255.4-1ubuntu8.17 now'
  stage_case fail "libudev1: had 255.4-1ubuntu8.16 before staging" "staging that moved a kept package (the systemd defect)"
  STUB_VERIFIED=DEB_POOL_VERIFIED STUB_VERIFY="" STUB_APT_RC=100
  stage_case fail "apt-get check exits 100 after staging" "a broken dependency state apt-get check reports"
  STUB_APT_RC=""
  stage_case fail "apt-get check exits nothing after staging" "an apt-get check that never answered"
  unset -f ssh_vm _deb_pool_scp stage_case

  mkdir -p "$T/admin"
  printf 'Package: libglib2.0-bin\nStatus: install ok installed\nVersion: 2.80.0-6ubuntu3.8\nArchitecture: amd64\nMaintainer: x <x@invalid>\nDescription: x\n\nPackage: polkitd\nStatus: install ok installed\nVersion: 124-2ubuntu1.24.04.3\nArchitecture: amd64\nMaintainer: x <x@invalid>\nDescription: x\n' \
    > "$T/admin/status"
  apt-get() {
    local a
    for a in "$@"; do [[ "$a" == libglib2.0-bin ]] && echo "Inst libglib2.0-bin [2.80.0-6ubuntu3.8] (2.80.0-6ubuntu3.9 Ubuntu:24.04/noble-updates [amd64])"; done
    echo "Inst polkitd [124-2ubuntu1.24.04.3] (124-2ubuntu1.24.04.4 Ubuntu:24.04/noble-updates [amd64])"
    echo "Inst gnome-shell (46.0-0ubuntu6~24.04.14 Ubuntu:24.04/noble-updates [amd64])"
    return 0
  }
  out=$(deb_pool_derive "$T/admin" "polkitd" gnome-shell libglib2.0-bin 2>&1); rc=$?
  if (( rc == 0 )) && [[ "$out" == $'gnome-shell\npolkitd' ]]; then
    ok "deb_pool_derive never asks apt for a root the image has, and keeps a declared upgrade"
  else
    bad "deb_pool_derive with an installed root and a declared upgrade: rc=$rc out=$out"
  fi
  out=$(deb_pool_derive "$T/admin" "" gnome-shell 2>&1); rc=$?
  if (( rc == 3 )) && [[ "$out" == *"polkitd [124-2ubuntu1.24.04.3] -> (124-2ubuntu1.24.04.4"* ]]; then
    ok "deb_pool_derive fails naming an upgrade no pool declared"
  else
    bad "deb_pool_derive with an undeclared upgrade: rc=$rc out=$out"
  fi
  unset -f apt-get

  printf '%s\n' 'Reading package lists...' 'Recommended packages:' \
    '  rhizo-addon intel-media-va-driver | mesa-va-drivers luit' \
    'The following NEW packages will be installed:' '  pipewire rhizo' \
    'Inst libbz2-1.0 [1.0.8-5.1build0.1] (1.0.8-5.1ubuntu0.1 Ubuntu:24.04/noble-updates [amd64])' \
    'Inst libva2 (2.20.0-2ubuntu0.2 localhost [amd64])' \
    'Get:1 /root/rhizo-artifact/rhizo_0.1.1_amd64.deb rhizo amd64 0.1.1 [16.3 MB]' \
    'Get:3 http://archive.ubuntu.com/ubuntu noble/main amd64 alsa-topology-conf all 1.2.5.1-2 [15.5 kB]' \
    'E: Failed to fetch http://archive.ubuntu.com/ubuntu/pool/main/a/alsa-ucm-conf/alsa-ucm-conf_1.2.10-1ubuntu5.13_all.deb  404  Not Found' \
    > "$T/online.log"
  printf 'luit\nrhizo-addon\n' > "$T/allowed"
  out=$(deb_pool_sim_inst "$T/online.log")
  if [[ "$out" == $'libbz2-1.0\t1.0.8-5.1ubuntu0.1\nlibva2\t2.20.0-2ubuntu0.2' ]]; then
    ok "deb_pool_sim_inst reads an upgrade at its new version and a new package at its own"
  else
    bad "deb_pool_sim_inst: $out"
  fi
  out=$(deb_pool_unmet_recommends "$T/online.log")
  if [[ "$out" == $'intel-media-va-driver\nluit\nmesa-va-drivers\nrhizo-addon' ]]; then
    ok "deb_pool_unmet_recommends reads every name under Recommended packages:, alternatives split"
  else
    bad "deb_pool_unmet_recommends: $out"
  fi
  out=$(deb_pool_apt_log_problems "$T/online.log" "$T/allowed")
  if [[ "$out" == *"apt reached a remote source: Get:3 http://archive.ubuntu.com"* && "$out" == *"E: Failed to fetch http://"* ]]; then
    ok "deb_pool_apt_log_problems names an install that fetched from the archive (sweep 6's 404)"
  else
    bad "deb_pool_apt_log_problems missed the remote fetch: $out"
  fi
  if [[ "$out" == *"(the pool lacks them): intel-media-va-driver mesa-va-drivers"* ]]; then
    ok "deb_pool_apt_log_problems names a Recommends left unmet that a connected host installs"
  else
    bad "deb_pool_apt_log_problems missed the unmet Recommends: $out"
  fi
  grep -v -e '://' -e 'intel-media' "$T/online.log" > "$T/offline.log"
  printf '%s\n' 'Recommended packages:' '  rhizo-addon luit' 'Setting up rhizo (0.1.1) ...' 'APT_RC=0' >> "$T/offline.log"
  out=$(deb_pool_apt_log_problems "$T/offline.log" "$T/allowed")
  if [[ -z "$out" ]]; then
    ok "deb_pool_apt_log_problems passes an install from the local pool that left only the connected host's own unmet Recommends"
  else
    bad "deb_pool_apt_log_problems refused a clean offline install: $out"
  fi
  judge_case() {
    local o
    o=$(deb_pool_apt_log_problems "$2" "$T/allowed")
    if [[ "$o" == *"$3"* ]]; then ok "deb_pool_apt_log_problems names $1"
    else bad "deb_pool_apt_log_problems on $1, want '$3': ${o:-<passed>}"; fi
  }
  sed '/^Setting up/,$d' "$T/offline.log" > "$T/cut.log"
  judge_case "a log cut short before apt reported APT_RC" "$T/cut.log" \
    "apt never reported finishing (no APT_RC= line): the log was cut short"
  { echo 'W: Unable to read /var/lib/test-runtime-debs/apt/apt.conf - RealFileExists (2: No such file or directory)'
    cat "$T/offline.log"; } > "$T/noconf-w.log"
  judge_case "apt reading no APT_CONFIG file (a warning, then the guest's own sources)" "$T/noconf-w.log" \
    "apt could not read its config and fell back to the guest's own sources: W: Unable to read /var/lib/test-runtime-debs/apt/apt.conf"
  printf 'APT_RC=NOCONF\n' > "$T/noconf.log"
  judge_case "a site whose guard found no offline config" "$T/noconf.log" \
    "the guest had no offline apt config (APT_RC=NOCONF)"
  sed 's/^APT_RC=0$/APT_RC=100/' "$T/offline.log" > "$T/rc100.log"
  judge_case "an apt that exited nonzero with no E: line" "$T/rc100.log" "apt exited APT_RC=100"
  printf '%s\n' 'Reading package lists...' ' rhizo : Depends: libpipewire-0.3-0t64 (>= 0.3.6) but it is not installable' \
    'E: Unable to correct problems, you have held broken packages.' 'APT_RC=100' > "$T/broken.log"
  out=$(deb_pool_apt_log_problems "$T/broken.log" "$T/allowed")
  if [[ "$out" == *"apt did not resolve the install:"*"rhizo : Depends: libpipewire-0.3-0t64 (>= 0.3.6) but it is not installable|E: Unable to correct problems"* ]]; then
    ok "deb_pool_apt_log_problems names a Depends the pool lacks, never passing a failed resolve as offline"
  else
    bad "deb_pool_apt_log_problems on a failed resolve: $out"
  fi
  : > "$T/empty.log"
  out=$(deb_pool_apt_log_problems "$T/empty.log" "$T/allowed")
  if [[ "$out" == "no apt output in"* ]]; then
    ok "deb_pool_apt_log_problems fails an empty log rather than passing it"
  else
    bad "deb_pool_apt_log_problems on an empty log: $out"
  fi

  pin=$(deb_pool_image_pin 2>&1); rc=$?
  if (( rc == 0 )) && [[ "$pin" =~ ^[0-9a-f]{64}$ ]] && grep -qx "BASE_SHA=\"$pin\"" "$DEB_POOL_TOOLS/../../images/ubuntu-base.sh"; then
    ok "deb_pool_image_pin reads ubuntu-base.sh's own BASE_SHA"
  else
    bad "deb_pool_image_pin: rc=$rc $pin"
  fi
  printf 'not the pinned image\n' > "$T/image"
  sha=$(sha256sum "$T/image" | cut -d' ' -f1)
  out=$(deb_pool_image_matches_pin "$T/image" "$sha" 2>&1); rc=$?
  if (( rc == 0 )) && [[ "$out" == "$sha" ]]; then
    ok "deb_pool_image_matches_pin passes an image whose sha256 is the pin"
  else
    bad "deb_pool_image_matches_pin refused an image matching its pin: rc=$rc $out"
  fi
  out=$(DEB_POOL_PRISTINE_IMG="$T/image" deb_pool_pristine_admindir "$T/pa" 2>&1); rc=$?
  if (( rc == 2 )) && [[ "$out" == *"has sha256 $sha, not the pin $pin"* && ! -e "$T/pa/admin" ]]; then
    ok "deb_pool_pristine_admindir refuses an image that is not the pin, before reading it"
  else
    bad "deb_pool_pristine_admindir on an unpinned image: rc=$rc $out"
  fi

  mkstub_deb() {
    mkdir -p "$T/src/$2_$3/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: x <x@invalid>\nDescription: x\n' "$2" "$3" \
      > "$T/src/$2_$3/DEBIAN/control"
    dpkg-deb -Znone --build "$T/src/$2_$3" "$1" >/dev/null
  }
  P="$T/vm/runtime-debs"
  mkdir -p "$P" "$T/debs"
  mkstub_deb "$P/libva2_2.20.0-2ubuntu0.2_amd64.deb" libva2 2.20.0-2ubuntu0.2
  mkstub_deb "$P/libfoo_1.0_all.deb" libfoo 1.0
  printf '# unmet\nrhizo-addon\n' > "$P/UNMET-RECOMMENDS"
  mkstub_deb "$T/debs/rhizo_0.2_amd64.deb" rhizo 0.2
  mkstub_deb "$T/debs/rhizo_0.1_amd64.deb" rhizo 0.1
  mkstub_deb "$T/debs/rhizo_0.3_amd64.deb" rhizo 0.3
  { printf 'deb\tN\t%s\trhizo_0.2_amd64.deb\n' "$(sha256sum "$T/debs/rhizo_0.2_amd64.deb" | cut -d' ' -f1)"
    printf 'deb\tN-1\t%s\trhizo_0.1_amd64.deb\n' "$(sha256sum "$T/debs/rhizo_0.1_amd64.deb" | cut -d' ' -f1)"
    deb_pool_stamp_files "$P"; } > "$T/rows"
  deb_pool_stamp_write "$P" "$pin" "$T/rows"
  cp "$P/$DEB_POOL_STAMP" "$T/stamp.good"
  stamp_case() {
    local o r
    o=$(deb_pool_stamp_problems "$P" "${@:3}"); r=$?
    if [[ -z "$2" ]]; then
      if (( r == 0 )) && [[ -z "$o" ]]; then ok "deb_pool_stamp_problems passes $1"; else bad "deb_pool_stamp_problems refused $1: $o"; fi
    elif (( r == 1 )) && [[ "$o" == *"$2"* ]]; then
      ok "deb_pool_stamp_problems names $1"
    else
      bad "deb_pool_stamp_problems on $1, want '$2': rc=$r ${o:-<passed>}"
    fi
    cp "$T/stamp.good" "$P/$DEB_POOL_STAMP"
  }
  stamp_case "the pool and .debs the check passed" "" "$T/debs/rhizo_0.2_amd64.deb" "$T/debs/rhizo_0.1_amd64.deb"
  stamp_case "a .deb the check never judged" "the check never judged rhizo_0.3_amd64.deb" "$T/debs/rhizo_0.3_amd64.deb"
  rm "$P/$DEB_POOL_STAMP"
  stamp_case "a pool with no stamp" "has no CHECKED stamp"
  sed -i '$d' "$P/$DEB_POOL_STAMP"
  stamp_case "a stamp cut short" "is incomplete"
  cp "$P/libfoo_1.0_all.deb" "$T/libfoo.keep"; printf 'x' >> "$P/libfoo_1.0_all.deb"
  stamp_case "a pool file changed since the check" "the pool's libfoo_1.0_all.deb is not the file the check passed"
  cp "$T/libfoo.keep" "$P/libfoo_1.0_all.deb"
  printf 'rhizo-addon\nintel-media-va-driver\n' > "$T/unmet.keep"; cp "$P/UNMET-RECOMMENDS" "$T/unmet.orig"
  cp "$T/unmet.keep" "$P/UNMET-RECOMMENDS"
  stamp_case "an UNMET-RECOMMENDS rewritten after the check (an outdated excuse)" "the pool's UNMET-RECOMMENDS is not the file the check passed"
  cp "$T/unmet.orig" "$P/UNMET-RECOMMENDS"
  mkstub_deb "$P/libbar_1.0_all.deb" libbar 1.0
  stamp_case "a pool file the check never saw" "the pool holds libbar_1.0_all.deb, which the check never saw"
  rm "$P/libbar_1.0_all.deb"; mv "$P/libfoo_1.0_all.deb" "$T/libfoo.keep"
  stamp_case "a pool file gone since the check" "the pool no longer holds libfoo_1.0_all.deb"
  mv "$T/libfoo.keep" "$P/libfoo_1.0_all.deb"

  mkdir -p "$T/glue-bin"
  printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$T/scp.log" > "$T/glue-bin/scp"; chmod +x "$T/glue-bin/scp"
  glue() {
    local call=("$@")
    : > "$T/scp.log"; : > "$T/glue-ssh.log"
    (
      set --
      FAILED=0
      fail() { echo "FAIL: $*" >> "$T/glue.out"; FAILED=$((FAILED + 1)); }
      pass() { echo "PASS: $*" >> "$T/glue.out"; }
      note() { :; }
      log() { :; }
      # shellcheck source=../../../../test/system/lib/installer-lib.sh
      source "$DEB_POOL_TOOLS/../../../../test/system/lib/installer-lib.sh"
      # shellcheck disable=SC2034
      EV="$T/ev" SHARE_DIR="$T/vm" SSH_OPTS=() SSH_PORT=22 SSH_TARGET=stub
      mkdir -p "$EV"
      INSTALLER_TRANSFERRED_DEBS=()
      [[ -z "${GLUE_SENT:-}" ]] || INSTALLER_TRANSFERRED_DEBS=("$GLUE_SENT")
      ssh_vm() {
        local body="${*: -1}"
        printf '%s\n---\n' "$body" >> "$T/glue-ssh.log"
        case "$body" in
          *"apt-get update"*)
            printf 'staged=2\nReading package lists...\nUPDATE_RC=0\n--- policy\n 500 file:%s ./ Packages\n--- config\nDir::Etc::sourcelist "%s/apt/sources.list";\n' \
              "$TEST_RHIZO_RUNTIME_DEBS" "$TEST_RHIZO_RUNTIME_DEBS" ;;
        esac
        return 0
      }
      PATH="$T/glue-bin:$PATH"
      "${call[@]}"
      echo "RC=$? FAILED=$FAILED SCP=$(grep -c . "$T/scp.log") UNMET=${INSTALLER_OFFLINE_UNMET:-none} SENT=${#INSTALLER_TRANSFERRED_DEBS[@]}"
    )
  }
  : > "$T/glue.out"
  out=$(GLUE_SENT="$T/debs/rhizo_0.2_amd64.deb" glue installer_stage_offline_repo t "$P")
  if [[ "$out" == "RC=0 FAILED=0 SCP=2 UNMET=$T/ev/t-offline-repo.UNMET-RECOMMENDS SENT=1" ]] \
      && cmp -s "$T/ev/t-offline-repo.UNMET-RECOMMENDS" "$P/UNMET-RECOMMENDS" \
      && [[ "$(head -1 "$T/glue-ssh.log")" == "rm -rf /var/lib/test-runtime-debs" ]]; then
    ok "installer_stage_offline_repo stages a pool its stamp names, with the .deb already sent, and judges by the staged UNMET-RECOMMENDS"
  else
    bad "installer_stage_offline_repo on a stamped pool: $out $(tail -2 "$T/glue.out" | tr '\n' ' ')"
  fi
  : > "$T/glue.out"
  out=$(GLUE_SENT="$T/debs/rhizo_0.3_amd64.deb" glue installer_stage_offline_repo t "$P")
  if [[ "$out" == "RC=1 FAILED=1 SCP=0 "* ]] && grep -q 'FAIL: .*the check never judged rhizo_0.3_amd64.deb' "$T/glue.out" \
      && [[ "$(head -1 "$T/glue-ssh.log")" == "rm -rf /var/lib/test-runtime-debs" ]] && ! grep -q 'apt-get' "$T/glue-ssh.log"; then
    ok "installer_stage_offline_repo refuses, before any scp, a pool whose stamp never judged the .deb sent, and leaves the guest no offline config"
  else
    bad "installer_stage_offline_repo with an unjudged .deb sent: $out $(tail -2 "$T/glue.out" | tr '\n' ' ')"
  fi
  : > "$T/glue.out"
  mv "$P/$DEB_POOL_STAMP" "$T/stamp.away"
  out=$(glue installer_stage_offline_repo t "$P")
  mv "$T/stamp.away" "$P/$DEB_POOL_STAMP"
  if [[ "$out" == "RC=1 FAILED=1 SCP=0 "* ]] && grep -q 'FAIL: .*has no CHECKED stamp' "$T/glue.out"; then
    ok "installer_stage_offline_repo refuses a pool with no stamp (UNMET-RECOMMENDS alone is no check)"
  else
    bad "installer_stage_offline_repo on an unstamped pool: $out $(tail -2 "$T/glue.out" | tr '\n' ' ')"
  fi
  : > "$T/glue.out"
  out=$(glue installer_transfer_artifact t "$T/debs/rhizo_0.3_amd64.deb" "$T/debs/rhizo_0.1_amd64.deb")
  if [[ "$out" == "RC=1 FAILED=1 SCP=0 "*"SENT=0" ]] && grep -q 'FAIL: .*the check never judged rhizo_0.3_amd64.deb' "$T/glue.out"; then
    ok "installer_transfer_artifact refuses, before any scp, a .deb the pool's check never judged"
  else
    bad "installer_transfer_artifact with an unjudged .deb: $out $(tail -2 "$T/glue.out" | tr '\n' ' ')"
  fi
  : > "$T/glue.out"
  out=$(glue installer_transfer_artifact t "$T/debs/rhizo_0.2_amd64.deb" "$T/debs/rhizo_0.1_amd64.deb")
  if [[ "$out" == "RC=0 FAILED=0 SCP=1 "*"SENT=2" ]]; then
    ok "installer_transfer_artifact sends .debs the pool's check judged, and records them for the staging check"
  else
    bad "installer_transfer_artifact with judged .debs: $out $(tail -2 "$T/glue.out" | tr '\n' ' ')"
  fi
  unset -f glue stamp_case mkstub_deb judge_case

  M="$T/mirror"
  mkdir -p "$M/test/vm/start" "$M/test/vm/guest-os" "$M/test/system/lib" "$M/tools/build/packaging/deb" "$M/tools/fetch/pools/deb" "$M/bin"
  for f in start/start-sway.sh start/start-audio.sh start/render-node-relabel.sh guest-os/guest-os-lib.sh; do
    ln -s "$DEB_POOL_TOOLS/../../../../test/vm/$f" "$M/test/vm/$f"
  done
  ln -s "$DEB_POOL_TOOLS/../../../../test/system/lib/desk-user-lib.sh" "$M/test/system/lib/desk-user-lib.sh"
  ln -s "$DEB_POOL_TOOLS/deb-pool-lib.sh" "$M/tools/fetch/pools/deb/deb-pool-lib.sh"
  ln -s "$DEB_POOL_TOOLS/pools.tsv" "$M/tools/fetch/pools/deb/pools.tsv"
  ln -s "$DEB_POOL_TOOLS/../../../build/packaging/deb/deb-pool-plan.py" "$M/tools/build/packaging/deb/deb-pool-plan.py"
  printf '#!/bin/sh\nexit 0\n' > "$M/bin/scp"; chmod +x "$M/bin/scp"
  cp "$DEB_POOL_TOOLS/fixtures/common.sh" "$M/test/vm/common.sh"
  out=$(STUB_SSH_LOG="$T/ssh.log" PATH="$M/bin:$PATH" bash "$M/test/vm/start/start-sway.sh" --install-only 2>&1); rc=$?
  rm -f /tmp/sway-plan-deb-pool-selftest-* /tmp/sway-install-deb-pool-selftest-*
  if (( rc == 0 )) && grep -q -- "deb-pool-plan.py --pool /root/share/sway-debs --root sway --root swaybg --root grim --root wlrctl --root foot" "$T/ssh.log"; then
    ok "start-sway.sh installs a missing sway through the planner, with the sway pool's roots"
  else
    bad "start-sway.sh did not install through the planner (rc=$rc): $(tail -3 <<<"$out" | tr '\n' '|')"
  fi
  # shellcheck disable=SC2016
  if grep -qE 'dpkg -i \$want|sway_\*\.deb swaybg_\*\.deb' "$T/ssh.log"; then
    bad "start-sway.sh still hands dpkg -i pool files it picked itself: $(grep -m1 -E 'dpkg -i' "$T/ssh.log")"
  else
    ok "start-sway.sh never runs dpkg -i on pool files outside the plan"
  fi
  rm -f "$T/ssh.log" "$T/ssh.log.installed"
  out=$(RHIZO_GUEST_OS=cachyos STUB_SSH_LOG="$T/ssh.log" PATH="$M/bin:$PATH" \
        bash "$M/test/vm/start/start-sway.sh" --install-only 2>&1); rc=$?
  rm -f /tmp/sway-plan-deb-pool-selftest-* /tmp/sway-install-deb-pool-selftest-*
  if (( rc != 0 )) && grep -q 'for p in sway grim foot; do pacman -Qq' "$T/ssh.log" \
     && ! grep -qE 'dpkg-query|deb-pool-plan' "$T/ssh.log" && grep -q 'cachyos guest lacks sway' <<<"$out"; then
    ok "start-sway.sh on cachyos checks pacman -Qq sway grim foot and refuses a missing one without the deb pool"
  else
    bad "start-sway.sh on cachyos did not take the pacman arm (rc=$rc): $(tail -3 <<<"$out" | tr '\n' '|')"
  fi
  out=$(RHIZO_GUEST_OS=cachyos STUB_SSH_FAIL=1 STUB_SSH_LOG="$T/ssh.log" PATH="$M/bin:$PATH" \
        bash "$M/test/vm/start/start-sway.sh" --install-only 2>&1); rc=$?
  if (( rc != 0 )) && grep -q 'could not ask the cachyos guest' <<<"$out"; then
    ok "start-sway.sh on cachyos fails when the guest cannot be asked, rather than reading it as installed"
  else
    bad "start-sway.sh on cachyos took a failed ssh for an answer (rc=$rc): $(tail -3 <<<"$out" | tr '\n' '|')"
  fi
  rm -f "$T/ssh.log" "$T/ssh.log.installed"
  out=$(STUB_SSH_LOG="$T/ssh.log" PATH="$M/bin:$PATH" bash "$M/test/vm/start/start-audio.sh" --install-only 2>&1); rc=$?
  rm -f /tmp/pipewire-plan-deb-pool-selftest-* /tmp/pipewire-install-deb-pool-selftest-*
  if (( rc == 0 )) && grep -q -- "deb-pool-plan.py --pool /root/share/pipewire-debs --root pipewire --root pipewire-bin --root wireplumber" "$T/ssh.log"; then
    ok "start-audio.sh installs a missing pipewire through the planner, with the pipewire pool's roots"
  else
    bad "start-audio.sh did not install pipewire through the planner (rc=$rc): $(tail -3 <<<"$out" | tr '\n' '|')"
  fi
  # shellcheck disable=SC2016
  if grep -qE 'dpkg -i \$want|pipewire_\*\.deb pipewire-bin_' "$T/ssh.log"; then
    bad "start-audio.sh still hands dpkg -i pool files it picked itself: $(grep -m1 -E 'dpkg -i' "$T/ssh.log")"
  else
    ok "start-audio.sh never runs dpkg -i on pool files outside the plan"
  fi
  rm -f "$T/ssh.log" "$T/ssh.log.installed"
  out=$(STUB_SSH_FAIL=1 STUB_SSH_LOG="$T/ssh.log" PATH="$M/bin:$PATH" bash "$M/test/vm/start/start-audio.sh" --install-only 2>&1); rc=$?
  if (( rc != 0 )) && grep -q 'could not ask the guest which pipewire' <<<"$out" && ! grep -q 'deb-pool-plan' "$T/ssh.log"; then
    ok "start-audio.sh fails when the guest cannot be asked which pipewire packages it holds, rather than reading it as configured"
  else
    bad "start-audio.sh took a failed ssh for an answer (rc=$rc): $(tail -3 <<<"$out" | tr '\n' '|')"
  fi
  rm -f "$T/ssh.log" "$T/ssh.log.installed"
  if grep -q 'tools/fetch/pools/deb/fetch.sh sway-debs' "$DEB_POOL_TOOLS/../../../../test/vm/start/start-sway.sh"; then
    ok "start-sway.sh's no-pool hint names fetch.sh sway-debs"
  else
    bad "start-sway.sh's no-pool hint does not name tools/fetch/pools/deb/fetch.sh sway-debs"
  fi
  if [[ " $DEB_POOL_GNOME_ROOTS " == *" gjs "* ]]; then
    ok "the GNOME roots carry gjs, which org.gnome.Shell.Notifications (the owner of org.freedesktop.Notifications) runs under"
  else
    bad "the GNOME roots lack gjs: gnome-shell's org.gnome.Shell.Notifications service Execs /usr/bin/gjs, so no GNOME vm has a notification daemon"
  fi
  row="$(awk -F'\t' '$1 == "sway-debs" { print $3 "|" $4 }' "$DEB_POOL_TABLE")/$(awk -F'\t' '$1 == "gnome-debs" { print $3 "|" $4 }' "$DEB_POOL_TABLE")/"
  if [[ "$DEB_POOL_SWAY_ROOTS|${DEB_POOL_SWAY_ALLOW_UPGRADE:--}/$DEB_POOL_GNOME_ROOTS|${DEB_POOL_GNOME_ALLOW_UPGRADE:--}/" == "$row" ]]; then
    ok "the sway and gnome roots and declared upgrades are pools.tsv's rows, - read as none"
  else
    bad "the compositor roots are not pools.tsv's rows: sway [$DEB_POOL_SWAY_ROOTS|$DEB_POOL_SWAY_ALLOW_UPGRADE] gnome [$DEB_POOL_GNOME_ROOTS|$DEB_POOL_GNOME_ALLOW_UPGRADE], table $row"
  fi
  printf 'sway-debs\tderived\tsway foot\t-\ngnome-debs\tlisted\tgnome-shell\t-\n' > "$T/pools-listed.tsv"
  out=$( (deb_pool_load_roots "$T/pools-listed.tsv"; echo "rc=$? sway=${DEB_POOL_SWAY_ROOTS-unset} gnome=${DEB_POOL_GNOME_ROOTS-unset}") 2>&1)
  if [[ "$out" == *"gnome-debs is listed; a staged compositor pool is derived"*"rc=2 sway=sway foot gnome=unset" ]]; then
    ok "a compositor pool that is not derived is refused by name and its roots stay unset"
  else
    bad "deb_pool_load_roots on a listed gnome row: $out"
  fi
  printf 'gnome-debs\tderived\tgnome-shell\t-\n' > "$T/pools-nosway.tsv"
  out=$( (deb_pool_load_roots "$T/pools-nosway.tsv"; echo "rc=$? sway=${DEB_POOL_SWAY_ROOTS-unset}") 2>&1)
  if [[ "$out" == *"unknown pool 'sway-debs': $T/pools-nosway.tsv names gnome-debs"*"rc=2 sway=unset" ]]; then
    ok "a table without the sway row is refused by name and the sway roots stay unset"
  else
    bad "deb_pool_load_roots without a sway row: $out"
  fi
  mkdir -p "$T/badrow" && cp "$DEB_POOL_TOOLS/deb-pool-lib.sh" "$T/badrow/" \
    && sed 's/^stream-debs\tclosure\tvainfo vpx-tools\t-$/stream-debs\tclosure\tvainfo,vpx-tools\t-/' "$DEB_POOL_TABLE" > "$T/badrow/pools.tsv"
  out=$(env -i PATH="$PATH" bash -c 'source "$1"; echo "rc=$? stamp=$(declare -F deb_pool_stamp_problems >/dev/null && echo defined || echo undefined) var=${DEB_POOL_STAMP+set} sway=${DEB_POOL_SWAY_ROOTS-unset}"' _ "$T/badrow/deb-pool-lib.sh" 2>&1)
  if [[ "$out" == *"vainfo,vpx-tools"*"rc=2 stamp=defined var=set sway=unset" ]]; then
    ok "a bad row in any pool refuses the table by name, leaves the roots unset and still defines the whole library"
  else
    bad "sourcing the library over a table with a bad stream-debs row: $out"
  fi
  echo "deb-pool-lib selftest: $( (( BAD )) && echo FAIL || echo OK ) ($BAD failed)"
  exit $(( BAD > 0 ? 1 : 0 ))
fi

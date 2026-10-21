#!/bin/bash
# fetch the rhizo runtime package pool
set -uo pipefail
RRD_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# print the usage text
rrd_usage() {
  cat <<'EOF'
Usage: tools/fetch/pools/deb/runtime-debs.sh [--check | --selftest]
  (none)       derive, download the missing .debs, then check
  --check      download no .deb, exit 1 naming each difference (needs sudo -n and the pinned image; about a minute)
  --selftest   test the derivation, the check and the stamp
  --stamp-covers <pool>...  exit 1 naming each pool stamp that misses a .deb (no network, no sudo)
  --kernel-debs  print the Rhizo kernel .debs, the two meta packages and the versioned ones they pin, or exit 2 naming one missing
RHIZO_DEB_DIR and RHIZO_DEB_DIR_PREV name the .deb directories;
RHIZO_KERNEL_DEB_DIR names the Rhizo kernel's, by default RHIZO_DEB_DIR.
EOF
}
# shellcheck source=./deb-pool-lib.sh
source "$RRD_TOOLS/deb-pool-lib.sh"

RRD_OWN="rhizo linux-image-rhizo linux-headers-rhizo"
RRD_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
RRD_ONLINE_SOURCES=(
  "deb [arch=amd64 signed-by=$RRD_KEYRING] http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse"
  "deb [arch=amd64 signed-by=$RRD_KEYRING] http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse"
  "deb [arch=amd64 signed-by=$RRD_KEYRING] http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse"
)
RRD_APT_CONFIG=""

# create a private apt environment in a directory
rrd_apt_env() {
  local d="$1"
  shift
  mkdir -p "$d/lists/partial" "$d/sources.list.d" "$d/preferences.d" "$d/apt.conf.d" "$d/cache/archives/partial"
  printf '%s\n' "$@" > "$d/sources.list"
  : > "$d/extended_states"
  : > "$d/status.empty"
  printf '%s\n' \
    "Dir::Etc::Parts \"$d/apt.conf.d\";" "Dir::Etc::Main \"/dev/null\";" \
    "Dir::Etc::SourceList \"$d/sources.list\";" "Dir::Etc::SourceParts \"$d/sources.list.d\";" \
    "Dir::Etc::Preferences \"$d/preferences\";" "Dir::Etc::PreferencesParts \"$d/preferences.d\";" \
    "Dir::State::Lists \"$d/lists\";" "Dir::State::extended_states \"$d/extended_states\";" \
    "Dir::Cache \"$d/cache\";" 'Dir::Cache::pkgcache "";' 'Dir::Cache::srcpkgcache "";' \
    'Acquire::Languages "none";' 'APT::Architecture "amd64";' 'APT::Architectures { "amd64"; };' \
    'Debug::NoLocking "true";' 'APT::Install-Recommends "true";' 'APT::Install-Suggests "false";' \
    > "$d/apt.conf"
  RRD_APT_CONFIG="$d/apt.conf"
  if ! rrd_apt "$d/status.empty" update > "$d/update.log" 2>&1 || grep -qE '^(W|E):' "$d/update.log"; then
    echo "apt-get update over $(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(file:|[a-z]+:\/\/)/) printf "%s ", $i }' "$d/sources.list")failed: $(grep -E '^(W|E):' "$d/update.log" | head -3 | tr '\n' '|')" >&2
    return 2
  fi
}

# set up the private apt environment with the online sources
rrd_online_env() { rrd_apt_env "$1" "${RRD_ONLINE_SOURCES[@]}"; }

# run apt-get in the private apt environment
rrd_apt() {
  local status="$1"
  shift
  [[ -s "$RRD_APT_CONFIG" ]] || { echo "rrd_apt: no private apt environment (rrd_apt_env)" >&2; return 2; }
  APT_CONFIG="$RRD_APT_CONFIG" apt-get -o Dir::State::status="$status" "$@"
}

# run apt-cache in the private apt environment
rrd_apt_cache() {
  local status="$1"
  shift
  [[ -s "$RRD_APT_CONFIG" ]] || { echo "rrd_apt_cache: no private apt environment (rrd_apt_env)" >&2; return 2; }
  APT_CONFIG="$RRD_APT_CONFIG" apt-cache -o Dir::State::status="$status" "$@"
}

# print the highest version .deb
rrd_newest() {
  local best="" f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    if [[ -z "$best" ]] || dpkg --compare-versions "$(dpkg-deb -f "$f" Version)" gt "$(dpkg-deb -f "$best" Version)"; then
      best="$f"
    fi
  done
  printf '%s' "$best"
}

# print the directory of the Rhizo kernel .debs
rrd_kernel_dir() { printf '%s' "${RHIZO_KERNEL_DEB_DIR:-${RHIZO_DEB_DIR:-$RRD_TOOLS/../../../../var/debs}}"; }

# print the N and N-1 .deb sets
rrd_sets() {
  local label dir r k
  for label in N N-1; do
    if [[ "$label" == N ]]; then
      dir="${RHIZO_DEB_DIR:-$RRD_TOOLS/../../../../var/debs}"
    else
      dir="${RHIZO_DEB_DIR_PREV:-$RRD_TOOLS/../../../../var/debs/prev}"
    fi
    r=$(rrd_newest "$dir"/rhizo_*_amd64.deb)
    if [[ -z "$r" ]]; then
      if [[ "$label" == N ]]; then
        echo "[fetch-rhizo-runtime-debs] no N rhizo .deb in $dir -- tools/build/packaging/deb/debs.sh" >&2
      else
        echo "[fetch-rhizo-runtime-debs] no N-1 rhizo .deb in $dir -- tools/build/packaging/deb/debs.sh --at <N-1 ref> --out $dir builds one" >&2
      fi
      return 2
    fi
    if [[ "$label" == N-1 ]] && dpkg-deb -f "$r" Depends 2>/dev/null | grep -qE '(^|[ ,])rhizo-binder-modules([ ,(]|$)'; then
      echo "[fetch-rhizo-runtime-debs] N-1 $(basename "$r") depends on rhizo-binder-modules, which no longer exists -- pass a N-1 built after the kernel fold in $dir" >&2
      return 2
    fi
    if ! k=$(deb_pool_kernel_debs "$r" "$(rrd_kernel_dir)"); then
      echo "[fetch-rhizo-runtime-debs] the $label set lacks a Rhizo kernel .deb $(basename "$r") depends on (see above)" >&2
      return 2
    fi
    printf '%s\t%s' "$label" "$r"
    # shellcheck disable=SC2086
    [[ -z "$k" ]] || printf '\t%s' $k
    printf '\n'
  done
}

# write the apt closure for each .deb set
rrd_derive() {
  local status="$1" sets="$2" out="$3" label own f
  local -a row
  grep -q . "$sets" 2>/dev/null || { echo "no .debs to derive against ($sets is empty)" >&2; return 2; }
  mkdir -p "$out"
  : > "$out/inst.tsv"
  : > "$out/unmet.all"
  own=" $RRD_OWN "
  while IFS=$'\t' read -r -a row; do
    label=${row[0]}
    if ! rrd_apt "$status" install --dry-run "${row[@]:1}" > "$out/sim-$label.txt" 2>&1; then
      echo "apt cannot install the $label .debs: $(grep -E '^E: |but it is not| Depends: ' "$out/sim-$label.txt" | head -6 | tr -s ' ' | tr '\n' '|')" >&2
      return 2
    fi
    deb_pool_sim_inst "$out/sim-$label.txt" >> "$out/inst.tsv"
    deb_pool_unmet_recommends "$out/sim-$label.txt" >> "$out/unmet.all"
    for f in "${row[@]:1}"; do
      own+="$(dpkg-deb -f "$f" Package) " || { echo "dpkg-deb cannot read the Package of $f" >&2; return 2; }
    done
  done < "$sets"
  awk -F'\t' -v own="$own" 'index(own, " " $1 " ") == 0' "$out/inst.tsv" | sort -u > "$out/closure.tsv"
  sort -u "$out/unmet.all" > "$out/unmet"
}

# print the Provides of each closure package
rrd_closure_providers() {
  local pairs
  pairs=$(awk -F'\t' 'NF { print $1 "=" $2 }' "$2")
  [[ -n "$pairs" ]] || return 0
  # shellcheck disable=SC2086
  rrd_apt_cache "$1" show $pairs 2>/dev/null | awk -v RS= -F'\n' '{
    p = v = r = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^Package: /) p = substr($i, 10)
      else if ($i ~ /^Version: /) v = substr($i, 10)
      else if ($i ~ /^Provides: /) r = substr($i, 11)
    }
    if (p != "") print p "\t" v "\t" r
  }'
}

# print a .deb's package and version
rrd_deb_fields() {
  dpkg-deb -f "$1" Package Version Provides | awk '
    /^Package: / { p = substr($0, 10) } /^Version: / { v = substr($0, 10) } /^Provides: / { r = substr($0, 11) }
    END { print p "\t" v "\t" r }'
}

# print each unmet .deb dependency clause
rrd_clauses_unmet() {
  python3 -c '
import re, subprocess, sys
status, prov_file, own, debs = sys.argv[1], sys.argv[2], set(sys.argv[3].split()), sys.argv[4:]
ALT = re.compile(r"^\s*([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?\s*(?:\(\s*(<<|<=|=|>=|>>|<|>)\s*([^)\s]+)\s*\))?")
OPS = {"<<": "lt", "<=": "le", "=": "eq", ">=": "ge", ">>": "gt", "<": "le", ">": "ge"}
real, virt, cmp = {}, {}, {}

def add(name, ver, provides):
    real.setdefault(name, set()).add(ver)
    for part in filter(None, (x.strip() for x in (provides or "").split(","))):
        m = ALT.match(part)
        if m:
            virt.setdefault(m.group(1), set()).add(m.group(3) if m.group(2) == "=" else None)

def ok(have, op, want):
    if op is None:
        return True
    key = (have, op, want)
    if key not in cmp:
        cmp[key] = subprocess.run(["dpkg", "--compare-versions", have, OPS[op], want]).returncode == 0
    return cmp[key]

def met(name, op, ver):
    if any(ok(v, op, ver) for v in real.get(name, ())):
        return True
    if any(op is None or (pv is not None and ok(pv, op, ver)) for pv in virt.get(name, ())):
        return True
    return name in own and name not in real

with open(status) as f:
    for stanza in f.read().split("\n\n"):
        fields = dict(re.findall(r"^([A-Za-z-]+): ?(.*)$", stanza, re.M))
        if fields.get("Status", "").endswith(" installed"):
            add(fields.get("Package", ""), fields.get("Version", ""), fields.get("Provides"))
with open(prov_file) as f:
    for line in f:
        row = line.rstrip("\n").split("\t")
        if row and row[0]:
            add(row[0], row[1] if len(row) > 1 else "", row[2] if len(row) > 2 else "")
ctl = {}
for deb in debs:
    out = subprocess.run(["dpkg-deb", "-f", deb, "Package", "Version", "Provides", "Pre-Depends", "Depends", "Recommends"],
                         capture_output=True, text=True, check=True).stdout
    ctl[deb] = dict(re.findall(r"^([A-Za-z-]+): ?(.*)$", out, re.M))
    add(ctl[deb].get("Package", ""), ctl[deb].get("Version", ""), ctl[deb].get("Provides"))
for deb in debs:
    pkg = ctl[deb].get("Package", deb)
    for field in ("Pre-Depends", "Depends", "Recommends"):
        for clause in filter(None, (c.strip() for c in ctl[deb].get(field, "").split(","))):
            alts = [m.groups() for m in (ALT.match(a) for a in clause.split("|")) if m]
            if any(met(*a) for a in alts):
                continue
            only = sorted(f"{n} {v}" for n, _, _ in alts for v in real.get(n, ()))
            print(f"{pkg} {field}: {clause}" + (" -- only " + ", ".join(only) if only else ""))
' "$1" "$2" "$RRD_OWN" "${@:3}"
}

# build a flat apt repository from the pool
rrd_offline_src() {
  local pool="$1" d="$2" f
  mkdir -p "$d/repo"
  for f in "$pool"/*.deb; do
    [[ -e "$f" ]] && ln -s "$(readlink -f "$f")" "$d/repo/"
  done
  (cd "$d/repo" && dpkg-scanpackages -m . /dev/null > Packages 2>/dev/null) || return 2
  rrd_apt_env "$d" "deb [trusted=yes] file:$d/repo ./"
}

# print each difference between pool and closure
rrd_check() {
  local status="$1" sets="$2" pool="$3" w="$4" p f m r n=0
  local debs=() row=()
  while IFS=$'\t' read -r -a row; do debs+=("${row[@]:1}"); done < "$sets"
  rrd_online_env "$w/online-src" 2>&1 || return 2
  rrd_derive "$status" "$sets" "$w/online" || return 2
  rrd_closure_providers "$status" "$w/online/closure.tsv" > "$w/online/providers.tsv" || return 2
  while IFS= read -r p; do
    echo "the derived closure leaves unmet $p"; n=$((n + 1))
  done < <(rrd_clauses_unmet "$status" "$w/online/providers.tsv" "${debs[@]}")
  while IFS= read -r p; do
    echo "the closure needs $p at two versions: $(awk -F'\t' -v p="$p" '$1 == p { printf "%s ", $2 }' "$w/online/closure.tsv")"; n=$((n + 1))
  done < <(cut -f1 "$w/online/closure.tsv" | uniq -d)

  : > "$w/pool.tsv"
  for f in "$pool"/*.deb; do
    [[ -e "$f" ]] || continue
    printf '%s\t%s\n' "$(rrd_deb_fields "$f")" "$(basename "$f")" >> "$w/pool.tsv"
  done
  while IFS= read -r p; do
    echo "the pool holds two files of $p: $(awk -F'\t' -v p="$p" '$1 == p { printf "%s ", $4 }' "$w/pool.tsv")"; n=$((n + 1))
  done < <(cut -f1 "$w/pool.tsv" | sort | uniq -d)
  while IFS=$'\t' read -r p m r f; do
    case "$p" in
      lack) echo "the pool lacks $m $r, which the closure needs" ;;
      skew) echo "the pool holds $m ${f%%$'\t'*} (${f#*$'\t'}), but the closure needs $r" ;;
      extra) echo "the pool holds $m, which the closure does not need" ;;
    esac
    n=$((n + 1))
  done < <(awk -F'\t' '
    NR == FNR { need[$1] = $2; next }
    { have[$1] = $2; file[$1] = $4 }
    END {
      for (p in need) {
        if (!(p in have)) print "lack\t" p "\t" need[p]
        else if (have[p] != need[p]) print "skew\t" p "\t" need[p] "\t" have[p] "\t" file[p]
      }
      for (p in have) if (!(p in need)) print "extra\t" file[p]
    }' "$w/online/closure.tsv" "$w/pool.tsv" | sort)
  grep -v '^#' "$pool/UNMET-RECOMMENDS" 2>/dev/null | awk 'NF { print $1 }' | sort -u > "$w/unmet-recorded"
  if ! cmp -s "$w/unmet-recorded" "$w/online/unmet"; then
    echo "UNMET-RECOMMENDS records [$(tr '\n' ' ' < "$w/unmet-recorded")] but a connected host leaves [$(tr '\n' ' ' < "$w/online/unmet")] unmet"; n=$((n + 1))
  fi

  if ! rrd_offline_src "$pool" "$w/offline-src" 2> "$w/offline-src.err"; then
    echo "apt over the pool alone could not be set up: $(tr '\n' ' ' < "$w/offline-src.err")"; n=$((n + 1))
  elif ! rrd_derive "$status" "$sets" "$w/offline" 2> "$w/offline.err"; then
    echo "from the pool alone, $(tr '\n' ' ' < "$w/offline.err")"; n=$((n + 1))
  else
    while IFS=$'\t' read -r p m; do
      echo "a connected host installs $p $m; from the pool alone apt does not"; n=$((n + 1))
    done < <(comm -23 "$w/online/closure.tsv" "$w/offline/closure.tsv")
    while IFS=$'\t' read -r p m; do
      echo "from the pool alone apt installs $p $m, which a connected host does not"; n=$((n + 1))
    done < <(comm -13 "$w/online/closure.tsv" "$w/offline/closure.tsv")
    while IFS= read -r p; do
      echo "from the pool alone apt leaves the Recommends $p unmet, which a connected host installs"; n=$((n + 1))
    done < <(comm -13 "$w/online/unmet" "$w/offline/unmet")
    while IFS= read -r p; do
      echo "a connected host leaves the Recommends $p unmet; from the pool alone apt installs it"; n=$((n + 1))
    done < <(comm -23 "$w/online/unmet" "$w/offline/unmet")
  fi
  while IFS= read -r p; do
    echo "the image and the pool leave unmet $p"; n=$((n + 1))
  done < <(rrd_clauses_unmet "$status" <(cut -f1-3 "$w/pool.tsv") "${debs[@]}")
  (( n == 0 ))
}

# print the stamp's deb and pool rows
rrd_stamp_rows() {
  local f row=()
  while IFS=$'\t' read -r -a row; do
    for f in "${row[@]:1}"; do
      printf 'deb\t%s\t%s\t%s\n' "${row[0]}" "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"
    done
  done < "$2"
  deb_pool_stamp_files "$1"
}

# check the pool and write its stamp
rrd_check_and_stamp() {
  local status="$1" sets="$2" pool="$3" w="$4" image="$5" rc
  rrd_stamp_rows "$pool" "$sets" > "$w/stamp-before.tsv"
  rrd_check "$status" "$sets" "$pool" "$w"
  rc=$?
  if (( rc == 0 )); then
    rrd_stamp_rows "$pool" "$sets" > "$w/stamp-after.tsv"
    if ! cmp -s "$w/stamp-before.tsv" "$w/stamp-after.tsv"; then
      echo "the pool or the .debs changed while the check ran: $(diff "$w/stamp-before.tsv" "$w/stamp-after.tsv" | grep '^[<>]' | awk -F'\t' '{ print $NF }' | sort -u | tr '\n' ' ')"
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    deb_pool_stamp_write "$pool" "$image" "$w/stamp-before.tsv" || rc=2
  else
    rm -f "$pool/$DEB_POOL_STAMP"
  fi
  return "$rc"
}

# set the exit and signal traps
rrd_temp_cleanup() {
  RRD_TMP=""
  trap 'rm -f -- "${RRD_TMP:-}"; rm -rf -- "${W:-}"' EXIT
  trap 'rm -f -- "${RRD_TMP:-}"; exit 130' INT
  trap 'rm -f -- "${RRD_TMP:-}"; exit 143' TERM
  trap 'rm -f -- "${RRD_TMP:-}"; exit 129' HUP
}

# remove stray temp files from the pool
rrd_sweep_temps() {
  local t
  [[ -d "$1" ]] || return 0
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    rm -f -- "$t" && echo "[fetch-rhizo-runtime-debs] removed a stray temp a killed run left: $t"
  done < <(find "$1" -maxdepth 1 -type f -name '*.tmp.*' -print)
}

# copy a file into the pool
rrd_install_pool_file() {
  RRD_TMP="$2/$(basename "$1").tmp.$$"
  if ! cp "$1" "$RRD_TMP"; then
    rm -f -- "$RRD_TMP"
    RRD_TMP=""
    return 1
  fi
  mv -f "$RRD_TMP" "$2/$(basename "$1")" || { rm -f -- "$RRD_TMP"; RRD_TMP=""; return 1; }
  RRD_TMP=""
}

# download the closure .debs into the pool
rrd_fetch() {
  local closure="$1" unmet="$2" status="$3" pool="$4" work f p v base missing=()
  work=$(mktemp -d) || return 2
  mkdir -p "$pool"
  # shellcheck disable=SC2046
  if ! (cd "$work" && rrd_apt "$status" download $(awk -F'\t' '{ print $1 "=" $2 }' "$closure")) > "$work.log" 2>&1; then
    echo "[fetch-rhizo-runtime-debs] apt-get download failed: $(tail -4 "$work.log" | tr '\n' '|')" >&2
    rm -rf "$work" "$work.log"
    return 2
  fi
  printf 'package\tversion\tarch\tsha256\tfile\n' > "$pool/MANIFEST.tsv.new"
  while IFS=$'\t' read -r p v; do
    f=""
    for base in "$work"/"${p}"_*.deb; do
      [[ -e "$base" && "$(dpkg-deb -f "$base" Version)" == "$v" ]] && f="$base"
    done
    [[ -n "$f" ]] || { missing+=("$p=$v"); continue; }
    base=$(basename "$f")
    rrd_install_pool_file "$f" "$pool" || { rm -rf "$work" "$work.log"; return 2; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$v" "$(dpkg-deb -f "$f" Architecture)" \
      "$(sha256sum "$pool/$base" | cut -d' ' -f1)" "$base" >> "$pool/MANIFEST.tsv.new"
  done < "$closure"
  rm -rf "$work" "$work.log"
  mv "$pool/MANIFEST.tsv.new" "$pool/MANIFEST.tsv"
  for f in "$pool"/*.deb; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f")
    awk -F'\t' -v b="$base" 'NR > 1 && $5 == b { found = 1 } END { exit !found }' "$pool/MANIFEST.tsv" && continue
    rm -f -- "$f" || { echo "[fetch-rhizo-runtime-debs] could not remove $base, which the closure no longer names" >&2; return 2; }
    echo "[fetch-rhizo-runtime-debs] removed $base: the closure no longer names it"
  done
  { echo "# Recommends apt leaves uninstalled on a CONNECTED host too; the only ones a vm's"
    echo "# offline install may leave unmet (installer-lib.sh). Derived; never edit by hand."
    cat "$unmet"; } > "$pool/UNMET-RECOMMENDS"
  (( ${#missing[@]} == 0 )) || { echo "[fetch-rhizo-runtime-debs] apt-get download produced no .deb for: ${missing[*]}" >&2; return 1; }
}

# print the check problems and summary
rrd_report() {
  local rc="$1"
  sed 's/^/[fetch-rhizo-runtime-debs]   /' "$2"
  case "$rc" in
    0) echo "[fetch-rhizo-runtime-debs] $3 holds the whole closure ($(find "$3" -maxdepth 1 -name '*.deb' | wc -l) packages), apt installs every set from it alone, and $DEB_POOL_STAMP names what was checked" ;;
    1) echo "[fetch-rhizo-runtime-debs] $3 differs from the closure in $(wc -l < "$2") way(s); no $DEB_POOL_STAMP, so no vm stages it" ;;
    *) echo "[fetch-rhizo-runtime-debs] could not check $3; no $DEB_POOL_STAMP, so no vm stages it" ;;
  esac
  return "$rc"
}

# run the selftest against fixture packages
rrd_selftest() {
  local T bad=0 out rc p name ver prov pin kind
  T=$(mktemp -d) || return 1
  RRD_SELFTEST_DIR="$T"
  trap 'rm -rf "$RRD_SELFTEST_DIR"' EXIT
  ok() { echo "SELFTEST OK: $1"; }
  nok() { echo "SELFTEST FAIL: $1"; bad=$((bad + 1)); }
  mkdeb() {
    local d="$T/src/${2}_$3_${1##*/}" arch="${MKDEB_ARCH:-all}"
    mkdir -p "$d/DEBIAN" "$1"
    { echo "Package: $2"; echo "Version: $3"; echo "Architecture: $arch"
      echo "Maintainer: selftest <selftest@invalid>"
      [[ -z "${4:-}" ]] || echo "Depends: $4"
      [[ -z "${5:-}" ]] || echo "Recommends: $5"
      [[ -z "${6:-}" ]] || echo "Provides: $6"
      echo "Description: selftest fixture"; } > "$d/DEBIAN/control"
    dpkg-deb -Znone --build "$d" "$1/${2}_${3}_$arch.deb" >/dev/null
  }
  mkdeb "$T/archive" libdep 1.0 "libupg (>= 2.0)"
  mkdeb "$T/archive" libupg 2.0
  mkdeb "$T/archive" librec 1.0 librec-dep ghost
  mkdeb "$T/archive" librec-dep 1.0
  mkdeb "$T/archive" libold 2.0
  mkdeb "$T/archive" libother 1.0
  mkdeb "$T/archive" kdep 1.0
  (cd "$T/archive" && dpkg-scanpackages -m . /dev/null > Packages 2>/dev/null)
  mkdir -p "$T/img"
  for p in base:1.0: libupg:1.0: libold:1.0: hdr-generic:1.0:linux-headers; do
    IFS=: read -r name ver prov <<<"$p"
    printf 'Package: %s\nStatus: install ok installed\nVersion: %s\nArchitecture: all\n' "$name" "$ver"
    [[ -z "$prov" ]] || printf 'Provides: %s\n' "$prov"
    printf 'Maintainer: x <x@invalid>\nDescription: x\n\n'
  done > "$T/img/status"
  MKDEB_ARCH=amd64 mkdeb "$T/debs" rhizo 0.2 "libdep, base, hdr-generic | linux-headers" "librec, rhizo-addon, libold (>= 2.0)"
  MKDEB_ARCH=amd64 mkdeb "$T/prev" rhizo 0.1 "libdep, base" rhizo-addon
  RRD_ONLINE_SOURCES=("deb [trusted=yes] file:$T/archive ./")
  RRD_OWN="$RRD_OWN rhizo-addon"
  pin=$(deb_pool_image_pin) || { nok "deb_pool_image_pin read no pin from ubuntu-base.sh"; return 1; }

  if RHIZO_DEB_DIR="$T/debs" RHIZO_DEB_DIR_PREV="$T/prev" rrd_sets > "$T/sets" 2>/dev/null \
      && [[ "$(cut -f1,2 "$T/sets" | tr '\t\n' '  ')" == "N $T/debs/rhizo_0.2_amd64.deb N-1 $T/prev/rhizo_0.1_amd64.deb " ]]; then
    ok "rrd_sets finds N and N-1"
  else
    nok "rrd_sets: $(cat "$T/sets")"
  fi
  mkdir -p "$T/noprev"
  out=$(RHIZO_DEB_DIR="$T/debs" RHIZO_DEB_DIR_PREV="$T/noprev" rrd_sets 2>&1 >/dev/null); rc=$?
  if (( rc == 2 )) && [[ "$out" == *"no N-1 rhizo .deb in $T/noprev"* ]]; then
    ok "rrd_sets exits 2 naming a missing N-1, never a closure for N alone"
  else
    nok "rrd_sets with no N-1: rc=$rc $out"
  fi
  MKDEB_ARCH=amd64 mkdeb "$T/oldprev" rhizo 0.1 "libdep, rhizo-binder-modules (>= 0.1.2), base"
  out=$(RHIZO_DEB_DIR="$T/debs" RHIZO_DEB_DIR_PREV="$T/oldprev" rrd_sets 2>&1 >/dev/null); rc=$?
  if (( rc == 2 )) && [[ "$out" == *"N-1 rhizo_0.1_amd64.deb depends on rhizo-binder-modules, which no longer exists"* ]]; then
    ok "rrd_sets exits 2 naming a N-1 that depends on rhizo-binder-modules"
  else
    nok "rrd_sets with a N-1 depending on rhizo-binder-modules: rc=$rc $out"
  fi

  if ! rrd_online_env "$T/online" 2> "$T/online.err"; then
    nok "rrd_online_env over the fixture archive failed: $(cat "$T/online.err")"
    return 1
  fi
  apt-config dump > "$T/host.dump" 2>&1
  APT_CONFIG="$RRD_APT_CONFIG" apt-config dump > "$T/env.dump" 2>&1
  if ! grep -q '^APT::NeverAutoRemove' "$T/host.dump"; then
    nok "this host's apt config has no APT::NeverAutoRemove to show rrd_apt_env leaves out"
  elif grep -qiE '^Dir::Etc::sourcelist "'"$T"'/online/sources.list";' "$T/env.dump" \
      && ! grep -q '^APT::NeverAutoRemove' "$T/env.dump"; then
    ok "rrd_apt_env reads its own sources and none of this host's apt.conf.d"
  else
    nok "rrd_apt_env leaks this host's apt config: $(grep -i 'sourcelist\|parts\|NeverAutoRemove' "$T/env.dump" | head -4 | tr '\n' '|')"
  fi
  rrd_derive "$T/img/status" "$T/sets" "$T/d" 2> "$T/d.err"; rc=$?
  out=$(tr '\n' ' ' < "$T/d/closure.tsv")
  if (( rc == 0 )) && [[ "$out" == $'libdep\t1.0 libold\t2.0 librec\t1.0 librec-dep\t1.0 libupg\t2.0 ' ]]; then
    ok "rrd_derive finds a Depends, the upgrade it needs, a Recommends and its Depends, a versioned Recommends' upgrade, and leaves our own packages out"
  else
    nok "rrd_derive: rc=$rc closure=[$out] $(cat "$T/d.err")"
  fi
  if [[ "$(tr '\n' ' ' < "$T/d/unmet")" == "ghost rhizo-addon " ]]; then
    ok "rrd_derive records the Recommends a connected host leaves unmet"
  else
    nok "rrd_derive unmet: $(tr '\n' ' ' < "$T/d/unmet")"
  fi
  for kind in image headers; do
    MKDEB_ARCH=amd64 mkdeb "$T/kernel" "linux-$kind-9.9.9-rhizo" 9.9.9-1 kdep
    MKDEB_ARCH=amd64 mkdeb "$T/kernel" "linux-$kind-rhizo" 9.9.9-1 "linux-$kind-9.9.9-rhizo (= 9.9.9-1)"
  done
  MKDEB_ARCH=amd64 mkdeb "$T/kn" rhizo 0.3 "libdep, linux-image-rhizo, linux-headers-rhizo"
  if RHIZO_DEB_DIR="$T/kn" RHIZO_DEB_DIR_PREV="$T/prev" RHIZO_KERNEL_DEB_DIR="$T/kernel" rrd_sets > "$T/ksets" 2>"$T/ksets.err" \
      && [[ "$(awk -F'\t' '$1 == "N" { for (i = 3; i <= NF; i++) { n = $i; sub(/.*\//, "", n); printf "%s ", n } }' "$T/ksets")" \
            == "linux-headers-rhizo_9.9.9-1_amd64.deb linux-headers-9.9.9-rhizo_9.9.9-1_amd64.deb linux-image-rhizo_9.9.9-1_amd64.deb linux-image-9.9.9-rhizo_9.9.9-1_amd64.deb " ]] \
      && [[ "$(awk -F'\t' '$1 == "N-1" { print NF }' "$T/ksets")" == 2 ]]; then
    ok "rrd_sets adds the two Rhizo kernel meta .debs and the versioned .debs they pin to the set whose rhizo .deb depends on them, and none to the one that does not"
  else
    nok "rrd_sets with a kernel-dependent N: $(tr '\t\n' ' |' < "$T/ksets") $(cat "$T/ksets.err")"
  fi
  mkdir -p "$T/kernel-nopin"
  cp "$T/kernel"/linux-image-*.deb "$T/kernel/linux-headers-rhizo_9.9.9-1_amd64.deb" "$T/kernel-nopin/"
  out=$(RHIZO_DEB_DIR="$T/kn" RHIZO_DEB_DIR_PREV="$T/prev" RHIZO_KERNEL_DEB_DIR="$T/kernel-nopin" rrd_sets 2>&1 >/dev/null); rc=$?
  if (( rc == 2 )) && [[ "$out" == *"pins linux-headers-9.9.9-rhizo (= 9.9.9-1), and $T/kernel-nopin holds no linux-headers-9.9.9-rhizo_9.9.9-1_*.deb"* ]]; then
    ok "rrd_sets exits 2 naming the versioned kernel .deb a meta .deb pins and the directory lacks"
  else
    nok "rrd_sets with no versioned headers .deb: rc=$rc $out"
  fi
  cp -a "$T/kernel" "$T/kernel-junk"
  echo junk > "$T/kernel-junk/linux-image-rhizo_9.9.10-1_amd64.deb"
  if RHIZO_DEB_DIR="$T/kn" RHIZO_DEB_DIR_PREV="$T/prev" RHIZO_KERNEL_DEB_DIR="$T/kernel-junk" rrd_sets > "$T/ksets-junk" 2>"$T/ksets-junk.err" \
      && grep -q "/linux-image-rhizo_9.9.9-1_amd64.deb" "$T/ksets-junk" \
      && grep -q "skipping $T/kernel-junk/linux-image-rhizo_9.9.10-1_amd64.deb, which dpkg-deb cannot read" "$T/ksets-junk.err"; then
    ok "rrd_sets names a kernel .deb dpkg-deb cannot read and takes the newest readable one"
  else
    nok "rrd_sets beside an unreadable kernel .deb: $(tr '\t\n' ' |' < "$T/ksets-junk") $(cat "$T/ksets-junk.err")"
  fi
  rrd_derive "$T/img/status" "$T/ksets" "$T/dk" 2> "$T/dk.err"; rc=$?
  out=$(cut -f1 "$T/dk/closure.tsv" 2>/dev/null | tr '\n' ' ')
  if (( rc == 0 )) && [[ "$out" == "kdep libdep libupg " ]]; then
    ok "rrd_derive puts the kernel .debs' own Depends in the closure and leaves the kernel packages out as our own"
  else
    nok "rrd_derive over a kernel-dependent set: rc=$rc closure=[$out] $(cat "$T/dk.err")"
  fi
  if [[ "$(rrd_stamp_rows "$T/kernel" "$T/ksets" | awk -F'\t' '$1 == "deb" && $2 == "N" { n++ } END { print n + 0 }')" == 5 ]]; then
    ok "rrd_stamp_rows names every .deb of the kernel-dependent set, the kernel's four included"
  else
    nok "rrd_stamp_rows over a kernel-dependent set: $(rrd_stamp_rows "$T/kernel" "$T/ksets" | grep $'^deb\t' | tr '\t\n' ' |')"
  fi
  rrd_closure_providers "$T/img/status" "$T/d/closure.tsv" > "$T/providers.tsv"
  out=$(rrd_clauses_unmet "$T/img/status" "$T/providers.tsv" "$T/debs/rhizo_0.2_amd64.deb")
  if [[ -z "$out" && "$(wc -l < "$T/providers.tsv")" == 5 ]]; then
    ok "rrd_clauses_unmet passes a closure that meets every clause (an alternative met by Provides, a versioned Recommends by the upgrade)"
  else
    nok "rrd_clauses_unmet refused a complete closure: $out ($(wc -l < "$T/providers.tsv") provider rows)"
  fi
  grep -v '^librec	' "$T/providers.tsv" > "$T/providers-norec.tsv"
  out=$(rrd_clauses_unmet "$T/img/status" "$T/providers-norec.tsv" "$T/debs/rhizo_0.2_amd64.deb")
  if [[ "$out" == "rhizo Recommends: librec" ]]; then
    ok "rrd_clauses_unmet names a Recommends the closure dropped, read from the control field"
  else
    nok "rrd_clauses_unmet missed a dropped Recommends: [$out]"
  fi
  grep -v '^libold	' "$T/providers.tsv" > "$T/providers-noold.tsv"
  out=$(rrd_clauses_unmet "$T/img/status" "$T/providers-noold.tsv" "$T/debs/rhizo_0.2_amd64.deb")
  if [[ "$out" == "rhizo Recommends: libold (>= 2.0) -- only libold 1.0" ]]; then
    ok "rrd_clauses_unmet names a versioned Recommends the image's older copy does not meet"
  else
    nok "rrd_clauses_unmet passed a versioned Recommends on the image's libold 1.0: [$out]"
  fi

  if rrd_fetch "$T/d/closure.tsv" "$T/d/unmet" "$T/img/status" "$T/pool" 2> "$T/fetch.err" \
      && [[ "$(LC_ALL=C ls "$T/pool" | tr '\n' ' ')" == "MANIFEST.tsv UNMET-RECOMMENDS libdep_1.0_all.deb libold_2.0_all.deb librec-dep_1.0_all.deb librec_1.0_all.deb libupg_2.0_all.deb " ]]; then
    ok "rrd_fetch downloads exactly the closure, with its manifest and unmet record"
  else
    nok "rrd_fetch: $(ls "$T/pool" 2>&1 | tr '\n' ' ') $(cat "$T/fetch.err")"
  fi
  rm -rf "$T/pool-superseded"; cp -a "$T/pool" "$T/pool-superseded"
  cp "$T/pool/libold_2.0_all.deb" "$T/pool-superseded/libold_1.5_all.deb"
  if rrd_fetch "$T/d/closure.tsv" "$T/d/unmet" "$T/img/status" "$T/pool-superseded" > "$T/fetch2.out" 2> "$T/fetch2.err" \
      && [[ ! -e "$T/pool-superseded/libold_1.5_all.deb" && -e "$T/pool-superseded/libold_2.0_all.deb" ]] \
      && grep -q 'removed libold_1.5_all.deb' "$T/fetch2.out"; then
    ok "rrd_fetch removes a .deb the closure no longer names and keeps the one it does"
  else
    nok "rrd_fetch left a superseded .deb or removed a needed one: $(ls "$T/pool-superseded" 2>&1 | tr '\n' ' ') $(cat "$T/fetch2.err")"
  fi

  copy_pool() { rm -rf "${T:?}/${1:?}"; cp -a "$T/pool" "$T/$1"; }
  check_case() {
    local o r want miss=""
    rm -rf "$T/w"; mkdir -p "$T/w"
    o=$(rrd_check_and_stamp "$T/img/status" "$T/sets" "$2" "$T/w" "$pin"); r=$?
    if (( $# == 2 )); then
      if (( r == 0 )) && [[ -z "$o" && -f "$2/$DEB_POOL_STAMP" ]]; then ok "rrd_check passes and stamps $1"
      else nok "rrd_check refused $1: rc=$r stamp=$( [[ -f "$2/$DEB_POOL_STAMP" ]] && echo yes || echo no) $o"; fi
      return
    fi
    for want in "${@:3}"; do [[ "$o" == *"$want"* ]] || miss+=" '$want'"; done
    if (( r == 1 )) && [[ -z "$miss" && ! -e "$2/$DEB_POOL_STAMP" ]]; then
      ok "rrd_check names $1, and leaves no stamp"
    else
      nok "rrd_check on $1: rc=$r, stamp=$( [[ -e "$2/$DEB_POOL_STAMP" ]] && echo left || echo none), missing$miss: $o"
    fi
  }
  check_case "the fetched pool" "$T/pool"
  out=$(deb_pool_stamp_problems "$T/pool" "$T/debs/rhizo_0.2_amd64.deb" "$T/prev/rhizo_0.1_amd64.deb"); rc=$?
  if (( rc == 0 )) && [[ -z "$out" ]] && grep -q $'^deb\tN-1\t' "$T/pool/$DEB_POOL_STAMP" \
      && grep -q $'^pool\t[0-9a-f]\\{64\\}\tUNMET-RECOMMENDS$' "$T/pool/$DEB_POOL_STAMP"; then
    ok "the stamp a passing check writes names the N and N-1 .debs and every pool file, and verifies"
  else
    nok "the passing check's stamp does not verify: rc=$rc $out"
  fi
  copy_pool pool-norec; rm "$T/pool-norec"/librec_*.deb
  check_case "a pool that dropped a Recommends, by apt over the pool alone and by the control field" "$T/pool-norec" \
    "from the pool alone apt leaves the Recommends librec unmet, which a connected host installs" \
    "the image and the pool leave unmet rhizo Recommends: librec"
  copy_pool pool-noold; rm "$T/pool-noold"/libold_*.deb
  check_case "a pool lacking the upgrade a versioned Recommends on an image package needs" "$T/pool-noold" \
    "the image and the pool leave unmet rhizo Recommends: libold (>= 2.0) -- only libold 1.0"
  copy_pool pool-nodep; rm "$T/pool-nodep"/libdep_*.deb
  check_case "a pool that dropped a Depends" "$T/pool-nodep" "from the pool alone, apt cannot install the N .debs"
  copy_pool pool-extra; cp "$T/archive"/libother_*.deb "$T/pool-extra/"
  check_case "a pool holding a file the closure does not need" "$T/pool-extra" \
    "the pool holds libother_1.0_all.deb, which the closure does not need"
  copy_pool pool-skew; rm "$T/pool-skew"/libdep_*.deb; mkdeb "$T/pool-skew" libdep 0.9 "libupg (>= 2.0)"
  check_case "a pool holding a closure package at another version, by version and by apt over the pool alone" "$T/pool-skew" \
    "the pool holds libdep 0.9 (libdep_0.9_all.deb), but the closure needs 1.0" \
    "a connected host installs libdep 1.0; from the pool alone apt does not" \
    "from the pool alone apt installs libdep 0.9, which a connected host does not"
  copy_pool pool-outdated; grep -vx ghost "$T/pool/UNMET-RECOMMENDS" > "$T/pool-outdated/UNMET-RECOMMENDS"
  check_case "an outdated UNMET-RECOMMENDS" "$T/pool-outdated" "UNMET-RECOMMENDS records [rhizo-addon ]"
  cp -a "$T/archive" "$T/archive2"; mkdeb "$T/archive2" libdep 1.1 "libupg (>= 2.0)"
  (cd "$T/archive2" && dpkg-scanpackages -m . /dev/null > Packages 2>/dev/null)
  RRD_ONLINE_SOURCES=("deb [trusted=yes] file:$T/archive2 ./")
  copy_pool pool-moved
  check_case "a pool fetched before the archive moved on" "$T/pool-moved" \
    "the pool holds libdep 1.0 (libdep_1.0_all.deb), but the closure needs 1.1"
  RRD_ONLINE_SOURCES=("deb [trusted=yes] file:$T/archive ./")
  rm -rf "$T/w"; mkdir -p "$T/w"
  rrd_check_and_stamp "$T/img/status" "$T/sets" "$T/pool" "$T/w" "${pin//?/0}" > /dev/null
  out=$(deb_pool_stamp_problems "$T/pool" "$T/debs/rhizo_0.2_amd64.deb"); rc=$?
  if (( rc == 1 )) && [[ "$out" == *"was checked against image ${pin//?/0}, not the pin $pin"* ]]; then
    ok "a stamp written for another image than the pin does not verify"
  else
    nok "a stamp for image ${pin//?/0} verified: rc=$rc $out"
  fi
  rrd_check_and_stamp "$T/img/status" "$T/sets" "$T/pool" "$T/w" "$pin" > /dev/null
  grep -v $'^deb\tN-1\t' "$T/pool/$DEB_POOL_STAMP" > "$T/stamp-n" && mv "$T/stamp-n" "$T/pool/$DEB_POOL_STAMP"
  out=$(deb_pool_stamp_problems "$T/pool" "$T/debs/rhizo_0.2_amd64.deb"); rc=$?
  if (( rc == 1 )) && [[ "$out" == *"names no N-1 .deb"* ]]; then
    ok "a stamp naming no N-1 .deb does not verify"
  else
    nok "a stamp with no N-1 row verified: rc=$rc $out"
  fi
  : > "$T/no-sets"
  rm -rf "$T/w"; mkdir -p "$T/w"
  rrd_check "$T/img/status" "$T/no-sets" "$T/pool" "$T/w" > /dev/null 2>&1; rc=$?
  if (( rc == 2 )); then
    ok "rrd_check cannot pass with no .debs to derive against (rc=2, never an empty closure that matches)"
  else
    nok "rrd_check with no .debs returned rc=$rc, not 2"
  fi
  RRD_APT_CONFIG=""
  echo "fetch-rhizo-runtime-debs selftest: $( (( bad )) && echo FAIL || echo OK ) ($bad failed)"
  (( bad == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  mode="${1:-}"
  case "$mode" in
    --selftest) rrd_selftest; exit $? ;;
    --stamp-covers)
      shift
      (( $# )) || { echo "fetch-rhizo-runtime-debs: --stamp-covers needs at least one pool dir" >&2; exit 2; }
      sets=$(rrd_sets) || exit 1
      stamp_debs=$(cut -f2- <<<"$sets" | tr '\t' '\n')
      bad=0
      for pool in "$@"; do
        # shellcheck disable=SC2086
        if ! out=$(deb_pool_stamp_problems "$pool" $stamp_debs); then
          printf '%s: %s\n' "$pool" "$(tr '\n' ';' <<<"$out" | sed 's/;$//')"
          bad=1
        fi
      done
      exit "$bad" ;;
    --kernel-debs)
      for meta in linux-image-rhizo linux-headers-rhizo; do
        deb_pool_kernel_meta_debs "$meta" "$(rrd_kernel_dir)" || exit 2
      done
      exit 0 ;;
    ""|--check|--check-derivation) ;;
    *) rrd_usage >&2; exit 2 ;;
  esac
  POOL="$RRD_TOOLS/../../../../var/share/runtime-debs"
  W=$(mktemp -d) || exit 2
  rrd_temp_cleanup
  rrd_sweep_temps "$POOL"
  rrd_sets > "$W/sets" || exit 2
  deb_pool_pristine_admindir "$W/img" || exit 2
  STATUS="$W/img/admin/status"
  if [[ -z "$mode" ]]; then
    rrd_online_env "$W/online-src" || exit 2
    if ! rrd_derive "$STATUS" "$W/sets" "$W/derive"; then
      echo "[fetch-rhizo-runtime-debs] apt cannot resolve the .debs against the pinned image" >&2
      exit 1
    fi
    rrd_closure_providers "$STATUS" "$W/derive/closure.tsv" > "$W/derive/providers.tsv" || exit 2
    # shellcheck disable=SC2046
    unmet=$(rrd_clauses_unmet "$STATUS" "$W/derive/providers.tsv" $(cut -f2- "$W/sets"))
    if [[ -n "$unmet" ]]; then
      echo "[fetch-rhizo-runtime-debs] the derivation leaves these clauses unmet, so nothing was downloaded:" >&2
      sed 's/^/  /' <<<"$unmet" >&2
      rm -f "$POOL/$DEB_POOL_STAMP"
      exit 1
    fi
    echo "[fetch-rhizo-runtime-debs] the closure: $(wc -l < "$W/derive/closure.tsv") package(s); a connected host leaves unmet: $(tr '\n' ' ' < "$W/derive/unmet")"
    rrd_fetch "$W/derive/closure.tsv" "$W/derive/unmet" "$STATUS" "$POOL" || { rm -f "$POOL/$DEB_POOL_STAMP"; exit 1; }
  fi
  mkdir -p "$W/check"
  rrd_check_and_stamp "$STATUS" "$W/sets" "$POOL" "$W/check" "$(cat "$W/img/image.sha256")" > "$W/problems"
  rrd_report $? "$W/problems" "$POOL"
fi

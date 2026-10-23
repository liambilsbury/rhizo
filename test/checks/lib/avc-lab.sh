#!/bin/bash
# query a denial capture against a lab policy
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

INTERNAL_SCRATCH=()
trap 'rm -rf "${INTERNAL_SCRATCH[@]}"' EXIT

ARGS=("$@")
set -- -h
source ./policy-lab.sh >/dev/null
set -- "${ARGS[@]}"

LAB_DIR="$VAR_DIR/scratch/policy-lab-scratch-avc-lab-$(_gsi_img_key)"

# check for an installed binary
require_tool() {
  command -v "$1" >/dev/null && return 0
  fail "$1 not found -- apt install $2"
  return 1
}

# drop nlmsg extended-permission rules from a CIL file
strip_nlmsg_xperms() {
  local in="$1" out="$2" before after
  before=$(grep -cE '^[[:space:]]*\((allowx|neverallowx|dontauditx|auditallowx)[[:space:]].*\(nlmsg[[:space:]]' "$in")
  grep -vE '^[[:space:]]*\((allowx|neverallowx|dontauditx|auditallowx)[[:space:]].*\(nlmsg[[:space:]]' "$in" > "$out" || return 1
  after=$(grep -cE '^[[:space:]]*\((allowx|neverallowx|dontauditx|auditallowx)[[:space:]].*\(nlmsg[[:space:]]' "$out")
  if (( after != 0 )); then
    fail "$after nlmsg rule(s) survived the strip of $in"
    return 1
  fi
  echo "$before"
}

# drop a policycap declaration from a file
strip_policycap() {
  local file="$1" name="$2"
  local tmp="$file.strip"
  if ! grep -qE "^[[:space:]]*\(policycap $name\)[[:space:]]*\$" "$file"; then
    fail "secilc named policycap $name but $file declares no such line"
    return 1
  fi
  grep -vE "^[[:space:]]*\(policycap $name\)[[:space:]]*\$" "$file" > "$tmp" || return 1
  mv -f "$tmp" "$file"
}

# print the policycap name from secilc stderr
bad_policycap() {
  sed -n 's/^Invalid policycap (\([A-Za-z0-9_]*\)).*/\1/p' "$1" | head -1
}

# print the unique tails of deny rules
deny_tails() {
  grep -E '^[[:space:]]*\(deny [A-Za-z0-9_]+ ' "$1" \
    | sed -E 's/^[[:space:]]*\(deny [A-Za-z0-9_]+ //' \
    | sort -u
}

# drop all of the deny rules and print the count
strip_deny() {
  local in="$1" out="$2" before after
  before=$(grep -cE '^[[:space:]]*\(deny [A-Za-z0-9_]+ ' "$in")
  grep -vE '^[[:space:]]*\(deny [A-Za-z0-9_]+ ' "$in" > "$out" || return 1
  after=$(grep -cE '^[[:space:]]*\(deny [A-Za-z0-9_]+ ' "$out")
  if (( after != 0 )); then
    fail "$after deny rule(s) survived the strip of $in"
    return 1
  fi
  echo "$before"
}

# delete ERE matches from a file
drop_lines() {
  grep -vE "$2" "$1" > "$1.next"
  (( $? <= 1 )) || return 1
  mv -f "$1.next" "$1"
}

# drop neverallow guards for the deny tails
strip_deny_guards() {
  local file="$1"; shift
  local tmp="$file.strip" tail esc attr n=0 stripped=" "
  cp "$file" "$tmp" || return 1
  for tail in "$@"; do
    [[ -n "$tail" ]] || continue
    esc=$(printf '%s' "$tail" | sed 's/[()]/\\&/g')
    attr=$(grep -E "^[[:space:]]*\(neverallow [A-Za-z0-9_]+ ${esc}\$" "$tmp" \
      | sed -E 's/^[[:space:]]*\(neverallow ([A-Za-z0-9_]+) .*/\1/')
    [[ -n "$attr" ]] || continue
    if [[ "$stripped" != *" $attr "* ]]; then
      if ! grep -qE "^[[:space:]]*\(typeattribute ${attr}\)[[:space:]]*\$" "$tmp"; then
        fail "found (neverallow $attr ...) guarding a stripped deny but no (typeattribute $attr) declaration to match it in $file"
        return 1
      fi
      drop_lines "$tmp" "^[[:space:]]*\(typeattribute ${attr}\)[[:space:]]*\$" || return 1
      drop_lines "$tmp" "^[[:space:]]*\(typeattributeset ${attr} .*\)[[:space:]]*\$" || return 1
      stripped+="$attr "
    fi
    drop_lines "$tmp" "^[[:space:]]*\(neverallow ${attr} ${esc}\$" || return 1
    log "WARNING: policy.lab weakened to compile -- dropped guard (neverallow $attr $tail) and its typeattribute; policy.lab now allows what the real boot policy denies"
    n=$((n + 1))
  done
  mv -f "$tmp" "$file" || return 1
  echo "$n"
}

# print denial lines in auditd record form
avc_records() {
  local capture="$1" domain="${2:-}" lines
  lines=$(grep -a 'avc:  denied' "$capture")
  if [[ -n "$domain" ]]; then
    lines=$(grep -a "scontext=u:r:$domain:" <<<"$lines")
  fi
  [[ -n "$lines" ]] || return 0
  sed 's/^\[[^]]*\] audit: type=1400 audit(\([^)]*\)): /type=AVC msg=audit(\1): /' <<<"$lines"
}

# build policy.lab from the CIL files
cmd_build() {
  local out_dir="" keep_deny=0 compiler=secilc
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out_dir="$2"; shift 2 ;;
      --keep-deny) keep_deny=1; shift ;;
      --render)
        # shellcheck disable=SC2034
        RENDER_CIL="$2"; shift 2 ;;
      *) echo "build: unknown arg: $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$out_dir" ]] || out_dir="$LAB_DIR"
  if (( keep_deny )); then
    compiler="$SECILC"
    [[ -x "$compiler" ]] || { fail "no $compiler -- run test/checks/lib/policy-lab.sh once to fetch the GSI's secilc"; return 1; }
  else
    require_tool secilc secilc || return 1
  fi
  require_tool seinfo setools || return 1
  mkdir -p "$out_dir" || return 1

  if ! do_compile "$out_dir" 0; then
    fail "the boot-path compile failed -- $out_dir/secilc.stderr:"
    cat "$out_dir/secilc.stderr" >&2
    return 1
  fi

  local lab_plat="$out_dir/plat_lab.cil" nlmsg
  nlmsg=$(strip_nlmsg_xperms "$PLAT_CIL" "$lab_plat") || return 1

  local lab_vendor="$out_dir/rhizo_vendor_lab.cil" vendor_nlmsg
  vendor_nlmsg=$(strip_nlmsg_xperms "$out_dir/rhizo_vendor_sepolicy.cil" "$lab_vendor") || return 1

  local policy="$out_dir/policy.lab" err="$out_dir/secilc.lab.stderr"
  local caps=() cap built=0 rounds i
  local denied=0 tails=() guarded=0
  rounds=$(grep -cE '^[[:space:]]*\(policycap ' "$lab_plat")
  for (( i = 0; i <= rounds + 1; i++ )); do
    if "$compiler" -m -M true -G -c 30 "$lab_plat" "$SYSTEM_EXT_CIL" "$PRODUCT_CIL" \
         "$lab_vendor" -o "$policy" -f /dev/null 2>"$err"; then
      built=1
      break
    fi
    if (( denied == 0 && ! keep_deny )) && grep -qxF 'Error: Unknown keyword deny' "$err"; then
      readarray -t tails < <(deny_tails "$lab_vendor")
      denied=$(strip_deny "$lab_vendor" "$lab_vendor.tmp") || return 1
      mv -f "$lab_vendor.tmp" "$lab_vendor"
      guarded=$(strip_deny_guards "$lab_vendor" "${tails[@]}") || return 1
      continue
    fi
    cap=$(bad_policycap "$err")
    [[ -n "$cap" ]] || break
    strip_policycap "$lab_plat" "$cap" || return 1
    caps+=("$cap")
  done
  if (( built == 0 )); then
    fail "secilc could not compile the lab policy -- $err:"
    cat "$err" >&2
    return 1
  fi

  log "stripped $nlmsg nlmsg extended-permission rule(s) from $(basename "$PLAT_CIL") and $vendor_nlmsg from rhizo_vendor_sepolicy.cil"
  if (( ${#caps[@]} > 0 )); then
    log "stripped ${#caps[@]} policycap(s) libsepol has no name for: ${caps[*]}"
  else
    log "libsepol knows every policycap this CIL set declares, none stripped"
  fi
  if (( denied > 0 )); then
    log "WARNING: policy.lab is weakened -- $denied deny rule(s) and $guarded matching neverallow guard(s) were dropped from $(basename "$lab_vendor")"
    log "WARNING: the real boot policy DENIES what those covered (${tails[*]}); policy.lab now ALLOWS it"
  else
    pass "libsepol parsed every 'deny' rule in this CIL set, none stripped"
  fi
  local stats
  stats=$(seinfo "$policy") || { fail "seinfo cannot read $policy"; return 1; }
  grep -E 'Classes:|Types:' <<<"$stats" >&2
  pass "policy.lab is readable by upstream setools"
  echo "$policy"
}

# explain a denial capture with audit2allow
cmd_explain() {
  local capture="" domain="" policy="" why=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) domain="$2"; shift 2 ;;
      --policy) policy="$2"; shift 2 ;;
      --why) why=1; shift ;;
      -*) echo "explain: unknown arg: $1" >&2; return 2 ;;
      *) capture="$1"; shift ;;
    esac
  done
  [[ -n "$capture" ]] || { usage >&2; return 2; }
  [[ -r "$capture" ]] || { fail "capture not readable: $capture"; return 2; }
  require_tool audit2allow policycoreutils-python-utils || return 1
  (( why == 0 )) || require_tool audit2why policycoreutils-python-utils || return 1
  [[ -n "$policy" ]] || policy=$(cmd_build --out "$LAB_DIR") || return 1

  local scratch; scratch=$(mktemp -d) || return 1
  INTERNAL_SCRATCH+=("$scratch")
  local records="$scratch/records.log"
  avc_records "$capture" "$domain" > "$records"
  local n; n=$(grep -c . "$records")
  if (( n == 0 )); then
    fail "no avc denial in $capture${domain:+ from source domain $domain}"
    return 1
  fi
  log "$n denial line(s)${domain:+ from $domain} in $(basename "$capture") against $policy"
  audit2allow -p "$policy" -i "$records" || return 1
  (( why == 0 )) && return 0
  audit2why -p "$policy" -i "$records"
}

# search the lab policy with sesearch
cmd_search() {
  local policy="" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --policy) policy="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if (( ${#args[@]} == 0 )); then
    usage >&2
    return 2
  fi
  require_tool sesearch setools || return 1
  [[ -n "$policy" ]] || policy=$(cmd_build --out "$LAB_DIR") || return 1
  sesearch "${args[@]}" "$policy"
}

# print the denial summary of a capture
cmd_denials() {
  local capture="" domain=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) domain="$2"; shift 2 ;;
      -*) echo "denials: unknown arg: $1" >&2; return 2 ;;
      *) capture="$1"; shift ;;
    esac
  done
  [[ -n "$capture" ]] || { usage >&2; return 2; }
  [[ -r "$capture" ]] || { fail "capture not readable: $capture"; return 2; }
  local input="$capture"
  if [[ -n "$domain" ]]; then
    local scratch; scratch=$(mktemp -d) || return 1
    INTERNAL_SCRATCH+=("$scratch")
    input="$scratch/filtered.log"
    grep -a "scontext=u:r:$domain:" "$capture" > "$input"
    if [[ ! -s "$input" ]]; then
      fail "no denial from source domain $domain in $capture"
      return 1
    fi
  fi
  python3 ./parse-avc.py "$input"
}

# test the strip functions against fixtures
cmd_selftest() {
  local t; t=$(mktemp -d) || return 1
  INTERNAL_SCRATCH+=("$t")
  local cases=0

  want() {
    cases=$((cases + 1))
    if ! grep -qF -- "$1" <<<"$2"; then
      echo "SELFTEST FAILED ($3): expected '$1' in:" >&2
      sed 's/^/    /' <<<"$2" >&2
      exit 1
    fi
  }
  reject() {
    cases=$((cases + 1))
    if grep -qF -- "$1" <<<"$2"; then
      echo "SELFTEST FAILED ($3): '$1' should be gone from:" >&2
      sed 's/^/    /' <<<"$2" >&2
      exit 1
    fi
  }
  equal() {
    cases=$((cases + 1))
    if [[ "$1" != "$2" ]]; then
      echo "SELFTEST FAILED ($3): got '$1', expected '$2'" >&2
      exit 1
    fi
  }

  cat > "$t/capture.log" <<'EOF'
[   12.345678] audit: type=1400 audit(1788612436.123:2277): avc:  denied  { mounton } for  pid=5288 comm="python3" path="/" dev="vda1" ino=2 scontext=u:r:rhizo_host:s0 tcontext=u:object_r:rootfs:s0 tclass=dir permissive=0
[   13.000000] audit: type=1400 audit(1788612437.500:2278): avc:  denied  { read } for  pid=5817 comm="system_server" name="foo" dev="vda1" ino=99 scontext=u:r:system_server:s0 tcontext=u:object_r:unlabeled:s0 tclass=file permissive=0
a line that is not a denial at all
EOF
  local out
  out=$(avc_records "$t/capture.log")
  equal "$(grep -c . <<<"$out")" 2 "transform kept both denials"
  want 'type=AVC msg=audit(1788612436.123:2277): avc:  denied  { mounton }' "$out" "auditd record form"
  reject 'audit: type=1400' "$out" "kernel printk prefix"
  reject '[   12.345678]' "$out" "kernel timestamp"

  out=$(avc_records "$t/capture.log" rhizo_host)
  equal "$(grep -c . <<<"$out")" 1 "domain filter kept one line"
  want 'scontext=u:r:rhizo_host:s0' "$out" "domain filter kept its own domain"
  reject 'system_server' "$out" "domain filter dropped the other domain"

  cat > "$t/frag.cil" <<'EOF'
(policycap open_perms)
(policycap lab_unknown_cap)
(allowx rhizo_host self (nlmsg (netlink_route_socket (0x1))))
(allowx rhizo_host self (ioctl (chr_file (0x5401))))
(allow rhizo_host rootfs (dir (search)))
(class netlink_route_socket (nlmsg_read nlmsg ))
EOF
  cat > "$t/expected.cil" <<'EOF'
(policycap open_perms)
(allowx rhizo_host self (ioctl (chr_file (0x5401))))
(allow rhizo_host rootfs (dir (search)))
(class netlink_route_socket (nlmsg_read nlmsg ))
EOF
  local dropped
  dropped=$(strip_nlmsg_xperms "$t/frag.cil" "$t/lab.cil") || exit 1
  equal "$dropped" 1 "one nlmsg rule dropped"

  printf 'Invalid policycap (lab_unknown_cap) at %s:2\nFailed to verify cil database\n' "$t/lab.cil" > "$t/err.txt"
  equal "$(bad_policycap "$t/err.txt")" lab_unknown_cap "policycap name read from secilc's rejection"
  strip_policycap "$t/lab.cil" lab_unknown_cap || exit 1

  cases=$((cases + 1))
  if ! out=$(diff -u "$t/expected.cil" "$t/lab.cil"); then
    echo "SELFTEST FAILED (strippers): the lab copy is not the fixture minus those two lines:" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  cases=$((cases + 1))
  if strip_policycap "$t/lab.cil" lab_unknown_cap 2>/dev/null; then
    echo "SELFTEST FAILED (strippers): stripping an absent policycap reported success" >&2
    exit 1
  fi

  cat > "$t/deny_frag.cil" <<'EOF'
(allow rhizo_host fs_type (filesystem (getattr mount unmount remount associate)))
(deny init binfmt_miscfs (filesystem (mount remount)))
(deny rhizo_host binfmt_miscfs (filesystem (mount remount)))
(typeattribute rhizo_binfmt_guard)
(typeattributeset rhizo_binfmt_guard (all))
(neverallow rhizo_binfmt_guard binfmt_miscfs (filesystem (mount remount)))
(typeattribute unrelated_guard)
(typeattributeset unrelated_guard (all))
(neverallow unrelated_guard some_other_type (dir (read)))
EOF

  local dtails
  dtails=$(deny_tails "$t/deny_frag.cil")
  equal "$(grep -c . <<<"$dtails")" 1 "deny_tails dedupes the two identical deny tails to one"
  want 'binfmt_miscfs (filesystem (mount remount)))' "$dtails" "deny_tails returns the shared tail"

  dropped=$(strip_deny "$t/deny_frag.cil" "$t/deny_stripped.cil") || exit 1
  equal "$dropped" 2 "both deny rules counted"
  local body; body=$(cat "$t/deny_stripped.cil")
  reject '(deny ' "$body" "deny rules gone after strip_deny"
  want '(allow rhizo_host fs_type' "$body" "strip_deny left the unrelated allow alone"
  want '(neverallow rhizo_binfmt_guard' "$body" "strip_deny does not touch the guard"

  local guarded
  guarded=$(strip_deny_guards "$t/deny_stripped.cil" "$dtails") || exit 1
  equal "$guarded" 1 "exactly one guard trio matched the stripped tail"
  body=$(cat "$t/deny_stripped.cil")
  reject 'rhizo_binfmt_guard' "$body" "the matching guard trio is gone"
  want 'unrelated_guard' "$body" "a guard for a different tail survives untouched"
  want '(allow rhizo_host fs_type' "$body" "strip_deny_guards left the unrelated allow alone"

  cat > "$t/shared_guard.cil" <<'EOF'
(deny init type_a (filesystem (mount remount)))
(deny init type_b (filesystem (mount remount)))
(typeattribute shared_guard)
(typeattributeset shared_guard (and (all) (not (rhizo_host))))
(neverallow shared_guard type_a (filesystem (mount remount)))
(neverallow shared_guard type_b (filesystem (mount remount)))
EOF
  dtails=$(deny_tails "$t/shared_guard.cil")
  equal "$(grep -c . <<<"$dtails")" 2 "deny_tails keeps two different tails apart"
  strip_deny "$t/shared_guard.cil" "$t/shared_stripped.cil" >/dev/null || exit 1
  mapfile -t tails_arr <<<"$dtails"
  guarded=$(strip_deny_guards "$t/shared_stripped.cil" "${tails_arr[@]}") || exit 1
  equal "$guarded" 2 "both neverallows of one shared guard attribute are dropped"
  reject 'shared_guard' "$(cat "$t/shared_stripped.cil")" "the shared guard's declaration, set and both neverallows are gone"

  cat > "$t/no_guard.cil" <<'EOF'
(deny init some_type (dir (read)))
EOF
  local none
  none=$(strip_deny_guards "$t/no_guard.cil" "some_type (dir (read)))") || exit 1
  equal "$none" 0 "a stripped deny with no matching neverallow guards nothing, and is not an error"

  cat > "$t/orphan_neverallow.cil" <<'EOF'
(neverallow orphan_guard some_type (dir (read)))
EOF
  cases=$((cases + 1))
  if strip_deny_guards "$t/orphan_neverallow.cil" "some_type (dir (read)))" 2>/dev/null; then
    echo "SELFTEST FAILED (strip_deny_guards): a neverallow with no (typeattribute NAME) declaration should refuse, not silently drop only the neverallow" >&2
    exit 1
  fi

  echo "avc-lab selftest: $cases assertions passed"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  explain) shift; cmd_explain "$@" ;;
  search) shift; cmd_search "$@" ;;
  denials) shift; cmd_denials "$@" ;;
  --selftest) shift; cmd_selftest "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

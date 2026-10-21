#!/bin/bash
# map each Android release to its GSI tree
# shellcheck disable=SC2034
declare -A GSI_DIR=(
  [a16]="/srv/rhizo/gsi_system"
  [a17]="/srv/rhizo/gsi_system_a17"
  [a15]="/srv/rhizo/gsi_system_a15"
  [a16-arm64]="/srv/rhizo/gsi_system_a16-arm64"
)
declare -A GSI_IMG=(
  [a16]="system.img"
  [a17]="gsi_a17.img"
  [a15]="gsi_a15.img"
  [a16-arm64]="gsi_a16-arm64.img"
)
declare -A GSI_DESC=(
  [a16]="Android 16 (baklava)"
  [a17]="Android 17 (cinnamonbun)"
  [a15]="Android 15 (vic)"
  [a16-arm64]="Android 16 (baklava) BP4A.251205.006, aosp_arm64 -- arm64 host"
)

declare -A GSI_KERNEL=(
  [a16]=""
  [a17]="rhizo"
  [a15]=""
)

declare -A LOOP_MAX_LOOP=(
  [a16]=51
  [a17]=54
  [a15]=48
)
LOOP_MAX_LOOP_DEFAULT=64

# print the loop device ceiling for a release
loop_max_loop() {
  local release="${1:-}"
  if [[ "${RHIZO_LOOP_PER_RELEASE:-}" == "1" && -n "${LOOP_MAX_LOOP[$release]:-}" ]]; then
    echo "${LOOP_MAX_LOOP[$release]}"
  else
    echo "$LOOP_MAX_LOOP_DEFAULT"
  fi
}

LOOP_HEADROOM_PER_INSTANCE=20

# print the loop ceiling for N instances
loop_max_loop_for_instances() {
  local release="$1" count="${2:?loop_max_loop_for_instances: instance count required}"
  local need="${LOOP_MAX_LOOP[$release]:-$LOOP_MAX_LOOP_DEFAULT}"
  echo $(( (need + LOOP_HEADROOM_PER_INSTANCE) * count ))
}

# compare max_loop to the loop budget
loop_budget_ok() {
  local release="$1" running="${2:?loop_budget_ok: running instance count required}"
  local max_loop_path="${3:-/sys/module/loop/parameters/max_loop}"
  local have
  have=$(cat "$max_loop_path" 2>/dev/null) || return 1
  [[ "$have" =~ ^[0-9]+$ ]] || return 1
  local want
  want=$(loop_max_loop_for_instances "$release" $((running + 1)))
  echo "$have $want"
  (( have >= want ))
}

RELEASE_LABELS=(a16 a17 a15)

# return whether a release has a GSI directory
release_known() { [[ -n "${GSI_DIR[$1]:-}" ]]; }

declare -A GSI_DIR_USERDEBUG=(
  [a16]="/srv/rhizo/gsi_system_userdebug"
)

# return whether a release has a userdebug GSI directory
userdebug_known() { [[ -n "${GSI_DIR_USERDEBUG[$1]:-}" ]]; }

# return whether the tree is the release's own
staged_set_is_of_tree() { [[ "${2%/}" == "${GSI_DIR[${1:-a16}]:-}" ]]; }

declare -A RELEASE_BUILD_ARTIFACT=(
  [a15]="share/rel/a15/rhizo-power-service"
)
declare -A RELEASE_BUILD_CMD=(
  [a15]="tools/build/hal/power-a15.sh"
)

# return whether a release needs a build artifact
release_build_needed() { [[ -n "${RELEASE_BUILD_ARTIFACT[$1]:-}" ]]; }

declare -A RELEASE_RETIRED=(
  [a17]="a17 needs the 6.12.99-rhizo kernel, which is retired"
)

# print why a release cannot boot on this rig
release_retired() { [[ -n "${RELEASE_RETIRED[$1]:-}" ]] && echo "${RELEASE_RETIRED[$1]}"; }

declare -A GSI_DATA_FORMAT=(
  [a16]="quota"
  [a17]="quota"
  [a15]="quota"
)

# print the /data template key for a release
resolve_data_template() {
  local rel="$1" variant="${2:-user}"
  local fmt="${GSI_DATA_FORMAT[$rel]:-}"
  if [[ -z "$fmt" ]]; then
    log "resolve_data_template: no declared /data format for release '$rel'"
    return 1
  fi
  local out key
  out=$("$REPO/tools/build/image/data-template.sh" "$rel" --format "$fmt" --variant "$variant" 2>&1)
  key=$(sed -n 's/^BUILD_TEMPLATE_OK key=\([0-9a-f]\{12\}\).*/\1/p' <<<"$out")
  if [[ -z "$key" ]]; then
    log "resolve_data_template: could not resolve a $fmt-format template for $rel/$variant (falling back to a wipe):"
    log "$out"
    return 1
  fi
  echo "$key"
}

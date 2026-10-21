# shellcheck shell=bash disable=SC2034  # the pin tables are read by the scripts that source this file
declare -A GSI_URL GSI_SHA GSI_DESC
GSI_URL[a15]="https://dl.google.com/developers/android/vic/images/gsi/aosp_x86_64-exp-BP1A.250405.005.C1-13151952-12978bf9.zip"
GSI_SHA[a15]="12978bf94c1e8dfee598941641df2aa73d29a0f967cc00f4f36b87ac1ed77bf2"
GSI_DESC[a15]="Android 15 (vic) BP1A.250405.005.C1"

GSI_URL[a16]="https://github.com/liambilsbury/rhizo/releases/download/gsi-a16-BP4A.251205.006-1/rhizo-gsi_x86_64-user-BP4A.251205.006-1.zip"
GSI_SHA[a16]="32d7103f1e54622d47256a32b0dc09400979d7a72b6111adf5340a504021906f"
GSI_DESC[a16]="Android 16 BP4A.251205.006, Rhizo's gsi_x86_64 build"

GSI_URL[a17]="https://dl.google.com/developers/android/cinnamonbun/images/gsi/aosp_x86_64-exp-CP41.260731.005.B1-16056512-0c37f98d.zip"
GSI_SHA[a17]="0c37f98dfd527202a3c61cc069d4efcdbc37ff8b88eb53e0047fb4ac8f552465"
GSI_DESC[a17]="Android 17 (cinnamonbun) CP41.260731.005.B1"

GSI_URL[a16-arm64]="https://dl.google.com/developers/android/baklava/images/gsi/aosp_arm64-exp-BP4A.251205.006-14401865-2171cf0e.zip"
GSI_SHA[a16-arm64]="2171cf0ea849f8eaa399f4bad2165fab80b0fd9e98d37723a705dca6c41e49ea"
GSI_DESC[a16-arm64]="Android 16 (baklava) BP4A.251205.006, aosp_arm64"

# print the seed zip for a release in a var dir: the one named for its pinned file, else gsi_<release>.zip
gsi_seed_path() {
  local named="$1/gsi-dl/${GSI_URL[$2]##*/}"
  if [[ -n "${GSI_URL[$2]:-}" && -f "$named" ]]; then printf '%s\n' "$named"; else printf '%s\n' "$1/gsi-dl/gsi_$2.zip"; fi
}

# print a release's /etc/rhizo/gsi-pins.tsv row: release, url, sha256 and description, tab-separated
gsi_pin_row() {
  [[ -n "${GSI_URL[$1]:-}" ]] || return 1
  printf '%s\t%s\t%s\t%s\n' "$1" "${GSI_URL[$1]}" "${GSI_SHA[$1]}" "${GSI_DESC[$1]}"
}

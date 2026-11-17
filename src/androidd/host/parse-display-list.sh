# shellcheck shell=sh
# composer display list reply parser

# print a display token per line
rhizo_dl_tokens() {
  printf '%s\n' "$1" | grep -oE '[0-9]+\([^)]*\)'
}

# print the display ids
rhizo_dl_ids() {
  rhizo_dl_tokens "$1" | grep -oE '^[0-9]+'
}

# print the ids of pooled spares
rhizo_dl_spares() {
  rhizo_dl_tokens "$1" | grep -E '[(,]pool[,)]' | grep -oE '^[0-9]+'
}

# print the ids of claimed displays
rhizo_dl_claimed() {
  rhizo_dl_tokens "$1" | grep -vE '[(,]pool[,)]' | grep -oE '^[0-9]+'
}

# print the width and height of display $2
rhizo_dl_geometry() {
  rhizo_dl_tokens "$1" | grep -E "^$2\(" | sed -E 's/^[0-9]+\(([0-9]+x[0-9]+).*/\1/'
}

# print the width and height of each display
rhizo_dl_geometries() {
  rhizo_dl_tokens "$1" | sed -E 's/^[0-9]+\(([0-9]+x[0-9]+).*/\1/'
}

# print field $3 of the display $2 token
rhizo_dl_field() {
  rhizo_dl_tokens "$1" | grep -E "^$2\(" | grep -oE "[(,]$3=[^,)]*" | sed -E 's/^[(,][^=]*=//'
}

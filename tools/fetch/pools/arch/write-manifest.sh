#!/bin/bash
# write MANIFEST.tsv in the guest pool directory
cd "$1" || exit 1
: > MANIFEST.tsv
for f in *.pkg.tar.zst; do
  line=$(pacman -Qp "$f") || { echo "pacman -Qp $f failed: $line"; exit 1; }
  [[ "$line" =~ ^[^[:space:]]+[[:space:]][^[:space:]]+$ ]] || { echo "pacman -Qp $f printed '$line', not a name and a version"; exit 1; }
  printf '%s\t%s\n' $line >> MANIFEST.tsv
done

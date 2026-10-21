#!/bin/bash
# check the guest pool against POOL.sha256 and the repository database
dir=$1 repo=$2 bad=0
cd "$dir" || { echo "$dir is not a directory on the guest"; exit 1; }
[[ -f POOL.sha256 ]] || { echo "$dir/POOL.sha256 is missing"; exit 1; }
sha256sum --check --quiet POOL.sha256 || bad=1
recorded=$(sed 's/^[0-9a-f]*  //' POOL.sha256 | LC_ALL=C sort)
present=$(find . -mindepth 1 -maxdepth 1 ! -name POOL.sha256 -printf '%f\n' | LC_ALL=C sort)
extra=$(LC_ALL=C comm -13 <(echo "$recorded") <(echo "$present"))
[[ -z "$extra" ]] || { echo "files POOL.sha256 does not list: $(tr '\n' ' ' <<<"$extra")"; bad=1; }
listed=$(tar -xOf "$repo.db.tar.zst" --wildcards '*/desc' | awk '$0 == "%FILENAME%" { getline; print }' | LC_ALL=C sort)
have=$(ls -- *.pkg.tar.zst | LC_ALL=C sort)
[[ -n "$have" ]] || { echo "$dir holds no package files"; bad=1; }
[[ "$listed" == "$have" ]] || { echo "$repo.db and the package files differ:"; diff <(echo "$listed") <(echo "$have"); bad=1; }
(( bad == 0 )) && echo "$(wc -l < POOL.sha256) files match POOL.sha256 and $(wc -l <<<"$have") packages are in $repo.db"
exit "$bad"

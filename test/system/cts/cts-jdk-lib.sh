#!/bin/bash
# choose the JDK a CTS or VTS suite runs under

# print the major java version of a JDK home, failing when it has no java that runs
jdk_major() {
  local v
  v=$("$1/bin/java" -version 2>&1 | sed -n 's/.* version "\([^"]*\)".*/\1/p' | head -1)
  [[ "$v" == 1.* ]] && v=${v#1.}
  v=${v%%[._+-]*}
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  echo "$v"
}

# print the JDK home a suite runs under
suite_java_home() {
  local root="$1" jvm="${2:-/usr/lib/jvm}" d m best="" best_m=0 seen=""
  if [[ -x "$root/jdk/bin/java" ]]; then
    echo "$root/jdk"
    return 0
  fi
  for d in "$jvm"/*/; do
    d=$(readlink -f "${d%/}") || continue
    m=$(jdk_major "$d") || continue
    seen+=" $(basename "$d")=$m"
    if (( m >= 11 && m > best_m )); then
      best=$d best_m=$m
    fi
  done
  if [[ -n "$best" ]]; then
    echo "$best"
    return 0
  fi
  echo "no JDK 11 or newer to run $root: it has no jdk/bin/java, and $jvm holds${seen:- no JDK}" >&2
  return 1
}

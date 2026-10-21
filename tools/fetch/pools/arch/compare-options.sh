#!/bin/bash
# compare the pool and stock pacman options
section() { sed -n '/^\[options\]/,/^\[/{/^\[/!p}' <<<"$1"; }
stock=$(pacman-conf --config /etc/pacman.conf) || { echo "pacman-conf --config /etc/pacman.conf exited $?" >&2; exit 1; }
pool=$(pacman-conf --config "$1") || { echo "pacman-conf --config $1 exited $?" >&2; exit 1; }
stock_opts=$(section "$stock")
pool_opts=$(section "$pool")
[[ -n "$stock_opts" ]] || { echo "pacman-conf --config /etc/pacman.conf printed no [options] lines, only: $(head -n 3 <<<"$stock" | tr '\n' ' ')" >&2; exit 1; }
[[ -n "$pool_opts" ]] || { echo "pacman-conf --config $1 printed no [options] lines, only: $(head -n 3 <<<"$pool" | tr '\n' ' ')" >&2; exit 1; }
diff <(echo "$stock_opts") <(echo "$pool_opts")

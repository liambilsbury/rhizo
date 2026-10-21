#!/bin/bash
# bring the guest network back up and write offline.ended
share=/root/share
up=0
[[ ! -f "$share/offline.nic" ]] || ip link set "$(<"$share/offline.nic")" up || up=$?
echo "Result=$SERVICE_RESULT ExitCode=$EXIT_CODE ExitStatus=$EXIT_STATUS ip_link_up_exit=$up" > "$share/offline.ended"

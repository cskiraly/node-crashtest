#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A power cut timed on the node's log: as soon as a line matching PATTERN (an extended regular
# expression) appears in the watcher's copy of the node's journal, power the VM off; boot it again
# after OFF seconds. Lines from before the start don't count. Needs a running watcher
# (observe/watch.sh); the cut follows the line within about a second (the journal stream's delay,
# plus a 0.1-s poll).
#
#   faults/power-on-log.sh NODE PATTERN [OFF_SECONDS] [TIMEOUT_SECONDS]   (defaults 10, 3600)

. "$(dirname "$0")/../lib/common.sh"
[ $# -ge 2 ] || { sed -n '3,9p' "$0"; exit 2; }
load_node "$1"
faults_allowed
PATTERN=$2 OFF=${3:-10} TIMEOUT=${4:-3600}
[ -n "$RUN" ] && [ -f "$RUN/node.log" ] || die "no watcher run for $NODE_NAME (start observe/watch.sh first)"

F=$RUN/node.log
seen=$(stat -c %s "$F") # bytes: each poll reads only what was added
end=$(( $(date +%s) + TIMEOUT ))
ev "power-on-log: waiting for /$PATTERN/ in the node's log"
while :; do
	if line=$(tail -c +"$((seen + 1))" "$F" | grep -m1 -E "$PATTERN"); then
		"${VIRSH[@]}" destroy "$VM" >/dev/null
		ev "power-on-log: power off $VM; matched: ${line:0:160}"
		break
	fi
	[ "$(date +%s)" -lt "$end" ] || { ev "power-on-log: timed out"; exit 1; }
	sleep 0.1
done
ssh -O exit "$NODE" 2>/dev/null || true # a shared ssh connection died with the VM
sleep "$OFF"
"${VIRSH[@]}" start "$VM" >/dev/null || die "could not start $VM"
ev "power-on-log: power on $VM (off ${OFF} s)"

#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A power cut timed on the node's log: as soon as a line matching PATTERN (an extended regular
# expression) appears in the watcher's copy of the node's journal, power the VM off; boot it again
# after OFF seconds. Lines from before the start don't count, nor lines stamped earlier (the watcher
# repeats a few lines when its journal stream reconnects, after a cut say). Needs a running watcher
# (observe/watch.sh); the cut follows the line within about a second (the journal stream's delay,
# plus a 0.1-s poll). Exits 3 if no such line came within TIMEOUT (no cut then), 1 on an error.
#
#   faults/power-on-log.sh NODE PATTERN [OFF_SECONDS] [TIMEOUT_SECONDS]   (defaults 10, 3600)

. "$(dirname "$0")/../lib/common.sh"
[ $# -ge 2 ] || { sed -n '3,10p' "$0"; exit 2; }
load_node "$1"
faults_allowed
PATTERN=$2 OFF=${3:-10} TIMEOUT=${4:-3600}
[ -n "$RUN" ] && [ -f "$RUN/node.log" ] || die "no watcher run for $NODE_NAME (start observe/watch.sh first)"

F=$RUN/node.log
seen=$(stat -c %s "$F") # bytes already read: each poll reads what was added since
since=$(date -u +%FT%T) # the node's journal is in UTC
end=$(( $(date +%s) + TIMEOUT ))
ev "power-on-log: waiting for /$PATTERN/ in the node's log"
while :; do
	size=$(stat -c %s "$F")
	if [ "$size" -gt "$seen" ]; then
		# One reader of exactly the new bytes, and awk reads to the end: a reader still writing into a
		# pipe closed early would be killed, and pipefail would turn the match into a failure.
		if line=$(dd if="$F" iflag=skip_bytes,count_bytes skip="$seen" count="$((size - seen))" status=none |
			P="$PATTERN" awk -v s="$since" '
			!found && substr($1, 1, 19) >= s && $0 ~ ENVIRON["P"] { print; found = 1 } END { exit !found }'); then
			"${VIRSH[@]}" destroy "$VM" >/dev/null || die "could not power off $VM"
			trap '"${VIRSH[@]}" start "$VM" >/dev/null 2>&1; ev "power-on-log: power on $VM (interrupted)"; exit 1' INT TERM
			ev "power-on-log: power off $VM; matched: ${line:0:160}"
			break
		fi
		# Up to a line's end, the next poll starts after what was read; a line still being written is
		# read again.
		[ -n "$(dd if="$F" iflag=skip_bytes skip="$((size - 1))" bs=1 count=1 status=none | tr -d '\n')" ] || seen=$size
	fi
	[ "$(date +%s)" -lt "$end" ] || { ev "power-on-log: timed out"; exit 3; }
	sleep 0.1
done
drop_shared
sleep "$OFF"
"${VIRSH[@]}" start "$VM" >/dev/null || die "could not start $VM"
ev "power-on-log: power on $VM (off ${OFF} s)"

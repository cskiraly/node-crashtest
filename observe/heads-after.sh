#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# After a fault, how long until the node gets new heads and follows the chain again. From SINCE (UTC,
# as in events.log) on: the first "Forkchoice requested sync to new head" above HEAD in the node's log
# (geth's engine API: the same with a consensus client or in light-client mode), then the first
# watcher line with the node's head within one block of the reference's. Needs a running watcher.
#
#   observe/heads-after.sh NODE SINCE HEAD [TIMEOUT_S]   (e.g. t-node 2026-10-08T09:01:28 3775591; default 3600)

. "$(dirname "$0")/../lib/common.sh"
set -u
[ $# -ge 3 ] || { sed -n '3,9p' "$0"; exit 2; }
load_node "$1"
SINCE=$2 HEAD=$3 TIMEOUT=${4:-3600}
[ -n "$RUN" ] || die "no watcher run for $NODE_NAME (start observe/watch.sh first)"
end=$(( $(date +%s) + TIMEOUT ))

first_head() {
	awk -v s="$SINCE" -v h="$HEAD" '$1 >= s && /Forkchoice requested sync to new head/ {
		if (match($0, /number=[0-9,]+/)) { n = substr($0, RSTART + 7, RLENGTH - 7); gsub(",", "", n)
			if (n + 0 > h) { print; exit } } }' "$RUN/node.log"
}
# caught_up: the watcher's last line, from SINCE on, has the node's head within a block of a known
# reference head.
caught_up() {
	tail -n 1 "$RUN/watch.log" | awk -v s="$SINCE" '{ t = substr($1, 1, 19)
		for (i = 1; i <= NF; i++) { if ($i ~ /^head=[0-9]+$/) h = substr($i, 6); if ($i ~ /^ref=[0-9]+$/) r = substr($i, 5) } }
		END { exit !(t >= s && h != "" && r + 0 > 0 && h + 1 >= r + 0) }'
}

log "waiting for a head above $HEAD after $SINCE"
until line=$(first_head) && [ -n "$line" ]; do
	[ "$(date +%s)" -lt "$end" ] || { log "no new head within ${TIMEOUT} s"; exit 1; }
	sleep 5
done
echo "first new head: ${line:0:180}"
until caught_up; do
	[ "$(date +%s)" -lt "$end" ] || { log "not at the reference's head within ${TIMEOUT} s"; exit 1; }
	sleep 5
done
echo "at the reference's head: $(tail -n 1 "$RUN/watch.log" | cut -c1-200)"

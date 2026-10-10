#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Network outages at the chain's head, one after the other, each once the node is back at the head:
#  - link: the VM's link down (all traffic) for LINK seconds;
#  - endpoints: the node's HTTP(S) traffic out cut (its beacon API endpoints, for a light client) for
#    ENDPOINTS seconds;
#  - devp2p: the node's peer-to-peer traffic cut for DEVP2P seconds. A light client should keep
#    following meanwhile (its blocks come from the endpoints): the scenario shows how far behind it
#    fell.
# After each: does the node get a head above the one before the outage within NEW_HEAD seconds, and
# how soon is it at the reference's head again. Then its log, and its history over the scenario.
#
#   scenarios/net-cuts.sh NODE [--link S] [--endpoints S] [--devp2p S] [--new-head S]
#                         (defaults 1800, 900, 300; 0 skips an outage; --new-head default 300)
#
# Passes when the node has a new head within NEW_HEAD seconds after every outage and is at the
# reference's head within 30 min, with no unexpected error in its log and its history intact.

. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || { sed -n '3,18p' "$0"; exit 2; }
node=$1
shift
LINK=1800 ENDPOINTS=900 DEVP2P=300 NEW_HEAD=300
while [ $# -ge 2 ]; do
	case $1 in
	--link) LINK=$2 ;;
	--endpoints) ENDPOINTS=$2 ;;
	--devp2p) DEVP2P=$2 ;;
	--new-head) NEW_HEAD=$2 ;;
	*) break ;;
	esac
	shift 2
done
[ $# = 0 ] || { sed -n '3,18p' "$0"; exit 2; }
scenario_start net-cuts "$node"
require_head 1800

# outage LABEL SECONDS FAULT...: one outage, then the questions after it.
outage() {
	local label=$1 secs=$2 h start
	shift 2
	[ "$secs" -gt 0 ] || { info "$label" "skipped"; return 0; }
	sleep 60
	h=$(node_head) || { fail "$label" "no head from the node before the outage"; return 1; }
	[ -n "$first" ] || first=$h
	start=$(now)
	"$@" || { fail "$label" "the fault failed"; return 1; }
	# How far behind the node fell while cut off (as far as the watcher could see it).
	info "$label-lag" "$(awk -v s="$start" -v e="$(now)" 'substr($1, 1, 19) >= s && substr($1, 1, 19) <= e {
		h = ""; r = ""; for (i = 2; i <= NF; i++) { if ($i ~ /^head=[0-9]+$/) h = substr($i, 6); if ($i ~ /^ref=[0-9]+$/) r = substr($i, 5) }
		if (h != "" && r != "" && r - h > max) max = r - h; if (h == "") blind++ }
		END { printf "at most %d blocks behind the reference while the watcher saw it (%d lines without)", max, blind }' "$RUN/watch.log")"
	after_fault "$label" "$(now)" "$h" 120 "$NEW_HEAD" 1800
}

first="" all=1
outage link "$LINK" "$CRASHTEST/faults/link.sh" "$NODE_FILE" "$LINK" || all=0
outage endpoints "$ENDPOINTS" "$CRASHTEST/faults/partial.sh" "$NODE_FILE" endpoints "$ENDPOINTS" || all=0
outage devp2p "$DEVP2P" "$CRASHTEST/faults/partial.sh" "$NODE_FILE" devp2p "$DEVP2P" || all=0
errors_check "$START"
if [ "$all" = 1 ] && [ -n "$first" ]; then
	if last=$(node_head); then history_check "$((first - 32))" "$last"; else fail history "no head from the node"; fi
fi
scenario_end

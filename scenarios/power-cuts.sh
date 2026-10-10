#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Power cuts at the chain's head: CUTS hard power-offs, OFF seconds each, the next one GAP seconds
# after the node is back at the head. After each: is the service running again by itself, does the
# node get a head above the one before the cut, how soon is it at the reference's head again, and how
# far back did it come up (what it hadn't written to disk). Then its log, and its history from just
# before the first cut.
#
#   scenarios/power-cuts.sh NODE [--cuts N] [--off SECONDS] [--gap SECONDS]   (defaults 3, 10, 120)
#
# Passes when after every cut the node has a new head within 15 min and is at the reference's head
# within an hour, with no unexpected error in its log and its history intact.

. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || { sed -n '3,12p' "$0"; exit 2; }
node=$1
shift
CUTS=3 OFF=10 GAP=120
while [ $# -ge 2 ]; do
	case $1 in
	--cuts) CUTS=$2 ;;
	--off) OFF=$2 ;;
	--gap) GAP=$2 ;;
	*) break ;;
	esac
	shift 2
done
[ $# = 0 ] || { sed -n '3,12p' "$0"; exit 2; }
scenario_start power-cuts "$node"
require_head 1800

first="" all=1
for i in $(seq "$CUTS"); do
	sleep "$GAP"
	h=$(node_head) || { fail "cut$i" "no head from the node before the cut"; all=0; break; }
	[ -n "$first" ] || first=$h
	"$CRASHTEST/faults/power.sh" "$NODE_FILE" "$OFF" || { fail "cut$i" "the power cut failed"; all=0; break; }
	after_fault "cut$i" "$(now)" "$h" 600 900 3600 || { all=0; break; }
done
errors_check "$START"
if [ "$all" = 1 ]; then
	if last=$(node_head); then history_check "$((first - 32))" "$last"; else fail history "no head from the node"; fi
fi
scenario_end

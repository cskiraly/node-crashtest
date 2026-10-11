#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A full disk at the chain's head: the file system holding the node's data full for SECONDS, then
# freed (faults/disk-full.sh). Then:
# is the service running again by itself, does the node get a head above the one before, how soon is
# it at the reference's head again. Errors from the full disk until the node is back at the head are
# expected; others aren't. Then its history from before the fault.
#
#   scenarios/disk-full.sh NODE [--for SECONDS]   (default 120)
#
# Passes when the node has a new head within 15 min after the space is back and is at the
# reference's head within an hour, with no unexpected error outside the fault and its history
# intact. (geth stops by itself, with exit status 0, when its disk is nearly full: a unit with
# Restart=on-failure doesn't start it again.)

. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || { sed -n '3,13p' "$0"; exit 2; }
node=$1
shift
FOR=120
while [ $# -ge 2 ]; do
	case $1 in
	--for) FOR=$2 ;;
	*) break ;;
	esac
	shift 2
done
[ $# = 0 ] || { sed -n '3,13p' "$0"; exit 2; }
number --for "$FOR"
scenario_start disk-full "$node"
require_head 1800

sleep 60
h=$(node_head) || not_run "no head from the node"
start=$(now)
if "$CRASHTEST/faults/disk-full.sh" "$NODE_FILE" "$FOR"; then
	after_fault disk "$(now)" "$h" 600 900 3600 && ok=1 || ok=0
	errors_check "$START" "$start" "$(date -u -d "@$(( $(date -u -d "${AT_HEAD}Z" +%s) + 60 ))" +%FT%T)"
	if [ "$ok" = 1 ]; then
		if last=$(node_head); then history_check "$((h - 96))" "$last"; else fail history "no head from the node"; fi
	fi
else
	fail disk "the fault failed"
fi
scenario_end

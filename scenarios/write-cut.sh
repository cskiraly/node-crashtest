#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Power cuts right after the node rewrites a file: by default WATCH_FILE (a light client's checkpoint
# file, say, saved at each finalized epoch). Ext4's auto_da_alloc is turned off first (until the
# boot), so that a file rewritten in place without a sync stays empty on disk until writeback, up to
# ~30 s, as on file systems without that heuristic; and the file system's journal is committed right
# after the write, as a database's own syncs would. ROUNDS cuts. After each: what the file held, is
# the service running again by itself, does the node get new heads, how soon is it at the reference's
# head again. Then its log, and its history over the scenario.
#
#   scenarios/write-cut.sh NODE [--file FILE] [--rounds N] [--keep-auto] [--wait S]
#                                                   (defaults WATCH_FILE, 2 rounds, 1800 s)
#
# --keep-auto   leave auto_da_alloc on: the window for an empty file shrinks to microseconds
# --wait        how long to wait for the file to change, each round
#
# Passes when after every cut the node has a new head within 15 min and is at the reference's head
# within an hour, with no unexpected error in its log and its history intact.

. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || { sed -n '3,18p' "$0"; exit 2; }
node=$1
shift
FILE="" ROUNDS=2 NOAUTO=--noauto WAIT=1800
while [ $# -ge 1 ]; do
	case $1 in
	--file) FILE=$2; shift 2 ;;
	--rounds) ROUNDS=$2; shift 2 ;;
	--keep-auto) NOAUTO=""; shift ;;
	--wait) WAIT=$2; shift 2 ;;
	*) sed -n '3,18p' "$0"; exit 2 ;;
	esac
done
number --rounds "$ROUNDS"; number --wait "$WAIT"
scenario_start write-cut "$node"
FILE=${FILE:-$WATCH_FILE}
[ -n "$FILE" ] || not_run "no file to watch: give --file, or set WATCH_FILE in the node's description"
require_head 1800

first="" all=1
for i in $(seq "$ROUNDS"); do
	# shellcheck disable=SC2086
	out=$("$CRASHTEST/faults/power-after-write.sh" "$NODE_FILE" "$FILE" $NOAUTO --off 5 --timeout "$WAIT")
	case $? in
	0) ;;
	3) # Nothing tested: the node didn't write the file (a light client's checkpoint waits for finality).
		[ "$i" != 1 ] || not_run "$FILE didn't change within $WAIT s: no cut"
		info "cut$i" "$FILE didn't change within $WAIT s: no further cut"; break ;;
	*) fail "cut$i" "the fault failed: $(tail -n 3 <<<"$out" | paste -sd' ')"; all=0; break ;;
	esac
	info "cut$i" "$(grep -E '^(written|after the boot|content)' <<<"$out" | paste -sd' ')"
	# The node's head just before the cut (the watcher's last line before it), and the times from the
	# boot: the fault itself waits for ssh and looks at the file afterwards.
	off_at=$(grep 'power-after-write: power off' "$RUN/events.log" | tail -n 1 | cut -c1-19)
	on_at=$(grep 'power-after-write: power on' "$RUN/events.log" | tail -n 1 | cut -c1-19)
	h=$(head_before "$off_at")
	[ -n "$h" ] || { fail "cut$i" "no head from the watcher before the cut"; all=0; break; }
	[ -n "$first" ] || first=$h
	after_fault "cut$i" "$on_at" "$h" 600 900 3600 || { all=0; break; }
done
errors_check "$START"
if [ "$all" = 1 ] && [ -n "$first" ]; then
	if last=$(node_head); then history_check "$((first - 96))" "$last"; else fail history "no head from the node"; fi
fi
scenario_end

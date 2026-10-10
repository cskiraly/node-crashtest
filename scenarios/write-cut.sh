#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Power cuts right after the node rewrites a file: by default WATCH_FILE (a light client's checkpoint
# file, say, saved at each finalized epoch). Ext4's auto_da_alloc is turned off first (until the
# boot), so that a file rewritten in place without a sync stays empty on disk until writeback, up to
# ~30 s, as on file systems without that heuristic; and the file system's journal is committed right
# after the write, as a database's own syncs would. ROUNDS cuts. After each: what the file held, is
# the service running again by itself, does the node get new heads, how soon is it at the reference's
# head again. Then its log.
#
#   scenarios/write-cut.sh NODE [--file FILE] [--rounds N] [--keep-auto]   (defaults WATCH_FILE, 2)
#
# --keep-auto   leave auto_da_alloc on: the window for an empty file shrinks to microseconds
#
# Passes when after every cut the node has a new head within 15 min and is at the reference's head
# within an hour, with no unexpected error in its log.

. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || { sed -n '3,16p' "$0"; exit 2; }
node=$1
shift
FILE="" ROUNDS=2 NOAUTO=--noauto
while [ $# -ge 1 ]; do
	case $1 in
	--file) FILE=$2; shift 2 ;;
	--rounds) ROUNDS=$2; shift 2 ;;
	--keep-auto) NOAUTO=""; shift ;;
	*) sed -n '3,16p' "$0"; exit 2 ;;
	esac
done
scenario_start write-cut "$node"
FILE=${FILE:-$WATCH_FILE}
[ -n "$FILE" ] || not_run "no file to watch: give --file, or set WATCH_FILE in the node's description"
require_head 1800

for i in $(seq "$ROUNDS"); do
	h=$(node_head)
	# shellcheck disable=SC2086
	out=$("$CRASHTEST/faults/power-after-write.sh" "$NODE_NAME" "$FILE" $NOAUTO --off 5) || { fail "cut$i" "the fault failed"; break; }
	info "cut$i" "$(grep -E '^(written|after the boot|content)' <<<"$out" | paste -sd' ')"
	after_fault "cut$i" "$(now)" "$h" 600 900 3600 || break
done
errors_check "$START"
scenario_end

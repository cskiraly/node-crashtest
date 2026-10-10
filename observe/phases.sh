#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# One line per event worth acting on, from the node's watcher files: the first line of each geth sync
# phase in the node's log, snap sync restarts, unclean shutdowns, ERROR/CRIT/Fatal/panic lines (not
# the known harmless ones), and changes in the watcher's view: reachable or not, the service's state,
# synced or syncing. Runs until stopped.
#
#   observe/phases.sh NODE

. "$(dirname "$0")/../lib/common.sh"
[ $# = 1 ] || { sed -n '3,8p' "$0"; exit 2; }
load_node "$1"
[ -n "$RUN" ] || die "no watcher run for $NODE_NAME (start observe/watch.sh first)"

# The known errors' pattern goes through the environment: awk -v would process its backslashes.
tail -n 0 -F "$RUN/node.log" "$RUN/watch.log" 2>/dev/null | KNOWN="$KNOWN_ERRORS" awk '
	/^$/ { next }
	/^==> .*node\.log <==$/ { src = "node"; next }
	/^==> .*watch\.log <==$/ { src = "watch"; next }
	src == "node" {
		key = ""
		if (/Syncing: state download in progress/) key = "state download"
		else if (/Syncing: state healing in progress/) key = "state healing"
		else if (/Syncing: chain download in progress/) key = "chain download"
		else if (/Disabled snap-sync after/) key = "snap sync done"
		else if (/Committed new head block/) key = "pivot committed"
		else if (/Starting log index at history cutoff/) key = "log index start"
		else if (/Log index head rendering in progress/) key = "log index head rendering"
		else if (/Log index head rendering finished/) key = "log index head done"
		else if (/Log index tail rendering in progress/) key = "log index tail rendering"
		else if (/Log index tail rendering finished/) key = "log index tail done"
		if (key != "" && !(key in seen)) { seen[key] = 1; print "phase: " key " | " substr($0, 1, 200); fflush(); next }
		# the same message (minus times, pid and ages) at most twice: a crash loop repeats itself
		k = $0; sub(/^[^ ]+ [^ ]+\[[0-9]+\]: /, "", k); sub(/^[A-Z]+ *\[[^]]*\] */, "", k); gsub(/age=[^ ]+/, "", k)
		if (/[Ss]nap sync from scratch|Restarting snap sync|Snap sync rolled forward|Resuming snap sync|Unclean shutdown detected/) {
			if (++n[k] <= 2) { print "snap/restart: " substr($0, 1, 220); fflush() }
			next
		}
		if (/ERROR|CRIT|Fatal|panic/ && $0 !~ ENVIRON["KNOWN"]) {
			if (++n[k] <= 2) { print "error: " substr($0, 1, 240); fflush() }
		}
		next
	}
	src == "watch" {
		reach = ($0 ~ /node=unreachable/) ? "unreachable" : "reachable"
		g = ""; if (match($0, /svc=[^ ]+/)) { g = substr($0, RSTART + 4, RLENGTH - 4); sub(/^[0-9]+\//, "", g) }
		s = ($0 ~ /sync=done/) ? "synced" : (($0 ~ /sync=cur/) ? "syncing" : "?")
		st = reach " svc=" g " " s
		if (st != last) { last = st; print "node: " substr($0, 1, 230); fflush() }
	}'

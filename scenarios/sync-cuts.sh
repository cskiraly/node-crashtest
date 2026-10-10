#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Power cuts through a sync: one cut at each phase of geth's sync, the moment the phase's first line
# appears in the node's log, until the node is synced and follows the chain; then its history and
# log index. The phases, in whatever order they come: state download, chain download, state healing,
# the end of snap sync ("Disabled snap-sync": the state database switches to full sync), log index
# rendering, the first block executed at the head (by the downloader, or a new head set over the engine
# API). A phase the node is past by the time the scenario could cut is skipped.
#
#   scenarios/sync-cuts.sh NODE [--reset] [--off SECONDS] [--timeout HOURS]   (defaults 10 s, 8 h)
#
# --reset   delete the node's database first (geth's, in DATADIR/geth; its node key and peers are
#           kept): the node syncs from scratch. Otherwise start the scenario while the node syncs.
#
# Passes when after every cut the service runs again by itself, and the node finishes its sync and
# follows the chain within the timeout, with no unexpected error in its log, its history complete
# and as on the reference, and its log index matching.

. "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || { sed -n '3,19p' "$0"; exit 2; }
node=$1
shift
RESET=0 OFF=10 HOURS=8
while [ $# -gt 0 ]; do
	case $1 in
	--reset) RESET=1; shift ;;
	--off) OFF=$2; shift 2 ;;
	--timeout) HOURS=$2; shift 2 ;;
	*) sed -n '3,19p' "$0"; exit 2 ;;
	esac
done
scenario_start sync-cuts "$node"
DEADLINE=$(( $(date +%s) + HOURS * 3600 ))

PHASES=(
	"state-download|Syncing: state download in progress"
	"chain-download|Syncing: chain download in progress"
	"state-healing|Syncing: state healing in progress"
	"snap-sync-done|Disabled snap-sync after"
	"log-index|Log index (head|tail) rendering in progress"
	"at-the-head|Imported new chain segment|Chain head was updated"
)

FROM=$START # errors count from here: after the reset, with --reset
if [ "$RESET" = 1 ]; then
	ev "sync-cuts: deleting the node's database"
	on "sudo -n systemctl stop '$SERVICE' && sudo -n find '$DATADIR/geth' -mindepth 1 -maxdepth 1 ! -name nodekey ! -name nodes -exec rm -rf {} + &&
		sudo -n systemctl start '$SERVICE'" || not_run "could not reset the node's database"
	FROM=$(now)
else
	line=$(watch_wait "$START" 120 'f["head"] ~ /^[0-9]+$/ && f["ref"] + 0 > 0') || not_run "no head from $NODE_NAME, or no reference"
	sed -n 's/.* head=\([0-9]*\) .* ref=\([0-9]*\).*/\1 \2/p' <<<"$line" | { read -r h r; [ $((h + 64)) -lt "$r" ]; } ||
		not_run "$NODE_NAME is at the chain's head, not syncing (--reset: sync again from scratch)"
fi

declare -A done_at=()
last=$START broken=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
	pattern=""
	for p in "${PHASES[@]}"; do [ -n "${done_at[${p%%|*}]:-}" ] || pattern="$pattern|${p#*|}"; done
	[ -n "$pattern" ] || break
	# Up to 2 h for the next phase; 20 min once the node follows the chain (what remains may be over).
	wait=7200
	watch_wait "$(date -u -d '30 seconds ago' +%FT%T)" 0 "$CAUGHT_UP" >/dev/null && wait=1200
	left=$(( DEADLINE - $(date +%s) ))
	[ "$left" -ge "$wait" ] || wait=$left
	out=$("$CRASHTEST/faults/power-on-log.sh" "$NODE_FILE" "${pattern#|}" "$OFF" "$wait")
	case $? in
	0) ;;
	3) info phases "no further phase line within $wait s"; break ;;
	*) fail phases "the power cut failed: $(tail -n 3 <<<"$out" | paste -sd' ')"; broken=1; break ;;
	esac
	end=$(now)
	matched=$(sed -n 's/.*matched: //p' <<<"$out" | head -1)
	phase=""
	for p in "${PHASES[@]}"; do grep -qE "${p#*|}" <<<"$matched" && phase=${p%%|*} && break; done
	[ -n "$phase" ] || { fail phases "a cut on a line of no phase: $matched"; break; }
	done_at[$phase]=$end
	last=$end
	info "cut-$phase" "${matched:0:150}"
	if line=$(watch_wait "$end" 600 "$RUNNING"); then
		ok "$phase-running" "the node runs again $(secs_from "$end" "$line") s after the power came back"
	else
		fail "$phase-running" "the node isn't running 600 s after the power came back: $(tail -n 1 "$RUN/watch.log" | cut -c1-160)"
		broken=1
		break
	fi
done
for p in "${PHASES[@]}"; do [ -n "${done_at[${p%%|*}]:-}" ] || info "${p%%|*}" "no cut (the phase didn't come up while the scenario watched)"; done

left=$(( DEADLINE - $(date +%s) ))
if [ "$broken" = 1 ]; then
	errors_check "$FROM"
elif line=$(watch_wait "$last" "$(( left > 60 ? left : 60 ))" "$CAUGHT_UP"); then
	ok synced "synced and at the reference's head at ${line:0:20}, $(secs_from "$START" "$line") s after the start"
	errors_check "$FROM"
	if head=$(node_head); then history_check "$(history_start)" "$head"; else fail history "no head from the node"; fi
	logs_check 3
else
	fail synced "not synced within the timeout"
	errors_check "$FROM"
fi
scenario_end

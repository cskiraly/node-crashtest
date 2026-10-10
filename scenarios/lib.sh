# SPDX-License-Identifier: GPL-3.0-or-later
# Shared by the scenarios (sourced): a watcher of the scenario's own, the questions every fault ends
# with, and the checks at the end. A scenario prints OK/FAIL lines (INFO lines for what is measured
# but not judged); its output, the watcher's files and the events go to its run directory. It exits
# 0 when every check passed, 1 when one failed, 2 when it couldn't run (e.g. the node wasn't at the
# chain's head to begin with).

. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
set -u

not_run() { printf 'NOT RUN: %s\n' "$*"; exit 2; }

# scenario_start NAME NODE: load the node (it must allow faults), start a watcher in a run directory
# of its own (RUN), and stop it when the scenario exits.
scenario_start() {
	SCENARIO=$1
	load_node "$2"
	faults_allowed
	RUN=$CRASHTEST_DIR/runs/$NODE_NAME-$SCENARIO-$(date +%Y%m%d-%H%M%S)
	mkdir -p "$RUN"
	exec > >(tee -a "$RUN/scenario.log") 2>&1
	"$CRASHTEST/observe/watch.sh" "$NODE_FILE" "$RUN" > "$RUN/watcher.out" 2>&1 &
	WATCHER=$!
	trap scenario_exit EXIT
	trap 'exit 130' INT TERM
	START=$(date -u +%FT%T)
	ev "scenario $SCENARIO on $NODE_NAME, run $RUN"
	wait_until 120 "the watcher's first line" test -s "$RUN/watch.log" || not_run "the watcher didn't start (see $RUN/watcher.out)"
}
scenario_exit() {
	kill "$WATCHER" 2>/dev/null
	log "run directory: $RUN"
}

# watch_wait SINCE TIMEOUT_S CONDITION: wait for a watcher line written at SINCE (UTC, as
# 2026-10-10T13:17:12) or later on which CONDITION holds (awk, on the line's fields f["head"],
# f["ref"], f["svc"], f["sync"], ...); print it. Returns 1 after TIMEOUT_S.
watch_wait() {
	local since=$1 end=$(( $(date +%s) + $2 )) cond=$3 line
	while :; do
		line=$(awk -v s="$since" '
			{ if (substr($1, 1, 19) < s) next; split("", f)
			  for (i = 2; i <= NF; i++) if ((p = index($i, "=")) > 0) f[substr($i, 1, p - 1)] = substr($i, p + 1) }
			'"$cond"' { print; exit }' "$RUN/watch.log")
		[ -z "$line" ] || { echo "$line"; return 0; }
		[ "$(date +%s)" -lt "$end" ] || return 1
		sleep 5
	done
}
# Running: the service, and the node's RPC answering (a node in a crash loop is "running" for a moment
# at every start, but doesn't get as far as its RPC).
RUNNING='f["svc"] ~ /active\/running$/ && f["head"] ~ /^[0-9]+$/'
CAUGHT_UP='f["sync"] == "done" && f["ref"] + 0 > 0 && f["head"] + 1 >= f["ref"] + 0'
head_above() { echo "f[\"head\"] + 0 > $1"; }

now() { date -u +%FT%T; }
# secs_from T LINE: seconds from T (UTC) to the time of a watcher line.
secs_from() { echo $(( $(date -u -d "${2:0:19}Z" +%s) - $(date -u -d "${1}Z" +%s) )); }

# node_head: the node's head, asked now (3 tries, 10 s apart); fails if the node gives none (a 0
# would make any later head look new).
node_head() {
	local r i
	for i in 1 2 3; do
		r=$(node_rpc eth_blockNumber 2>/dev/null | jq -r '.result // empty' 2>/dev/null)
		[[ $r =~ ^0x[0-9a-fA-F]+$ ]] && { printf '%d' "$r"; return 0; }
		[ "$i" = 3 ] || sleep 10
	done
	return 1
}

# head_before T: the node's head on the watcher's last line before T (UTC), or nothing.
head_before() {
	awk -v t="$1" 'substr($1, 1, 19) < t { for (i = 2; i <= NF; i++) if ($i ~ /^head=[0-9]+$/) h = substr($i, 6) }
		END { print h }' "$RUN/watch.log"
}

# require_head TIMEOUT_S: the node follows the chain (synced, at the reference's head), or the
# scenario doesn't run.
require_head() {
	watch_wait "$(now)" "$1" "$CAUGHT_UP" >/dev/null || not_run "$NODE_NAME isn't at the chain's head (see $RUN/watch.log)"
}

# after_fault LABEL END HEAD [RUNNING_S HEAD_S CAUGHT_UP_S]: the questions every fault ends with,
# each within its time from END (UTC, when the fault ended). Is the service running (by itself), with
# its RPC answering, within RUNNING_S (default 600)? Does the node's head pass HEAD (its head before
# the fault) within HEAD_S (900)? Is it at the reference's head within CAUGHT_UP_S (3600)? Also shows
# the head the node came back with (a rewind after a power cut). Sets AT_HEAD, the time it was at the
# head again.
after_fault() {
	local label=$1 end=$2 head=$3 line h0 t0
	t0=$(date -u -d "${end}Z" +%s)
	AT_HEAD=$end
	# by LIMIT CONDITION: a watcher line from END on where CONDITION holds, at most LIMIT s after END.
	by() {
		local left=$(( t0 + $1 - $(date +%s) ))
		line=$(watch_wait "$end" $(( left > 0 ? left : 0 )) "$2") && [ "$(secs_from "$end" "$line")" -le "$1" ]
	}
	if by "${4:-600}" "$RUNNING"; then
		ok "$label-running" "after $(secs_from "$end" "$line") s"
		h0=$(watch_wait "$end" 60 'f["head"] ~ /^[0-9]+$/' | sed -n 's/.* head=\([0-9]*\).*/\1/p')
		[ -z "$h0" ] || [ "$h0" -ge "$head" ] || info "$label-rewind" "back at block $h0, $((head - h0)) blocks below the head before ($head)"
	else
		fail "$label-running" "the node isn't running ${4:-600} s after the fault: $(tail -n 1 "$RUN/watch.log" | cut -c1-160)"
		return 1
	fi
	if by "${5:-900}" "$(head_above "$head")"; then
		ok "$label-new-head" "a head above $head after $(secs_from "$end" "$line") s"
	else
		fail "$label-new-head" "no head above $head within ${5:-900} s of the fault"
		return 1
	fi
	if by "${6:-3600}" "$CAUGHT_UP"; then
		ok "$label-caught-up" "at the reference's head after $(secs_from "$end" "$line") s"
		AT_HEAD=${line:0:19}
	else
		fail "$label-caught-up" "not at the reference's head within ${6:-3600} s of the fault"
		return 1
	fi
}

# errors_check FROM [START END]...: ERROR, CRIT, Fatal and panic lines in the node's log from FROM
# (UTC) on, but the known harmless ones (KNOWN_ERRORS) and those between a START and END given (a full
# disk makes errors); each distinct message once (times, ids and counters stripped).
errors_check() {
	local from=$1 out
	shift
	# No log line since FROM is no evidence: the watcher's journal stream failed.
	awk -v s="$from" 'substr($1, 1, 19) >= s { found = 1; exit } END { exit !found }' "$RUN/node.log" 2>/dev/null ||
		{ fail errors "no line of the node's log from $from on, in $RUN/node.log"; return; }
	out=$(KNOWN="$KNOWN_ERRORS" WINDOWS="$*" awk -v s="$from" '
		BEGIN { n = split(ENVIRON["WINDOWS"], w, " ") }
		{ t = substr($1, 1, 19); if (t < s) next
		  for (i = 1; i + 1 <= n; i += 2) if (t >= w[i] && t <= w[i + 1]) next }
		{ r = $0; sub(/^[^ ]+ [^ ]+: /, "", r) } # the message, after the time and "geth[PID]: "
		r ~ /^(ERROR|CRIT) *\[|^Fatal:|^panic:|^fatal error:/ && $0 !~ ENVIRON["KNOWN"] {
			k = $0; sub(/^[^ ]+ [^ ]+\[[0-9]+\]: /, "", k); sub(/^[A-Z]+ *\[[^]]*\] */, "", k)
			gsub(/=[^ ]+/, "=", k); if (!(k in seen)) { seen[k] = 1; print substr($0, 1, 220) } }' "$RUN/node.log") ||
		{ fail errors "could not read $RUN/node.log"; return; }
	if [ -z "$out" ]; then
		ok errors "no unexpected ERROR, CRIT, Fatal or panic in the node's log"
	else
		fail errors "$(grep -c . <<<"$out") distinct unexpected messages:"
		sed 's/^/     /' <<<"$out" | head -10
	fi
}

# history_check FROM TO: checks/history.sh over FROM..TO, about 20 blocks compared with the reference.
history_check() {
	local out
	if out=$("$CRASHTEST/checks/history.sh" "$NODE_FILE" "$1" "$2" "$(( ($2 - $1) / 20 + 1 ))" 2>&1); then
		ok history "blocks $1-$2: no gap, receipts complete, as on the reference"
	else
		fail history "blocks $1-$2:"
		grep -v '^OK ' <<<"$out" | sed 's/^/     /' | head -10
	fi
}

# logs_check WINDOWS: checks/logs.sh, the node's log index against its receipts and the reference.
logs_check() {
	local out
	if out=$("$CRASHTEST/checks/logs.sh" "$NODE_FILE" "$1" 2>&1); then
		ok logs "$1 windows of 5,000 blocks: the log index as the receipts and the reference"
	else
		fail logs "the log index:"
		grep -v '^OK ' <<<"$out" | sed 's/^/     /' | head -10
	fi
}

# scenario_end: the verdict; exit 1 if a check failed.
scenario_end() {
	ev "scenario $SCENARIO on $NODE_NAME: $([ "$FAILED" = 0 ] && echo passed || echo FAILED)"
	finish
}

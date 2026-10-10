#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Watch a node while faults hit it. Every 10 s one line in RUNDIR/watch.log: UTC time; the VM's state
# and link (libvirt); from the node, over one ssh connection of its own that gives up 15 s after the
# link goes: uptime, the service's state/substate/restarts, WATCH_FILE's mtime:size, the use of
# DATADIR's file system, the sync (eth_syncing), the head, peers; every 30 s the reference's head.
# The node's journal streams into RUNDIR/node.log and picks up again after a cut (lines around a
# reconnect can repeat). The faults log to RUNDIR/events.log. RUNDIR defaults to
# $CRASHTEST_DIR/runs/NODE-<time>; its path goes to $CRASHTEST_DIR/current-NODE, where the faults find
# it. Stop it by its PID (printed).
#
#   observe/watch.sh NODE [RUNDIR]

. "$(dirname "$0")/../lib/common.sh"
set -u
[ $# -ge 1 ] || { sed -n '3,13p' "$0"; exit 2; }
load_node "$1"
RUN=${2:-$CRASHTEST_DIR/runs/$NODE_NAME-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$RUN"
echo "$RUN" > "$CRASHTEST_DIR/current-$NODE_NAME"
MAC=$(vm_mac)
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-crashtest-%C"
	-o ControlPersist=120 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$NODE")

# One probe on the node: the state line, then eth_syncing, eth_blockNumber and net_peerCount (one JSON
# reply per line).
PROBE="SERVICE='$SERVICE' DATADIR='$DATADIR' RPC='$RPC' WATCH_FILE='$WATCH_FILE'
$(cat <<'PROBE_END'
r() { curl -s -m 5 -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":[]}" "$RPC"; echo; }
st=$(systemctl show "$SERVICE" -p ActiveState -p SubState -p NRestarts --value | paste -sd/)
wf=none; [ -z "$WATCH_FILE" ] || wf=$(sudo -n stat -c '%Y:%s' "$WATCH_FILE" 2>/dev/null || echo missing)
echo "up=$(cut -d. -f1 /proc/uptime) svc=$st file=$wf used=$(df -BG --output=used "$DATADIR" | tail -1 | tr -d ' ')"
r eth_syncing
r eth_blockNumber
r net_peerCount
PROBE_END
)"

HEX='def hex: if type == "string" then ltrimstr("0x") | ascii_downcase | explode
	| reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end)) else . end;'
SYNC="$HEX"' .result | if . == false then "sync=done" elif . == null then "sync=?" else
	"sync=cur:\(.currentBlock|hex),hi:\(.highestBlock|hex),acc:\(.syncedAccounts|hex),slots:\(.syncedStorage|hex),"
	+ "code:\(.syncedBytecodes|hex),healed:\(.healedTrienodes|hex),healing:\(.healingTrienodes|hex),"
	+ "txidx:\(.txIndexRemainingBlocks|hex),stidx:\(.stateIndexRemaining|hex)" end'
NUM="$HEX"' .result | hex'

journal() {
	local since
	while :; do
		since=$(grep -E '^20[0-9]{2}-' "$RUN/node.log" 2>/dev/null | tail -1 | cut -c1-19 | tr T ' ')
		if [ -n "$since" ]; then
			"${SSH[@]}" "sudo -n journalctl -fu '$SERVICE' -o short-iso-precise --no-hostname --since '$since UTC'" >> "$RUN/node.log" 2>> "$RUN/watch.err"
		else
			"${SSH[@]}" "sudo -n journalctl -fu '$SERVICE' -o short-iso-precise --no-hostname -n 200" >> "$RUN/node.log" 2>> "$RUN/watch.err"
		fi
		sleep 5
	done
}
journal &
JPID=$!
trap 'kill "$JPID" $(pgrep -P "$JPID") 2>/dev/null; exit 0' TERM INT
log "watching $NODE_NAME ($NODE, $VM, $MAC) into $RUN; pid $$ (journal $JPID)"

i=0 ref=""
while :; do
	now=$(date -u +%FT%TZ)
	vm=$("${VIRSH[@]}" domstate "$VM" 2>/dev/null | head -1 | tr ' ' _)
	link=$("${VIRSH[@]}" domif-getlink "$VM" "$MAC" 2>/dev/null | awk '{ print $NF }')
	[ $((i % 3)) = 0 ] && ref=$(rpc "$REF" eth_blockNumber 2>/dev/null | jq -r "$NUM" 2>/dev/null)
	out=$(timeout 20 "${SSH[@]}" bash -s <<<"$PROBE" 2>/dev/null)
	if [ -n "$out" ]; then
		state=$(sed -n 1p <<<"$out")
		sync=$(sed -n 2p <<<"$out" | jq -r "$SYNC" 2>/dev/null)
		head=$(sed -n 3p <<<"$out" | jq -r "$NUM" 2>/dev/null)
		peers=$(sed -n 4p <<<"$out" | jq -r "$NUM" 2>/dev/null)
		echo "$now vm=$vm link=$link $state ${sync:-sync=?} head=${head:-?} peers=${peers:-?} ref=${ref:-?}"
	else
		echo "$now vm=$vm link=$link node=unreachable ref=${ref:-?}"
	fi >> "$RUN/watch.log"
	i=$((i + 1))
	sleep 10
done

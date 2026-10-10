# SPDX-License-Identifier: GPL-3.0-or-later
# Shared helpers for node-crashtest's scripts (sourced). Every script works on a node described by an
# env file (see node.env.example), loaded with load_node.

set -o pipefail

CRASHTEST=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Where node descriptions live, and where runs keep their logs (outside the repository).
CRASHTEST_CONFIG=${CRASHTEST_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/node-crashtest}
CRASHTEST_DIR=${CRASHTEST_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/node-crashtest}
VIRSH=(virsh -c qemu:///system)

log() { printf '%s %s\n' "$(date +%T)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Results: one line per check; `finish` prints the verdict and exits 1 if any failed.
FAILED=0
ok() { printf 'OK   %-14s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %-14s %s\n' "$1" "$2"; FAILED=1; }
check() { # NAME EXPECTED ACTUAL [DETAIL]
	if [ "$2" = "$3" ]; then ok "$1" "${4:-$3}"; else fail "$1" "expected '$2', got '$3'"; fi
}
finish() {
	if [ "$FAILED" = 0 ]; then log "all checks passed"; else log "some checks FAILED"; fi
	exit "$FAILED"
}

# wait_until TIMEOUT_S DESCRIPTION COMMAND...: poll every 10 s until COMMAND succeeds. COMMAND runs
# anew each time: pass a function, not a test whose arguments were expanded once.
wait_until() {
	local end=$(( $(date +%s) + $1 )) what=$2
	shift 2
	until "$@"; do
		[ "$(date +%s)" -lt "$end" ] || { log "timed out waiting for: $what"; return 1; }
		sleep 10
	done
}

# Public RPCs for checks against an independent view of the chain.
reference_rpc() {
	case $1 in
	mainnet) echo https://ethereum-rpc.publicnode.com ;;
	sepolia) echo https://ethereum-sepolia-rpc.publicnode.com ;;
	hoodi) echo https://ethereum-hoodi-rpc.publicnode.com ;;
	*) return 1 ;;
	esac
}

# rpc URL METHOD [PARAMS]: a JSON-RPC call's reply (raw JSON), from this machine.
rpc() {
	curl -s -m 60 -H 'Content-Type: application/json' \
		-d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":${3:-[]}}" "$1"
}

# load_node NAME_OR_FILE: the node's settings (NODE_NAME, NODE, SSH_CONFIG, VM, NETWORK, SERVICE,
# SERVICE_USER, DATADIR, RPC, WATCH_FILE, HISTORY_START, HISTORY_START_CMD, FAULTS_OK), from
# $CRASHTEST_CONFIG/nodes/NAME.env or from the file given; then NODE_FILE, that file (what a script
# passes on to the scripts it runs); NODE_SSH, the ssh command for the node; REF, the reference's RPC;
# and RUN, the node's current run directory (the watcher's), if any.
load_node() {
	local f=$1
	[[ $f == */* || $f == *.env ]] || f=$CRASHTEST_CONFIG/nodes/$1.env
	[ -r "$f" ] || die "no node description $f (see lib/node.env.example)"
	NODE_FILE=$(readlink -f "$f")
	NODE="" SSH_CONFIG="" VM="" NETWORK="" SERVICE=geth SERVICE_USER=geth DATADIR=/var/lib/geth RPC=http://127.0.0.1:8545
	WATCH_FILE="" HISTORY_START="" HISTORY_START_CMD="" FAULTS_OK=""
	# shellcheck disable=SC1090
	. "$f"
	NODE_NAME=$(basename "$f" .env)
	[ -n "$NODE" ] || die "$f: NODE (the ssh destination) is missing"
	[ -n "$VM" ] || die "$f: VM (the libvirt domain) is missing"
	NODE_SSH=(ssh)
	[ -z "$SSH_CONFIG" ] || NODE_SSH+=(-F "$SSH_CONFIG")
	REF=$(reference_rpc "$NETWORK") || die "$f: NETWORK '$NETWORK' has no reference RPC"
	RUN=$(cat "$CRASHTEST_DIR/current-$NODE_NAME" 2>/dev/null || true)
}

# faults_allowed: refuse to touch a node that isn't marked as a test node (FAULTS_OK=1), or whose ssh
# destination isn't its VM: power and link faults go to the VM through libvirt, the others (iptables,
# a full disk, a database reset) over ssh, so both must reach the same machine. (Checked while the VM
# has an address libvirt knows: its DHCP lease on a NAT network.)
faults_allowed() {
	[ "${FAULTS_OK:-}" = 1 ] || die "$NODE_NAME isn't marked as a test node (FAULTS_OK=1 in its env file); no faults on it"
	local host addrs
	addrs=$("${VIRSH[@]}" domifaddr "$VM" 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1] }')
	[ -n "$addrs" ] || return 0
	host=$("${NODE_SSH[@]}" -G "$NODE" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')
	[[ $host =~ ^[0-9.]+$ ]] || host=$(getent ahostsv4 "$host" | awk 'NR == 1 { print $1 }')
	grep -qxF "${host:-none}" <<<"$addrs" ||
		die "$NODE_NAME: ssh reaches $NODE at ${host:-an unknown address}, but the VM $VM is at $(paste -sd' ' <<<"$addrs"): not the same machine; no faults"
}

# ev TEXT...: an event, with UTC time to the millisecond, to stdout and the run's events.log.
ev() {
	local line
	line="$(date -u +%FT%T.%3NZ) $*"
	echo "$line"
	[ -z "${RUN:-}" ] || echo "$line" >> "$RUN/events.log"
}

# on COMMAND: run COMMAND on the node (a shell command line, over ssh). A refused connection is tried
# again, 6 times 10 s apart: the node's firewall may limit new ssh connections (to 6 in 30 s, say),
# which a fault's checks right after a boot can exceed. Nothing ran on the node then, so this is
# safe for any command.
on() {
	local err rc i
	err=$(mktemp)
	for i in 1 2 3 4 5 6; do
		"${NODE_SSH[@]}" -o BatchMode=yes "$NODE" "$@" 2>"$err" && rc=0 || rc=$?
		[ "$rc" = 255 ] && [ "$i" -lt 6 ] && grep -q 'Connection refused' "$err" && { sleep 10; continue; }
		break
	done
	cat "$err" >&2
	rm -f "$err"
	return "$rc"
}

# The watcher's shared ssh connection to the node (CONTROL), and one the node's ssh config may share
# (ControlMaster): after a power cut, ssh through them would hang until their keepalives give up, if
# they have any. Faults that cut the power close both at once (drop_shared).
CONTROL="$HOME/.ssh/cm-crashtest-%C"
drop_shared() {
	"${NODE_SSH[@]}" -o "ControlPath=$CONTROL" -O exit "$NODE" 2>/dev/null
	"${NODE_SSH[@]}" -O exit "$NODE" 2>/dev/null
	true
}

# node_rpc METHOD [PARAMS]: a JSON-RPC call to the node, made on the node.
node_rpc() {
	on "curl -s -m 120 -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}' $RPC"
}

# vm_mac: the MAC address of the VM's (first) network interface.
vm_mac() { "${VIRSH[@]}" domiflist "$VM" | awk 'NR > 2 && $5 { print $5; exit }'; }

# history_start: the first block of the node's history (HISTORY_START, or HISTORY_START_CMD run on
# the node), or nothing.
history_start() {
	if [ -n "$HISTORY_START" ]; then echo "$HISTORY_START"
	elif [ -n "$HISTORY_START_CMD" ]; then on "$HISTORY_START_CMD"
	fi
}

# ERROR lines geth logs in normal operation, not counted as failures (but shown):
# - "Cleaning spurious beacon sync leftovers": the downloader's skeleton cleanup.
# - "Beacon backfilling failed ... syncing canceled (requested)": the downloader restarted its own sync
#   cycle (a new head with a gap); it carries on at once.
# - "Reject duplicated disable operation": pathdb, at every start during a snap sync.
# - "SetHead invalidated finalized block": after a crash, the state rewinds to what pathdb had written
#   to disk, which can be thousands of blocks back (it keeps up to 256 MB of recent state in memory),
#   past the finalized block; geth carries on from there. The scenarios show the rewind.
# - "Corrupted index item detected": after a crash, the unsynced end of a freezer table's index can hold
#   zeros; geth truncates it at startup and downloads that part again (the freezer's own repair).
# - "Failed NewPayload/ForkchoiceUpdated ... context deadline exceeded": blsync gives geth 5 s to answer
#   each engine API call, which a node busy syncing can exceed; the next head follows.
# - "Log index initialization failed ... cannot start indexing before history cutoff point": a geth
#   without go-ethereum#35875 builds no log index on a node whose history starts at a custom cutoff
#   (provision/geth.sh's default); eth_getLogs still answers, unindexed (checks/logs.sh compares it).
# - "Truncating ancient chain": after a crash during a snap sync, the freezer can hold blocks beyond the
#   last snap-sync block the key-value store recorded; geth truncates them at startup (by design) and
#   downloads them again.
# - "Blobs unavailable, dropping reorged tx": a reorg put back a blob transaction whose blobs the node
#   never had (it saw the transaction only in a block); the pool can't keep it.
KNOWN_ERRORS='Cleaning spurious beacon sync leftovers|Beacon backfilling failed.*syncing canceled \(requested\)|Reject duplicated disable operation|SetHead invalidated finalized block|Corrupted index item detected|Failed (NewPayload|ForkchoiceUpdated).*context deadline exceeded|Log index initialization failed.*cannot start indexing before history cutoff point|Truncating ancient chain|Blobs unavailable, dropping reorged tx'

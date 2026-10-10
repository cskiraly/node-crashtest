#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A plain geth node on a test VM (provision/vm.sh), as a systemd service, following a public network
# one of two ways:
#  - the light client (default): geth's beacon light client (blsync) on public beacon API endpoints,
#    from a checkpoint file seeded with the current finalized root (geth keeps it current after that);
#  - a consensus client (--cl prysm): Prysm's beacon node on the same VM, checkpoint-synced.
# Then writes the node's description, $CRASHTEST_CONFIG/nodes/NAME.env, with FAULTS_OK=1.
#
#   provision/geth.sh NAME --geth BIN [options]
#
#   --geth BIN             the geth to run: linux/amd64, for Ubuntu 24.04 (glibc 2.39 at most)
#   --network NET          hoodi (default) or sepolia; mainnet with --beacon-api or --cl
#   --beacon-api URL       a beacon API endpoint for the light client (repeatable; defaults below)
#   --cl prysm             Prysm instead of the light client
#   --prysm BIN            its beacon node binary (default: the release pinned below, fetched and
#                          checked on the VM)
#   --checkpoint-sync URL  Prysm's checkpoint sync endpoint, also for the genesis state (defaults below)
#   --history BLOCKS|all   the history geth keeps: about BLOCKS blocks back from the finalized block
#                          (default 50000), or all of it. Chosen once, on the first install
#   --restart POLICY       the units' Restart= (default always: geth stops with exit 0 when the disk is
#                          nearly full, which on-failure doesn't restart)
#   --geth-flags "FLAGS"   more geth flags
#   --cpus N --mem MB --disk GB   for a new VM (defaults 4, 8192, 100)
#
# Without a VM named NAME, creates one. On an existing one made by provision/vm.sh, replaces the
# binaries and the units and restarts the services, keeping the data: the same node on another geth.
# The node: user geth, data in /var/lib/geth, JSON-RPC on 127.0.0.1:8545 (eth, net, web3).

. "$(dirname "$0")/../lib/common.sh"
set -eu

PRYSM_VERSION=v7.2.1
PRYSM_SHA256=b4651effbccb242c181452ac89f176f28186b96e1548a3ed29c5d035fc9cabbc
PRYSM_URL=https://github.com/OffchainLabs/prysm/releases/download/$PRYSM_VERSION/beacon-chain-$PRYSM_VERSION-linux-amd64

usage() { sed -n '3,28p' "$0"; exit 2; }
[ $# -ge 1 ] && [[ $1 != -* ]] || usage
NAME=$1
shift
GETH="" NETWORK=hoodi APIS="" CL="" PRYSM="" CKPT_SYNC="" HISTORY=50000 RESTART=always GETH_FLAGS=""
VMARGS=()
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || usage
	case $1 in
	--geth) GETH=$2 ;;
	--network) NETWORK=$2 ;;
	--beacon-api) APIS="$APIS $2" ;;
	--cl) CL=$2 ;;
	--prysm) PRYSM=$2 ;;
	--checkpoint-sync) CKPT_SYNC=$2 ;;
	--history) HISTORY=$2 ;;
	--restart) RESTART=$2 ;;
	--geth-flags) GETH_FLAGS=$2 ;;
	--cpus | --mem | --disk) VMARGS+=("$1" "$2") ;;
	*) usage ;;
	esac
	shift 2
done
[ -n "$GETH" ] && [ -x "$GETH" ] || die "--geth: an executable geth binary"
[ -z "$PRYSM" ] || [ -x "$PRYSM" ] || die "--prysm: an executable"
[[ $HISTORY =~ ^([0-9]+|all)$ ]] || die "--history: a number of blocks, or all"
case $CL in "" | prysm) ;; *) die "--cl: prysm (or nothing, for the light client)" ;; esac
case $NETWORK in
hoodi)
	DEFAULT_APIS="https://lodestar-hoodi.chainsafe.io http://testing.hoodi.beacon-api.nimbus.team"
	DEFAULT_CKPT=https://checkpoint-sync.hoodi.ethpandaops.io ;;
sepolia)
	DEFAULT_APIS="https://lodestar-sepolia.chainsafe.io"
	DEFAULT_CKPT=https://checkpoint-sync.sepolia.ethpandaops.io ;;
mainnet) DEFAULT_APIS="" DEFAULT_CKPT=https://beaconstate.info ;;
*) die "--network: hoodi, sepolia or mainnet" ;;
esac
APIS=${APIS:-$DEFAULT_APIS}
CKPT_SYNC=${CKPT_SYNC:-$DEFAULT_CKPT}
[ -n "$CL" ] || [ -n "$APIS" ] || die "the light client needs --beacon-api on $NETWORK"
REF=$(reference_rpc "$NETWORK")

NODES=$CRASHTEST_CONFIG/nodes
SSHCFG=$NODES/$NAME.ssh
vm() { ssh -F "$SSHCFG" -o BatchMode=yes "$NAME" "$@"; }

# --- the VM -----------------------------------------------------------------------------------
if "${VIRSH[@]}" dominfo "$NAME" >/dev/null 2>&1; then
	[ "$("${VIRSH[@]}" desc "$NAME")" = "node-crashtest VM" ] && [ -f "$SSHCFG" ] ||
		die "$NAME exists but wasn't made by provision/vm.sh"
	log "updating the node on $NAME"
	vm 'systemctl stop geth prysm 2>/dev/null; true'
else
	log "creating the VM $NAME"
	"$CRASHTEST/provision/vm.sh" create "$NAME" "${VMARGS[@]}" >/dev/null
	vm 'export DEBIAN_FRONTEND=noninteractive; apt-get -qq -o DPkg::Lock::Timeout=600 update &&
		apt-get -qq -o DPkg::Lock::Timeout=600 install -y jq curl iptables >/dev/null' ||
		die "could not install packages on $NAME"
fi

# --- geth ---------------------------------------------------------------------------------------
log "installing geth ($(sha256sum "$GETH" | cut -c1-12))"
vm 'cat > /usr/local/bin/geth.new && chmod 755 /usr/local/bin/geth.new' < "$GETH"
GETH_VERSION=$(vm '/usr/local/bin/geth.new version' | awk -F': ' '/^Version|^Git Commit:/ { printf "%s ", $2 }') ||
	die "this geth doesn't run on $NAME (Ubuntu 24.04: is it linux/amd64, for glibc 2.39 at most?)"
GETH_VERSION=${GETH_VERSION% }
vm 'mv -f /usr/local/bin/geth.new /usr/local/bin/geth
	id geth >/dev/null 2>&1 || useradd --system --home-dir /var/lib/geth --shell /usr/sbin/nologin geth
	install -d -o geth -g geth -m 700 /var/lib/geth
	install -d -m 755 /etc/node-crashtest'

# The history cutoff: chosen once (geth refuses a database whose tail doesn't match --history.chain).
cutoff=$(vm 'cat /etc/node-crashtest/history-chain 2>/dev/null' || true)
if [ -z "$cutoff" ]; then
	if [ "$HISTORY" = all ]; then
		cutoff=all
	else
		fin=$(( $(rpc "$REF" eth_getBlockByNumber '["finalized",false]' | jq -r .result.number) ))
		n=$(( fin > HISTORY ? fin - HISTORY : 0 ))
		hash=$(rpc "$REF" eth_getBlockByNumber "[\"$(printf 0x%x "$n")\",false]" | jq -r .result.hash)
		[[ $hash =~ ^0x[0-9a-f]{64}$ ]] || die "no block $n from the reference ($REF)"
		cutoff=$n:$hash
	fi
	vm "echo '$cutoff' > /etc/node-crashtest/history-chain"
	log "history: $cutoff"
fi
[ "$cutoff" = all ] && HISTORY_START=0 || HISTORY_START=${cutoff%%:*}

flags="--$NETWORK --datadir /var/lib/geth --syncmode snap --history.chain $cutoff"
flags="$flags --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth,net,web3"
WATCH_FILE=""
if [ -z "$CL" ]; then
	# The light client's checkpoint: seeded with the finalized root that the endpoints agree on, unless
	# the file holds one already (geth's own, kept current).
	WATCH_FILE=/var/lib/geth/checkpoint
	if ! vm "[ \"\$(stat -c %s $WATCH_FILE 2>/dev/null)\" = 66 ] && grep -qE '^0x[0-9a-f]{64}\$' $WATCH_FILE"; then
		root=""
		for _ in 1 2 3 4 5; do
			roots=$(for a in $APIS; do
				curl -fsS -m 20 "$a/eth/v1/beacon/headers/finalized" | jq -r .data.root || true
			done | grep -E '^0x[0-9a-f]{64}$' | sort -u)
			[ "$(grep -c . <<<"$roots")" = 1 ] && root=$roots && break
			sleep 15 # none, or the endpoints disagree (finality moved between requests)
		done
		[ -n "$root" ] || die "no finalized root the endpoints agree on ($APIS)"
		vm "printf %s $root > $WATCH_FILE && chown geth:geth $WATCH_FILE && chmod 600 $WATCH_FILE && sync $WATCH_FILE"
		log "checkpoint: $root"
	fi
	for a in $APIS; do flags="$flags --beacon.api $a"; done
	flags="$flags --beacon.checkpoint.file $WATCH_FILE"
else
	flags="$flags --authrpc.addr 127.0.0.1 --authrpc.port 8551 --authrpc.jwtsecret /etc/node-crashtest/jwt.hex"
fi
flags="$flags $GETH_FLAGS"

unit() { # NAME DESCRIPTION USER EXEC
	cat <<EOF
[Unit]
Description=$2 (node-crashtest)
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
User=$3
Group=$3
ExecStart=$4
Restart=$RESTART
RestartSec=10
TimeoutStopSec=300
KillSignal=SIGINT
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}
unit geth geth geth "/usr/local/bin/geth $flags" | vm 'cat > /etc/systemd/system/geth.service'

# --- Prysm -------------------------------------------------------------------------------------
if [ "$CL" = prysm ]; then
	if [ -n "$PRYSM" ]; then
		log "installing Prysm ($(sha256sum "$PRYSM" | cut -c1-12))"
		vm 'cat > /usr/local/bin/beacon-chain && chmod 755 /usr/local/bin/beacon-chain' < "$PRYSM"
	else
		log "installing Prysm $PRYSM_VERSION"
		vm "set -e; d=\$(mktemp -d); curl -sSfL -o \$d/beacon-chain '$PRYSM_URL'
			echo '$PRYSM_SHA256  '\$d/beacon-chain | sha256sum -c --quiet
			install -m 755 \$d/beacon-chain /usr/local/bin/beacon-chain; rm -rf \$d" || die "could not install Prysm"
	fi
	vm 'set -e
		getent group jwt >/dev/null || groupadd --system jwt
		id prysm >/dev/null 2>&1 || useradd --system --home-dir /var/lib/prysm --shell /usr/sbin/nologin prysm
		usermod -aG jwt geth; usermod -aG jwt prysm
		install -d -o prysm -g prysm -m 700 /var/lib/prysm
		[ -s /etc/node-crashtest/jwt.hex ] || openssl rand -hex 32 > /etc/node-crashtest/jwt.hex
		chown root:jwt /etc/node-crashtest/jwt.hex; chmod 640 /etc/node-crashtest/jwt.hex'
	# Its HTTP API (3500) and gRPC (4000) listen on 127.0.0.1 by default.
	unit prysm Prysm prysm "/usr/local/bin/beacon-chain --$NETWORK --datadir /var/lib/prysm --accept-terms-of-use \
--execution-endpoint http://127.0.0.1:8551 --jwt-secret /etc/node-crashtest/jwt.hex \
--checkpoint-sync-url $CKPT_SYNC --genesis-beacon-api-url $CKPT_SYNC" | vm 'cat > /etc/systemd/system/prysm.service'
	vm 'systemctl daemon-reload && systemctl enable -q geth prysm && systemctl restart geth prysm'
else
	vm 'systemctl disable -q --now prysm 2>/dev/null; systemctl daemon-reload && systemctl enable -q geth && systemctl restart geth'
fi

# --- the node's description ---------------------------------------------------------------------
cat > "$NODES/$NAME.env" <<EOF
# Written by node-crashtest's provision/geth.sh on $(date -u +%FT%TZ): geth ${GETH_VERSION:-?}
# ($(sha256sum "$GETH" | cut -c1-12)), ${CL:-the light client}, history from $HISTORY_START.
NODE=$NAME
SSH_CONFIG=$SSHCFG
VM=$NAME
NETWORK=$NETWORK
SERVICE=geth
SERVICE_USER=geth
DATADIR=/var/lib/geth
RPC=http://127.0.0.1:8545
WATCH_FILE=$WATCH_FILE
HISTORY_START=$HISTORY_START
FAULTS_OK=1
EOF
up() { [ -n "$(vm "curl -s -m 5 -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}' http://127.0.0.1:8545" 2>/dev/null)" ]; }
wait_until 300 "geth's RPC on $NAME" up || die "geth doesn't answer on $NAME: see journalctl -u geth there"
log "$NAME: geth ${GETH_VERSION:-?} running (${CL:-light client}); node description $NODES/$NAME.env"

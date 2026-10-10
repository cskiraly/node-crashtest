#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The node's log index after faults. Over WINDOWS windows of 5,000 blocks spread across the node's
# history (from its first block, HISTORY_START or HISTORY_START_CMD, to the head):
#  - on the node, every log eth_getLogs returns (the log index) against the logs in the window's
#    receipts (the raw data; checks/history.sh compares those with the reference);
#  - eth_getLogs for the deposit contract and the window's three busiest addresses, node against the
#    reference (which may refuse queries without an address).
# A log is compared as (block, log index, tx hash, address, topics, data); a side is "<count> <digest>".
# No whole-window queries against public endpoints.
#
#   checks/logs.sh NODE [WINDOWS]   (default 6)

. "$(dirname "$0")/../lib/common.sh"
set -u
[ $# -ge 1 ] || { sed -n '3,12p' "$0"; exit 2; }
load_node "$1"
N=${2:-6}
DEPOSIT=0x00000000219ab540356cbb839cbe05303d7705fa
SPAN=5000

LINE='[.blockNumber, .logIndex, .transactionHash, (.address | ascii_downcase), (.topics | join(",")), .data] | join("|")'
# digest: reads an eth_getLogs reply, prints "<count> <digest>" or the error.
digest() {
	local out
	out=$(jq -r "if .error then \"error: \(.error.message)\" else (.result[] | $LINE) end" 2>/dev/null) || { echo "no answer"; return; }
	if [[ $out == error:* ]]; then echo "$out"; return; fi
	echo "$(grep -c . <<<"$out") $(LC_ALL=C sort <<<"$out" | sha256sum | cut -c1-12)"
}

# On the node, for FROM..TO: "index <count> <digest>", "receipts <count> <digest>", and
# "addr <address> <count> <digest>" for the deposit contract and the window's three busiest addresses.
NODE_SCRIPT=$(cat <<'NODE_END'
r() { curl -s -m 120 -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$RPC"; }
LINE='[.blockNumber, .logIndex, .transactionHash, (.address | ascii_downcase), (.topics | join(",")), .data] | join("|")'
range="\"fromBlock\":\"$(printf 0x%x $FROM)\",\"toBlock\":\"$(printf 0x%x $TO)\""
all=$(r eth_getLogs "[{$range}]" | jq -r ".result[] | $LINE")
echo "index $(grep -c . <<<"$all") $(LC_ALL=C sort <<<"$all" | sha256sum | cut -c1-12)"
ADDRS="$DEPOSIT $(cut -d'|' -f4 <<<"$all" | sort | uniq -c | sort -rn | head -3 | awk '{print $2}' | tr '\n' ' ')"
rec=$(for ((n = FROM; n <= TO; n++)); do r eth_getBlockReceipts "[\"$(printf 0x%x $n)\"]" | jq -r ".result[].logs[] | $LINE"; done)
echo "receipts $(grep -c . <<<"$rec") $(LC_ALL=C sort <<<"$rec" | sha256sum | cut -c1-12)"
for a in $ADDRS; do
	l=$(r eth_getLogs "[{$range,\"address\":\"$a\"}]" | jq -r ".result[] | $LINE")
	echo "addr $a $(grep -c . <<<"$l") $(LC_ALL=C sort <<<"$l" | sha256sum | cut -c1-12)"
done
NODE_END
)

start=$(history_start)
[[ $start =~ ^[0-9]+$ ]] || die "the node's first block is unknown: set HISTORY_START or HISTORY_START_CMD in its env file"
head=$(( $(node_rpc eth_blockNumber | jq -r .result) ))
[ "$head" -gt $((start + SPAN)) ] || die "node head $head too close to its first block $start"
log "history $start-$head; $N windows of $SPAN blocks"
for i in $(seq 0 $((N - 1))); do
	from=$(( start + (head - SPAN - start) * i / (N > 1 ? N - 1 : 1) ))
	to=$(( from + SPAN - 1 ))
	out=$(on "FROM=$from TO=$to DEPOSIT=$DEPOSIT RPC='$RPC' bash -s" <<<"$NODE_SCRIPT")
	idx=$(awk '$1 == "index" {print $2, $3}' <<<"$out")
	rec=$(awk '$1 == "receipts" {print $2, $3}' <<<"$out")
	check "index-$i" "$rec" "$idx" "blocks $from-$to: all $idx logs, as in the receipts"
	while read -r _ a cnt dg; do
		ref=$(rpc "$REF" eth_getLogs "[{\"fromBlock\":\"$(printf 0x%x $from)\",\"toBlock\":\"$(printf 0x%x $to)\",\"address\":\"$a\"}]" | digest)
		check "ref-$i-${a:0:8}" "$ref" "$cnt $dg" "blocks $from-$to, $a: $cnt logs as on the reference"
	done < <(awk '$1 == "addr"' <<<"$out")
done
finish

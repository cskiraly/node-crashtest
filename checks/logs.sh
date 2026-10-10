#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The node's log index after faults. Over WINDOWS windows of 5,000 blocks spread across the node's
# history (from its first block, HISTORY_START or HISTORY_START_CMD, to the reference's finalized
# block or the node's head, the lower):
#  - on the node, every log eth_getLogs returns (the log index) against the logs in the window's
#    receipts (the raw data; checks/history.sh compares those with the reference);
#  - eth_getLogs for the deposit contract and the window's three busiest addresses, node against the
#    reference (which may refuse queries without an address).
# A log is compared as (block, log index, tx hash, address, topics, data); a side is "<count> <digest>".
# An answer missing on the node fails the check; one the reference doesn't give leaves that address
# uncompared (INFO), and the check fails if nothing was compared. No whole-window queries against
# public endpoints. A node without a log index (geth logs "reverting to unindexed mode") answers a
# whole window by reading every receipt: hundreds of MB, minutes; each query on the node gets 15 min.
#
#   checks/logs.sh NODE [WINDOWS]   (default 6)

. "$(dirname "$0")/../lib/common.sh"
set -u
[ $# -ge 1 ] || { sed -n '3,16p' "$0"; exit 2; }
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
# "addr <address> <count> <digest>" for the deposit contract and the window's three busiest addresses;
# "error" for the count and the digest when an answer had no result.
NODE_SCRIPT=$(cat <<'NODE_END'
r() { curl -s -m 900 -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$RPC"; }
T=$(mktemp)
trap 'rm -f "$T"' EXIT
LINE='[.blockNumber, .logIndex, .transactionHash, (.address | ascii_downcase), (.topics | join(",")), .data] | join("|")'
# q METHOD PARAMS FILTER: one line for each thing FILTER makes of the answer's result (an array), or
# "!" if the answer had none.
q() { r "$1" "$2" > "$T" && [ -s "$T" ] && jq -r "if (.result | type) == \"array\" then .result | $3 else \"!\" end" "$T" 2>/dev/null || echo '!'; }
# out NAME LINES: "NAME <count> <digest>", or "NAME error error".
out() { if grep -qx '!' <<<"$2"; then echo "$1 error error"; else echo "$1 $(grep -c . <<<"$2") $(LC_ALL=C sort <<<"$2" | sha256sum | cut -c1-12)"; fi; }
range="\"fromBlock\":\"$(printf 0x%x $FROM)\",\"toBlock\":\"$(printf 0x%x $TO)\""
all=$(q eth_getLogs "[{$range}]" ".[] | $LINE")
out index "$all"
ADDRS="$DEPOSIT $(grep -vx '!' <<<"$all" | cut -d'|' -f4 | sort | uniq -c | sort -rn | head -3 | awk '{print $2}' | tr '\n' ' ')"
rec=$(for ((n = FROM; n <= TO; n++)); do q eth_getBlockReceipts "[\"$(printf 0x%x $n)\"]" ".[].logs[] | $LINE"; done)
out receipts "$rec"
for a in $ADDRS; do out "addr $a" "$(q eth_getLogs "[{$range,\"address\":\"$a\"}]" ".[] | $LINE")"; done
NODE_END
)

start=$(history_start)
[[ $start =~ ^[0-9]+$ ]] || die "the node's first block is unknown: set HISTORY_START or HISTORY_START_CMD in its env file"
head=$(node_rpc eth_blockNumber | jq -r '.result // empty' 2>/dev/null) || true
[[ $head =~ ^0x[0-9a-f]+$ ]] || die "no head from the node"
fin=$(ref_rpc eth_getBlockByNumber '["finalized",false]' | jq -r '.result.number // empty' 2>/dev/null) || true
[[ $fin =~ ^0x[0-9a-f]+$ ]] || die "no finalized block from the reference ($REF)"
top=$(( head < fin ? head : fin ))
[ "$top" -gt $((start + SPAN)) ] || die "the node's history $start-$top is shorter than a window"
log "history $start-$top; $N windows of $SPAN blocks"
compared=0
for i in $(seq 0 $((N - 1))); do
	from=$(( start + (top - SPAN - start) * i / (N > 1 ? N - 1 : 1) ))
	to=$(( from + SPAN - 1 ))
	if ! out=$(on "FROM=$from TO=$to DEPOSIT=$DEPOSIT RPC='$RPC' bash -s" <<<"$NODE_SCRIPT"); then
		fail "window-$i" "blocks $from-$to: the read on the node failed"
		continue
	fi
	idx=$(awk '$1 == "index" { print $2, $3 }' <<<"$out")
	rec=$(awk '$1 == "receipts" { print $2, $3 }' <<<"$out")
	if ! [[ $idx =~ ^[0-9]+\ [0-9a-f]{12}$ && $rec =~ ^[0-9]+\ [0-9a-f]{12}$ ]]; then
		fail "index-$i" "blocks $from-$to: an answer missing on the node (index: ${idx:-none}, receipts: ${rec:-none})"
		continue
	fi
	check "index-$i" "$rec" "$idx" "blocks $from-$to: all ${idx%% *} logs, as in the receipts"
	n=0
	while read -r _ a cnt dg; do
		n=$((n + 1))
		[ "$cnt" != error ] || { fail "addr-$i-${a:0:8}" "blocks $from-$to, $a: no answer on the node"; continue; }
		if ! ref=$(ref_rpc eth_getLogs "[{\"fromBlock\":\"$(printf 0x%x $from)\",\"toBlock\":\"$(printf 0x%x $to)\",\"address\":\"$a\"}]"); then
			info "ref-$i-${a:0:8}" "blocks $from-$to, $a: the reference didn't answer"
			continue
		fi
		compared=$((compared + 1))
		check "ref-$i-${a:0:8}" "$(digest <<<"$ref")" "$cnt $dg" "blocks $from-$to, $a: $cnt logs as on the reference"
	done < <(awk '$1 == "addr"' <<<"$out")
	[ "$n" -gt 0 ] || fail "addr-$i" "blocks $from-$to: no address queried on the node"
done
[ "$compared" -gt 0 ] || fail reference "nothing compared with the reference"
finish

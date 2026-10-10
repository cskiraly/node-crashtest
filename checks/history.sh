#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The node's history after faults: no gap, nothing that differs from the chain. For every block
# FROM..TO on the node: the block (hash, transactions) and its receipts (one per transaction); every
# STEP-th block, the first and the last also against the reference: the same hash and the same
# receipts (a digest of status, cumulative gas and logs).
#
#   checks/history.sh NODE FROM TO [STEP]   (default STEP 100)

. "$(dirname "$0")/../lib/common.sh"
set -u
[ $# -ge 3 ] || { sed -n '3,8p' "$0"; exit 2; }
load_node "$1"
FROM=$2 TO=$3 STEP=${4:-100}
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

# On the node, one ssh session: "number hash txs receipts digest" per block, or "number missing …".
on "FROM=$FROM TO=$TO RPC='$RPC' bash -s" > "$OUT" <<'NODE_END'
r() { curl -s -m 20 -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$RPC"; }
for ((n = FROM; n <= TO; n++)); do
	h=$(printf 0x%x "$n")
	b=$(r eth_getBlockByNumber "[\"$h\",false]" | jq -r '.result | if . == null then "null" else "\(.hash) \(.transactions | length)" end')
	rc=$(r eth_getBlockReceipts "[\"$h\"]" | jq -c '.result | if . == null then null else [.[] | [.status, .cumulativeGasUsed, [.logs[] | [.address, .topics, .data]]]] end')
	if [ "$b" = null ] || [ "$rc" = null ]; then echo "$n missing block=$b receipts=${rc:0:20}"; continue; fi
	echo "$n $b $(jq length <<<"$rc") $(sha256sum <<<"$rc" | cut -c1-12)"
done
NODE_END

missing=$(grep -c ' missing ' "$OUT")
bad=$(awk '$3 != $4 && $2 != "missing"' "$OUT" | wc -l)
total=$(grep -c . "$OUT")
check blocks "$((TO - FROM + 1))" "$total" "$total blocks read from the node"
check gaps 0 "$missing" "no block or receipts missing in $FROM-$TO"
check receipts 0 "$bad" "one receipt per transaction"
[ "$missing" = 0 ] || grep ' missing ' "$OUT" | head -5

diffs=0 compared=0
while read -r n hash _ _ digest; do
	[ "$hash" = missing ] && continue
	if [ $(( (n - FROM) % STEP )) = 0 ] || [ "$n" = "$TO" ]; then
		h=$(printf 0x%x "$n")
		rh=$(rpc "$REF" eth_getBlockByNumber "[\"$h\",false]" | jq -r '.result.hash')
		rrc=$(rpc "$REF" eth_getBlockReceipts "[\"$h\"]" | jq -c '[.result[] | [.status, .cumulativeGasUsed, [.logs[] | [.address, .topics, .data]]]]')
		rd=$(sha256sum <<<"$rrc" | cut -c1-12)
		compared=$((compared + 1))
		if [ "$rh" != "$hash" ] || [ "$rd" != "$digest" ]; then
			diffs=$((diffs + 1)); echo "  block $n: node $hash/$digest, reference $rh/$rd"
		fi
	fi
done < "$OUT"
check reference 0 "$diffs" "$compared blocks compared with the reference (hash and receipts)"
finish

#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The node's history after faults: no gap, nothing that differs from the chain. For every block
# FROM..TO on the node: the block (hash, transactions) and its receipts (one per transaction, the
# block's own: their block hash and their transactions'). Every STEP-th block, the first and the last also against the reference, up to the
# reference's finalized block (above it, a reorg may change a block between the two reads): the same
# hash and the same receipts (a digest of status, cumulative gas and logs). A block the reference
# doesn't answer for stays uncompared (INFO); the check fails if none was compared.
#
#   checks/history.sh NODE FROM TO [STEP]   (default STEP 100)

. "$(dirname "$0")/../lib/common.sh"
set -u
[ $# -ge 3 ] || { sed -n '3,10p' "$0"; exit 2; }
load_node "$1"
FROM=$2 TO=$3 STEP=${4:-100}
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
# What the digest covers, of a block's receipts: the same on the node and here.
RECEIPTS='[.[] | [.status, .cumulativeGasUsed, [.logs[] | [.address, .topics, .data]]]] | tojson'

# On the node, one ssh session: "number hash txs receipts digest" per block, or "number missing …", or
# "number mismatch …": receipts that name another block (twice), lack the block's hash, or aren't one
# per transaction of the block, in its order.
on "FROM=$FROM TO=$TO RPC='$RPC' RECEIPTS='$RECEIPTS' bash -s" > "$OUT" <<'NODE_END' || fail node "the read on the node failed"
r() { curl -s -m 20 -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$RPC"; }
for ((n = FROM; n <= TO; n++)); do
	h=$(printf 0x%x "$n")
	# Twice at most: a reorg between the two reads pairs a block with another block's receipts. The
	# receipts' block: "-" for none, "?" when they don't all name one.
	for try in 1 2; do
		b=$(r eth_getBlockByNumber "[\"$h\",false]" | jq -r '.result | select(type == "object") | "\(.hash) \(.transactions | length) \(.transactions | join(","))"' 2>/dev/null)
		rc=$(r eth_getBlockReceipts "[\"$h\"]" | jq -r ".result | select(type == \"array\") | \"\(if length == 0 then \"-\" else [.[].blockHash] | unique | (if length == 1 and (.[0] | type) == \"string\" then .[0] else \"?\" end) end)|\(length)|\(if all(.[]; .transactionHash | type == \"string\") then [.[].transactionHash] | join(\",\") else \"?\" end)|\($RECEIPTS)\"" 2>/dev/null)
		read -r bh bn bt <<<"$b"
		IFS='|' read -r rh cnt rt dj <<<"$rc"
		[ -n "$bh" ] && [ -n "$rh" ] && [ "$rh" != - ] && [ "$rh" != "$bh" ] || break
	done
	if ! [[ $bh =~ ^0x[0-9a-f]{64}$ && $bn =~ ^[0-9]+$ && $cnt =~ ^[0-9]+$ ]]; then
		echo "$n missing block=${bh:-none} receipts=${cnt:-none}"
	elif { [ "$rh" != - ] && [ "$rh" != "$bh" ]; } || [ "$cnt" != "$bn" ] || [ "$rt" != "$bt" ]; then
		echo "$n mismatch block=$bh txs=$bn receipts=$cnt of=$rh"
	else
		echo "$n $bh $bn $cnt $(sha256sum <<<"$dj" | cut -c1-12)"
	fi
done
NODE_END

# Rows in order, one per block; complete ones; and receipts that aren't the block's.
rows=$(awk -v f="$FROM" '$1 == f + NR - 1' "$OUT" | wc -l)
good=$(awk '$2 ~ /^0x[0-9a-f]{64}$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9a-f]{12}$/' "$OUT" | wc -l)
mism=$(awk '$2 == "mismatch"' "$OUT" | wc -l)
check blocks "$((TO - FROM + 1))" "$rows" "$rows blocks read from the node"
check gaps 0 "$((rows - good - mism))" "no block or receipts missing in $FROM-$TO"
check receipts 0 "$mism" "one receipt per transaction, the block's own"
[ "$rows" = "$good" ] || grep -v ' 0x[0-9a-f]* [0-9]* [0-9]* [0-9a-f]*$' "$OUT" | head -5

fin=$(ref_rpc eth_getBlockByNumber '["finalized",false]' '.result.number | type == "string"' | jq -r .result.number 2>/dev/null) || true
[[ $fin =~ ^0x[0-9a-f]+$ ]] || { fail reference "no finalized block from the reference ($REF)"; finish; }
fin=$((fin))
diffs=0 compared=0 unavailable=0
while read -r n hash _ _ digest; do
	[[ $hash == 0x* ]] && [ "$n" -le "$fin" ] || continue
	if [ $(( (n - FROM) % STEP )) = 0 ] || [ "$n" = "$TO" ] || [ "$n" = "$fin" ]; then
		h=$(printf 0x%x "$n")
		if ! rb=$(ref_rpc eth_getBlockByNumber "[\"$h\",false]" '.result.hash | type == "string"') ||
			! rr=$(ref_rpc eth_getBlockReceipts "[\"$h\"]" '.result | type == "array"'); then
			unavailable=$((unavailable + 1))
			continue
		fi
		rh=$(jq -r '.result.hash' <<<"$rb")
		rd=$(jq -r ".result | $RECEIPTS" <<<"$rr" | sha256sum | cut -c1-12)
		compared=$((compared + 1))
		if [ "$rh" != "$hash" ] || [ "$rd" != "$digest" ]; then
			diffs=$((diffs + 1)); echo "  block $n: node $hash/$digest, reference $rh/$rd"
		fi
	fi
done < "$OUT"
[ "$unavailable" = 0 ] || info reference "$unavailable blocks not compared: the reference didn't answer"
if [ "$compared" = 0 ]; then
	fail reference "no block compared with the reference (its finalized block: $fin)"
else
	check reference 0 "$diffs" "$compared blocks compared with the reference (hash and receipts), up to block $((TO < fin ? TO : fin))"
fi
finish

#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A partial network outage, for the node's own traffic only (the SERVICE_USER's), for SECONDS:
#
#   faults/partial.sh NODE endpoints SECONDS   its HTTP(S) out (tcp 80/443) is reset: beacon API
#                                              endpoints, for a node that follows them
#   faults/partial.sh NODE devp2p SECONDS      everything it sends but tcp 80/443 and DNS is cut, and
#                                              tcp/udp 30303 in: its peers
#
# The rules sit in chains of their own (crashtest-out, crashtest-in; IPv4 and IPv6), loopback
# excepted (its RPC). The VM removes them by itself SECONDS + 60 s after the cut (a transient systemd
# timer), should this script not get to it.

. "$(dirname "$0")/../lib/common.sh"
[ $# = 3 ] && [[ $3 =~ ^[0-9]+$ ]] || { sed -n '3,13p' "$0"; exit 2; }
load_node "$1"
faults_allowed
MODE=$2 FOR=$3

case $MODE in
endpoints)
	OUT='-p tcp -m multiport --dports 80,443 -j REJECT --reject-with tcp-reset'
	IN=''
	;;
devp2p)
	OUT='-p tcp -m multiport ! --dports 80,443 -j REJECT --reject-with tcp-reset
-p udp ! --dport 53 -j DROP'
	IN='-p tcp --dport 30303 -j REJECT --reject-with tcp-reset
-p udp --dport 30303 -j DROP'
	;;
*) sed -n '3,13p' "$0"; exit 2 ;;
esac

# The commands for the node: set up (or take down) the chains in both families.
up="" down=""
for t in iptables ip6tables; do
	up="$up $t -N crashtest-out; $t -N crashtest-in; $t -A crashtest-out -o lo -j RETURN;"
	while IFS= read -r r; do [ -z "$r" ] || up="$up $t -A crashtest-out -m owner --uid-owner $SERVICE_USER $r;"; done <<<"$OUT"
	while IFS= read -r r; do [ -z "$r" ] || up="$up $t -A crashtest-in $r;"; done <<<"$IN"
	up="$up $t -I OUTPUT 1 -j crashtest-out; $t -I INPUT 1 -j crashtest-in;"
	down="$down $t -D OUTPUT -j crashtest-out; $t -D INPUT -j crashtest-in; $t -F crashtest-out; $t -X crashtest-out; $t -F crashtest-in; $t -X crashtest-in;"
done

unit=crashtest-uncut-$$
on "sudo -n sh -c '$down' 2>/dev/null; sudo -n systemd-run -q --unit=$unit --on-active=$((FOR + 60)) /bin/sh -c '$down' && sudo -n sh -c '$up'" ||
	die "could not set up the cut"
trap 'on "sudo -n sh -c \"$down\" 2>/dev/null; sudo -n systemctl stop $unit.timer 2>/dev/null; true"; ev "partial cut ($MODE) on $NODE_NAME restored (interrupted)"; exit 1' INT TERM
ev "partial cut ($MODE) on $NODE_NAME"
sleep "$FOR"
on "sudo -n sh -c '$down'; sudo -n systemctl stop $unit.timer 2>/dev/null; true"
ev "partial cut ($MODE) on $NODE_NAME restored (cut ${FOR} s)"

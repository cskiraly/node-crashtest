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

# The commands for the node: set up the chains in both families (stopping at the first failure), and
# take them down (whatever there is of them; it fails unless a listing of all the rules, itself
# successful, shows none of them). -w: wait for the xtables lock, which another firewall update may
# hold.
up="set -e;" down="" gone=""
for t in iptables ip6tables; do
	T="$t -w 10"
	up="$up $T -N crashtest-out; $T -N crashtest-in; $T -A crashtest-out -o lo -j RETURN;"
	while IFS= read -r r; do [ -z "$r" ] || up="$up $T -A crashtest-out -m owner --uid-owner $SERVICE_USER $r;"; done <<<"$OUT"
	while IFS= read -r r; do [ -z "$r" ] || up="$up $T -A crashtest-in $r;"; done <<<"$IN"
	up="$up $T -I OUTPUT 1 -j crashtest-out; $T -I INPUT 1 -j crashtest-in;"
	for c in out:OUTPUT in:INPUT; do
		down="$down while $T -D ${c#*:} -j crashtest-${c%:*} 2>/dev/null; do :; done; $T -F crashtest-${c%:*} 2>/dev/null; $T -X crashtest-${c%:*} 2>/dev/null;"
	done
	gone="$gone ! { $T -S || echo crashtest-unlisted; } | grep -q crashtest- &&" # no $: systemd-run may expand it
done
down="$down $gone true"

unit=crashtest-uncut-$$
# restore: the rules taken down; then, only once they're gone, the VM's own cleanup cancelled.
restore() { on "sudo -n sh -c '$down'" && on "sudo -n systemctl stop $unit.timer 2>/dev/null; true"; }
on "sudo -n sh -c '$down'" || die "could not remove an earlier cut's rules"
# The VM's own cleanup, should this script not get to it: tried for a minute.
on "sudo -n systemd-run -q --unit=$unit --on-active=$((FOR + 60)) /bin/sh -c 'for i in 1 2 3 4 5 6; do $down && exit 0; sleep 10; done; exit 1'" ||
	die "could not arm the cleanup"
if ! on "sudo -n sh -c '$up'"; then
	restore || log "the rules may still be there: the VM removes them by itself within $((FOR + 60)) s"
	die "could not set up the cut"
fi
trap 'restore && ev "partial cut ($MODE) on $NODE_NAME restored (interrupted)" ||
	ev "partial cut ($MODE) on $NODE_NAME: could not restore; the VM does within $((FOR + 60)) s"; exit 1' INT TERM
ev "partial cut ($MODE) on $NODE_NAME"
sleep "$FOR"
restore || { ev "partial cut ($MODE) on $NODE_NAME: could not restore; the VM does within 60 s"; exit 1; }
ev "partial cut ($MODE) on $NODE_NAME restored (cut ${FOR} s)"

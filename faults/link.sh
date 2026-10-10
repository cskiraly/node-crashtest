#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A network outage: the VM's link down (carrier loss: every connection of the node times out, ssh
# included), for SECONDS, then up again. Interrupted, it puts the link up before exiting.
#
#   faults/link.sh NODE SECONDS

. "$(dirname "$0")/../lib/common.sh"
[ $# = 2 ] && [[ $2 =~ ^[0-9]+$ ]] || { sed -n '3,7p' "$0"; exit 2; }
load_node "$1"
faults_allowed
FOR=$2
MAC=$(vm_mac)
[ -n "$MAC" ] || die "no network interface on $VM"

# up: the link up again, and shared ssh connections closed: during a long outage the node's sshd may
# have dropped them without the client side noticing.
up() { "${VIRSH[@]}" domif-setlink "$VM" "$MAC" up >/dev/null && drop_shared; }
trap 'up; ev "link up $VM (interrupted)"; exit 1' INT TERM
ev "link down $VM"
"${VIRSH[@]}" domif-setlink "$VM" "$MAC" down >/dev/null || die "could not take the link of $VM down"
sleep "$FOR"
up || die "could not put the link of $VM up again"
ev "link up $VM (down ${FOR} s)"

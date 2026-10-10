#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A power cut: a hard power-off of the node's VM (virsh destroy: whatever the guest's kernel hadn't
# written to disk yet is lost), OFF seconds without power, then a boot.
#
#   faults/power.sh NODE [OFF_SECONDS]   (default 30)

. "$(dirname "$0")/../lib/common.sh"
[ $# -ge 1 ] || { sed -n '3,6p' "$0"; exit 2; }
load_node "$1"
faults_allowed
OFF=${2:-30}

ev "power off $VM"
"${VIRSH[@]}" destroy "$VM" >/dev/null || die "could not power off $VM"
drop_shared
sleep "$OFF"
"${VIRSH[@]}" start "$VM" >/dev/null || die "could not start $VM"
ev "power on $VM (off ${OFF} s)"

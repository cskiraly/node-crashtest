#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A full disk: the node's root file system filled to the last block, as root (so the blocks ext4
# reserves for root go too: nothing can write), for SECONDS, then freed. The filler is
# /var/tmp/crashtest-fill*; the VM deletes it by itself SECONDS + 120 s after the start (a transient
# systemd timer), should this script not get to it.
#
#   faults/disk-full.sh NODE SECONDS

. "$(dirname "$0")/../lib/common.sh"
[ $# = 2 ] && [[ $2 =~ ^[0-9]+$ ]] || { sed -n '3,8p' "$0"; exit 2; }
load_node "$1"
faults_allowed
FOR=$2
unit=crashtest-unfill-$$

release() { on "sudo -n rm -f /var/tmp/crashtest-fill /var/tmp/crashtest-fill2; sudo -n systemctl stop $unit.timer 2>/dev/null; df -h / | tail -1"; }
on "sudo -n systemd-run -q --unit=$unit --on-active=$((FOR + 120)) /bin/sh -c 'rm -f /var/tmp/crashtest-fill*'" ||
	die "could not arm the cleanup"
trap 'release; ev "disk full: space freed on $NODE_NAME (interrupted)"; exit 1' INT TERM
ev "disk full: filling / on $NODE_NAME"
# All but 64 MiB at once, then the rest in 1-MiB writes until nothing more fits.
on 'sudo -n sh -c "set -e; free=\$(( \$(stat -f -c %f /) * \$(stat -f -c %S /) )); fallocate -l \$(( free - 67108864 )) /var/tmp/crashtest-fill; dd if=/dev/zero of=/var/tmp/crashtest-fill2 bs=1M status=none 2>/dev/null || true; df -h / | tail -1"'
ev "disk full: / on $NODE_NAME is full"
sleep "$FOR"
release
ev "disk full: space freed on $NODE_NAME (full for ${FOR} s)"

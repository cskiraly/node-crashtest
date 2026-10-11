#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A full disk: the file system that holds the node's data (DATADIR) filled to the last block, as root
# (so the blocks ext4 reserves for root go too: nothing can write), for SECONDS, then freed. The
# fillers are .crashtest-fill* at that file system's top; the VM deletes them by itself SECONDS + 120 s
# after the start (a transient systemd timer), should this script not get to it. Exits 1 if the disk
# couldn't be filled.
#
#   faults/disk-full.sh NODE SECONDS

. "$(dirname "$0")/../lib/common.sh"
[ $# = 2 ] && [[ $2 =~ ^[0-9]+$ ]] || { sed -n '3,10p' "$0"; exit 2; }
load_node "$1"
faults_allowed
FOR=$2
unit=crashtest-unfill-$$
M=$(on "df --output=target $(sq "$DATADIR") | tail -n 1") && [[ $M == /* ]] || die "no file system for $DATADIR on $NODE"
FILL=${M%/}/.crashtest-fill

# release: the fillers removed, by root's shell (the file system's top may be closed to the ssh user);
# then, only once they're gone, the VM's own cleanup cancelled.
GONE="rm -f $(sq "$FILL")*; ! ls -d $(sq "$FILL")* >/dev/null 2>&1"
CLEANUP=/run/crashtest-unfill-$$.sh
release() {
	on "sudo -n sh -c $(sq "$GONE")" &&
		on "sudo -n systemctl stop $unit.timer 2>/dev/null; sudo -n rm -f $CLEANUP; df -h $(sq "$M") | tail -n 1"
}
# The VM's own cleanup: a script in /run, which a transient timer runs (its path in the timer's command
# line, not the paths: systemd would expand a ${...} in them).
printf '%s\nrm -f "$0"\n' "$GONE" | on "sudo -n tee $CLEANUP >/dev/null" &&
	on "sudo -n systemd-run -q --unit=$unit --on-active=$((FOR + 120)) /bin/sh $CLEANUP" || die "could not arm the cleanup"
trap 'release && ev "disk full: space freed on $NODE_NAME (interrupted)" ||
	ev "disk full: could not free the space on $NODE_NAME; the VM does within $((FOR + 120)) s"; exit 1' INT TERM
ev "disk full: filling $M on $NODE_NAME"
# All but 64 MiB at once, then 1-MiB writes until nothing more fits, three times (the node may free
# space meanwhile). Full when not even 64 KiB more can be written. (The free blocks don't tell: ext4
# keeps up to 16 MiB for its own metadata, which no one can fill.)
if ! on "sudo -n bash -s $(sq "$M") $(sq "$FILL")" <<'NODE_END'; then
set -e
f=$(( $(stat -f -c %f "$1") * $(stat -f -c %S "$1") ))
[ "$f" -le 67108864 ] || fallocate -l $(( f - 67108864 )) "$2"
for i in 1 2 3; do dd if=/dev/zero of="$2.$i" bs=1M status=none 2>/dev/null || true; done
df -h "$1" | tail -n 1
! dd if=/dev/zero of="$2.probe" bs=64K count=1 conv=fsync status=none 2>/dev/null || { echo "$1 isn't full" >&2; exit 1; }
NODE_END
	release && ev "disk full: could not fill $M on $NODE_NAME; space freed" ||
		ev "disk full: could not fill $M on $NODE_NAME, nor free it; the VM does within $((FOR + 120)) s"
	exit 1
fi
ev "disk full: $M on $NODE_NAME is full"
sleep "$FOR"
release || { ev "disk full: could not free the space on $NODE_NAME; the VM does within 120 s"; exit 1; }
ev "disk full: space freed on $NODE_NAME (full for ${FOR} s)"

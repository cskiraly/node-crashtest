#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A power cut right after the node rewrites a file: on the node, wait for FILE's mtime to change, by
# default make FILE's file system commit its journal (an fsync of another file on it, as a database's
# own syncs would), then power off at once and boot again. Prints what the file holds after the boot,
# and the service's state.
#
#   faults/power-after-write.sh NODE FILE [--noauto] [--no-fsync] [--off SECONDS] [--timeout SECONDS]
#
# --noauto    remount FILE's file system with noauto_da_alloc first (ext4; until the boot, or back at
#             once if there was no cut): a file rewritten in place without a sync then stays empty on
#             disk until writeback, up to ~30 s, instead of a few microseconds
# --no-fsync  don't force the journal commit; rely on whatever the node syncs itself
# --off       seconds without power (default 5)
# --timeout   how long to wait for the write (default 1800); without one, exit 3 (and no cut)

. "$(dirname "$0")/../lib/common.sh"
[ $# -ge 2 ] || { sed -n '3,15p' "$0"; exit 2; }
load_node "$1"
faults_allowed
FILE=$2
shift 2
NOAUTO=0 FSYNC=1 OFF=5 TIMEOUT=1800
while [ $# -gt 0 ]; do
	case $1 in
	--noauto) NOAUTO=1; shift ;;
	--no-fsync) FSYNC=0; shift ;;
	--off) OFF=$2; shift 2 ;;
	--timeout) TIMEOUT=$2; shift 2 ;;
	*) die "unknown option $1" ;;
	esac
done
[[ $OFF =~ ^[0-9]+$ && $TIMEOUT =~ ^[0-9]+$ ]] || die "--off, --timeout: whole numbers of seconds"

F=$(sq "$FILE")
on "sudo -n test -f $F" || die "no file $FILE on $NODE"
# FILE's file system: its mount point, type and options. Remounted only if it isn't noauto_da_alloc yet.
fs=$(on "findmnt -n -o TARGET,FSTYPE,OPTIONS --target $F") || die "no file system for $FILE on $NODE"
read -r MNT FSTYPE OPTS <<<"$fs"
REMOUNT=0
if [ "$NOAUTO" = 1 ] && [[ ,$OPTS, != *,noauto_da_alloc,* ]]; then
	[ "$FSTYPE" = ext4 ] || die "--noauto: $FILE is on $FSTYPE ($MNT), not ext4"
	REMOUNT=1
fi
# Until the power is off, on any exit: stop the wait, here and on the node (by its name; [l]: not this
# command's own), and mount the file system with auto_da_alloc again if it was turned off here.
waiter=""
restore() {
	[ -z "$waiter" ] || { pkill -P "$waiter" 2>/dev/null; kill "$waiter" 2>/dev/null; }
	on "sudo -n pkill -f 'crashtest-pol[l]-$$'; true"
	[ "$REMOUNT" = 0 ] || on "sudo -n mount -o remount,auto_da_alloc $(sq "$MNT")" ||
		log "$MNT on $NODE may still be mounted with noauto_da_alloc, until its next boot"
}
trap restore EXIT
trap 'exit 1' INT TERM
[ "$REMOUNT" = 0 ] || on "sudo -n mount -o remount,noauto_da_alloc $(sq "$MNT")" ||
	die "could not remount $MNT with noauto_da_alloc"
ev "power-after-write: waiting for $FILE to change (noauto=$NOAUTO fsync=$FSYNC; $MNT: $(on "findmnt -n -o OPTIONS --target $F"))"
# On the node: poll the mtime every 50 ms, for TIMEOUT at most (exit 3); on a change, optionally fsync
# a file on the same file system (a journal commit), print the time and return; exit 4 if a step
# failed. The power goes off as soon as ssh returns. In the background, so that an interrupt ends the
# wait at once.
on "sudo -n bash -s crashtest-poll-$$ $F $TIMEOUT $FSYNC $(sq "${MNT%/}/.crashtest-fsync")" <<'NODE_END' &
m=$(stat -c %y "$2") || exit 4
end=$(( $(date +%s) + $3 ))
while [ "$(stat -c %y "$2" 2>/dev/null)" = "$m" ]; do [ "$(date +%s)" -lt "$end" ] || exit 3; sleep 0.05; done
saved=$(stat -c %y "$2") || exit 4
[ "$4" = 0 ] || echo x | dd of="$5" conv=fsync status=none || exit 4
echo "written $saved, size $(stat -c %s "$2"), committed at $(date -u +%T.%N)"
NODE_END
waiter=$!
rc=0
wait "$waiter" || rc=$?
waiter=""
[ "$rc" != 3 ] || { ev "power-after-write: $FILE didn't change within $TIMEOUT s; no cut"; exit 3; }
[ "$rc" != 4 ] || die "on the node, reading $FILE or the fsync failed; no cut"
[ "$rc" = 0 ] || die "the wait for $FILE failed; no cut"
"${VIRSH[@]}" destroy "$VM" >/dev/null || die "could not power off $VM"
trap - EXIT
trap '"${VIRSH[@]}" start "$VM" >/dev/null 2>&1; ev "power-after-write: power on $VM (interrupted)"; exit 1' INT TERM
ev "power-after-write: power off $VM"
drop_shared
sleep "$OFF"
"${VIRSH[@]}" start "$VM" >/dev/null || die "could not start $VM"
ev "power-after-write: power on $VM"
up() { "${NODE_SSH[@]}" -o ConnectTimeout=5 -o ControlPath=none -o BatchMode=yes "$NODE" true 2>/dev/null; }
wait_until 300 "the VM's ssh" up || die "no ssh after the boot"
# Before the service rewrites it: read it at once. (It may have, if it starts within seconds.)
on "sudo -n stat -c 'after the boot: %s bytes, mtime %y' $F; printf 'content: '; sudo -n head -c 200 $F; echo"
sleep 15
on "systemctl show $SERVICE -p ActiveState -p SubState -p NRestarts | paste -sd' '"
ev "power-after-write: done"

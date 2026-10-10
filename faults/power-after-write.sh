#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A power cut right after the node rewrites a file: on the node, wait for FILE's mtime to change, by
# default make the file system commit its journal (an fsync of another file, as a database's own
# syncs would), then power off at once and boot again. Prints what the file holds after the boot,
# and the service's state.
#
#   faults/power-after-write.sh NODE FILE [--noauto] [--no-fsync] [--off SECONDS] [--timeout SECONDS]
#
# --noauto    remount the root file system with noauto_da_alloc first (ext4; until the boot): a file
#             rewritten in place without a sync then stays empty on disk until writeback, up to
#             ~30 s, instead of a few microseconds
# --no-fsync  don't force the journal commit; rely on whatever the node syncs itself
# --off       seconds without power (default 5)
# --timeout   how long to wait for the write (default 1800); without one, exit 3 (and no cut)

. "$(dirname "$0")/../lib/common.sh"
[ $# -ge 2 ] || { sed -n '3,16p' "$0"; exit 2; }
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

on "sudo -n test -f '$FILE'" || die "no file $FILE on $NODE"
# Until the power is off, on any exit: stop the wait, here and on the node (by its name; [l]: not this
# command's own), and mount / with auto_da_alloc again if it was turned off here.
waiter=""
restore() {
	[ -z "$waiter" ] || { pkill -P "$waiter" 2>/dev/null; kill "$waiter" 2>/dev/null; }
	on "sudo -n pkill -f 'crashtest-pol[l]-$$'; true"
	[ "$NOAUTO" = 0 ] || on 'sudo -n mount -o remount,auto_da_alloc /' ||
		log "/ on $NODE may still be mounted with noauto_da_alloc, until its next boot"
}
trap restore EXIT
trap 'exit 1' INT TERM
[ "$NOAUTO" = 0 ] || on 'sudo -n mount -o remount,noauto_da_alloc /' || die "could not remount / with noauto_da_alloc"
ev "power-after-write: waiting for $FILE to change (noauto=$NOAUTO fsync=$FSYNC; $(on findmnt -n -o OPTIONS /))"
# On the node: poll the mtime every 50 ms, for TIMEOUT at most (exit 3); on a change, optionally fsync
# another file (a journal commit), print the time and return. The power goes off as soon as ssh returns.
# In the background, so that an interrupt ends the wait at once.
on "sudo -n bash -c 'm=\$(stat -c %y \"$FILE\"); end=\$((\$(date +%s) + $TIMEOUT))
	while [ \"\$(stat -c %y \"$FILE\")\" = \"\$m\" ]; do [ \$(date +%s) -lt \$end ] || exit 3; sleep 0.05; done
	saved=\$(stat -c %y \"$FILE\")
	[ $FSYNC = 1 ] && echo x | dd of=/var/tmp/crashtest-fsync conv=fsync status=none
	echo \"written \$saved, size \$(stat -c %s \"$FILE\"), committed at \$(date -u +%T.%N)\"' crashtest-poll-$$" &
waiter=$!
rc=0
wait "$waiter" || rc=$?
waiter=""
[ "$rc" != 3 ] || { ev "power-after-write: $FILE didn't change within $TIMEOUT s; no cut"; exit 3; }
[ "$rc" = 0 ] || die "the wait for $FILE failed"
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
on "sudo -n stat -c 'after the boot: %s bytes, mtime %y' '$FILE'; printf 'content: '; sudo -n head -c 200 '$FILE'; echo"
sleep 15
on "systemctl show $SERVICE -p ActiveState -p SubState -p NRestarts | paste -sd' '"
ev "power-after-write: done"

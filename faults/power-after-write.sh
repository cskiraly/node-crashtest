#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A power cut right after the node rewrites a file: on the node, wait for FILE's mtime to change, by
# default make the file system commit its journal (an fsync of another file, as a database's own
# syncs would), then power off at once and boot again. Prints what the file holds after the boot,
# and the service's state.
#
#   faults/power-after-write.sh NODE FILE [--noauto] [--no-fsync] [--off SECONDS]
#
# --noauto    remount the root file system with noauto_da_alloc first (ext4; until the boot): a file
#             rewritten in place without a sync then stays empty on disk until writeback, up to
#             ~30 s, instead of a few microseconds
# --no-fsync  don't force the journal commit; rely on whatever the node syncs itself
# --off       seconds without power (default 5)

. "$(dirname "$0")/../lib/common.sh"
[ $# -ge 2 ] || { sed -n '3,15p' "$0"; exit 2; }
load_node "$1"
faults_allowed
FILE=$2
shift 2
NOAUTO=0 FSYNC=1 OFF=5
while [ $# -gt 0 ]; do
	case $1 in
	--noauto) NOAUTO=1; shift ;;
	--no-fsync) FSYNC=0; shift ;;
	--off) OFF=$2; shift 2 ;;
	*) die "unknown option $1" ;;
	esac
done

on "sudo -n test -f '$FILE'" || die "no file $FILE on $NODE"
[ "$NOAUTO" = 0 ] || on 'sudo -n mount -o remount,noauto_da_alloc / && findmnt -n -o OPTIONS /'
ev "power-after-write: waiting for $FILE to change (noauto=$NOAUTO fsync=$FSYNC; $(on findmnt -n -o OPTIONS /))"
# On the node: poll the mtime every 50 ms; on a change, optionally fsync another file (a journal
# commit), print the time and return. The power goes off as soon as ssh returns.
on "sudo -n bash -c 'm=\$(stat -c %y \"$FILE\"); while [ \"\$(stat -c %y \"$FILE\")\" = \"\$m\" ]; do sleep 0.05; done
	saved=\$(stat -c %y \"$FILE\")
	[ $FSYNC = 1 ] && echo x | dd of=/var/tmp/crashtest-fsync conv=fsync status=none
	echo \"written \$saved, size \$(stat -c %s \"$FILE\"), committed at \$(date -u +%T.%N)\"'"
"${VIRSH[@]}" destroy "$VM" >/dev/null || die "could not power off $VM"
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

#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Test VMs for nodes (libvirt, qemu:///system): fresh Ubuntu 24.04 cloud images, root over ssh with
# node-crashtest's own key ($CRASHTEST_CONFIG/id_ed25519, made on first use). Each VM gets an ssh
# config of its own, $CRASHTEST_CONFIG/nodes/NAME.ssh (host NAME, with its own known_hosts), so
# ~/.ssh is left alone: `ssh -F ~/.config/node-crashtest/nodes/NAME.ssh NAME`. The VMs are marked as
# made here, and delete refuses any other.
#
#   provision/vm.sh create NAME [--cpus N] [--mem MB] [--disk GB]   (defaults 4, 8192, 100)
#   provision/vm.sh delete NAME     the VM, its disk, its files in $CRASHTEST_CONFIG/nodes
#   provision/vm.sh ip NAME
#   provision/vm.sh list            the VMs made here
#
# Disks are thin (qcow2 on a shared base image), but a node's image grows towards its full size as
# the node rewrites its database (discards don't shrink the file on every host file system, btrfs
# for one): size disks for the node, and check the host's free space first.

. "$(dirname "$0")/../lib/common.sh"
set -eu

BASE=node-crashtest-noble.qcow2
IMAGE_URL=https://cloud-images.ubuntu.com/noble/current
MARK="node-crashtest VM"
KEY=$CRASHTEST_CONFIG/id_ed25519
NODES=$CRASHTEST_CONFIG/nodes

usage() { sed -n '3,16p' "$0"; exit 2; }

vm_ip() {
	"${VIRSH[@]}" domifaddr "$1" 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1]; exit }'
}
ours() { [ "$("${VIRSH[@]}" desc "$1" 2>/dev/null)" = "$MARK" ]; }

ensure_base() {
	"${VIRSH[@]}" vol-info "$BASE" --pool default >/dev/null 2>&1 && return
	local dir img=noble-server-cloudimg-amd64.img
	dir=$(mktemp -d)
	log "downloading the Ubuntu 24.04 cloud image"
	curl -sSfL -o "$dir/$img" "$IMAGE_URL/$img"
	(cd "$dir" && curl -sSfL "$IMAGE_URL/SHA256SUMS" | grep " \*\?$img\$" | sha256sum -c --quiet) || die "image checksum mismatch"
	"${VIRSH[@]}" vol-create-as default "$BASE" "$(stat -c %s "$dir/$img")" --format qcow2 >/dev/null
	"${VIRSH[@]}" vol-upload "$BASE" "$dir/$img" --pool default
	rm -rf "$dir"
}

create() {
	local name=$1 cpus=4 mem=8192 disk=100 ud ip=""
	shift
	while [ $# -gt 0 ]; do
		case $1 in
		--cpus) cpus=$2; shift 2 ;;
		--mem) mem=$2; shift 2 ;;
		--disk) disk=$2; shift 2 ;;
		*) usage ;;
		esac
	done
	[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "NAME: lower-case letters, digits and dashes"
	"${VIRSH[@]}" dominfo "$name" >/dev/null 2>&1 && die "a VM named $name exists already"
	"${VIRSH[@]}" vol-info "$name.qcow2" --pool default >/dev/null 2>&1 && die "a disk $name.qcow2 exists already"
	mkdir -p "$NODES"
	[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C node-crashtest -f "$KEY"
	ensure_base
	"${VIRSH[@]}" vol-create-as default "$name.qcow2" "${disk}G" --format qcow2 \
		--backing-vol "$BASE" --backing-vol-format qcow2 >/dev/null
	ud=$(mktemp)
	cat > "$ud" <<EOF
#cloud-config
hostname: $name
disable_root: false
ssh_pwauth: false
users:
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
EOF
	virt-install --connect qemu:///system --name "$name" --metadata "description=$MARK" \
		--memory "$mem" --vcpus "$cpus" --disk "vol=default/$name.qcow2,discard=unmap" --import \
		--os-variant ubuntu24.04 --network network=default --cloud-init "user-data=$ud" \
		--noautoconsole --graphics none >/dev/null
	rm -f "$ud"
	for _ in $(seq 60); do ip=$(vm_ip "$name"); [ -n "$ip" ] && break; sleep 5; done
	[ -n "$ip" ] || die "$name got no address"
	rm -f "$NODES/$name.known_hosts"
	cat > "$NODES/$name.ssh" <<EOF
# node-crashtest VM $name (provision/vm.sh); deleted with provision/vm.sh delete $name
Host $name
    HostName $ip
    User root
    IdentityFile "$KEY"
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile "$NODES/$name.known_hosts"
    StrictHostKeyChecking accept-new
EOF
	for _ in $(seq 60); do
		ssh -F "$NODES/$name.ssh" -o ConnectTimeout=5 "$name" 'cloud-init status --wait >/dev/null' 2>/dev/null && break
		sleep 5
	done
	ssh -F "$NODES/$name.ssh" -o BatchMode=yes "$name" true || die "no root login on $name ($ip)"
	echo "$ip"
}

delete() {
	local name=$1
	"${VIRSH[@]}" dominfo "$name" >/dev/null 2>&1 || die "no VM named $name"
	ours "$name" || die "$name wasn't made by provision/vm.sh; not deleting it"
	"${VIRSH[@]}" destroy "$name" >/dev/null 2>&1 || true
	"${VIRSH[@]}" undefine "$name" --remove-all-storage >/dev/null || die "could not delete $name"
	rm -f "$NODES/$name.ssh" "$NODES/$name.known_hosts" "$CRASHTEST_DIR/current-$name"
	# Its description too, if it describes this VM.
	! grep -qx "VM=$name" "$NODES/$name.env" 2>/dev/null || rm -f "$NODES/$name.env"
	log "deleted $name"
}

list() {
	local d
	for d in $("${VIRSH[@]}" list --all --name); do
		ours "$d" && printf '%-20s %-10s %s\n' "$d" "$("${VIRSH[@]}" domstate "$d" | head -1)" "$(vm_ip "$d")"
	done
	true
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case $cmd in
create) [ $# -ge 1 ] || usage; create "$@" ;;
delete) [ $# = 1 ] || usage; delete "$1" ;;
ip) [ $# = 1 ] || usage; vm_ip "$1" ;;
list) [ $# = 0 ] || usage; list ;;
*) usage ;;
esac

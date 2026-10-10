# Provisioning

A provisioner sets up a node on a VM and describes it in an env file (`lib/node.env.example`) for
the faults, the watcher, the checks and the scenarios.

## The contract

- a VM in libvirt (`qemu:///system`), reachable over ssh with sudo without a password, running the
  node as a systemd service with its journal in journald, and `curl`, `jq`, `iptables` and
  `fallocate` installed;
- an env file, `~/.config/node-crashtest/nodes/NAME.env`, naming the VM, the ssh destination (and
  an ssh config file of its own, if it needs one), the network, the service, its user, its data
  directory and its RPC address, and `FAULTS_OK=1` once the node may be cut.

node-crashtest doesn't care how the node got there. A project that deploys nodes in its own way
brings its own provisioner, so that the faults hit the node as that project runs it: its systemd
unit and restart policy, its data layout, its configuration.

## Here

| | |
|---|---|
| `vm.sh create NAME [--cpus N] [--mem MB] [--disk GB]` | a test VM: Ubuntu 24.04 cloud image, thin disk, root over ssh with node-crashtest's own key (`~/.config/node-crashtest/id_ed25519`). Its ssh config is a file of its own (`nodes/NAME.ssh`, with its own known_hosts): `~/.ssh` is left alone |
| `vm.sh delete NAME` / `ip NAME` / `list` | delete refuses VMs it didn't make (they carry a mark), and removes the VM's files in `nodes/` |
| `geth.sh NAME --geth BIN [...]` | geth on such a VM (made if missing), as a systemd service: as a light client on public beacon API endpoints (checkpoint file seeded with the finalized root), or next to Prysm (`--cl prysm`, checkpoint sync); a history of 50,000 blocks by default. Writes `nodes/NAME.env`. On an existing VM it replaces the binaries and units and keeps the data: the same node on another geth |

The geth binary must run on Ubuntu 24.04 (glibc 2.39): build it there or in a container, or
statically. The units restart geth after any exit (`--restart`, default `always`): geth stops with
exit status 0 when its disk is nearly full.

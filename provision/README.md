# Provisioning

A provisioner puts a node on a VM and describes it in an env file,
`~/.config/node-crashtest/nodes/NAME.env` (see `lib/node.env.example`): the VM, the ssh destination,
the network, the systemd service and its user, the data directory, the RPC address, and `FAULTS_OK=1`,
without which nothing cuts the node. The VM is in libvirt (`qemu:///system`), reachable over ssh with
sudo without a password, and has `curl`, `jq`, `iptables` and `fallocate`. Faults, and `geth.sh`
before it changes a VM, check that ssh reaches that VM: the machine at the other end must have the
VM's UUID (its firmware's, which libvirt sets), and the VM must be running.

A project that deploys nodes its own way brings its own provisioner, so that the faults hit the node
as that project runs it.

Here:

- `vm.sh create NAME [--cpus N] [--mem MB] [--disk GB]`, `delete NAME`, `ip NAME`, `list`: test VMs
  from the Ubuntu 24.04 cloud image, root over ssh with a key and an ssh config of their own
  (`nodes/NAME.ssh`), so `~/.ssh` is left alone. They carry a mark; `delete` refuses any other VM.
- `geth.sh NAME --geth BIN [--cl prysm] [...]`: geth on such a VM, as a light client on public beacon
  API endpoints or next to Prysm, keeping 50,000 blocks of history by default; it writes the env file.
  Run on an existing node, it swaps the binaries and keeps the data, and the settings it isn't given.
  The binary must run on Ubuntu 24.04 (glibc 2.39).

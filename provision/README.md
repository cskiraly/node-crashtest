# Provisioning

A provisioner sets up a node on a VM and describes it in an env file (`lib/node.env.example`) for
the faults, the watcher and the checks. node-crashtest doesn't care how: a project that deploys
nodes in its own way brings its own provisioner, so that the faults hit the node as that project
runs it (its systemd unit, restart policy, data layout, configuration).

The contract:

- a VM in libvirt (`qemu:///system`), reachable over ssh with passwordless sudo, running the node
  as a systemd service with its journal in journald;
- an env file naming the VM, the ssh destination, the network, the service, its user, its data
  directory and its RPC address, and `FAULTS_OK=1` once the node may be cut.

To come here: a provisioner for plain geth on an Ubuntu cloud image, in beacon light-client mode
(`--beacon.api`) or next to a consensus client.

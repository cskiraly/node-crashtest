# node-crashtest

Crash tests for Ethereum nodes. A node runs in a local VM, syncing or following a public network;
node-crashtest cuts its power or its network, or fills its disk, at a chosen moment, then checks that
it came back on its own, how long it took, and that its data is intact.

## Why VMs

A power cut loses what the kernel hadn't written to disk yet. Killing a process or a container
doesn't: the page cache survives, and the writes in it reach the disk anyway. Writes that were never
synced are exactly where crash bugs hide, so the faults here act on a VM:

- **power:** a hard power-off (`virsh destroy`), then a boot;
- **network:** the VM's link down, or only part of the node's traffic cut inside the guest (its
  beacon API endpoints, or its peer-to-peer traffic);
- **disk:** the root file system filled to the last block;
- **timing:** a power cut the moment the node logs a given line, or right after it rewrites a given
  file.

And on a real network, so that every phase of a sync happens at real size: the state download,
healing, the switch to full sync, the history download, index building.

## What it isn't

[Attacknet](https://github.com/crytic/attacknet) does chaos testing of devnets on Kubernetes, with
Chaos Mesh: network faults, killed or restarted containers, I/O errors and latency, clock skew,
CPU and memory stress, across clients. node-crashtest is complementary: one node on a public network,
real power loss, a real full disk, faults timed on log lines, and the node's data checked against an
independent node.

## Layout

| Directory | What |
|---|---|
| `lib/` | shared helpers (`common.sh`) and the node description |
| `faults/` | power, link, partial cuts, disk full, power cuts timed on a log line or a file write |
| `observe/` | the watcher (a status line every 10 s, the node's journal, an event log), time to new heads, sync phases |
| `checks/` | the node's history (blocks, receipts) and log index against a reference |
| `provision/` | test VMs (`vm.sh`), a plain geth node on one (`geth.sh`), and the interface for a project's own provisioner |
| `scenarios/` | OK/FAIL scenarios built from the above: power cuts through a sync and at the head, network outages, a full disk, a power cut after a file write |

## Quick start

```sh
provision/geth.sh t-node --geth ~/go-ethereum/build/bin/geth   # a VM, geth as a light client on Hoodi
scenarios/sync-cuts.sh t-node     # a power cut at each phase of its first sync (~1-2 h on Hoodi)
scenarios/power-cuts.sh t-node    # then, at the head: power cuts,
scenarios/net-cuts.sh t-node      # network outages,
scenarios/disk-full.sh t-node     # a full disk,
scenarios/write-cut.sh t-node     # a power cut right after geth saves its checkpoint file
provision/vm.sh delete t-node
```

Each scenario prints OK/FAIL lines and exits 0 if all passed; its logs stay in a run directory
(`~/.cache/node-crashtest/runs/`). See `scenarios/README.md`.

## A node

Every script works on a node described by a small env file (`nodes/NAME.env` in the config directory,
`~/.config/node-crashtest` by default): its ssh destination and libvirt domain, its network, its
systemd unit and user, its data directory and RPC address. See `lib/node.env.example`. A provisioner
writes it (`provision/geth.sh`, or a project's own: see `provision/README.md`).

## Requirements

A Linux host with libvirt and KVM (`virsh -c qemu:///system`, `virt-install`, the `default` storage
pool and NAT network), `ssh`, `curl` and `jq`. The node: a VM reachable over ssh with sudo without a
password, running the node as a systemd service, with `journalctl`, `curl`, `jq`, `iptables` (partial
cuts) and `fallocate` (disk full). `provision/vm.sh` makes such VMs from the Ubuntu 24.04 cloud image.

Disk: a node's VM image grows towards its whole disk size over time (a Hoodi node: 100 GB), whatever
the node holds. Check the host's free space before creating one.

## Status

Started in October 2026 from experiments on geth in beacon light-client mode (blsync) on Hoodi, which
found crash and outage bugs fixed in go-ethereum and in the deployment tooling around it. Provisioned
so far: geth, as a light client or next to Prysm.

## License

GPL-3.0-or-later (see `LICENSE`).

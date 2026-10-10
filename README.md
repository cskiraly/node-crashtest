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
| `provision/` | how a node gets set up (an interface: a project brings its own) |
| `scenarios/` | OK/FAIL scenarios built from the above (to come) |

## A node

Every script works on a node described by a small env file (`nodes/NAME.env` in the config directory,
`~/.config/node-crashtest` by default): its ssh destination and libvirt domain, its network, its
systemd unit and user, its data directory and RPC address. See `lib/node.env.example`.

## Requirements

A Linux host with libvirt and KVM (`virsh -c qemu:///system`), `ssh`, `curl` and `jq`. The node: a VM
reachable over ssh with sudo, running the node as a systemd service, with `journalctl`, `iptables`
(partial cuts) and `fallocate` (disk full).

## Status

Started in October 2026 from experiments on geth in beacon light-client mode (blsync) on Hoodi, which
found crash and outage bugs fixed in go-ethereum and in the deployment tooling around it. The faults,
the watcher and the checks are here; provisioners and scenarios come next.

## License

GPL-3.0-or-later (see `LICENSE`).

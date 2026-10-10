# node-crashtest

Crash tests for Ethereum nodes. A node runs in a local VM on a public network; node-crashtest cuts its
power or its network, or fills its disk, at a chosen moment, then checks that the node came back by
itself, how long that took, and that its data is intact.

A VM, because a power cut loses what the kernel hadn't written to disk yet, which killing a process
or a container doesn't, and unsynced writes are where crash bugs hide. A public network, so that every
phase of a sync happens at real size. ([Attacknet](https://github.com/crytic/attacknet) tests devnets
on Kubernetes, with killed containers and network and I/O faults; this is complementary.)

## Quick start

```sh
provision/geth.sh t-node --geth ~/go-ethereum/build/bin/geth   # a VM, geth as a light client on Hoodi
scenarios/sync-cuts.sh t-node     # a power cut at each phase of its first sync
scenarios/power-cuts.sh t-node    # then, at the head:
scenarios/net-cuts.sh t-node
scenarios/disk-full.sh t-node
scenarios/write-cut.sh t-node
provision/vm.sh delete t-node
```

The geth must be v1.17.7 or later, for the history the provisioner keeps by default (50,000 blocks);
an older one with `--history all`. Each scenario prints OK/FAIL lines, exits 0 when all passed, and
keeps its logs in `~/.cache/node-crashtest/runs/`. What each one does: `scenarios/README.md`.

## Layout

| | |
|---|---|
| `faults/` | a power cut (also on a log line, or right after a file write), the link down, part of the node's traffic cut, the disk full |
| `observe/` | the watcher: a status line every 10 s, the node's journal, the events |
| `checks/` | the node's history and log index against a public reference |
| `provision/` | test VMs, and geth on one; a project can bring its own provisioner (`provision/README.md`) |
| `scenarios/` | the OK/FAIL scenarios |
| `lib/` | shared helpers; a node is described by an env file (`lib/node.env.example`) |

## Requirements

A Linux host with KVM and libvirt (`virsh`, `virt-install`, the storage pool `default` and the NAT
network `default`), `ssh`, `curl` and `jq`. A node's VM image grows to its whole disk size over time
(100 GB for a Hoodi node): check the free space first.

## Status

Started in October 2026 from experiments on geth's beacon light client on Hoodi, which found crash bugs
fixed in go-ethereum. Provisioned so far: geth, as a light client or next to Prysm.

## License

GPL-3.0-or-later (see `LICENSE`).

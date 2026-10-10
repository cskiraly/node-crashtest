# Scenarios

    scenarios/NAME.sh NODE [OPTIONS]

Each scenario runs a watcher of its own and applies its faults; after each one it asks: is the node
running again by itself (its RPC answering), does it get a new head, how soon is it at the reference's
head. At the end: no unexpected error in its log, and its history intact. It prints OK, FAIL and INFO
lines, exits 0, 1 (a check failed) or 2 (it couldn't run), and keeps its logs in
`~/.cache/node-crashtest/runs/`.

| Scenario | Faults | Time |
|---|---|---|
| `sync-cuts.sh [--reset]` | a power cut at the start of each phase of geth's sync (state download, chain download, healing, the end of snap sync, log index, the head); then the history and the log index | the sync, plus ~1 h |
| `power-cuts.sh [--cuts N]` | power cuts at the head; shows how far back each one set the node | ~15 min |
| `net-cuts.sh [--link S] [--endpoints S] [--devp2p S]` | the link down 30 min, then only the beacon API endpoints 15 min, then only the peers 5 min | ~1 h |
| `disk-full.sh [--for S]` | the disk full for 2 min | ~10 min |
| `write-cut.sh [--file F]` | a power cut right after the node rewrites a file (a light client's checkpoint), with ext4's `auto_da_alloc` off | ~10 min |

A script run without arguments shows all its options. Limits count from the end of the fault: a new
head within 15 min (5 for `net-cuts`), the reference's head within an hour (30 min for `net-cuts`). The
error lines geth logs in normal operation or after a crash are in `lib/common.sh` (`KNOWN_ERRORS`),
each with its reason. `sync-cuts` and the error check read geth's log lines; the rest works for any
client.

`lib.sh` has the pieces for a new one: `scenario_start`, `require_head`, `after_fault`,
`errors_check`, `history_check`, `logs_check`, `scenario_end`.

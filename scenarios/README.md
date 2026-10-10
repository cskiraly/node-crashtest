# Scenarios

OK/FAIL scenarios built from the faults, the watcher and the checks. Each one starts a watcher of
its own and ends with the same questions: did the node come back without a person, how long until it
followed the chain again, is its log free of unexpected errors, is its history intact.

    scenarios/NAME.sh NODE [OPTIONS]

A scenario prints one line per check (`OK`, `FAIL`, or `INFO` for what is measured but not judged)
and exits 0 when every check passed, 1 when one failed, 2 when it couldn't run (the node wasn't at the
chain's head, say). Its output, the watcher's status lines, the node's journal and the events go to a
run directory, `~/.cache/node-crashtest/runs/NODE-SCENARIO-TIME/`.

| Scenario | Faults | Passes when | Time |
|---|---|---|---|
| `sync-cuts.sh [--reset] [--off S] [--timeout H]` | a power cut at each phase of geth's sync, as the phase's first line appears: state download, chain download, state healing, the end of snap sync, log index rendering, the first block at the head (`--reset`: from an empty database) | the node runs again after every cut, finishes its sync and follows the chain; no unexpected error; history and log index intact | the sync, plus ~1 h of checks |
| `power-cuts.sh [--cuts N] [--off S] [--gap S]` | power cuts at the head (default 3) | a new head within 15 min, at the reference's head within an hour, after each; no unexpected error; history intact. Shows how far back each cut set the node | ~15 min |
| `net-cuts.sh [--link S] [--endpoints S] [--devp2p S] [--new-head S]` | the link down (default 30 min); the node's HTTP(S) out cut (its beacon API endpoints; 15 min); its peer-to-peer traffic cut (5 min) | a new head within `--new-head` (default 5 min) after each, at the reference's head within 30 min; no unexpected error. Shows how far behind it fell meanwhile | ~1 h |
| `disk-full.sh [--for S]` | the root file system full (default 2 min) | the node runs again by itself, a new head within 15 min, at the head within an hour; no unexpected error outside the fault; history intact | ~10 min |
| `write-cut.sh [--file F] [--rounds N] [--keep-auto]` | a power cut right after the node rewrites a file (default: `WATCH_FILE`, a light client's checkpoint), ext4's `auto_da_alloc` off | a new head within 15 min, at the head within an hour, after each; no unexpected error | ~10 min per round |

"Running" means the service is active and the node's RPC answers: a node in a crash loop is active
for a moment at every start. The scenarios that judge the node's log, and `sync-cuts.sh`'s phases,
read geth's log lines; the faults and the other checks work for any client.

## Writing one

`lib.sh` has the pieces: `scenario_start` (a watcher in a run directory of its own), `require_head`,
`after_fault` (running again, a new head, caught up, with the times), `errors_check`, `history_check`,
`logs_check` and `scenario_end`.

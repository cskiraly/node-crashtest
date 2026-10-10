# Scenarios

To come: OK/FAIL scenarios built from the faults, the watcher and the checks, each ending with the
same questions: did the node come back without a person, how long did it take to follow the chain
again, is its history intact.

The first ones, from the experiments this started with (geth in light-client mode, Hoodi):

| Scenario | Faults | Passes when |
|---|---|---|
| power cuts during a sync | power cuts at each sync phase, repeated a few minutes apart, and timed on log lines (the end of snap sync) | the node starts by itself after each, finishes its sync, history and log index intact |
| power cut after a file write | a cut right after the node rewrites a file (e.g. a checkpoint), with `--noauto` | the node starts by itself |
| network outages | the link down for minutes to hours, at the head and during a sync | new heads within a minute or so after the link is back |
| partial outages | only the beacon API endpoints, or only the peers | the node keeps following (peers only), or follows again soon after (endpoints) |
| disk full | the root file system full for minutes | the node starts again by itself once there is room |

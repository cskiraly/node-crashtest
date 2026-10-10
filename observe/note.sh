#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A note in the node's event log (what was done by hand, or why), next to the faults' events.
#
#   observe/note.sh NODE TEXT...

. "$(dirname "$0")/../lib/common.sh"
[ $# -ge 2 ] || { sed -n '3,5p' "$0"; exit 2; }
load_node "$1"
shift
ev "note: $*"

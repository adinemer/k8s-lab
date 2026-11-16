#!/usr/bin/env bash
# breaks/p0-08-containerd-stopped.sh - P0-08 break: containerd stopped on w3.
# Used by re-drills and, later, by incident.sh. Run from a clean snapshot.
# Undo: ssh w3 "sudo systemctl start containerd"
#       (or: revert-all.sh clean)

set -euo pipefail

ssh -o ConnectTimeout=5 w3 "sudo systemctl stop containerd"

echo "break applied"

#!/usr/bin/env bash
# breaks/p0-04-containerd-config.sh - P0-04 break: a TOML syntax error in w1's containerd config.
# Used by re-drills and, later, by incident.sh. Run from a clean snapshot.
# Undo: ssh w1 "sudo sed -i '1d' /etc/containerd/config.toml && sudo systemctl restart containerd"
#       (or: revert-all.sh clean)

set -euo pipefail

# Put an invalid first line in config.toml, then restart containerd so it fails to start.
# "|| true": the restart is expected to fail, and that failure is the break.
ssh -o ConnectTimeout=5 w1 \
  "sudo sed -i '1i this is [not valid toml' /etc/containerd/config.toml &&
   { sudo systemctl restart containerd || true; }"

echo "break applied"

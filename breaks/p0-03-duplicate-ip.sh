#!/usr/bin/env bash
# breaks/p0-03-duplicate-ip.sh - P0-03 break: give w2 the same IP as w1.
# Used by re-drills and, later, by incident.sh. Run from a clean snapshot.
# Undo: sudo virsh snapshot-revert w2 <snapshot> --running   (w2 becomes unreachable by SSH)

set -euo pipefail

# Rewrite w2's address, then apply it 3 seconds after this SSH session has closed,
# so the session ends cleanly instead of hanging.
ssh -o ConnectTimeout=5 w2 \
  "sudo sed -i 's#192.168.150.22/#192.168.150.21/#' /etc/netplan/50-cloud-init.yaml &&
   sudo systemd-run --quiet --on-active=3 netplan apply"

echo "break applied"

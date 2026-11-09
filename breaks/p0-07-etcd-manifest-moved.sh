#!/usr/bin/env bash
# breaks/p0-07-etcd-manifest-moved.sh - P0-07 break: etcd's static pod manifest moved off cp3.
# Used by re-drills and, later, by incident.sh. Run from a clean snapshot.
# Undo: ssh cp3 "sudo mv /root/etcd.yaml /etc/kubernetes/manifests/etcd.yaml"
#       (or: revert-all.sh clean)

set -euo pipefail

# Move the manifest out of the directory the kubelet watches; the kubelet then stops etcd.
# /root is outside /etc/kubernetes/manifests, so the kubelet ignores the file there.
ssh -o ConnectTimeout=5 cp3 \
  "sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml"

echo "break applied"

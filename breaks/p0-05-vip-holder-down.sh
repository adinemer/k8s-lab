#!/usr/bin/env bash
# Break for P0-05 HA control plane: shut down the control-plane node holding the API VIP.
# Runs on the host. Expected result: the kube-vip lease and the VIP move to another
# control-plane node, and kubectl keeps working through api.lab.internal.
# Undo: virsh start <node>, then wait until all 6 nodes are Ready.
set -euo pipefail

VIRSH="virsh -c qemu:///system"

holder=$(kubectl -n kube-system get lease plndr-cp-lock \
  -o jsonpath='{.spec.holderIdentity}')

if [[ -z "$holder" ]]; then
  echo "No kube-vip lease holder found; is the cluster up?" >&2
  exit 1
fi

$VIRSH shutdown "$holder" >/dev/null
echo "Break applied at $(date +%T)."

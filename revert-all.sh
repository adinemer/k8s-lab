#!/usr/bin/env bash
# revert-all.sh NAME - return every lab VM to snapshot NAME, running.
#   ./revert-all.sh pre-break
#   ./revert-all.sh --spec kthw.yaml clean
# Checks that every VM has the snapshot before changing any of them.
# Then waits until the API answers through the VIP and every node is Ready,
# up to WAIT_SECONDS (default 300). A reverted running snapshot resumes with
# stale leases: kube-vip can lose its lease, drop the VIP and restart, so the
# VIP is briefly unanswered ("no route to host"). WAIT_SECONDS=0 skips the
# wait, for a snapshot taken before the cluster existed.
 
source "$(dirname "$0")/lib.sh"
 
usage() { sed -n '2,11p' "$0"; }
parse_args "$@"
[[ ${#ARGS[@]} -eq 1 ]] || die "usage: revert-all.sh [--spec FILE] NAME"
SNAP="${ARGS[0]}"
ARGS=()                                   # revert every node in the spec
 
NODES="$(selected_nodes)"
while read -r NAME _; do
  "${VIRSH[@]}" snapshot-info "$NAME" "$SNAP" >/dev/null 2>&1 ||
    die "$NAME has no snapshot '$SNAP'; nothing was reverted"
done <<< "$NODES"
 
while read -r NAME _; do
  say "$NAME: revert to $SNAP"
  "${VIRSH[@]}" snapshot-revert "$NAME" "$SNAP" --running >/dev/null
done <<< "$NODES"
 
WAIT_SECONDS="${WAIT_SECONDS:-300}"
if (( WAIT_SECONDS > 0 )); then
  deadline=$((SECONDS + WAIT_SECONDS))
  say "waiting for the API through the VIP (up to ${WAIT_SECONDS}s)"
  until kubectl get --raw='/readyz' >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "API not answering after ${WAIT_SECONDS}s; check: kubectl get --raw='/readyz?verbose'"
    sleep 5
  done
  left=$((deadline - SECONDS)); (( left > 0 )) || left=1
  say "waiting for every node to be Ready (up to ${left}s)"
  kubectl wait --for=condition=Ready node --all --timeout="${left}s" >/dev/null ||
    die "not every node is Ready; check: kubectl get nodes"
  kubectl get nodes
  say "lease holder: $(kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}')"
fi
 
say "done"
 
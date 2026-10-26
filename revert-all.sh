#!/usr/bin/env bash
# revert-all.sh NAME - return every lab VM to snapshot NAME, running.
#   ./revert-all.sh pre-break
#   ./revert-all.sh --spec kthw.yaml clean
# Checks that every VM has the snapshot before changing any of them.

source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,5p' "$0"; }
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

say "done"

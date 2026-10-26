#!/usr/bin/env bash
# snapshot-all.sh NAME - snapshot every lab VM under NAME (for example clean, pre-break).
#   ./snapshot-all.sh pre-break
#   ./snapshot-all.sh --spec kthw.yaml clean
# An older snapshot with the same NAME is replaced.

source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,5p' "$0"; }
parse_args "$@"
[[ ${#ARGS[@]} -eq 1 ]] || die "usage: snapshot-all.sh [--spec FILE] NAME"
SNAP="${ARGS[0]}"
ARGS=()                                   # snapshot every node in the spec

NODES="$(selected_nodes)"              # stops here if a name is wrong
while read -r NAME _; do
  vm_exists "$NAME" || die "$NAME does not exist; run lab-up.sh first"
  if "${VIRSH[@]}" snapshot-info "$NAME" "$SNAP" >/dev/null 2>&1; then
    "${VIRSH[@]}" snapshot-delete "$NAME" "$SNAP" >/dev/null
  fi
  say "$NAME: snapshot $SNAP"
  "${VIRSH[@]}" snapshot-create-as "$NAME" "$SNAP" --atomic >/dev/null
done <<< "$NODES"

say "done"

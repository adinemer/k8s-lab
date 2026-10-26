#!/usr/bin/env bash
# lab-down.sh - destroy lab VMs and delete their disks and snapshots.
#   ./lab-down.sh            destroy every node in lab.yaml
#   ./lab-down.sh cp2        destroy only cp2
#   ./lab-down.sh --spec kthw.yaml   use another spec file
# The base image and the libvirt network are never touched.

source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,6p' "$0"; }
parse_args "$@"

NODES="$(selected_nodes)"              # stops here if a name is wrong
while read -r NAME _; do
  if ! vm_exists "$NAME"; then
    say "$NAME does not exist, skipping"
    continue
  fi
  say "destroying $NAME"
  "${VIRSH[@]}" destroy "$NAME" >/dev/null 2>&1 || true        # power off (fine if already off)
  "${VIRSH[@]}" undefine "$NAME" --snapshots-metadata >/dev/null # forget the VM and its snapshot list
  sudo rm -f "$DISK_DIR/$NAME.qcow2" "$DISK_DIR/$NAME-seed.iso" # disk (holds the snapshots) and seed CD
done <<< "$NODES"

say "done"

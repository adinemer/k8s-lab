# lib.sh - shared helpers for lab-up.sh, lab-down.sh, snapshot-all.sh, revert-all.sh.
# Not run directly; the other scripts load it with "source".

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # folder these scripts live in
SPEC="$LAB_DIR/lab.yaml"                                  # default spec, changed by --spec
VIRSH=(sudo virsh -c qemu:///system)                      # always talk to the system libvirt
DISK_DIR="/var/lib/libvirt/images/k8s-lab"                # where VM disks are kept

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

# parse_args "$@": reads --spec FILE, and leaves the other words in ARGS.
parse_args() {
  ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --spec) [[ $# -ge 2 ]] || die "--spec needs a file"; SPEC="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done
  [[ -f "$SPEC" ]] || die "spec file not found: $SPEC"
}

# net_get KEY: prints one value from the "network:" section of the spec.
net_get() {
  awk -v key="$1:" '
    /^network:/ { inside = 1; next }
    inside && /^[^ ]/ { inside = 0 }
    inside && $1 == key { print $2; exit }
  ' "$SPEC"
}

# top_get KEY: prints a top-level value (for example "image:"), or nothing.
top_get() {
  awk -v key="$1:" '$1 == key { print $2; exit }' "$SPEC"
}

# all_nodes: prints one line per node: "name ip vcpu ram_gib disk_gib".
all_nodes() {
  grep -E '^[[:space:]]*-[[:space:]]*\{[[:space:]]*name:' "$SPEC" |
    sed -E 's/.*name:[[:space:]]*([^,[:space:]]+)[[:space:]]*,[[:space:]]*ip:[[:space:]]*([^,[:space:]]+)[[:space:]]*,[[:space:]]*vcpu:[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*ram_gib:[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*disk_gib:[[:space:]]*([0-9]+).*/\1 \2 \3 \4 \5/'
}

# selected_nodes: the nodes named in ARGS, or every node when ARGS is empty.
selected_nodes() {
  local nodes; nodes="$(all_nodes)"
  [[ -n "$nodes" ]] || die "no nodes found in $SPEC"
  if [[ ${#ARGS[@]} -eq 0 ]]; then
    echo "$nodes"; return
  fi
  local want line found
  for want in "${ARGS[@]}"; do
    found=""
    while read -r line; do
      [[ "${line%% *}" == "$want" ]] && { echo "$line"; found=1; }
    done <<< "$nodes"
    [[ -n "$found" ]] || die "node '$want' is not in $SPEC"
  done
}

# vm_exists NAME: true if libvirt already has a VM with that name.
vm_exists() { "${VIRSH[@]}" dominfo "$1" >/dev/null 2>&1; }

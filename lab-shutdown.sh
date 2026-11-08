#!/usr/bin/env bash
# lab-shutdown.sh - shut down the running lab VMs, in order.
#   ./lab-shutdown.sh
#   ./lab-shutdown.sh --spec kthw.yaml   use another spec file
# 1. w1, w2 and w3, then waits until all three are shut off
# 2. cp2 and cp3, then waits until both are shut off
# 3. cp1 last
# Each VM gets a clean shutdown (virsh shutdown, like pressing the power button).
# A VM still running after WAIT_SECONDS (default 180) is forced off with
# virsh destroy, like pulling the plug, and the script says which ones.
# A VM that is already shut off is not touched. The network is left running.

source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,11p' "$0"; }
parse_args "$@"
[[ ${#ARGS[@]} -eq 0 ]] || die "lab-shutdown.sh takes no node names; it stops the whole lab"

WAIT_SECONDS="${WAIT_SECONDS:-180}"

# stop_vms NAME...: shut down each running VM and wait until all are shut off;
# force off any VM still running after WAIT_SECONDS.
stop_vms() {
  local n state waiting=() still=()
  for n in "$@"; do
    vm_exists "$n" || { say "$n does not exist, skipping"; continue; }
    state="$(vm_state "$n")"
    if [[ "$state" == "shut off" ]]; then
      say "$n already shut off"
    else
      say "shutting down $n"
      "${VIRSH[@]}" shutdown "$n" >/dev/null
      waiting+=("$n")
    fi
  done
  [[ ${#waiting[@]} -gt 0 ]] || return 0

  local deadline=$((SECONDS + WAIT_SECONDS))
  while :; do
    still=()
    for n in "${waiting[@]}"; do
      [[ "$(vm_state "$n")" == "shut off" ]] || still+=("$n")
    done
    [[ ${#still[@]} -gt 0 ]] || break
    if (( SECONDS >= deadline )); then
      for n in "${still[@]}"; do
        say "$n still running after ${WAIT_SECONDS}s: forcing it off (virsh destroy)"
        "${VIRSH[@]}" destroy "$n" >/dev/null
      done
      break
    fi
    sleep 5
  done
  for n in "${waiting[@]}"; do say "$n shut off"; done
}

mapfile -t CPS < <(cp_nodes)
mapfile -t WORKERS < <(worker_nodes)
[[ ${#CPS[@]} -gt 0 ]] || die "no cp* nodes in $SPEC"

# Workers first, then every control plane node but the first, then the first.
if [[ ${#WORKERS[@]} -gt 0 ]]; then stop_vms "${WORKERS[@]}"; fi
if [[ ${#CPS[@]} -gt 1 ]];     then stop_vms "${CPS[@]:1}";  fi
stop_vms "${CPS[0]}"

say "done. Start the lab again with: ./lab-start.sh"

#!/usr/bin/env bash
# lab-start.sh - start the lab VMs that are shut off, in order.
#   ./lab-start.sh
#   ./lab-start.sh --spec kthw.yaml   use another spec file
# 1. starts the lab network if it is not active
# 2. routes *.lab.internal lookups on the host to the lab DNS (resolvectl)
# 3. cp1, then waits until it answers SSH
# 4. cp2 and cp3, then waits until both answer SSH
# 5. w1, w2 and w3, then waits until all three answer SSH
# A VM that is already running is not touched, so running it twice is safe.
# Each stage waits up to WAIT_SECONDS (default 300) before giving up.

source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,11p' "$0"; }
parse_args "$@"
[[ ${#ARGS[@]} -eq 0 ]] || die "lab-start.sh takes no node names; it starts the whole lab"

WAIT_SECONDS="${WAIT_SECONDS:-300}"
NET_NAME="$(net_get name)"

# start_vms NAME...: start each VM that is shut off.
start_vms() {
  local n state
  for n in "$@"; do
    vm_exists "$n" || die "$n does not exist; create it with ./lab-up.sh $n"
    state="$(vm_state "$n")"
    case "$state" in
      running)    say "$n already running" ;;
      "shut off") say "starting $n"; "${VIRSH[@]}" start "$n" >/dev/null ;;
      *)          die "$n is '$state'; start it by hand or fix it first" ;;
    esac
  done
}

# wait_ssh NAME...: wait until every VM answers SSH, or stop after WAIT_SECONDS.
wait_ssh() {
  local n deadline=$((SECONDS + WAIT_SECONDS))
  for n in "$@"; do
    until ssh -o ConnectTimeout=5 -o BatchMode=yes "$n" true 2>/dev/null; do
      (( SECONDS < deadline )) || die "$n did not answer SSH within ${WAIT_SECONDS}s"
      sleep 5
    done
    say "$n answers SSH"
  done
}

# 1. The network the VMs plug into.
"${VIRSH[@]}" net-info "$NET_NAME" >/dev/null 2>&1 || die "network $NET_NAME is not defined; run ./lab-up.sh"
if [[ ! "$("${VIRSH[@]}" net-info "$NET_NAME")" =~ Active:[[:space:]]+yes ]]; then
  say "starting network $NET_NAME"
  "${VIRSH[@]}" net-start "$NET_NAME" >/dev/null
fi

# 2. Host DNS for the lab domain (lib.sh).
lab_dns

# 3-5. Control plane first: the first node, then the others; workers last.
mapfile -t CPS < <(cp_nodes)
mapfile -t WORKERS < <(worker_nodes)
[[ ${#CPS[@]} -gt 0 ]] || die "no cp* nodes in $SPEC"

start_vms "${CPS[0]}";     wait_ssh "${CPS[0]}"
if [[ ${#CPS[@]} -gt 1 ]]; then
  start_vms "${CPS[@]:1}"; wait_ssh "${CPS[@]:1}"
fi
if [[ ${#WORKERS[@]} -gt 0 ]]; then
  start_vms "${WORKERS[@]}"; wait_ssh "${WORKERS[@]}"
fi

say "done. All VMs answer SSH; Kubernetes may need a minute more. Check: kubectl get nodes"

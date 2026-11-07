#!/usr/bin/env bash
# cluster-up.sh - turn prepared lab VMs into the HA cluster (unit P0-06).
#   ./cluster-up.sh
# Run on the host, after lab-up.sh and node-prep.sh on all 6 nodes.
# Does by script what P0-05 did by hand:
#   1. host can resolve api.lab.internal
#   2. kube-vip static pod on cp1, then kubeadm init on cp1 (kubeadm-config.yaml)
#   3. cp2 and cp3 join as control plane, each gets kube-vip
#   4. w1-w3 join as workers
#   5. kubeconfig copied to the host, Cilium installed with Helm
#   6. waits until every node is Ready
# Safe to run again: a node that has already joined is skipped.

source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,12p' "$0"; }
parse_args "$@"

KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-v1.3.1}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.4}"
VIP_IFACE="${VIP_IFACE:-enp1s0}"               # the VMs' only NIC
VIP="$(awk '/^vip:/ { for (i = 1; i <= NF; i++) if ($i == "ip:") print $(i+1) }' "$SPEC" | tr -d '},')"
DOMAIN="$(net_get domain)"
GATEWAY="$(net_get gateway)"
BRIDGE="$(net_get bridge)"
API_NAME="api.$DOMAIN"
KUBECONFIG_HOST="$HOME/.kube/config"

[[ -n "$VIP" ]] || die "no vip ip in $SPEC"

CPS=(); WORKERS=()
while read -r NAME _; do
  case "$NAME" in
    cp*) CPS+=("$NAME") ;;
    *)   WORKERS+=("$NAME") ;;
  esac
done <<< "$(all_nodes)"
FIRST_CP="${CPS[0]}"

on() { local n=$1; shift; ssh "$n" "$@"; }        # run a command on a node
joined() { on "$1" 'sudo test -f /etc/kubernetes/kubelet.conf'; }

# ---------------------------------------------------------------- 0. checks
for n in "${CPS[@]}" "${WORKERS[@]}"; do
  on "$n" true 2>/dev/null || die "cannot ssh to $n; run lab-up.sh and wait for boot"
  on "$n" 'command -v kubeadm >/dev/null' || die "$n has no kubeadm; run node-prep.sh on it first"
done
command -v kubectl >/dev/null || die "kubectl not found on the host"
command -v helm >/dev/null || die "helm not found on the host"

# ---------------------------------------------------------------- 1. host DNS
# libvirt's dnsmasq on the gateway knows api.lab.internal. Route the lab domain
# there. resolvectl settings last until the bridge goes down, so check every run.
if ! getent hosts "$API_NAME" >/dev/null; then
  say "routing ~$DOMAIN to $GATEWAY on $BRIDGE"
  sudo resolvectl dns "$BRIDGE" "$GATEWAY"
  sudo resolvectl domain "$BRIDGE" "~$DOMAIN"
  getent hosts "$API_NAME" >/dev/null || die "host still cannot resolve $API_NAME"
fi

# kube_vip NODE CONF: write the kube-vip static pod on NODE, reading CONF
# (admin.conf normally; super-admin.conf only on the first node during init).
kube_vip() {
  local node=$1 conf=$2
  say "$node: kube-vip $KUBE_VIP_VERSION static pod ($conf)"
  on "$node" "sudo bash -s" <<EOF
set -euo pipefail
img=ghcr.io/kube-vip/kube-vip:$KUBE_VIP_VERSION
ctr -n k8s.io image pull "\$img" >/dev/null
mkdir -p /etc/kubernetes/manifests
ctr -n k8s.io run --rm --net-host "\$img" kube-vip-gen /kube-vip manifest pod \
  --interface $VIP_IFACE --address $VIP --controlplane --arp --leaderElection \
  | sed 's#/etc/kubernetes/admin.conf#/etc/kubernetes/$conf#' > /etc/kubernetes/manifests/kube-vip.yaml
EOF
}

# ---------------------------------------------------------------- 2. first control plane
if joined "$FIRST_CP"; then
  say "$FIRST_CP already initialised, skipping init"
else
  # admin.conf has no rights until init has bound it to cluster-admin, so the
  # first kube-vip uses super-admin.conf, then switches back once init is done.
  kube_vip "$FIRST_CP" super-admin.conf
  say "$FIRST_CP: kubeadm init"
  scp -q "$LAB_DIR/kubeadm-config.yaml" "$FIRST_CP:/tmp/kubeadm-config.yaml"
  on "$FIRST_CP" 'sudo kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs' \
    > "$LAB_DIR/kubeadm-init.log" || die "kubeadm init failed; see kubeadm-init.log"
  on "$FIRST_CP" "sudo sed -i 's#/etc/kubernetes/super-admin.conf#/etc/kubernetes/admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml"
fi

# ---------------------------------------------------------------- 3 + 4. joins
# A fresh token and certificate key on every run, so a rerun days later still works.
JOIN="$(on "$FIRST_CP" 'sudo kubeadm token create --print-join-command')"
CERT_KEY="$(on "$FIRST_CP" 'sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1')"
[[ -n "$JOIN" && -n "$CERT_KEY" ]] || die "could not get a join command from $FIRST_CP"

for n in "${CPS[@]:1}"; do
  if joined "$n"; then say "$n already joined, skipping"; continue; fi
  say "$n: join as control plane"
  on "$n" "sudo $JOIN --control-plane --certificate-key $CERT_KEY" >/dev/null ||
    die "$n failed to join"
  kube_vip "$n" admin.conf
done

for n in "${WORKERS[@]}"; do
  if joined "$n"; then say "$n already joined, skipping"; continue; fi
  say "$n: join as worker"
  on "$n" "sudo $JOIN" >/dev/null || die "$n failed to join"
done

# ---------------------------------------------------------------- 5. kubeconfig + Cilium
mkdir -p "$(dirname "$KUBECONFIG_HOST")"
if [[ -f "$KUBECONFIG_HOST" ]] && ! cmp -s <(on "$FIRST_CP" 'sudo cat /etc/kubernetes/admin.conf') "$KUBECONFIG_HOST"; then
  cp "$KUBECONFIG_HOST" "$KUBECONFIG_HOST.bak-$(date +%Y%m%d-%H%M%S)"
fi
on "$FIRST_CP" 'sudo cat /etc/kubernetes/admin.conf' > "$KUBECONFIG_HOST"
chmod 600 "$KUBECONFIG_HOST"
say "kubeconfig written to $KUBECONFIG_HOST"

say "Cilium $CILIUM_VERSION"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
  --namespace kube-system --set ipam.mode=kubernetes >/dev/null

# ---------------------------------------------------------------- 6. wait
say "waiting for all nodes to be Ready (up to 10 min)"
kubectl wait --for=condition=Ready node --all --timeout=600s >/dev/null ||
  die "not every node is Ready; check: kubectl get nodes"
kubectl get nodes -o wide
say "done. Lease holder: $(kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}')"

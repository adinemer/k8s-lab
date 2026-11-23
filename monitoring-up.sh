#!/usr/bin/env bash
# monitoring-up.sh - install the observability stack from unit P0-08.
#   ./monitoring-up.sh
# Run on the host, after cluster-up.sh (all 6 nodes Ready).
#   1. metrics-server in kube-system, with --kubelet-insecure-tls
#      (lab shortcut: kubelet serving certificates are self-signed)
#   2. kube-prometheus-stack in namespace monitoring, chart defaults
#   3. waits until both are running, then checks kubectl top nodes
# Safe to run again: helm upgrade --install changes only what differs.
# The control-plane metrics bindings (0.0.0.0) are not set here: they come
# from kubeadm-config.yaml, which cluster-up.sh already used.

source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,11p' "$0"; }
parse_args "$@"

command -v kubectl >/dev/null || die "kubectl not found on the host"
command -v helm >/dev/null || die "helm not found on the host"
kubectl get nodes >/dev/null 2>&1 || die "cannot reach the cluster; run cluster-up.sh first"

# ---------------------------------------------------------------- 1. metrics-server
say "metrics-server"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' >/dev/null

# ---------------------------------------------------------------- 2. kube-prometheus-stack
say "kube-prometheus-stack in namespace monitoring"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace >/dev/null

# ---------------------------------------------------------------- 3. wait and check
say "waiting for metrics-server (up to 5 min)"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s >/dev/null ||
  die "metrics-server is not ready; check: kubectl -n kube-system get pods"

say "waiting for every pod in monitoring to be Ready (up to 10 min)"
kubectl -n monitoring wait --for=condition=Ready pod --all --timeout=600s >/dev/null ||
  die "not every monitoring pod is Ready; check: kubectl -n monitoring get pods"

# metrics-server needs one scrape cycle before kubectl top answers.
for _ in $(seq 1 12); do
  kubectl top nodes >/dev/null 2>&1 && break
  sleep 10
done
kubectl top nodes || die "kubectl top nodes still fails; check: kubectl -n kube-system logs deploy/metrics-server"

kubectl -n monitoring get pods
say "done. Prometheus UI: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090"

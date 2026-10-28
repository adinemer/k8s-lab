#!/usr/bin/env bash
# node-prep.sh - prepare one Ubuntu node for kubeadm (unit P0-04).
#
# Run as root ON the node. From the host, for every node:
#   for n in cp1 cp2 cp3 w1 w2 w3; do ssh "$n" 'sudo bash -s' < node-prep.sh; done
#
# Safe to run again: every step checks the current state first and only
# changes what is different.
#
# What it does:
#   1. swap off (now and after reboot)
#   2. kernel modules overlay + br_netfilter (now and after reboot)
#   3. sysctls for bridged traffic and IP forwarding
#   4. containerd 2.x, systemd cgroups, crictl pointed at it
#   5. kubeadm / kubelet / kubectl from the v1.35 repo, held

set -euo pipefail

K8S_MINOR="${K8S_MINOR:-1.35}"   # N-2, from lab.yaml

log()  { echo "[node-prep] $*"; }
fail() { echo "[node-prep] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root (sudo bash node-prep.sh)"
export DEBIAN_FRONTEND=noninteractive

# write_file PATH CONTENT
# Writes CONTENT to PATH only if it differs. Returns 0 if it wrote, 1 if not.
write_file() {
  local path=$1 content=$2
  if [[ -f $path && "$(cat "$path")" == "$content" ]]; then
    return 1
  fi
  printf '%s\n' "$content" > "$path"
  log "wrote $path"
  return 0
}

# ---------------------------------------------------------------- 1. swap
if swapon --show --noheadings | grep -q .; then
  swapoff -a
  log "swap turned off"
fi
# Comment out any swap line in fstab so it stays off after reboot.
sed -ri '/^[^#].*\sswap\s/ s/^/#/' /etc/fstab

# ---------------------------------------------------------------- 2. modules
write_file /etc/modules-load.d/k8s.conf $'overlay\nbr_netfilter' || true
modprobe overlay
modprobe br_netfilter

# ---------------------------------------------------------------- 3. sysctls
write_file /etc/sysctl.d/99-k8s.conf \
$'net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1' || true
sysctl --system >/dev/null

# ---------------------------------------------------------------- 4. containerd
apt-get update -qq
apt-get install -y -qq ca-certificates curl gpg >/dev/null

if ! dpkg -s containerd >/dev/null 2>&1; then
  apt-get install -y -qq containerd >/dev/null
  log "containerd installed"
fi

ctr_ver=$(containerd --version | awk '{print $3}' | sed 's/^v//')
[[ ${ctr_ver%%.*} -ge 2 ]] || fail "containerd is $ctr_ver, not 2.x; stopping"

# Build the wanted config: containerd's own defaults + SystemdCgroup = true.
# Compare with what is on disk and replace it only if different.
mkdir -p /etc/containerd
tmp=$(mktemp)
containerd config default > "$tmp"
if grep -q 'SystemdCgroup' "$tmp"; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$tmp"
else
  sed -i "/runtimes\.runc\.options\]/a\            SystemdCgroup = true" "$tmp"
fi
grep -q 'SystemdCgroup = true' "$tmp" || fail "could not set SystemdCgroup in containerd config"

restart_ctr=0
if ! cmp -s "$tmp" /etc/containerd/config.toml; then
  install -m 644 "$tmp" /etc/containerd/config.toml
  log "wrote /etc/containerd/config.toml"
  restart_ctr=1
fi
rm -f "$tmp"

systemctl enable --quiet containerd
if (( restart_ctr )) || ! systemctl is-active --quiet containerd; then
  systemctl restart containerd
  log "containerd restarted"
fi

write_file /etc/crictl.yaml \
$'runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock' || true

# ---------------------------------------------------------------- 5. kube packages
key=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
list=/etc/apt/sources.list.d/kubernetes.list
repo="https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/"

install -d -m 755 /etc/apt/keyrings
if [[ ! -f $key ]]; then
  curl -fsSL "${repo}Release.key" | gpg --dearmor -o "$key"
  log "added Kubernetes apt key"
fi
if write_file "$list" "deb [signed-by=$key] $repo /"; then
  apt-get update -qq
fi

pkgs=(kubelet kubeadm kubectl)
if ! dpkg -s kubeadm kubelet kubectl >/dev/null 2>&1; then
  apt-get install -y -qq "${pkgs[@]}" >/dev/null
  log "installed ${pkgs[*]}"
fi
apt-mark hold "${pkgs[@]}" >/dev/null
systemctl enable --quiet kubelet

kubeadm_ver=$(kubeadm version -o short)
[[ $kubeadm_ver == "v${K8S_MINOR}."* ]] || fail "kubeadm is $kubeadm_ver, expected v${K8S_MINOR}.x"

# ---------------------------------------------------------------- summary
echo
log "$(hostname): done"
log "  swap:       $(swapon --show --noheadings | grep -q . && echo ON || echo off)"
log "  containerd: $ctr_ver ($(systemctl is-active containerd))"
log "  kubeadm:    $kubeadm_ver"
log "  held:       $(apt-mark showhold | tr '\n' ' ')"

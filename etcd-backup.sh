#!/usr/bin/env bash
# etcd-backup.sh - snapshot etcd from one control-plane node and check it (unit P0-07).
#   ./etcd-backup.sh          back up from cp1
#   ./etcd-backup.sh cp2      back up from cp2
# Runs on the host. Works without the API server: it reaches etcd through
# crictl on the node, using the etcdctl and etcdutl inside the etcd container.
#   1. etcdctl snapshot save, into the node's /var/lib/etcd (mounted in the pod)
#   2. etcdutl snapshot status, on that file
#   3. copy to backups/ on the host, check the checksum, delete the node copy
# etcd 3.6 removed "etcdctl snapshot status"; etcdutl does it now.

source "$(dirname "$0")/lib.sh"

usage() { sed -n '2,10p' "$0"; }
parse_args "$@"
[[ ${#ARGS[@]} -le 1 ]] || die "usage: etcd-backup.sh [NODE]"
NODE="${ARGS[0]:-cp1}"
[[ "$NODE" == cp* ]] || die "$NODE is not a control-plane node"

STAMP="$(date +%Y%m%d-%H%M%S)"
REMOTE="/var/lib/etcd/backup-$STAMP.db"            # inside the etcd pod's data mount
BACKUP_DIR="$LAB_DIR/backups"
LOCAL="$BACKUP_DIR/etcd-$NODE-$STAMP.db"
PKI=/etc/kubernetes/pki/etcd
ETCDCTL_ARGS="--endpoints=https://127.0.0.1:2379 --cacert=$PKI/ca.crt --cert=$PKI/server.crt --key=$PKI/server.key"

on() { local n=$1; shift; ssh "$n" "$@"; }

CID="$(on "$NODE" 'sudo crictl ps --name "^etcd$" --state running -q' | head -n 1)"
[[ -n "$CID" ]] || die "no running etcd container on $NODE"

say "$NODE: etcdctl snapshot save"
on "$NODE" "sudo crictl exec $CID etcdctl $ETCDCTL_ARGS snapshot save $REMOTE" >/dev/null

say "$NODE: etcdutl snapshot status"
on "$NODE" "sudo crictl exec $CID etcdutl snapshot status $REMOTE -w table"

mkdir -p "$BACKUP_DIR"
on "$NODE" "sudo cat $REMOTE" > "$LOCAL"
WANT="$(on "$NODE" "sudo sha256sum $REMOTE" | awk '{ print $1 }')"
GOT="$(sha256sum "$LOCAL" | awk '{ print $1 }')"
[[ "$GOT" == "$WANT" ]] || die "copy of $REMOTE does not match; kept on $NODE"
on "$NODE" "sudo rm -f $REMOTE"

say "done: $LOCAL ($(du -h "$LOCAL" | cut -f1))"

#!/usr/bin/env bash
# fake-kubelet.sh - the Go FakeKubelet loop (internal/mirage/node.go:174-260)
# as an exec order: for every Node labelled mirage.cluster.x-k8s.io/fake-node=true,
# renew its kube-node-lease Lease and refresh its condition heartbeats
# (Ready=True unless the mirage.cluster.x-k8s.io/unhealthy annotation is
# present, in which case Ready=False and the lease is left to expire).
# Runs three passes 10 s apart so a 30 s cooldown keeps nodes inside the
# 40 s node-monitor grace period. Pods on fake nodes are not touched.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
[ -f "$KUBECONFIG" ] || { echo "fake-kubelet: no scoped kubeconfig at $KUBECONFIG"; exit 0; }
# Run as a long-lived loop: the orders lane dispatches this order once per
# pass (tens of seconds to minutes when reconciles are busy), so a short
# script leaves gaps longer than the 40 s node-monitor grace period. Loop for
# MIRAGE_PROSE_KUBELET_SECONDS (default 570 s, under the order's 10 m
# timeout) with a pass every MIRAGE_PROSE_KUBELET_INTERVAL (10 s); the
# order's tracking bead single-flights the next dispatch until this exits.
SECS="${MIRAGE_PROSE_KUBELET_SECONDS:-570}"
INT="${MIRAGE_PROSE_KUBELET_INTERVAL:-10}"
HERE="$(cd "$(dirname "$0")" && pwd)"
start=$(date +%s); n=0; errs=0
while :; do
  n=$((n + 1))
  python3 "$HERE/fake_kubelet.py" || errs=$((errs + 1))
  now=$(date +%s)
  [ $((now - start + INT)) -ge "$SECS" ] && break
  sleep "$INT"
done
echo "fake-kubelet: $n passes in $(( $(date +%s) - start )) s, $errs with errors"
exit 0

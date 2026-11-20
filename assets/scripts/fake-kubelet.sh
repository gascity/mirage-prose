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
PASSES="${MIRAGE_PROSE_KUBELET_PASSES:-3}"
for ((i = 1; i <= PASSES; i++)); do
  python3 "$(cd "$(dirname "$0")" && pwd)/fake_kubelet.py" || echo "fake-kubelet: pass $i had errors"
  [ "$i" -lt "$PASSES" ] && sleep 10
done
exit 0

#!/bin/sh
# mirage-prose doctor: the Go controller must be scaled to 0 while the prose
# controller runs, or the two fight over every object.
set -eu
. "$(cd "$(dirname "$0")" && pwd)/../assets/scripts/env.sh"
[ -f "$KUBECONFIG" ] || { echo "scoped kubeconfig missing at $KUBECONFIG"; exit 2; }
R=$(kubectl -n mirage-system get deploy mirage-controller-manager -o jsonpath='{.spec.replicas}/{.status.readyReplicas}' --request-timeout=10s 2>/dev/null || echo "forbidden")
case "$R" in
  "0/"|"0/0") echo "mirage-controller-manager scaled to 0 (prose controller owns the objects)"; exit 0 ;;
  forbidden) echo "cannot read deploy/mirage-controller-manager with the scoped identity (expected: it is read-only there); check with the admin kubeconfig"; exit 0 ;;
  *) echo "mirage-controller-manager is at $R: scale it to 0 before running the prose controller (admin: kubectl -n mirage-system scale deploy mirage-controller-manager --replicas=0)"; exit 1 ;;
esac

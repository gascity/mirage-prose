#!/bin/sh
# mirage-prose doctor: is the apiserver reachable with the SCOPED identity?
set -eu
. "$(cd "$(dirname "$0")" && pwd)/../assets/scripts/env.sh"
if [ ! -f "$KUBECONFIG" ]; then
  echo "scoped kubeconfig missing at $KUBECONFIG"
  echo "Create it: deploy/make-kubeconfig.sh (needs the admin kubeconfig once); or set MIRAGE_PROSE_KUBECONFIG"
  exit 2
fi
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not on PATH"; exit 2; }
WHO=$(kubectl auth whoami -o jsonpath='{.status.userInfo.username}' --request-timeout=10s 2>/dev/null || true)
case "$WHO" in
  system:serviceaccount:*:mirage-prose) ;;
  "") echo "apiserver not reachable or token expired (KUBECONFIG=$KUBECONFIG)"; echo "Renew: deploy/make-kubeconfig.sh"; exit 2 ;;
  *) echo "kubeconfig authenticates as $WHO, not the mirage-prose ServiceAccount"; exit 1 ;;
esac
kubectl get --raw=/readyz --request-timeout=10s >/dev/null 2>&1 || { echo "/readyz not ok"; exit 2; }
echo "apiserver ready; acting as $WHO"
exit 0

#!/usr/bin/env bash
# publish-kubeconfig.sh <cluster> <namespace>
#
# MirageControlPlane.reconcileKubeconfig (miragecontrolplane_controller.go:105-128)
# as a script, so the token never reaches a transcript: builds the workload
# kubeconfig (mirage/kubeconfig.go:56-73) from the durable
# mirage-system/mirage-workload-token (cmd/main.go:162-181) and creates the
# <cluster>-kubeconfig Secret exactly as util/kubeconfig.GenerateSecret does.
# Prints metadata only. Idempotent: exits 0 if the Secret already exists.
set -euo pipefail
umask 077
CLUSTER="${1:?usage: publish-kubeconfig.sh <cluster> <namespace>}"
NS="${2:?usage: publish-kubeconfig.sh <cluster> <namespace>}"
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

if kubectl -n "$NS" get secret "$CLUSTER-kubeconfig" >/dev/null 2>&1; then
  echo "kubeconfig secret $NS/$CLUSTER-kubeconfig already published"
  exit 0
fi
CUID=$(kubectl -n "$NS" get clusters.cluster.x-k8s.io "$CLUSTER" -o jsonpath='{.metadata.uid}')
[ -n "$CUID" ] || { echo "cluster $NS/$CLUSTER not found"; exit 1; }
SERVER="${MIRAGE_PROSE_WORKLOAD_SERVER:-}"
if [ -z "$SERVER" ]; then
  SERVER="https://$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}'):443"
fi
CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
[ -n "$CA" ] || { echo "no certificate-authority-data in $KUBECONFIG"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
kubectl -n mirage-system get secret mirage-workload-token -o jsonpath='{.data.token}' | base64 -d > "$TMP/token"
[ -s "$TMP/token" ] || { echo "mirage-system/mirage-workload-token has no token"; exit 1; }

python3 - "$CLUSTER" "$NS" "$CUID" "$SERVER" "$CA" "$TMP/token" > "$TMP/secret.json" <<'PY'
import base64, json, sys
cluster, ns, uid, server, ca, tokfile = sys.argv[1:7]
token = open(tokfile).read().strip()
kc = {
    "apiVersion": "v1", "kind": "Config", "preferences": {},
    "clusters": [{"name": cluster, "cluster": {"server": server, "certificate-authority-data": ca}}],
    "users": [{"name": f"{cluster}-admin", "user": {"token": token}}],
    "contexts": [{"name": f"{cluster}@mirage", "context": {"cluster": cluster, "user": f"{cluster}-admin"}}],
    "current-context": f"{cluster}@mirage",
}
secret = {
    "apiVersion": "v1", "kind": "Secret", "type": "cluster.x-k8s.io/secret",
    "metadata": {
        "name": f"{cluster}-kubeconfig", "namespace": ns,
        "labels": {"cluster.x-k8s.io/cluster-name": cluster},
        "ownerReferences": [{"apiVersion": "cluster.x-k8s.io/v1beta2", "kind": "Cluster", "name": cluster, "uid": uid}],
    },
    "data": {"value": base64.b64encode(json.dumps(kc).encode()).decode()},
}
json.dump(secret, sys.stdout)
PY
kubectl create -f "$TMP/secret.json" --field-manager=mirage-prose
echo "published $NS/$CLUSTER-kubeconfig: owner Cluster/$CLUSTER ($CUID), server $SERVER, user $CLUSTER-admin (token of mirage-system/mirage-workload)"

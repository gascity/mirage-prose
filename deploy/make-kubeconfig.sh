#!/usr/bin/env bash
# make-kubeconfig.sh [duration]
#
# Operator step, run ONCE with the admin kubeconfig in $KUBECONFIG: mints a
# short-lived token for the mirage-prose ServiceAccount (TokenRequest, no
# Secret created) and writes the agents' kubeconfig, mode 0600, to
# $MIRAGE_PROSE_KUBECONFIG (default ~/k3s-beads/mirage-prose.kubeconfig).
# Re-run when the token expires. The file is never committed.
set -euo pipefail
umask 077
DUR="${1:-12h}"
OUT="${MIRAGE_PROSE_KUBECONFIG:-$HOME/k3s-beads/mirage-prose.kubeconfig}"
SERVER=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
[ -n "$SERVER" ] && [ -n "$CA" ] || { echo "admin kubeconfig has no server/CA"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
kubectl -n mirage-system create token mirage-prose --duration="$DUR" > "$TMP/token"
[ -s "$TMP/token" ] || { echo "token request failed"; exit 1; }
python3 - "$SERVER" "$CA" "$TMP/token" > "$TMP/kc" <<'PY'
import json, sys
server, ca, tokfile = sys.argv[1:4]
tok = open(tokfile).read().strip()
json.dump({
  "apiVersion": "v1", "kind": "Config",
  "clusters": [{"name": "k3s-beads", "cluster": {"server": server, "certificate-authority-data": ca}}],
  "users": [{"name": "mirage-prose", "user": {"token": tok}}],
  "contexts": [{"name": "mirage-prose@k3s-beads", "context": {"cluster": "k3s-beads", "user": "mirage-prose"}}],
  "current-context": "mirage-prose@k3s-beads",
}, sys.stdout)
PY
mkdir -p "$(dirname "$OUT")"
install -m 0600 "$TMP/kc" "$OUT"
echo "wrote $OUT (mode 0600, token valid $DUR) for system:serviceaccount:mirage-system:mirage-prose"
KUBECONFIG="$OUT" kubectl auth whoami -o jsonpath='{.status.userInfo.username}{"\n"}'

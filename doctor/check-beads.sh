#!/bin/sh
# mirage-prose doctor: is the k3s-beads /v0 door up (the cluster as a graph)?
set -eu
. "$(cd "$(dirname "$0")" && pwd)/../assets/scripts/env.sh"
command -v curl >/dev/null 2>&1 || { echo "curl not found"; exit 2; }
if ! curl -fsS -m 5 "$MIRAGE_PROSE_BEADS/v0/beads/context" >/dev/null 2>&1; then
  echo "beads /v0 unreachable at $MIRAGE_PROSE_BEADS (bd -C ~/k3s-beads serve --addr 127.0.0.1:8099)"
  exit 2
fi
N=$(curl -fsS -m 10 "$MIRAGE_PROSE_BEADS/v0/beads/issues?label=k8s&type=mirageclusters&limit=50" | jq '.items | length' 2>/dev/null || echo "?")
echo "beads /v0 reachable at $MIRAGE_PROSE_BEADS; $N mirageclusters visible as beads"
exit 0

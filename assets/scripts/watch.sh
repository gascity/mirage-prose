#!/usr/bin/env bash
# watch.sh <resource> - the informer+predicate half of a controller, as a poll.
#
# Lists every object of <resource>, decides with the same gating the Go
# reconcilers use whether it needs a reconcile, and slings
# mol-mirage-reconcile for each one that has no open reconcile bead, up to
# MIRAGE_PROSE_MAX_SLING per run. Objects that already had
# MIRAGE_PROSE_MAX_ATTEMPTS reconciles are reported as STUCK and left alone.
# No LLM is involved; it never writes to the cluster.
set -euo pipefail
RES="${1:?usage: watch.sh <resource>}"
# shellcheck source=env.sh
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
MAX_SLING="${MIRAGE_PROSE_MAX_SLING:-3}"
MAX_ATTEMPTS="${MIRAGE_PROSE_MAX_ATTEMPTS:-6}"
TARGET="${MIRAGE_PROSE_TARGET:-${GC_RIG:+$GC_RIG/}mirage-reconciler}"
DRY="${MIRAGE_PROSE_DRY_RUN:-false}"

if [ ! -f "$KUBECONFIG" ]; then
  echo "watch[$RES]: no scoped kubeconfig at $KUBECONFIG; nothing to do"
  exit 0
fi

OBJS=$(kubectl get "$RES" -A -o json --request-timeout=20s)
CLUSTERS=$(kubectl get clusters.cluster.x-k8s.io -A -o json --request-timeout=20s)
MACHINES=$(kubectl get machines.cluster.x-k8s.io -A -o json --request-timeout=20s)
# Names only: the script never reads Secret data.
KUBECONFIG_SECRETS=$(kubectl get secrets -A -l cluster.x-k8s.io/cluster-name -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' --request-timeout=20s || true)

CANDIDATES=$(python3 - "$RES" "$KUBECONFIG_SECRETS" <<'PY' "$OBJS" "$CLUSTERS" "$MACHINES"
import json, sys
res, secret_names = sys.argv[1], set(sys.argv[2].split())
objs, clusters, machines = (json.loads(a) for a in sys.argv[3:6])
FIN = "mirage.cluster.x-k8s.io/finalizer"
PAUSED = "cluster.x-k8s.io/paused"
by_cluster = {(c["metadata"]["namespace"], c["metadata"]["name"]): c for c in clusters["items"]}
by_machine = {(m["metadata"]["namespace"], m["metadata"]["name"]): m for m in machines["items"]}

def owner(o, kind):
    for r in o["metadata"].get("ownerReferences", []):
        if r.get("kind") == kind:
            return r["name"]
    return None

def infra_ready(c):
    return bool(((c.get("status") or {}).get("initialization") or {}).get("infrastructureProvisioned"))

for o in objs["items"]:
    md, st, sp = o["metadata"], o.get("status") or {}, o.get("spec") or {}
    ns, name = md["namespace"], md["name"]
    deleting = bool(md.get("deletionTimestamp"))
    has_fin = FIN in md.get("finalizers", [])
    if PAUSED in (md.get("annotations") or {}):
        continue
    # resolve the owner chain the contract names
    cluster = None
    if res in ("mirageclusters", "miragecontrolplanes"):
        cn = owner(o, "Cluster")
        cluster = by_cluster.get((ns, cn)) if cn else None
        if cluster is None:
            continue  # "waiting for Cluster owner" - a watch would wake us later
    else:
        mn = owner(o, "Machine")
        machine = by_machine.get((ns, mn)) if mn else None
        if machine is None:
            continue
        cn = machine["metadata"].get("labels", {}).get("cluster.x-k8s.io/cluster-name")
        cluster = by_cluster.get((ns, cn)) if cn else None
        if cluster is None:
            continue
    if (cluster.get("spec") or {}).get("paused"):
        continue
    reason = None
    if res == "mirageclusters":
        if deleting:
            reason = "deleting" if has_fin else None
        elif not has_fin:
            reason = "finalizer"
        elif not (st.get("initialization") or {}).get("provisioned"):
            reason = "provision"
    elif res == "mirageconfigs":
        if deleting:
            reason = None  # no finalizer, no delete branch in the Go code
        elif not (st.get("initialization") or {}).get("dataSecretCreated"):
            reason = "bootstrap"
    elif res == "miragemachines":
        if deleting:
            reason = "deleting" if has_fin else None
        elif not has_fin:
            reason = "finalizer"
        elif not infra_ready(cluster):
            reason = None  # gate: cluster infra
        elif not ((machine.get("spec") or {}).get("bootstrap") or {}).get("dataSecretName"):
            reason = None  # gate: bootstrap data secret
        elif not st.get("nodeName"):
            reason = "provision" if not (st.get("initialization") or {}).get("provisioned") else "register-node"
    elif res == "miragecontrolplanes":
        if deleting:
            reason = "deleting" if has_fin else None
        elif not has_fin:
            reason = "finalizer"
        elif not infra_ready(cluster):
            reason = None
        else:
            desired = sp.get("replicas", 1)
            cname = cluster["metadata"]["name"]
            if f"{ns}/{cname}-kubeconfig" not in secret_names:
                reason = "kubeconfig"
            elif st.get("replicas") != desired or st.get("readyReplicas") != desired or not st.get("ready"):
                reason = "machines %s/%s ready" % (st.get("readyReplicas", 0), desired)
    if reason:
        print(ns, name, reason)
PY
)

if [ -z "$CANDIDATES" ]; then
  echo "watch[$RES]: all at contract state"
  exit 0
fi

# Reconcile beads are wisps labelled mirage-prose + obj:<res>/<ns>/<name>.
OPEN=$(gc bd list --label mirage-prose --include-ephemeral --limit 0 --json 2>/dev/null | jq -r '.[]?.labels[]? | select(startswith("obj:"))' | sort -u || true)
ALL=$(gc bd list --all --label mirage-prose --include-ephemeral --limit 0 --json 2>/dev/null | jq -r '.[]?.labels[]? | select(startswith("obj:"))' | sort | uniq -c || true)

n=0
while read -r ns name reason; do
  [ -n "$name" ] || continue
  obj="obj:$RES/$ns/$name"
  if grep -qx "$obj" <<<"$OPEN"; then
    echo "watch[$RES]: $ns/$name needs '$reason' - reconcile already open"
    continue
  fi
  prior=$(awk -v o="$obj" '$2==o {print $1}' <<<"$ALL"); prior="${prior:-0}"
  attempt=$((prior + 1))
  if [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
    echo "watch[$RES]: STUCK $ns/$name needs '$reason' after $prior reconciles; not slinging (cap $MAX_ATTEMPTS)"
    continue
  fi
  if [ "$n" -ge "$MAX_SLING" ]; then
    echo "watch[$RES]: $ns/$name needs '$reason' - deferred (cap $MAX_SLING per run)"
    continue
  fi
  n=$((n + 1))
  echo "watch[$RES]: sling $ns/$name needs '$reason' attempt $attempt -> $TARGET"
  OUT=$(gc sling "$TARGET" mol-mirage-reconcile --formula --json \
        --var "kind=$RES" --var "namespace=$ns" --var "name=$name" \
        --var "attempt=$attempt" --var "dry_run=$DRY" \
        --title "reconcile $RES/$ns/$name" 2>&1) || { echo "watch[$RES]: sling failed: $OUT"; continue; }
  ROOT=$(printf '%s' "$OUT" | jq -r 'if type=="array" then .[0] else . end | (.root_id // .root_bead_id // .bead_id // .id // .wisp_id // empty)' 2>/dev/null || true)
  if [ -z "$ROOT" ]; then
    echo "watch[$RES]: could not find the root bead id in sling output: $OUT"
    continue
  fi
  gc bd update "$ROOT" --add-label mirage-prose --add-label "$obj" >/dev/null
  echo "watch[$RES]: slung $ROOT for $ns/$name (attempt $attempt)"
done <<<"$CANDIDATES"

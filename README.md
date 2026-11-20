# mirage-prose

A Kubernetes controller written in English, run by Gas City, on a cluster
whose datastore is beads.

[`cluster-api-provider-mirage`](https://github.com/luthermonson/cluster-api-provider-mirage)
is a fake Cluster API provider: four Go reconcilers (MirageCluster,
MirageControlPlane, MirageMachine, MirageConfig) and a fake-kubelet loop that
take a `Cluster` from applied to `Provisioned` with fake Nodes `Ready`, on a
timer, creating no real infrastructure. This pack recreates those
controllers as **prose**: the contract is a skill (`skills/mirage-contract`),
one reconcile is a formula (`formulas/mol-mirage-reconcile`), the watch is a
set of orders (`orders/watch-*`), and the thing that runs it all is a Gas
City city whose agents act through the apiserver under their own scoped
identity. The cluster it reconciles runs on
[k3s-on-beads](https://github.com/luthermonson/kine/tree/beads-backend):
every Kubernetes object is a bead in a Dolt-backed beads store, so the
cluster the controller edits and the beads the controller's own work leaves
behind are the same kind of thing, and a reconcile can cite the revision it
observed and the revision it produced.

## Why

- **The controller is readable.** `skills/mirage-contract/SKILL.md` is the
  provider contract per kind, rule by rule, in the order the Go code applies
  them, with idempotency ("if already so, do nothing"), ownerReferences,
  finalizers and deletion, and every rule cites the Go file and line it came
  from. A reviewer who has never read controller-runtime can check it against
  the Go.
- **The work leaves a trail in the same graph.** Each reconcile is a
  molecule whose root bead records what it observed (`bead:`,
  `observed_rev:`), what it decided, what it patched, and what it produced
  (`produced:` bead ids and revisions). The cluster object's own bead history
  (`bd history`) shows the revision that reconcile wrote. The two stores are
  one Dolt server; see "Where the city lives".
- **The orchestrator is the controller manager.** Gas City's orders lane is
  the informer, `gc sling` is the work queue, the agent pool is the worker
  pool, `max_active_sessions` is `MaxConcurrentReconciles`, and
  loop-safety (5 no-progress attempts, then stop) is the rate limiter.

## Layout

| Path | What |
|---|---|
| `skills/mirage-contract/SKILL.md` | The provider contract in English, per kind, cited to the Go reconcilers |
| `skills/k8s-reconcile/SKILL.md` | How to reconcile one object: observe, decide, act, verify, record; loop safety |
| `formulas/mol-mirage-reconcile.formula.toml` | One molecule = one reconcile (vars `kind`, `namespace`, `name`, `attempt`, `dry_run`); steps observe → decide → act → verify, assignee `mirage-reconciler` |
| `orders/watch-<kind>.toml` | The watch: every 30 s list the kind, sling a reconcile for each object not at its contract state with no open reconcile bead (`assets/scripts/watch.sh`) |
| `orders/fake-kubelet.toml` | The Go `FakeKubelet` heartbeat loop, kept mechanical (`assets/scripts/fake_kubelet.py`) |
| `agents/mirage-reconciler/` | The pool agent the molecules are routed to; the two skills are its standing role |
| `doctor/` | Scoped identity reaches the apiserver, `/v0` is up, the Go controller is scaled to 0 |
| `deploy/rbac.yaml` | ServiceAccount `mirage-prose` and least-privilege RBAC (mirage kinds, Machines, Nodes, Secrets in the cluster namespace, node Leases) |
| `deploy/make-kubeconfig.sh` | Operator step: mint a short-lived token and write the agents' kubeconfig, 0600, outside the repo |
| `assets/scripts/publish-kubeconfig.sh` | The control-plane reconcile's kubeconfig Secret, built without the token ever reaching a transcript |

## How it runs

```
orders lane (30 s)                      agent pool (claude, tmux)
  watch-miragemachines ──kubectl get──▶ objects not at contract state, no open bead
        │                                           │
        └─ gc sling <rig>/mirage-reconciler mol-mirage-reconcile --var kind=… --var name=…
                                                    │
                              molecule (wisp): observe → decide → act → verify
                                                    │
                              session: gc hook --claim → skills → kubectl patch (SA mirage-prose)
                                                    │
                              root-bead notes: bead:, observed_rev:, decision:, actions:, produced:, status:
```

Why polling: kine-beads does not journal its writes yet (beads 1.3.4 turns
the events journal on only from `cmd/bd`), so gc's `event` trigger cannot
see a cluster mutation. When it does, each `watch-*` order becomes an
`event` order fed by an `exec` events provider over
`/v0/beads/events:watch`, and the predicate script stays the same.

## Run it

Prerequisites: a k3s-on-beads rig (`KUBECONFIG` to its admin kubeconfig,
`bd serve` on `127.0.0.1:8099`), CAPI core and the mirage CRDs installed,
`gc` 1.5.1, `bd` 1.3.4, `kubectl`, `jq`, `python3`.

```sh
# 1. identity (admin kubeconfig, once)
kubectl apply -f deploy/rbac.yaml
deploy/make-kubeconfig.sh 12h          # -> ~/k3s-beads/mirage-prose.kubeconfig (0600)

# 2. hand the objects to the prose controller
kubectl -n mirage-system scale deploy mirage-controller-manager --replicas=0

# 3. a city with this repo as a rig (the repo root is the pack)
gc init --template minimal --default-provider claude --no-start ~/mirage-prose-city
gc rig add ~/mirage-prose --name mirage-prose --include ~/mirage-prose
gc start ~/mirage-prose-city

# 4. apply a cluster and watch
kubectl apply -f ~/cluster-api-provider-mirage/examples/quickstart-cluster.yaml
kubectl get cluster,miragecluster,miragecontrolplane,machines,miragemachines,nodes -w
gc order list; gc bd list --label mirage-prose --include-ephemeral --all
```

Done when the Cluster is `Provisioned`/`Available=True`, the control plane
has 3 Machines `Running` with `nodeRef`, the MachineDeployment is 3/3 and
the 6 fake Nodes are `Ready`.

Knobs (environment of the city/agents; defaults in `assets/scripts/env.sh`):
`MIRAGE_PROSE_KUBECONFIG`, `MIRAGE_PROSE_BEADS`, `MIRAGE_PROSE_MAX_SLING`
(per watch run, 3), `MIRAGE_PROSE_MAX_ATTEMPTS` (per object, 6),
`MIRAGE_PROSE_WAIT_BUDGET` (seconds a reconcile may sleep on timers, 600),
`MIRAGE_PROSE_DRY_RUN`.

## Where the city lives, and why

The cluster's beads live in the `k3s_beads` database of the rig's Dolt
server (`~/k3s-beads`, server mode). The city gets **its own database on the
same server** (`gc init --beads-target external --dolt-host 127.0.0.1
--dolt-port 3307 --dolt-database mirage_prose`), not the `k3s_beads` database
itself: gc's `bd init` and its core housekeeping orders (`reaper`,
`wisp-compact`, `gate-sweep`) write config and close/purge beads in whatever
store they are pointed at, and a reaper that closes a bead labelled `k8s`
deletes a cluster object. Reconcile beads therefore reference cluster beads
by id and revision (`bead:`, `observed_rev:`, `produced:` in the notes), and
the cluster beads carry no edge back; the "one graph" is one server, two
databases, joined by citation. The experiment log in the report shows the
`bd dep tree` on the city side and `bd history` on the cluster side.

## What it cannot do

- **Speed.** A Go reconcile takes milliseconds; a prose reconcile is an LLM
  session that reads two skills and runs a dozen kubectl calls, minutes each,
  with a few in flight. The quickstart converges in tens of minutes, not
  tens of seconds; `kourt` plans need a longer settle window (`plans/`).
- **Cost.** Every reconcile spends tokens. The watch caps slings per run and
  attempts per object, and a no-progress loop stops itself, but a
  high-churn object (a MachineDeployment rollout) is expensive.
- **Heartbeats.** A kubelet heartbeat is not a decision; `fake-kubelet` stays
  a script. Pods scheduled onto fake Nodes are not marked Running.
- **Watches.** Until kine journals, the watch is a poll (above).

## Verdict

See the report in the repo's first PR / the owner's worklog: the pack is
judged with the same `kourt` plan the Go controller passes
(`capi-live`, snapshot source), with `configmaps/coredns` excepted and the
settle window widened for prose speed.

## License

MIT.

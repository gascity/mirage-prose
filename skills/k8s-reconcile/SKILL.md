---
name: k8s-reconcile
description: How to reconcile one Kubernetes object as a Gas City agent on k3s-on-beads - observe the object, its owner chain and its bead history, decide against the provider contract, act through the apiserver with a scoped identity, verify, and record what you saw and what you produced in the molecule root-bead notes. Includes the loop-safety rules (never re-send an identical patch, stop after 5 no-progress attempts). Use for every mol-mirage-reconcile step.
---

# Reconcile one object

You are one reconcile of a controller written in English. The contract for
*what* to do is in the `mirage-contract` skill; this skill is *how*. The
object is named by the molecule's vars: `kind` (the resource name as kubectl
spells it: `mirageclusters`, `miragecontrolplanes`, `miragemachines`,
`mirageconfigs`), `namespace`, `name`, plus `attempt` (how many reconciles
this object has already had, counting this one) and `dry_run`.

## Environment

```bash
export KUBECONFIG="${MIRAGE_PROSE_KUBECONFIG:-$HOME/k3s-beads/mirage-prose.kubeconfig}"
export BEADS="${MIRAGE_PROSE_BEADS:-http://127.0.0.1:8099}"
kubectl auth whoami   # must print system:serviceaccount:mirage-system:mirage-prose
```

If the kubeconfig is missing or `kubectl auth whoami` fails, do not try any
other credential: write `status: failed` and `error: kubeconfig` into the
root-bead notes and close the bead. The admin kubeconfig is never yours.

Every write names its field manager: `kubectl ... --field-manager=mirage-prose`.

## 1. Observe

Gather, and keep the output (you will cite it):

1. The object: `kubectl get <kind> -n <ns> <name> -o yaml`. Not found: the
   reconcile is over (`status: done`, `decision: object gone`).
2. The owner chain the contract names: the owner Cluster (`clusters.cluster.x-k8s.io`),
   or the owner Machine and then its Cluster. Read them with `-o yaml` too;
   you need `status.initialization.*`, `spec.paused`, `spec.bootstrap.dataSecretName`,
   `spec.version`, `spec.failureDomain`, labels and uids.
3. The object's bead and revision. Every Kubernetes object on this rig is a
   bead in the `k3s_beads` store, labelled `k8s`, whose `external_ref` is the
   etcd key. Look it up through `bd serve`:
   ```bash
   KEY="/registry/<group>/<kind>/<ns>/<name>"   # e.g. /registry/infrastructure.cluster.x-k8s.io/miragemachines/default/foo
   curl -s "$BEADS/v0/beads/issues?label=k8s&type=<kind>&limit=500" \
     | jq -r --arg k "$KEY" '.items[] | select(.external_ref==$k) | "\(.id) \(.updated_at)"'
   curl -s "$BEADS/v0/beads/issues/<id>" | jq '{id, revision, updated_at, parent, labels}'
   ```
   Core kinds use their registry names (`/registry/minions/<node>` for Nodes,
   `/registry/secrets/<ns>/<name>`, `/registry/cluster.x-k8s.io/machines/<ns>/<name>`).
   Record the bead id and `revision` as `observed_rev`. Dependencies of type
   `parent-child` on that bead are its ownerReferences as the graph sees them.
4. Recent history: the previous reconcile beads of this object. The watch
   script labels every molecule root `obj:<kind>/<ns>/<name>`:
   ```bash
   gc bd list --all --label "obj:<kind>/<ns>/<name>" --json | jq -r '.[] | "\(.id) \(.status) \(.updated_at)"'
   gc bd show <previous root id> --json | jq -r '.[0].notes'
   ```
   Read the last one's `decision:` and `actions:`. If it reported the same
   state you see now and acted, something did not take; say so.

## 2. Decide

Walk the contract section for the kind top to bottom. Write the decision as
one line before acting, in the form
`decision: <rule> because <field>=<value>` (for example
`decision: stage1 start timer because status.provisioningStartedAt unset`).
If the contract says "do nothing", the decision is `decision: no-op (<why>)`
and you go straight to step 5 with `status: waiting` (owner missing, gating
not met, paused) or `status: done` (already terminal).

`dry_run=true`: decide as usual, write the decision and the patches you
*would* send into the notes, send nothing, finish with `status: dry-run`.

## 3. Act

- One contract step is one `kubectl` write. Use merge patches:
  - metadata/spec: `kubectl patch <kind> <name> -n <ns> --type=merge --field-manager=mirage-prose -p '<json>'`
  - status: the same with `--subresource=status`
  - creates: `kubectl create -f - --field-manager=mirage-prose <<'EOF' ... EOF`
  - deletes: `kubectl delete <kind> <name> -n <ns> --ignore-not-found`
- Conditions are a whole list: compute the new list from the current one
  (keep other types, apply the SetStatusCondition rule from the contract),
  then patch `status.conditions` with the full list.
- Finalizers: `{"metadata":{"finalizers":["mirage.cluster.x-k8s.io/finalizer", ...existing]}}`;
  to remove, patch the list without it. Never clear other controllers' finalizers.
- Timers: when a step says *wait*, `sleep` until `startedAt + targetSeconds`
  (plus one second), **re-read the object**, then continue with the next step
  against the fresh copy. Total sleeping in one reconcile is capped at
  the wait budget `MIRAGE_PROSE_WAIT_BUDGET` (default 600 s). When the budget
  is gone, finish with `status: progressed`; the watch will sling again.
- Before sending a patch, compare it to the current object. A patch that
  changes nothing is not sent (write `skip: <step> already true` instead).
- Secrets: never print `data`/`stringData` of any Secret you read or write.
  Use `assets/scripts/publish-kubeconfig.sh` for the cluster kubeconfig.
- Nothing outside the contract: no scaling the Go controller, no editing
  Clusters/MachineDeployments/MachineSets, no deleting anything the
  contract does not name, no `kubectl apply` of whole objects you did not create.

## 4. Verify

Re-read the object (and the Node/Secret you created) and check each field
you set holds. Fetch the bead again and record its new `revision` as
`produced_rev`. If a field did not take (admission rewrote it, conflict,
forbidden), say which, and fix it only if the contract says the same
patch is still right; a `Forbidden` means the identity lacks a permission:
record it and stop (`status: failed`, `error: forbidden <verb> <resource>`).

## 5. Record

The molecule root bead is the control bead. Write the notes with
`gc bd update "$ROOT" --notes "<text>"` (whole text, keys one per line):

```
object: <kind>/<ns>/<name>
attempt: <attempt>
bead: <object bead id>
observed_rev: <revision before>
owner: <Cluster or Machine>/<name> (<status you relied on>)
decision: <one line>
actions: <verb kind/name>; <verb kind/name>; ...   (or "none")
skips: <steps skipped because already true>          (optional)
produced: <object bead id>@<revision after>; <node bead id>; <secret bead id>   (what you changed)
waited: <seconds slept>
status: done | progressed | waiting | failed | dry-run
error: <only with failed>
```

`done` means the object is now at a terminal contract state; `progressed`
means you changed it but it is not terminal yet (another reconcile will
follow); `waiting` means you wrote nothing because a gate is not met.

Then set the outcome and close:

```bash
gc bd update "$ROOT" --set-metadata gc.outcome=pass     # or fail
gc bd close "$ROOT" --reason "<kind>/<name>: <status> - <decision>"
```

## Loop safety

- **Never re-send an identical patch.** If the object already equals the
  result of a step, skip it.
- **No-progress means stop.** If `attempt` is 5 or more and the previous
  reconcile beads for this object show the same `decision` with no change in
  `observed_rev`, do not act: finish with `status: failed`,
  `error: no-progress after <n> attempts`, and `gc.outcome=fail`. The watch
  script will not sling that object again past its cap; a human reads the notes.
- One reconcile touches one object plus the children the contract names for
  it (its Node and Lease, its Secret, the control-plane Machine trio). Never
  reconcile a sibling because it looks wrong; the watch will sling it.
- Spend: no exploratory `kubectl get -A` sweeps, no reading the whole bead
  store. The lists above are enough.

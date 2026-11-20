---
name: mirage-contract
description: The Cluster API "mirage" provider contract in plain English, one section per kind (MirageCluster, MirageControlPlane, MirageMachine incl. the fake Node, MirageConfig). Every rule says which fields and conditions to set, in what order, when to do nothing, which ownerReferences and finalizers to add, and what deletion does, and cites the Go reconciler file and line it was derived from. Use when reconciling any mirage object, or when deciding whether an object is already at its contract state.
---

# The mirage provider contract

Source of truth: `cluster-api-provider-mirage` at commit `92e5ab5`
(`internal/controller/*.go`, `internal/mirage/node.go`, `internal/mirage/timing.go`).
When this document and the Go code disagree, the Go code wins; fix this
document (and say so in the root-bead notes).

Mirage is a *fake* provider: nothing it reconciles creates real
infrastructure. Each object "provisions" by waiting a short timer, then
flipping to its terminal state, and the machine stage ends by registering a
fake Node so that Cluster API core can set the Machine's `nodeRef`.

Conventions used below:

- "status" means the `status` subresource; write it with
  `kubectl patch ... --subresource=status`. "spec" and "metadata" are written
  with a plain patch. The Go code uses a `patch.Helper` that does exactly this
  split (`miragecluster_controller.go:48-56` and the same block in each reconciler).
- A *condition* is a `metav1.Condition`: `type`, `status` (`"True"|"False"`),
  `reason`, `message`, `observedGeneration` = the object's current
  `metadata.generation`, `lastTransitionTime`. Setting one follows
  `apimeta.SetStatusCondition` (`helpers.go:34-42`): if a condition of that type
  exists with the **same status**, keep its `lastTransitionTime` and only
  update reason/message/observedGeneration; otherwise set `lastTransitionTime`
  to now. Other conditions in the list are kept.
- *now* is the current UTC time in RFC 3339 with seconds (`2026-11-20T03:04:05Z`).
- The finalizer is `mirage.cluster.x-k8s.io/finalizer` (`api/infrastructure/v1alpha1/common.go`).
- Phases are the strings `Pending`, `Provisioning`, `Provisioned`, `Deleting` (`helpers.go:12-17`).
- **Paused** (`helpers.go:21-29`): an object is paused when its owner Cluster
  has `spec.paused: true` or the object carries the annotation
  `cluster.x-k8s.io/paused` (any value). A paused object gets **no write at all**.
- **Timers** (`timing.go`): every fake stage holds for `targetSeconds`, a
  per-object integer written into status on first observation. The Go
  controller runs the "fast" profile (`timing.go:57-72`): cluster provision
  3 s, machine (VM) provision 5 s, bootstrap 2 s, node registration 3 s,
  delete 3 s, each with random jitter. The prose controller uses the **base
  value without jitter** (3 / 5 / 2 / 3 / 3), unless the object carries
  `mirage.cluster.x-k8s.io/provision-duration` (or
  `mirage.cluster.x-k8s.io/delete-duration` for deletes), a Go duration that
  replaces the base (`timing.go:113-142`); the minimum is 1 s. A stage is
  *elapsed* when `startedAt + targetSeconds <= now`. Because one reconcile of
  this controller takes longer than any of these timers, a reconcile may
  **start a timer, sleep until it elapses, re-read the object, and finish the
  stage in the same reconcile**. Each pass is still one patch, in the order
  given below; never collapse "start timer" and "finish stage" into one patch.
- **Idempotency**: every rule is of the form "if X is not already so, make it
  so". If the object is already at the state a step produces, skip the step
  (no patch). Never re-send a patch whose result would equal the current object.
- **Identity**: all writes go through the `mirage-prose` ServiceAccount
  kubeconfig (`--field-manager=mirage-prose`). Never use another kubeconfig.

Every reconcile starts the same way (`*_controller.go` `Reconcile`):

1. `kubectl get` the object. If it does not exist: nothing to do, finish
   (`miragecluster_controller.go:35-37`).
2. Resolve the owner named in the kind's section. If it is missing: **do
   nothing** and finish with `status: waiting` (the Go code returns without a
   requeue and relies on a watch; the watch order re-slings later).
3. If paused: do nothing (`:58-61`).
4. If `metadata.deletionTimestamp` is set: run the kind's **Deletion** rules
   and stop.
5. If the finalizer is missing (and the kind uses one): add it with a
   metadata patch (`:67-70`); then continue (the Go code requeues; continuing
   is equivalent).
6. Run the kind's **Normal** rules.

---

## MirageCluster (`infrastructure.cluster.x-k8s.io/v1alpha1`)

Source: `internal/controller/miragecluster_controller.go`.

**Owner**: the `ownerReferences` entry with `kind: Cluster`
(`util.GetOwnerCluster`, `:39-46`). Cluster API core adds it; until it exists
do nothing.

**Finalizer**: yes (`:67-70`).

**Normal** (`reconcileNormal`, `:75-116`):

1. If `status.initialization.provisioned == true`: already provisioned,
   terminal, **do nothing** (`:78-80`).
2. If `status.provisioningStartedAt` is unset (`:83-93`), write one status patch:
   - `status.provisioningStartedAt: <now>`
   - `status.targetProvisioningSeconds: 3` (cluster-provision timer; see Timers)
   - `status.phase: Provisioning`
   - condition `Ready=False`, reason `Provisioning`, message
     `fake infrastructure provisioning (~3s)` (the number is the target)
   Then wait for the timer.
3. If the timer has not elapsed (`:95-99`): `status.phase` must be
   `Provisioning` (patch only if it is not); wait.
4. Timer elapsed (`:101-115`), two patches:
   - spec patch: if `spec.controlPlaneEndpoint.host` is empty, set
     `spec.controlPlaneEndpoint: {host: "<name>.mirage.local", port: 6443}` (`:102-107`).
   - status patch, all at once:
     - `status.failureDomains: <copy of spec.failureDomains>` (`:108`; `[]` if the spec has none)
     - `status.initialization: {provisioned: true}` (`:109`)
     - `status.ready: true` (`:110`)
     - `status.phase: Provisioned` (`:111`)
     - condition `Ready=True`, reason `Provisioned`, message `fake infrastructure is ready` (`:112-113`)

   Cluster API core reads `status.initialization.provisioned`,
   `spec.controlPlaneEndpoint` and `status.failureDomains` from this object
   and sets `Cluster.status.initialization.infrastructureProvisioned`, which
   gates every other kind below.

**Deletion** (`reconcileDelete`, `:118-137`):

1. If `status.deletionStartedAt` is unset: status patch
   `status.deletionStartedAt: <now>`, `status.targetProvisioningSeconds: 3`
   (delete timer), `status.phase: Deleting` (`:120-128`). Wait.
2. Timer not elapsed: `status.phase: Deleting`, wait (`:129-133`).
3. Elapsed: remove the finalizer with a metadata patch (`:134`). Nothing
   else is cleaned up for a cluster. The apiserver then deletes the object.

---

## MirageConfig (`bootstrap.cluster.x-k8s.io/v1alpha1`)

Source: `internal/controller/mirageconfig_controller.go`.

**Owner**: the `ownerReferences` entry with `kind: Machine`
(`util.GetOwnerMachine`, `:40-47`); then the Cluster named by that Machine's
label `cluster.x-k8s.io/cluster-name` (`util.GetClusterFromMetadata`,
`:48-52`). Either missing: do nothing.

**Finalizer**: **none**. The Go reconciler never adds one and has no
deletion branch (`:32-119`). On `deletionTimestamp`: do nothing.

**Normal** (`:68-118`):

1. If `status.initialization.dataSecretCreated == true`: terminal, do nothing (`:68-70`).
2. If `status.provisioningStartedAt` is unset (`:73-82`): status patch
   - `status.provisioningStartedAt: <now>`
   - `status.targetProvisioningSeconds: 2` (bootstrap timer)
   - condition `Ready=False`, reason `Generating`, message `fake bootstrap data is being generated`
   Wait for the timer (`:83-86`; no phase field on this kind).
3. Elapsed (`:88-110`): create the bootstrap data Secret unless it already
   exists (`AlreadyExists` is fine):
   ```yaml
   apiVersion: v1
   kind: Secret
   type: cluster.x-k8s.io/secret
   metadata:
     name: <config name>            # secretName := cfg.Name  (:89)
     namespace: <config namespace>
     labels:
       cluster.x-k8s.io/cluster-name: <cluster name>
     ownerReferences:
     - apiVersion: bootstrap.cluster.x-k8s.io/v1alpha1
       kind: MirageConfig
       name: <config name>
       uid: <config uid>
       controller: true               # (:97-104)
   stringData:
     value: |                         # exactly this text (:90-91)
       ## mirage fake bootstrap for <config name>
       ## cluster: <cluster name>
       ## machine: <machine name>
       <spec.extraData>
     format: mirage
   ```
   The `value` text is four lines, each ending in a newline; the fourth line
   is `spec.extraData` verbatim (for example `role=control-plane` or
   `role=worker`), empty if the spec has none.
4. Then one status patch (`:112-116`):
   - `status.dataSecretName: <config name>`
   - `status.initialization: {dataSecretCreated: true}`
   - `status.ready: true`
   - condition `Ready=True`, reason `Generated`, message `fake bootstrap data secret created`

   Cluster API core copies `status.dataSecretName` into
   `Machine.spec.bootstrap.dataSecretName`, which the MirageMachine waits for.

---

## MirageMachine (`infrastructure.cluster.x-k8s.io/v1alpha1`)

Source: `internal/controller/miragemachine_controller.go` and
`internal/mirage/node.go`.

**Owner**: the `ownerReferences` entry with `kind: Machine` (`:46-53`), then
the Cluster from the Machine's `cluster.x-k8s.io/cluster-name` label
(`:54-58`). Either missing: do nothing.

**Finalizer**: yes (`:78-81`).

**Normal** (`reconcileNormal`, `:86-206`):

Gating, checked in this order, each "stop" meaning: if `status.phase` is
empty set it to `Pending` (one status patch), otherwise write nothing; finish
with `status: waiting`:

1. `Cluster.status.initialization.infrastructureProvisioned` must be `true` (`:90-96`).
2. `Machine.spec.bootstrap.dataSecretName` must be set (`:97-103`).
3. If `status.nodeName` is non-empty: terminal, do nothing (`:106-108`).

Stage 1, the fake VM (`:111-151`), applies while
`status.initialization.provisioned` is not `true`:

1. If `status.provisioningStartedAt` is unset (`:113-123`): status patch
   - `status.provisioningStartedAt: <now>`
   - `status.targetProvisioningSeconds: 5` (machine-provision timer)
   - `status.phase: Provisioning`
   - condition `Ready=False`, reason `Provisioning`, message `fake VM is being created (~5s)`
   Wait.
2. Not elapsed: `status.phase: Provisioning`, wait (`:124-128`).
3. Elapsed (`:129-150`): first a spec patch, then a status patch.
   - spec: `spec.providerID: "mirage://<namespace>/<name>"` if empty (`:130-132`);
     `spec.failureDomain: <Machine.spec.failureDomain>` if empty and the
     Machine has one (`:133-135`).
   - status, all at once:
     - `status.addresses: [{type: InternalIP, address: "10.255.0.1"}, {type: Hostname, address: "<name>"}]` (`:136-139`)
     - `status.initialization: {provisioned: true}` (`:140`)
     - `status.ready: true` (`:141`)
     - `status.phase: Provisioned` (`:142`)
     - `status.nodeRegisterStartedAt: <now>` (`:143-144`)
     - `status.targetNodeSeconds: 3` (node-register timer, `:145`)
     - condition `Ready=True`, reason `Provisioned`, message `fake VM created; registering node` (`:146-147`)

   Cluster API core reads `spec.providerID`, `status.addresses` and
   `status.initialization.provisioned` and copies them to the Machine.

Stage 2, node registration (`:153-205`), applies once stage 1 is done and
`status.nodeName` is still empty:

1. Wait until `status.nodeRegisterStartedAt + status.targetNodeSeconds` has
   elapsed (`:154-157`).
2. Compute (`:159-177`):
   - `isControlPlane`: the Machine has the label `cluster.x-k8s.io/control-plane` (any value).
   - `nodeName` = the MirageMachine's name.
   - `version` = `Machine.spec.version`, or `v1.34.0` if empty.
   - capacity: `cpu` = `spec.nodeCPU` or `"4"`, `memory` = `spec.nodeMemory` or `"8Gi"`,
     `pods` = `spec.nodePods` or `"110"`, `ephemeral-storage` = `"50Gi"` (`node.go:47-56`).
3. Ensure the fake Node (`node.go:46-128`, `EnsureFakeNode`). Two writes:
   create-or-patch the Node, then update its status subresource, then the lease.

   Node (create if missing; otherwise merge these labels, providerID and taints into it, `node.go:88-104`):
   ```yaml
   apiVersion: v1
   kind: Node
   metadata:
     name: <nodeName>
     labels:
       kubernetes.io/hostname: <nodeName>
       kubernetes.io/os: linux
       kubernetes.io/arch: amd64
       mirage.cluster.x-k8s.io/fake-node: "true"
       mirage.cluster.x-k8s.io/machine: <Machine name>
       cluster.x-k8s.io/cluster-name: <cluster name>
       node-role.kubernetes.io/control-plane: ""      # only when isControlPlane
       # plus every entry of MirageMachine spec.nodeLabels (they win on collision)
   spec:
     providerID: <spec.providerID>
     taints:
     - key: mirage.cluster.x-k8s.io/fake            # only when spec.schedulable is NOT true
       value: "true"
       effect: NoSchedule
     - key: node-role.kubernetes.io/control-plane   # only when isControlPlane
       effect: NoSchedule
   ```
   Note: there is deliberately **no ownerReference** on the Node (`node.go:88`);
   the only link to the Machine is the `mirage.cluster.x-k8s.io/machine` label.

   Node status (`kubectl patch node <nodeName> --subresource=status --type=merge`, `node.go:106-126`):
   ```json
   {"status": {
     "capacity":    {"cpu": "<cpu>", "memory": "<memory>", "pods": "<pods>", "ephemeral-storage": "50Gi"},
     "allocatable": {"cpu": "<cpu>", "memory": "<memory>", "pods": "<pods>", "ephemeral-storage": "50Gi"},
     "nodeInfo": {"kubeletVersion": "<version>", "operatingSystem": "linux", "architecture": "amd64"},
     "addresses": [{"type": "Hostname", "address": "<nodeName>"}, {"type": "InternalIP", "address": "10.255.0.1"}],
     "conditions": [
       {"type": "Ready",          "status": "True",  "reason": "KubeletReady",               "message": "mirage fake kubelet is posting ready", "lastHeartbeatTime": "<now>", "lastTransitionTime": "<now>"},
       {"type": "MemoryPressure", "status": "False", "reason": "KubeletHasSufficientMemory", "message": "", "lastHeartbeatTime": "<now>", "lastTransitionTime": "<now>"},
       {"type": "DiskPressure",   "status": "False", "reason": "KubeletHasNoDiskPressure",   "message": "", "lastHeartbeatTime": "<now>", "lastTransitionTime": "<now>"},
       {"type": "PIDPressure",    "status": "False", "reason": "KubeletHasSufficientPID",    "message": "", "lastHeartbeatTime": "<now>", "lastTransitionTime": "<now>"}
     ]
   }}
   ```
   Lease (`ensureLease`, `node.go:144-160`), create or patch
   `leases.coordination.k8s.io/<nodeName>` in namespace `kube-node-lease`
   with `spec.holderIdentity: <nodeName>`, `spec.leaseDurationSeconds: 40`,
   `spec.renewTime: <now, RFC3339 with microseconds>`. A missing
   `kube-node-lease` namespace is not an error.

   The ghost-node fault injection in `:181-200` is **disabled**: never create
   a second Node.
4. Then one status patch on the MirageMachine (`:201-203`):
   - `status.nodeName: <nodeName>`
   - condition `Ready=True`, reason `NodeRegistered`, message `fake node "<nodeName>" registered`

   Cluster API core's Machine controller then finds the Node whose
   `spec.providerID` equals the Machine's `spec.providerID` (through the
   cluster's kubeconfig Secret, see MirageControlPlane) and sets
   `Machine.status.nodeRef`. The Node's Ready heartbeat is **not** the
   reconciler's job: the Go binary runs a separate `FakeKubelet` loop
   (`node.go:174-260`) that renews the lease and heartbeat every 5 s; this
   pack's `fake-kubelet` order does the same.

**Deletion** (`reconcileDelete`, `:223-247`):

1. If `status.deletionStartedAt` is unset: status patch
   `status.deletionStartedAt: <now>`, `status.targetProvisioningSeconds: 3`
   (delete timer), `status.phase: Deleting` (`:225-233`). Wait.
2. Not elapsed: `status.phase: Deleting`, wait (`:234-238`).
3. Elapsed: if `status.nodeName` is non-empty, delete the Node
   `<status.nodeName>` and its Lease in `kube-node-lease` (`:239-243`,
   `DeleteFakeNode` `node.go:162-173`; not-found is fine). Then remove the
   finalizer (`:244`). `status.nodeName` is left as it is.

---

## MirageControlPlane (`controlplane.cluster.x-k8s.io/v1alpha1`)

Source: `internal/controller/miragecontrolplane_controller.go` and
`cmd/main.go:159-191` (the workload kubeconfig).

**Owner**: the `ownerReferences` entry with `kind: Cluster` (`:56-63`).

**Finalizer**: yes (`:86-89`).

**Every non-paused reconcile**, before anything else, makes sure these two
status fields hold (`:79-80`; part of the first status patch you write, or a
patch of their own if nothing else changes):

- `status.selector: "cluster.x-k8s.io/cluster-name=<cluster name>,cluster.x-k8s.io/control-plane"`
- `status.version: <spec.version>`

**Gating** (`:92-95`): `Cluster.status.initialization.infrastructureProvisioned`
must be `true`, otherwise stop (`status: waiting`).

**Kubeconfig** (`reconcileKubeconfig`, `:105-128`; `mirage/kubeconfig.go`;
`cmd/main.go:162-191`): if the Secret `<cluster name>-kubeconfig` in the
cluster's namespace exists, do nothing. Otherwise create it. Mirage fakes the
workload cluster *as the management cluster*, so the kubeconfig points back
at this apiserver and authenticates as the `mirage-system/mirage-workload`
ServiceAccount, whose durable token is `data.token` of the Secret
`mirage-system/mirage-workload-token` (`main.go:167-175`). Shape
(`kubeconfig.go:56-73`, `util/kubeconfig.GenerateSecret`):

- kubeconfig: one cluster `<cluster name>` with `server` = the in-cluster
  apiserver URL (`https://<kubernetes service clusterIP>:443`, `main.go` via
  `InClusterWorkloadConnection`) and the cluster CA; one user
  `<cluster name>-admin` with `token`; one context `<cluster name>@mirage`
  selecting both, set as `current-context`.
- Secret: name `<cluster name>-kubeconfig`, namespace of the Cluster, type
  `cluster.x-k8s.io/secret`, label `cluster.x-k8s.io/cluster-name: <cluster name>`,
  one ownerReference `{apiVersion: cluster.x-k8s.io/v1beta2, kind: Cluster, name, uid}`
  (no `controller` flag), data key `value`.

Use `assets/scripts/publish-kubeconfig.sh <cluster> <namespace>` from the
pack for this step: it builds the file and creates the Secret without ever
printing the token. **Never print, log or paste the token or the kubeconfig.**

**Machines** (`reconcileMachines`, `:150-189`):

- `desired` = `spec.replicas`, or 1 if unset (`:152`).
- `owned` = Machines in the control plane's namespace with labels
  `cluster.x-k8s.io/cluster-name=<cluster name>` **and**
  `cluster.x-k8s.io/control-plane` (present, any value) **and** an
  ownerReference whose `uid` is this MirageControlPlane's uid (`:130-148`).
- If `len(owned) < desired` (`:161-167`): create **one** machine (below),
  update status, then wait about 2 s (`Profile.PollInterval`, `timing.go:69`)
  and re-list; repeat until `len(owned) == desired`. The Go controller
  creates one machine per reconcile on purpose so they start on a staggered
  timeline; keep that staggering.
- If `len(owned) > desired` (`:170-180`): delete the owned Machine with the
  newest `creationTimestamp` (`newest`, `:318-329`), update status, wait, re-list.
- Then update status (`updateStatus`, `:191-220`), one status patch:
  - `ready` = number of owned Machines whose `status.nodeRef.name` is set (`:193-197`)
  - `status.replicas: len(owned)`, `status.readyReplicas: ready`,
    `status.availableReplicas: ready`, `status.upToDateReplicas: len(owned)` (`:198-201`)
  - `status.initialization: {controlPlaneInitialized: <ready >= 1>}` (`:203-206`)
  - `status.ready: <desired > 0 and ready >= desired>` (`:207`)
  - condition `Available` (`:209-219`):
    - `True`, reason `Ready`, message `fake control plane is ready` when `status.ready`
    - else `False`, reason `ScalingUp`, message `control plane initialized; <ready>/<desired> machines ready` when `ready >= 1`
    - else `False`, reason `Initializing`, message `fake control plane is initializing`
- If `readyReplicas < desired` the Go controller requeues every 2 s
  (`:185-187`). In prose: keep re-listing the Machines every ~15 s for up to
  the reconcile's wait budget (see the k8s-reconcile skill), and re-run the
  status update whenever `ready` changes. If the budget runs out, finish with
  `status: progressed` so the watch slings a fresh reconcile later.

**Creating one control-plane machine** (`createMachine`, `:222-296`), in this order:

1. Read the `MirageMachineTemplate` named
   `spec.machineTemplate.infrastructureRef.name` in the same namespace (`:226-232`).
2. `base` = `<control plane name>-<5 random characters from "bcdfghjklmnpqrstvwxz2456789">` (`:234`, `rand.String(5)`).
3. Create the Machine (`:239-264`):
   ```yaml
   apiVersion: cluster.x-k8s.io/v1beta2
   kind: Machine
   metadata:
     name: <base>
     namespace: <namespace>
     labels:
       cluster.x-k8s.io/cluster-name: <cluster name>
       cluster.x-k8s.io/control-plane: ""
     ownerReferences:
     - apiVersion: controlplane.cluster.x-k8s.io/v1alpha1
       kind: MirageControlPlane
       name: <control plane name>
       uid: <control plane uid>
       controller: true
       blockOwnerDeletion: true
   spec:
     clusterName: <cluster name>
     version: <spec.version>
     bootstrap:
       configRef:
         apiGroup: bootstrap.cluster.x-k8s.io
         kind: MirageConfig
         name: <base>
     infrastructureRef:
       apiGroup: infrastructure.cluster.x-k8s.io
       kind: MirageMachine
       name: <base>
   ```
4. Read back the created Machine's `uid`; `machineOwner` =
   `{apiVersion: cluster.x-k8s.io/v1beta2, kind: Machine, name: <base>, uid: <machine uid>, controller: true, blockOwnerDeletion: true}` (`:266`).
5. Create the MirageConfig (`:268-279`; already-exists is fine):
   `name: <base>`, same namespace, label `cluster.x-k8s.io/cluster-name`,
   `ownerReferences: [machineOwner]`, `spec.extraData: "role=control-plane"`.
6. Create the MirageMachine (`:281-292`; already-exists is fine):
   `name: <base>`, same namespace, label `cluster.x-k8s.io/cluster-name`,
   `ownerReferences: [machineOwner]`, `spec:` = the template's
   `spec.template.spec` verbatim (e.g. `nodeCPU`, `nodeMemory`, `nodePods`).

Worker Machines are **not** this controller's business: Cluster API core's
MachineSet creates them (and their MirageMachine/MirageConfig from the
templates named by the MachineDeployment).

**Deletion** (`reconcileDelete`, `:298-316`): list the owned Machines; delete
every one that is not already deleting; while any still exists, wait ~2 s
and re-list (bounded by the reconcile budget; finish with
`status: progressed` if they are still there). When none is left, remove the
finalizer (`:314`).

---

## Quick reference: terminal states

| Kind | Terminal (needs no reconcile) |
|---|---|
| MirageCluster | `status.initialization.provisioned == true` and not deleting |
| MirageConfig | `status.initialization.dataSecretCreated == true` |
| MirageMachine | `status.nodeName` non-empty and not deleting |
| MirageControlPlane | finalizer present, kubeconfig Secret exists, `status.replicas == status.readyReplicas == desired`, `status.ready == true`, and not deleting |

Deleting objects that still carry the finalizer always need a reconcile
(except MirageConfig, which has none).

#!/usr/bin/env python3
"""One fake-kubelet pass: heartbeat + lease for every fake Node (node.go:206-233)."""
import datetime
import json
import subprocess
import sys

FAKE = "mirage.cluster.x-k8s.io/fake-node=true"
UNHEALTHY = "mirage.cluster.x-k8s.io/unhealthy"
FM = ["--field-manager=mirage-prose"]


def kubectl(*args, inp=None):
    return subprocess.run(["kubectl", *args], input=inp, capture_output=True, text=True)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_micro():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def set_ready(conds, status, reason, msg, now):
    """setNodeReady: flip Ready, keep lastTransitionTime unless the status changed."""
    for c in conds:
        if c["type"] == "Ready":
            if c.get("status") != status:
                c["lastTransitionTime"] = now
            c.update(status=status, reason=reason, message=msg, lastHeartbeatTime=now)
            return conds
    conds.append({"type": "Ready", "status": status, "reason": reason, "message": msg,
                  "lastHeartbeatTime": now, "lastTransitionTime": now})
    return conds


r = kubectl("get", "nodes", "-l", FAKE, "-o", "json", "--request-timeout=20s")
if r.returncode:
    print("fake-kubelet: list nodes failed:", r.stderr.strip())
    sys.exit(1)
rc = 0
for n in json.loads(r.stdout)["items"]:
    name = n["metadata"]["name"]
    now = now_iso()
    conds = (n.get("status") or {}).get("conditions") or []
    if UNHEALTHY in (n["metadata"].get("annotations") or {}):
        conds = set_ready(conds, "False", "MirageFaultInjected", "unhealthy annotation present", now)
        p = kubectl("patch", "node", name, "--subresource=status", "--type=merge", *FM,
                    "-p", json.dumps({"status": {"conditions": conds}}))
        if p.returncode:
            print(f"fake-kubelet: {name}: status patch failed: {p.stderr.strip()}"); rc = 1
        continue  # no lease renewal: let it go unreachable
    # healthy path: lease, then heartbeat on every condition
    lease = {"spec": {"holderIdentity": name, "leaseDurationSeconds": 40, "renewTime": now_micro()}}
    p = kubectl("-n", "kube-node-lease", "patch", "lease", name, "--type=merge", *FM, "-p", json.dumps(lease))
    if p.returncode and "NotFound" in p.stderr:
        body = {"apiVersion": "coordination.k8s.io/v1", "kind": "Lease",
                "metadata": {"name": name, "namespace": "kube-node-lease"}, **lease}
        p = kubectl("create", "-f", "-", *FM, inp=json.dumps(body))
    if p.returncode:
        print(f"fake-kubelet: {name}: lease failed: {p.stderr.strip()}"); rc = 1
    conds = set_ready(conds, "True", "KubeletReady", "mirage fake kubelet is posting ready", now)
    # If the node-lifecycle controller marked the pressure conditions Unknown
    # (NodeStatusUnknown) during a heartbeat gap, restore the canonical set
    # EnsureFakeNode writes (node.go:118-124): CAPI's NodeHealthy reads ALL
    # conditions, and a lingering Unknown keeps the Machine NotReady.
    canonical = {"MemoryPressure": ("KubeletHasSufficientMemory", ""),
                 "DiskPressure": ("KubeletHasNoDiskPressure", ""),
                 "PIDPressure": ("KubeletHasSufficientPID", "")}
    present = {c["type"] for c in conds}
    for c in conds:
        if c["type"] in canonical and c.get("status") != "False":
            c.update(status="False", reason=canonical[c["type"]][0], message=canonical[c["type"]][1], lastTransitionTime=now)
    for t, (reason, msg) in canonical.items():
        if t not in present:
            conds.append({"type": t, "status": "False", "reason": reason, "message": msg,
                          "lastHeartbeatTime": now, "lastTransitionTime": now})
    for c in conds:
        c["lastHeartbeatTime"] = now
    p = kubectl("patch", "node", name, "--subresource=status", "--type=merge", *FM,
                "-p", json.dumps({"status": {"conditions": conds}}))
    if p.returncode:
        print(f"fake-kubelet: {name}: status patch failed: {p.stderr.strip()}"); rc = 1
sys.exit(rc)

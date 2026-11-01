#!/usr/bin/env python3
"""Tests for cellwait.py on synthetic kubectl output (run: python3 scripts/lib/cellwait_test.py)."""
import json, os, subprocess, sys, tempfile
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
L = {"app.kubernetes.io/instance": "demo"}
def ts(sec_ago): return (datetime.now(timezone.utc) - timedelta(seconds=sec_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
def wl(kind, name, ready): return {"kind": kind, "metadata": {"name": name, "generation": 1, "labels": L}, "spec": {"replicas": 1}, "status": {"observedGeneration": 1, "replicas": 1, "readyReplicas": 1 if ready else 0, "availableReplicas": 1 if ready else 0, "updatedReplicas": 1, "unavailableReplicas": 0 if ready else 1}}
def pod(name, phase, ready, inits=None, conts=None, age=30, labels=None, owner=None):
    return {"metadata": {"name": name, "creationTimestamp": ts(age), "labels": {**L, **(labels or {})}, "ownerReferences": [owner] if owner else []}, "status": {"phase": phase, "conditions": [{"type": "Ready", "status": "True" if ready else "False"}], "initContainerStatuses": inits or [], "containerStatuses": conts or []}}
def rs(name, deployment, revision): return {"metadata": {"name": name, "labels": L, "annotations": {"deployment.kubernetes.io/revision": revision}, "ownerReferences": [{"kind": "Deployment", "name": deployment}]}}
def deploy_rev(w, revision): w["metadata"]["annotations"] = {"deployment.kubernetes.io/revision": revision}; return w
RS_OWNER = lambda name: {"kind": "ReplicaSet", "name": name}
OK = {"name": "c", "ready": True, "restartCount": 0, "state": {"running": {}}}
def waiting(reason): return {"name": "c", "ready": False, "restartCount": 0, "state": {"waiting": {"reason": reason}}}
INIT_RUN = {"name": "migrate", "ready": False, "restartCount": 0, "state": {"running": {}}}
INIT_DONE = {"name": "migrate", "ready": False, "restartCount": 0, "state": {"terminated": {"exitCode": 0}}}
PVC_WFFC = {"metadata": {"name": "demo-backups"}, "status": {"phase": "Pending"}}
PVC_BOUND = {"metadata": {"name": "demo-registry-data"}, "status": {"phase": "Bound"}}
EVENTS = [{"involvedObject": {"name": "demo-backups"}, "lastTimestamp": ts(5), "type": "Normal", "message": "waiting for first consumer to be created before binding"},
          {"involvedObject": {"name": "demo-web-1"}, "lastTimestamp": ts(9), "type": "Warning", "message": 'Failed to pull image "secops-web:dev": not found'},
          {"involvedObject": {"name": "demo-web-1"}, "lastTimestamp": ts(5), "type": "Normal", "message": 'Pulling image "secops-web:dev"'}]  # newer, but a Warning explains the pod

def snapshot(mode, *args, deployments=(), statefulsets=(), pods=(), pvcs=(), jobs=(), pvs=(), replicasets=(), events=None):
    with tempfile.TemporaryDirectory() as d:
        for name, items in [("deployments", deployments), ("statefulsets", statefulsets), ("pods", pods), ("persistentvolumeclaims", pvcs), ("jobs", jobs), ("events", EVENTS if events is None else events), ("persistentvolumes", [{"metadata": {"name": n}} for n in pvs]), ("replicasets", replicasets)]:
            json.dump({"items": list(items)}, open(os.path.join(d, f"{name}.json"), "w"))
        out = subprocess.run([sys.executable, os.path.join(HERE, "cellwait.py"), mode, *args], check=True, capture_output=True, text=True, env={**os.environ, "CELLWAIT_FIXTURE_DIR": d}).stdout
        return json.loads(out)

def test():
    # starting: init containers and unready containers are progress, the WaitForFirstConsumer PVC is not blocking
    s = snapshot("cell", "ns", "demo", deployments=[wl("Deployment", "demo-api", False), wl("Deployment", "demo-keycloak", False)], statefulsets=[wl("StatefulSet", "demo-postgres", True)],
                 pods=[pod("demo-api-1", "Pending", False, inits=[INIT_RUN], age=400), pod("demo-keycloak-1", "Running", False, conts=[waiting("")]), pod("demo-postgres-0", "Running", True, conts=[OK])], pvcs=[PVC_WFFC, PVC_BOUND])
    assert not s["done"] and s["summary"] == "1/3 workloads rolled out, pods 1/3 ready", s
    assert s["waiting"] == ["demo-api-1 (Init:0/1)", "demo-keycloak-1 (Running 0/1)"], s["waiting"]
    assert s["stuck"] == [], s["stuck"]  # Pending with a running init container for 400 s is not stuck
    assert s["info"] == ["pvc demo-backups (Pending, waiting for first consumer to be created before binding)"], s["info"]
    # stuck: image pull failure with its event; Pending for minutes with nothing running
    s = snapshot("cell", "ns", "demo", deployments=[wl("Deployment", "demo-web", False), wl("Deployment", "demo-api", False)],
                 pods=[pod("demo-web-1", "Pending", False, conts=[waiting("ImagePullBackOff")], age=400), pod("demo-api-1", "Pending", False, age=400)], pvcs=[PVC_BOUND])
    assert [x["text"] for x in s["stuck"]] == ['demo-web-1: image pull (ImagePullBackOff) — Failed to pull image "secops-web:dev": not found', "demo-api-1: pending for minutes (Pending) — no event"], s["stuck"]
    assert "demo-web-1 (Pending 0/1 ImagePullBackOff)" in s["waiting"], s["waiting"]
    # ErrImagePull and ImagePullBackOff are the same condition: same key, so the caller warns once
    s2 = snapshot("cell", "ns", "demo", deployments=[wl("Deployment", "demo-web", False)], pods=[pod("demo-web-1", "Pending", False, conts=[waiting("ErrImagePull")], age=400)], pvcs=[])
    assert s2["stuck"][0]["key"] == s["stuck"][0]["key"] == "demo-web-1|image pull", (s2["stuck"], s["stuck"])
    # Pending for minutes whose last event is scheduling / pulling progress is slow, not stuck
    s = snapshot("cell", "ns", "demo", deployments=[wl("Deployment", "demo-api", False)], pods=[pod("demo-api-1", "Pending", False, age=400)], pvcs=[],
                 events=[{"involvedObject": {"name": "demo-api-1"}, "lastTimestamp": ts(5), "message": "Successfully assigned ns/demo-api-1 to kind-control-plane"}])
    assert s["stuck"] == [] and s["waiting"] == ["demo-api-1 (Pending 0/1)"], s
    # after a rollback only the current ReplicaSet's pods count; Failed / Succeeded pods of the old one are history
    s = snapshot("cell", "ns", "demo", deployments=[deploy_rev(wl("Deployment", "demo-keycloak", False), "3")],
                 replicasets=[rs("demo-keycloak-old", "demo-keycloak", "2"), rs("demo-keycloak-new", "demo-keycloak", "3")],
                 pods=[pod("demo-keycloak-old-x", "Failed", False, age=400, owner=RS_OWNER("demo-keycloak-old")), pod("demo-keycloak-old-y", "Pending", False, conts=[waiting("ImagePullBackOff")], age=400, owner=RS_OWNER("demo-keycloak-old")),
                       pod("demo-keycloak-new-z", "Running", False, conts=[waiting("")], owner=RS_OWNER("demo-keycloak-new"))], pvcs=[])
    assert s["waiting"] == ["demo-keycloak-new-z (Running 0/1)"] and s["stuck"] == [], s
    # a StatefulSet pod of a superseded controller revision is ignored too
    sts = wl("StatefulSet", "demo-runner", False); sts["status"]["updateRevision"] = "demo-runner-new"
    s = snapshot("cell", "ns", "demo", statefulsets=[sts], pods=[pod("demo-runner-0", "Pending", False, age=400, labels={"controller-revision-hash": "demo-runner-old"}, owner={"kind": "StatefulSet", "name": "demo-runner"})], pvcs=[])
    assert s["waiting"] == ["demo-runner (1/1 updated, 0/1 ready)"] and s["stuck"] == [], s
    # a workload without any pod yet is named itself
    s = snapshot("cell", "ns", "demo", deployments=[wl("Deployment", "demo-web", False)], pods=[], pvcs=[])
    assert s["waiting"] == ["demo-web (1/1 updated, 0/1 ready, 0/1 available)"], s["waiting"]
    # ready: job pods are not counted; an unbound WaitForFirstConsumer PVC does not block
    s = snapshot("cell", "ns", "demo", deployments=[wl("Deployment", "demo-api", True)], pods=[pod("demo-api-1", "Running", True, inits=[INIT_DONE], conts=[OK]), pod("demo-backup-x-k", "Succeeded", False, labels={"job-name": "demo-backup-x"})], pvcs=[PVC_WFFC])
    assert s["done"] and s["summary"] == "all workloads rolled out (1/1 workloads rolled out, pods 1/1 ready)" and s["info"], s
    # mid-rollout after `helm upgrade`: the OLD pod is the ready one, the NEW pod the updated one — the Deployment reports
    # replicas 2 / updated 1 / ready 1 / available 1, and that is not done (a broken new image would otherwise pass)
    mid = deploy_rev(wl("Deployment", "demo-api", True), "2"); mid["metadata"]["generation"] = 2
    mid["status"].update({"observedGeneration": 2, "replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1, "unavailableReplicas": 1})
    s = snapshot("cell", "ns", "demo", deployments=[mid], replicasets=[rs("demo-api-old", "demo-api", "1"), rs("demo-api-new", "demo-api", "2")],
                 pods=[pod("demo-api-old-a", "Running", True, conts=[OK], owner=RS_OWNER("demo-api-old")), pod("demo-api-new-b", "Running", False, conts=[waiting("")], owner=RS_OWNER("demo-api-new"))], pvcs=[])
    assert not s["done"] and s["waiting"] == ["demo-api-new-b (Running 0/1)"] and s["summary"] == "0/1 workloads rolled out, pods 0/1 ready", s
    # the controller has not even seen the new generation yet (one second after helm returned): not done
    stale = wl("Deployment", "demo-api", True); stale["metadata"]["generation"] = 2
    s = snapshot("cell", "ns", "demo", deployments=[stale], pods=[pod("demo-api-1", "Running", True, conts=[OK])], pvcs=[])
    assert not s["done"] and s["waiting"] == ["demo-api (controller has not observed the new generation yet)"], s
    # new pod ready but the old one still terminating (replicas 2, unavailable 0): not done until it is gone; the
    # terminating pod is not listed
    tail = deploy_rev(wl("Deployment", "demo-api", True), "2"); tail["metadata"]["generation"] = 2
    tail["status"].update({"observedGeneration": 2, "replicas": 2, "updatedReplicas": 1, "readyReplicas": 2, "availableReplicas": 2, "unavailableReplicas": 0})
    term = pod("demo-api-old-a", "Running", True, conts=[OK], owner=RS_OWNER("demo-api-old")); term["metadata"]["deletionTimestamp"] = ts(1)
    s = snapshot("cell", "ns", "demo", deployments=[tail], replicasets=[rs("demo-api-old", "demo-api", "1"), rs("demo-api-new", "demo-api", "2")],
                 pods=[term, pod("demo-api-new-b", "Running", True, conts=[OK], owner=RS_OWNER("demo-api-new"))], pvcs=[])
    assert not s["done"] and s["waiting"] == ["demo-api (1 old replica(s) still terminating)"] and s["summary"] == "0/1 workloads rolled out, pods 1/1 ready", s
    # a StatefulSet whose update revision is not current yet is not done either
    sts2 = wl("StatefulSet", "demo-runner", True); sts2["status"].update({"currentRevision": "demo-runner-old", "updateRevision": "demo-runner-new"})
    s = snapshot("cell", "ns", "demo", statefulsets=[sts2], pods=[pod("demo-runner-0", "Running", True, conts=[OK], labels={"controller-revision-hash": "demo-runner-new"}, owner={"kind": "StatefulSet", "name": "demo-runner"})], pvcs=[])
    assert not s["done"], s
    # a PVC that is Pending for another reason blocks
    s = snapshot("cell", "ns", "demo", deployments=[wl("Deployment", "demo-api", True)], pods=[pod("demo-api-1", "Running", True, conts=[OK])], pvcs=[{"metadata": {"name": "demo-registry-data"}, "status": {"phase": "Pending"}}])
    assert not s["done"] and s["waiting"] == ["pvc demo-registry-data (Pending)"], s
    # jobs
    job = lambda conds, name="j1": {"metadata": {"name": name}, "status": {"conditions": conds}}
    s = snapshot("job", "ns", "j1", jobs=[job([])], pods=[pod("j1-k", "Pending", False, inits=[INIT_RUN], labels={"job-name": "j1"})])
    assert not s["done"] and s["waiting"] == ["j1-k (Init:0/1)"], s
    s = snapshot("job", "ns", "j1", jobs=[job([{"type": "Complete", "status": "True"}])])
    assert s["done"] and not s["failed"], s
    s = snapshot("job", "ns", "j1", jobs=[job([{"type": "Failed", "status": "True"}])], pods=[pod("j1-k", "Failed", False, conts=[{"name": "dump", "ready": False, "restartCount": 0, "state": {"terminated": {"exitCode": 1}}}], labels={"job-name": "j1"})])
    assert s["done"] and s["failed"] and [x["text"] for x in s["stuck"]] == ["j1-k (Failed 0/1)"], s
    s = snapshot("job", "ns", "missing", jobs=[])
    assert s["done"] and s["failed"], s
    # persistent volumes
    s = snapshot("pvs", "pv-1", "pv-2", pvs=["pv-1"])
    assert not s["done"] and s["waiting"] == ["pv pv-1"] and s["summary"] == "1/2 volumes released", s
    s = snapshot("pvs", "pv-1", pvs=[])
    assert s["done"], s
    print("cellwait ok")

if __name__ == "__main__":
    test()

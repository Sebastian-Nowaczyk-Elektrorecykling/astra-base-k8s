#!/usr/bin/env bash
# Real API-server eviction test on an isolated fake Node in the disposable CI kind cluster.
set -euo pipefail
[[ $(kubectl config current-context) == kind-elektro-validation ]] || { echo 'Requires kind-elektro-validation.' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/lib/node-maintenance.sh
source "$repo/scripts/lib/node-maintenance.sh"
node=maintenance-pdb-test
namespace=maintenance-test
cleanup() {
  kubectl delete namespace "$namespace" --ignore-not-found --wait=false >/dev/null
  kubectl delete node "$node" --ignore-not-found --wait=false >/dev/null
}
trap cleanup EXIT
kubectl create namespace "$namespace"
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Node
metadata:
  name: maintenance-pdb-test
---
apiVersion: v1
kind: ReplicationController
metadata:
  name: protected
  namespace: maintenance-test
spec:
  replicas: 1
  selector:
    app: maintenance-protected
  template:
    metadata:
      labels:
        app: maintenance-protected
    spec:
      nodeName: maintenance-pdb-test
      containers:
        - name: test
          image: registry.k8s.io/pause:3.10
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: protected
  namespace: maintenance-test
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: maintenance-protected
YAML
for attempt in {1..30}; do
  pod=$(kubectl -n "$namespace" get pods -l app=maintenance-protected -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -z $pod ]] || break
  sleep 1
done
[[ -n $pod ]]
# No container is started on this fake Node. Make API status Ready to exercise PDB's protected eviction path.
kubectl -n "$namespace" patch pod "$pod" --subresource=status --type=merge \
  -p '{"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}'
for attempt in {1..30}; do
  if kubectl -n "$namespace" get pdb protected -o json | jq -e '.status.currentHealthy == 1 and .status.disruptionsAllowed == 0' >/dev/null; then break; fi
  [[ $attempt != 30 ]] || { echo 'PDB did not observe the ready test pod.' >&2; exit 1; }
  sleep 1
done
node_uid=$(kubectl get node "$node" -o jsonpath='{.metadata.uid}')
# Use the API-assigned test metadata; no SSH host operation is involved.
machine_id=$(kubectl get node "$node" -o json | jq -r ' .status.nodeInfo.machineID')
longhorn=false delete_emptydir=false timeout=3
if (evacuate_node) >.cache/drain-pdb.log 2>&1; then
  echo 'Maintenance unexpectedly bypassed a PodDisruptionBudget.' >&2; exit 1
fi
grep -qi 'disruption budget' .cache/drain-pdb.log
kubectl -n "$namespace" get pod "$pod" -o json | jq -e '.metadata.deletionTimestamp == null' >/dev/null
echo 'Real Kubernetes eviction denied by PDB; maintenance did not delete the protected pod.'

#!/usr/bin/env bash
# Runs only against the disposable CI kind cluster, never a user's current context.
set -euo pipefail
[[ $(kubectl config current-context) == kind-elektro-validation ]] || { echo 'Requires kind-elektro-validation context.' >&2; exit 1; }
kubectl create namespace flux-system
kubectl apply --server-side --field-manager=elektro-validation -f rendered/namespaces.yaml
helm upgrade --install kyverno .cache/charts/kyverno/kyverno --namespace kyverno \
  --values .cache/values/kyverno.yaml --wait --timeout 10m
kubectl apply --server-side --force-conflicts -f rendered/crds.yaml
kubectl wait --for=condition=Established crd --all --timeout=3m
kubectl apply --server-side --field-manager=elektro-validation -f rendered/infrastructure-admission.yaml
if ! kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true mutatingpolicy/cnpg-storage-default --timeout=2m; then
  kubectl get mutatingpolicy cnpg-storage-default -o yaml >&2
  kubectl -n kyverno logs deployment/kyverno-admission-controller --tail=100 >&2
  exit 1
fi
kubectl apply --server-side --dry-run=server --validate=strict -f clusters/base/reconciliation.yaml >/dev/null
# Allow the API server to observe bindings, polling a real denial rather than assuming immediate propagation.
for attempt in {1..30}; do
  if ! kubectl create service nodeport bypass --tcp=80:80 -n default --dry-run=server -o yaml >/dev/null 2>&1; then break; fi
  if [[ $attempt == 30 ]]; then echo 'Admission binding never became effective.' >&2; exit 1; fi
  sleep 1
done
for file in rendered/infrastructure-*.yaml; do
  # Admission was applied above; test its own remaining manifests without running workloads.
  kubectl apply --server-side --field-manager=elektro-validation --dry-run=server --validate=strict -f "$file" >/dev/null
done
for file in examples/backups/barman-release.yaml examples/backups/object-store.yaml \
  examples/backups/scheduled-backup.yaml examples/backups/longhorn-target.yaml; do
  kubectl apply --server-side --dry-run=server --validate=strict -f "$file" >/dev/null
done
kubectl apply --dry-run=server -f examples/cnpg-cluster.yaml -o json >.cache/cnpg-default.json
python3 - <<'PY'
import json
assert json.load(open('.cache/cnpg-default.json'))['spec']['storage']['storageClass'] == 'longhorn-cnpg'
PY
python3 - <<'PY'
import yaml
cluster = yaml.safe_load(open('examples/cnpg-cluster.yaml'))
cluster['spec']['storage']['storageClass'] = 'longhorn-3'
cluster['spec']['walStorage'] = {'size': '1Gi'}
with open('.cache/explicit-cnpg.yaml', 'w') as output:
    yaml.safe_dump(cluster, output)
PY
kubectl apply --dry-run=server -f .cache/explicit-cnpg.yaml -o json >.cache/cnpg-explicit.json
python3 - <<'PY'
import json
spec = json.load(open('.cache/cnpg-explicit.json'))['spec']
assert spec['storage']['storageClass'] == 'longhorn-3'
assert spec['walStorage']['storageClass'] == 'longhorn-cnpg'
PY
python3 - <<'PY'
import copy, json, subprocess, yaml
base = yaml.safe_load(open('examples/cnpg-cluster.yaml'))
for data, wal in [('', ''), (None, None), ('longhorn-3', 'longhorn'), ('longhorn-cnpg', 'longhorn-3')]:
    cluster = copy.deepcopy(base)
    cluster['spec']['storage']['storageClass'] = data
    cluster['spec']['walStorage'] = {'size': '1Gi', 'storageClass': wal}
    result = subprocess.run(['kubectl', 'apply', '--dry-run=server', '-f', '-', '-o', 'json'],
                            input=yaml.safe_dump(cluster), text=True, capture_output=True, check=True)
    spec = json.loads(result.stdout)['spec']
    assert spec['storage']['storageClass'] == (data or 'longhorn-cnpg'), spec
    assert spec['walStorage']['storageClass'] == (wal or 'longhorn-cnpg'), spec
PY
reject() {
  local reason=$1
  shift
  if "$@" >.cache/rejection.log 2>&1; then
    echo "Unexpectedly admitted: $*" >&2; exit 1
  fi
  [[ $(cat .cache/rejection.log) == *"$reason"* ]] || { cat .cache/rejection.log >&2; exit 1; }
}
reject 'NodePort services bypass' kubectl create service nodeport bypass --tcp=80:80 -n default --dry-run=server
reject 'Route-specific security overrides' kubectl apply --dry-run=server -f tests/fixtures/route-override.yaml
reject 'Only Keycloak may use' kubectl apply --dry-run=server -f tests/fixtures/native-bypass.yaml
reject 'Init/debug containers cannot' kubectl apply --dry-run=server -f tests/fixtures/privileged-init.yaml
# Verify the storage default cannot silently disappear when its webhook is unavailable.
kubectl -n kyverno scale deployment/kyverno-admission-controller --replicas=0
kubectl -n kyverno wait --for=delete pod -l app.kubernetes.io/component=admission-controller --timeout=2m
for file in examples/cnpg-cluster.yaml .cache/explicit-cnpg.yaml; do
  if kubectl apply --dry-run=server -f "$file" >.cache/defaulting-outage.log 2>&1; then
    cat .cache/defaulting-outage.log >&2
    echo 'CNPG without a data/WAL class was admitted while its mutator was unavailable.' >&2; exit 1
  fi
  # A disconnected Fail webhook rejects before validation; a gracefully removed
  # webhook leaves the independent native class guard to reject the same request.
  grep -Eq 'failed calling webhook|CNPG (WAL )?storage must have an explicit class after defaulting' .cache/defaulting-outage.log
done
kubectl -n kyverno scale deployment/kyverno-admission-controller --replicas=1
kubectl -n kyverno rollout status deployment/kyverno-admission-controller --timeout=3m
kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true mutatingpolicy/cnpg-storage-default --timeout=2m
python3 tests/domains.py
echo 'Server-side schemas, CNPG default mutation and negative admission cases passed.'

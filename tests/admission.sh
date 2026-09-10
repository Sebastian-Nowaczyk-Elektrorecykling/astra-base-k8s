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
echo 'Server-side schemas, CNPG default mutation and negative admission cases passed.'

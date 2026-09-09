#!/usr/bin/env bash
# Runs only against the disposable CI kind cluster, never a user's current context.
set -euo pipefail
[[ $(kubectl config current-context) == kind-astra-validation ]] || { echo 'Requires kind-astra-validation context.' >&2; exit 1; }
kubectl create namespace flux-system
kubectl apply -f rendered/namespaces.yaml
helm upgrade --install kyverno .cache/charts/kyverno/kyverno --namespace kyverno \
  --values .cache/values/kyverno.yaml --wait --timeout 10m
kubectl apply --server-side --force-conflicts -f rendered/crds.yaml
kubectl wait --for=condition=Established crd --all --timeout=3m
kubectl apply -f rendered/infrastructure-admission.yaml
# Allow the API server to observe bindings, polling a real denial rather than assuming immediate propagation.
for attempt in {1..30}; do
  if ! kubectl create service nodeport bypass --tcp=80:80 -n default --dry-run=server -o yaml >/dev/null 2>&1; then break; fi
  if [[ $attempt == 30 ]]; then echo 'Admission binding never became effective.' >&2; exit 1; fi
  sleep 1
done
for file in rendered/infrastructure-*.yaml; do
  # Admission was applied above; test its own remaining manifests without running workloads.
  kubectl apply --server-side --dry-run=server --validate=strict -f "$file" >/dev/null
done
kubectl apply --dry-run=server -f examples/cnpg-cluster.yaml -o json >.cache/cnpg-default.json
python3 - <<'PY'
import json
assert json.load(open('.cache/cnpg-default.json'))['spec']['storage']['storageClass'] == 'longhorn-cnpg'
PY
if kubectl create service nodeport bypass --tcp=80:80 -n default --dry-run=server; then
  echo 'NodePort bypass was admitted.' >&2; exit 1
fi
if kubectl apply --dry-run=server -f tests/fixtures/route-override.yaml; then
  echo 'Route policy override was admitted.' >&2; exit 1
fi
if kubectl apply --dry-run=server -f tests/fixtures/native-bypass.yaml; then
  echo 'Native-listener bypass was admitted.' >&2; exit 1
fi
echo 'Server-side schemas, CNPG default mutation and negative admission cases passed.'

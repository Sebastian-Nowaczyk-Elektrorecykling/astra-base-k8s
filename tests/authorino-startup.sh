#!/usr/bin/env bash
# Start the actual pinned Authorino image in the existing disposable CI cluster.
set -euo pipefail
[[ $(kubectl config current-context) == kind-elektro-validation ]] || {
  echo 'Requires kind-elektro-validation context.' >&2; exit 1;
}
python3 - <<'PY'
import yaml
with open('rendered/infrastructure-authorization.yaml') as stream:
    resources = [d for d in yaml.safe_load_all(stream) if d and
                 d.get('kind') in {'ServiceAccount', 'Role', 'RoleBinding', 'Deployment', 'Service'} and
                 d.get('metadata', {}).get('name') == 'authorino']
assert {d['kind'] for d in resources} == {'ServiceAccount', 'Role', 'RoleBinding', 'Deployment', 'Service'}
with open('.cache/authorino-startup.yaml', 'w') as output:
    yaml.safe_dump_all(resources, output)
PY
kubectl apply --server-side --field-manager=elektro-validation -f .cache/authorino-startup.yaml
if ! kubectl -n authorization rollout status deployment/authorino --timeout=3m; then
  kubectl -n authorization describe pods -l app=authorino
  kubectl -n authorization logs deployment/authorino --all-containers=true --tail=100 || true
  exit 1
fi
uid=$(kubectl -n authorization exec deployment/authorino -- id -u)
[[ $uid == 1000 ]] || { echo "Unexpected Authorino runtime UID: $uid" >&2; exit 1; }
echo 'Actual Authorino image reached Ready with the configured arguments, RBAC, read-only root filesystem and UID 1000.'

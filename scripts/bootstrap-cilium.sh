#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
[[ $# == 1 && -f $1 ]] || { echo 'Usage: bootstrap-cilium.sh local/cluster.env' >&2; exit 2; }
# shellcheck source=/dev/null
source "$1"
# shellcheck source=lib/cluster-settings.sh
source "$repo/scripts/lib/cluster-settings.sh"
select_cluster "${CLUSTER_NAME:-laptops}"
: "${API_HOST:?}"
command -v helm >/dev/null
command -v kubectl >/dev/null
# Persist the address before the first Helm install so Flux adopts the same endpoint.
bash "$repo/scripts/configure-cluster.sh" "$1"
check_cluster_target
# Once Flux owns the release, use reconciliation/recovery instead of racing its Helm controller.
if [[ -n $(kubectl get crd helmreleases.helm.toolkit.fluxcd.io --ignore-not-found -o name) ]]; then
  if [[ -n $(kubectl -n kube-system get helmrelease cilium --ignore-not-found -o name) ]]; then
    echo 'Flux already manages Cilium. Commit the settings change and follow docs/cilium-api-recovery.md.' >&2
    exit 1
  fi
fi
helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium
# Same release name, namespace, values and pin as Flux: Flux takes over this release.
helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
  --namespace kube-system --values "$repo/infrastructure/cilium/values.yaml" \
  --set-string "k8sServiceHost=$API_HOST" --set k8sServicePort=6443 --wait --timeout 10m
kubectl wait --for=condition=Ready nodes --all --timeout=10m

#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
[[ $# == 1 && -f $1 ]] || { echo 'Usage: bootstrap-cilium.sh local/cluster.env' >&2; exit 2; }
# shellcheck source=/dev/null
source "$1"
: "${API_HOST:?}"
command -v helm >/dev/null
command -v kubectl >/dev/null
helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium
# Same release name, namespace, values and pin as Flux: Flux takes over this release.
helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
  --namespace kube-system --values "$repo/infrastructure/cilium/values.yaml" \
  --set-string "k8sServiceHost=$API_HOST" --set k8sServicePort=6443 --wait --timeout 10m
kubectl wait --for=condition=Ready nodes --all --timeout=10m

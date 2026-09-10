#!/usr/bin/env bash
# Copy the shared, nonsecret bootstrap settings into the GitOps ConfigMap.
set -euo pipefail
check=false
if [[ ${1:-} == --check ]]; then check=true; shift; fi
[[ $# == 1 && -f $1 ]] || {
  echo 'Usage: configure-cluster.sh [--check] local/cluster.env' >&2; exit 2;
}
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
settings="$repo/clusters/laptops/settings.yaml"
for cmd in kubectl jq; do command -v "$cmd" >/dev/null; done
# This is the same administrator-controlled shell config used to install k3s.
# shellcheck source=/dev/null
source "$1"
[[ ${API_HOST:-} =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || {
  echo 'API_HOST must be a bare IPv4 address or DNS name, without https:// or :6443.' >&2; exit 2;
}
[[ ${POD_CIDR:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || {
  echo 'POD_CIDR must be the existing IPv4 pod network, for example 10.42.0.0/16.' >&2; exit 2;
}
# --local does not contact Kubernetes; the workstation can run this before a cluster exists.
current=$(kubectl patch --local --type=merge --patch '{}' --filename "$settings" -o json)
jq -e '.kind == "ConfigMap" and .metadata.name == "cluster-settings" and .metadata.namespace == "flux-system"' \
  <<<"$current" >/dev/null
if jq -e --arg host "$API_HOST" --arg cidr "$POD_CIDR" \
  '.data.API_HOST == $host and .data.POD_CIDR == $cidr' <<<"$current" >/dev/null; then
  echo "Bootstrap and GitOps settings agree: API_HOST=$API_HOST, POD_CIDR=$POD_CIDR"
  exit 0
fi
if $check; then
  echo 'Bootstrap and GitOps settings disagree; Flux would overwrite the local Cilium API address.' >&2
  jq -r '"GitOps API_HOST=" + .data.API_HOST + ", POD_CIDR=" + .data.POD_CIDR' <<<"$current" >&2
  echo "Local  API_HOST=$API_HOST, POD_CIDR=$POD_CIDR" >&2
  echo 'Run bash scripts/configure-cluster.sh local/cluster.env, then commit and push settings.yaml.' >&2
  exit 1
fi
patch=$(jq -n --arg host "$API_HOST" --arg cidr "$POD_CIDR" '{data: {API_HOST: $host, POD_CIDR: $cidr}}')
tmp=$(mktemp "$repo/clusters/laptops/.settings.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
kubectl patch --local --type=merge --patch "$patch" --filename "$settings" -o yaml >"$tmp"
chmod --reference="$settings" "$tmp"
mv -- "$tmp" "$settings"
echo "Updated GitOps settings: API_HOST=$API_HOST, POD_CIDR=$POD_CIDR"
echo 'Review, commit and push clusters/laptops/settings.yaml before Flux takes over Cilium.'

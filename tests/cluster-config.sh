#!/usr/bin/env bash
# Exercise the real local configuration handoff with the installed kubectl and jq.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/elektro-config-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/scripts/lib" "$tmp/clusters/laptops"
cp -r "$repo/clusters/base" "$tmp/clusters/base"
cp "$repo/scripts/lib/cluster-settings.sh" "$tmp/scripts/lib/"
cp "$repo/scripts/validate-cluster.py" "$tmp/scripts/"
cp "$repo/scripts/configure-cluster.sh" "$tmp/scripts/"
cp "$repo/clusters/laptops/settings.yaml" "$tmp/clusters/laptops/"
settings="$tmp/clusters/laptops/settings.yaml"
kubectl patch --local --type=merge --patch '{"data":{"API_HOST":"old-api.invalid","POD_CIDR":"10.99.0.0/16"}}' \
  -f "$settings" -o yaml >"$tmp/initial.yaml"
mv "$tmp/initial.yaml" "$settings"
before=$(kubectl patch --local --type=merge --patch '{}' -f "$settings" -o json | jq -S 'del(.data.API_HOST, .data.POD_CIDR, .data.SERVICE_CIDR, .data.CLUSTER_DNS)')
for host in 198.51.100.17 api.elektro.example; do
  cat >"$tmp/cluster.env" <<EOF
API_HOST=$host
POD_CIDR=10.88.0.0/16
SERVICE_CIDR=10.89.0.0/16
CLUSTER_DNS=10.89.0.10
UNRELATED_SETTING=must-not-be-copied
EOF
  digest=$(sha256sum "$settings")
  if bash "$tmp/scripts/configure-cluster.sh" --check "$tmp/cluster.env" >"$tmp/check.log" 2>&1; then
    echo 'A mismatched bootstrap/GitOps address was accepted.' >&2; exit 1
  fi
  grep -Fq 'Bootstrap and GitOps settings disagree' "$tmp/check.log"
  [[ $(sha256sum "$settings") == "$digest" ]]
  bash "$tmp/scripts/configure-cluster.sh" "$tmp/cluster.env"
  updated=$(kubectl patch --local --type=merge --patch '{}' -f "$settings" -o json)
  jq -e --arg host "$host" '.data.API_HOST == $host and .data.POD_CIDR == "10.88.0.0/16" and .data.SERVICE_CIDR == "10.89.0.0/16" and .data.CLUSTER_DNS == "10.89.0.10"' <<<"$updated" >/dev/null
  [[ $(jq -S 'del(.data.API_HOST, .data.POD_CIDR, .data.SERVICE_CIDR, .data.CLUSTER_DNS)' <<<"$updated") == "$before" ]]
  bash "$tmp/scripts/configure-cluster.sh" --check "$tmp/cluster.env"
  digest=$(sha256sum "$settings")
  bash "$tmp/scripts/configure-cluster.sh" "$tmp/cluster.env"
  [[ $(sha256sum "$settings") == "$digest" ]]
done
echo 'Configuration mismatch rejection, IP/DNS synchronization, unrelated settings and idempotency passed.'

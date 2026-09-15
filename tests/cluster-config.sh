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
cp "$repo/scripts/configure-bgp.py" "$tmp/scripts/"
cp "$repo/clusters/laptops/settings.yaml" "$tmp/clusters/laptops/"
settings="$tmp/clusters/laptops/settings.yaml"
# Files from the retired unnamed bootstrap must not silently target laptops.
printf 'API_HOST=192.168.2.153\n' >"$tmp/unnamed.env"
if bash "$tmp/scripts/configure-cluster.sh" "$tmp/unnamed.env" >"$tmp/unnamed.log" 2>&1; then
  echo 'An unnamed bootstrap file was accepted.' >&2; exit 1
fi
grep -Fq 'Export a named profile' "$tmp/unnamed.log"
kubectl patch --local --type=merge --patch '{"data":{"API_HOST":"old-api.invalid","POD_CIDR":"10.99.0.0/16"}}' \
  -f "$settings" -o yaml >"$tmp/initial.yaml"
mv "$tmp/initial.yaml" "$settings"
before=$(kubectl patch --local --type=merge --patch '{}' -f "$settings" -o json | jq -S 'del(.data.API_HOST, .data.POD_CIDR, .data.SERVICE_CIDR, .data.CLUSTER_DNS)')
for host in 198.51.100.17 api.elektro.example; do
  cat >"$tmp/cluster.env" <<EOF
CLUSTER_NAME=laptops
INTERNAL_DOMAIN=internal
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
# BGP values import through the same profile handoff; generator uses real local kubectl.
cat >>"$tmp/cluster.env" <<'EOF'
BGP_ROUTER_IP=192.168.2.2
BGP_LOCAL_ASN=64515
BGP_PEER_ASN=64514
EOF
bash "$tmp/scripts/configure-cluster.sh" "$tmp/cluster.env"
python3 "$tmp/scripts/configure-bgp.py" laptops --node-ip 192.168.2.153 >"$tmp/router.txt"
grep -Fq 'set protocols bgp 64514 neighbor 192.168.2.153 remote-as 64515' "$tmp/router.txt"
if grep -Fq 'parameters router-id' "$tmp/router.txt"; then
  echo 'Router generation overwrote the existing global router ID.' >&2; exit 1
fi
python3 "$tmp/scripts/configure-bgp.py" laptops --node-ip 192.168.2.153 --router-id 192.168.2.2 >"$tmp/router.txt"
grep -Fq 'set protocols bgp 64514 parameters router-id 192.168.2.2' "$tmp/router.txt"

# Generated env files carry the complete nonsecret network handoff and detect
# stale router/DNS/pool values before bootstrap, without mutating the profile.
bash "$tmp/scripts/configure-cluster.sh" --export laptops >"$tmp/export.env"
for key in LAN_CIDR LB_CIDR LB_START LB_STOP EDGE_IP DNS_IP DNS_UPSTREAMS DNS_CLIENT_CIDR BGP_ROUTER_IP BGP_LOCAL_ASN BGP_PEER_ASN IDENTITY_HOST PUBLIC_EDGE_IP; do
  grep -q "^${key}=" "$tmp/export.env"
done
bash "$tmp/scripts/configure-cluster.sh" --check "$tmp/export.env"
digest=$(sha256sum "$settings")
bash "$tmp/scripts/configure-cluster.sh" "$tmp/export.env"
[[ $(sha256sum "$settings") == "$digest" ]]
for override in BGP_ROUTER_IP=192.168.2.3 DNS_IP=10.44.0.243 LB_STOP=10.44.0.250; do
  cp "$tmp/export.env" "$tmp/stale.env"
  printf '%s\n' "$override" >>"$tmp/stale.env"
  if bash "$tmp/scripts/configure-cluster.sh" --check "$tmp/stale.env" >"$tmp/stale.log" 2>&1; then
    echo 'Stale exported network configuration was accepted.' >&2; exit 1
  fi
  grep -Fq 'Bootstrap and GitOps settings disagree' "$tmp/stale.log"
  [[ $(sha256sum "$settings") == "$digest" ]]
done
for override in BGP_ENABLED=true BGP_ENABLED=false LAN_INTERFACE_REGEX=eth0; do
  cp "$tmp/export.env" "$tmp/retired.env"
  printf '%s\n' "$override" >>"$tmp/retired.env"
  if bash "$tmp/scripts/configure-cluster.sh" "$tmp/retired.env" >"$tmp/retired.log" 2>&1; then
    echo 'A retired L2/BGP setting was silently accepted.' >&2; exit 1
  fi
  grep -Fq 'Remove retired' "$tmp/retired.log"
  [[ $(sha256sum "$settings") == "$digest" ]]
done
kubectl patch --local --type=merge --patch '{"data":{"CLUSTER_NAME":"another"}}' \
  -f "$settings" -o yaml >"$tmp/wrong-name.yaml"
mv "$tmp/wrong-name.yaml" "$settings"
if bash "$tmp/scripts/configure-cluster.sh" --export laptops >"$tmp/wrong-name.env" 2>"$tmp/wrong-name.log"; then
  echo 'Export accepted a mismatched profile identity.' >&2; exit 1
fi
grep -Fq 'does not match its directory' "$tmp/wrong-name.log"
[[ ! -s "$tmp/wrong-name.env" ]]
echo 'Profile identity, full network handoff, stale/retired settings, router ID preservation and idempotency passed.'

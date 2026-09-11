#!/usr/bin/env bash
# Bridge the selected GitOps profile and the nonsecret k3s bootstrap configuration.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/cluster-settings.sh
source "$repo/scripts/lib/cluster-settings.sh"
for cmd in kubectl jq python3; do command -v "$cmd" >/dev/null; done
if [[ ${1:-} == --export && $# == 2 ]]; then
  select_cluster "$2"
  current=$(cluster_settings_json)
  python3 "$repo/scripts/validate-cluster.py" <<<"$current"
  echo '# Generated from the selected GitOps profile; contains no credentials.'
  jq -r '.data | to_entries[] | select(.key | IN("CLUSTER_NAME","API_HOST","POD_CIDR","SERVICE_CIDR","CLUSTER_DNS","INTERNAL_DOMAIN")) | .key + "=" + (.value | @sh)' <<<"$current"
  exit 0
fi
check=false
if [[ ${1:-} == --check ]]; then check=true; shift; fi
[[ $# == 1 && -f $1 ]] || {
  echo 'Usage: configure-cluster.sh [--check] local/cluster.env | --export CLUSTER_NAME' >&2; exit 2;
}
# Administrator-controlled shell configuration, also consumed by install-k3s.sh.
# shellcheck source=/dev/null
source "$1"
select_cluster
INTERNAL_DOMAIN=${INTERNAL_DOMAIN:-internal}
current=$(cluster_settings_json)
jq -e --arg cluster "$cluster_name" '.data.CLUSTER_NAME == $cluster' <<<"$current" >/dev/null || {
  echo 'CLUSTER_NAME in settings.yaml does not match its directory.' >&2; exit 2;
}
patch=$(jq -n '{data:{}}')
for key in API_HOST POD_CIDR SERVICE_CIDR CLUSTER_DNS INTERNAL_DOMAIN; do
  [[ -n ${!key:-} ]] || { echo "Missing $key in bootstrap configuration." >&2; exit 2; }
  patch=$(jq --arg key "$key" --arg value "${!key}" '.data[$key]=$value' <<<"$patch")
done
# Optional LAN settings can also be supplied by an existing administrator env file.
for key in EDGE_IP DNS_IP DNS_CLIENT_CIDR DNS_UPSTREAMS LB_START LB_STOP LAN_INTERFACE_REGEX IDENTITY_HOST PUBLIC_EDGE_IP; do
  if [[ -n ${!key:-} ]]; then
    patch=$(jq --arg key "$key" --arg value "${!key}" '.data[$key]=$value' <<<"$patch")
  fi
done
candidate=$(jq --argjson patch "$patch" '.data += $patch.data' <<<"$current")
python3 "$repo/scripts/validate-cluster.py" <<<"$candidate"
if [[ $(jq -S .data <<<"$candidate") == "$(jq -S .data <<<"$current")" ]]; then
  echo "Bootstrap and GitOps settings agree for $cluster_name: API_HOST=$API_HOST, POD_CIDR=$POD_CIDR"
  exit 0
fi
if $check; then
  echo "Bootstrap and GitOps settings disagree for $cluster_name; refusing to overwrite working cluster configuration." >&2
  echo "Export a current env file from clusters/$cluster_name, or run configure-cluster.sh on the intended env file and commit the change." >&2
  exit 1
fi
settings="$cluster_dir/settings.yaml"
tmp=$(mktemp "$cluster_dir/.settings.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
kubectl patch --local --type=merge --patch "$patch" -f "$settings" -o yaml >"$tmp"
chmod --reference="$settings" "$tmp"
mv -- "$tmp" "$settings"
echo "Updated clusters/$cluster_name/settings.yaml. Review, commit and push before Flux takes over."

#!/usr/bin/env bash
# Workstation CLI for the two scheduling roles of an existing k3s server.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
# shellcheck source=lib/node-maintenance.sh
source "$repo/scripts/lib/node-maintenance.sh"
usage() {
  echo 'Usage: bash scripts/set-server-role.sh --node NAME --ssh USER@HOST --role controller|hybrid [--apply] [--delete-emptydir-data] [--timeout SECONDS]'
  echo 'Run on the workstation with a cluster-admin KUBECONFIG. Default: read-only checks.'
  echo 'Keeps the existing server/etcd member. Worker/server changes use remove-node.sh followed by a fresh join.'
}
maintenance_args "$@"
[[ $desired_role =~ ^(controller|hybrid)$ && -z $resume ]] || { usage >&2; exit 2; }
load_node
[[ $current_role != worker ]] || fail 'An agent must be removed and rejoined as a server; use remove-node.sh.'
if [[ $desired_role == controller ]]; then check_capacity; fi
capture_storage
# Verify the on-host config is supported before any workload or storage movement.
echo "Plan: set $node to $desired_role, persist the role in k3s config and update live labels/taint. The server and etcd member stay running."
if [[ $desired_role == controller ]]; then echo 'Longhorn evacuation and a PDB-respecting drain happen before disabling workloads.'; fi
$apply || { echo 'Checks completed. Add --apply to change the role.'; exit 0; }
backup_id="$node_uid-$(date -u +%Y%m%dT%H%M%SZ)"
remote backup "$current_role"
trap 'rc=$?; if ((rc != 0)); then echo "Role change stopped. The node may remain cordoned or have Longhorn eviction enabled. Resolve the cause and rerun the same command; see docs/node-role-changes.md." >&2; fi' EXIT
if [[ $desired_role == controller ]]; then evacuate_node; else kube cordon "$node"; fi
assert_same_node
remote "$desired_role" "$current_role"
if [[ $desired_role == controller ]]; then
  kube taint node "$node" elektro.local/dedicated=control-plane:NoSchedule --overwrite
  kube label node "$node" elektro.local/role=controller elektro.local/workloads=false node.longhorn.io/create-default-disk=false --overwrite
  remaining_pods_gone() {
    local pods
    pods=$(kube get pods -A --field-selector "spec.nodeName=$node" -o json) || return 1
    jq -e 'all(.items[]; (.status.phase == "Succeeded" or .status.phase == "Failed") or
      (.metadata.namespace == "kube-system" and any(.metadata.ownerReferences[]?;
        .kind == "DaemonSet" and (.name == "cilium" or .name == "cilium-envoy" or .name == "kube-vip"))))' <<<"$pods" >/dev/null
  }
  wait_until 'non-network pods (including storage/GPU DaemonSets) to leave the dedicated controller' remaining_pods_gone
else
  kube label node "$node" elektro.local/role=hybrid elektro.local/workloads=true node.longhorn.io/create-default-disk=true --overwrite
  if kube get node "$node" -o json | jq -e 'any(.spec.taints[]?; .key == "elektro.local/dedicated" and .effect == "NoSchedule")' >/dev/null; then
    kube taint node "$node" elektro.local/dedicated:NoSchedule-
  fi
  if $longhorn; then
    lh_node_present() { [[ -n $(kube -n longhorn-system get nodes.longhorn.io "$node" --ignore-not-found -o name) ]]; }
    wait_until 'Longhorn to recognize the workload-capable node' lh_node_present
    kube -n longhorn-system patch nodes.longhorn.io "$node" --type=merge -p '{"spec":{"evictionRequested":false,"allowScheduling":true}}'
  fi
fi
kube uncordon "$node"
echo "$node is now $desired_role. Existing server identity and etcd membership were retained."

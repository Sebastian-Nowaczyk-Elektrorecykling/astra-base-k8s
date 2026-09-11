#!/usr/bin/env bash
# Workstation CLI: drain storage/workloads, retire k3s membership, uninstall over SSH.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
# shellcheck source=lib/node-maintenance.sh
source "$repo/scripts/lib/node-maintenance.sh"
usage() {
  echo 'Usage: bash scripts/remove-node.sh --node NAME --ssh USER@HOST [--apply] [--delete-emptydir-data] [--timeout SECONDS] [--resume STATE.json]'
  echo 'Run on the workstation with a cluster-admin KUBECONFIG. Default: read-only checks.'
  echo 'Removes a healthy node using SSH/root, native k3s etcd retirement and the upstream uninstaller.'
}
maintenance_args "$@"
[[ -z $desired_role ]] || fail 'Use install-k3s.sh to select the role when rejoining.'
phase=new state_file='' backup_id='' member_name=''
if [[ -n $resume ]]; then
  [[ -f $resume && $apply == true ]] || fail '--resume requires an existing state file and --apply.'
  state_file=$resume
  [[ $(jq -r .node "$state_file") == "$node" && $(jq -r .ssh_target "$state_file") == "$ssh_target" ]] || fail 'Resume node/SSH target differs from the saved operation.'
  node_json=$(jq -c .node_snapshot "$state_file")
  node_uid=$(jq -er .node_uid "$state_file")
  machine_id=$(jq -er .machine_id "$state_file")
  current_role=$(jq -er .current_role "$state_file")
  backup_id=$(jq -er .backup_id "$state_file")
  member_name=$(jq -r .member_name "$state_file")
  affected=$(jq -c .affected "$state_file")
  longhorn=$(jq -r .longhorn "$state_file")
  phase=$(jq -er .phase "$state_file")
  [[ $current_role =~ ^(worker|controller|hybrid)$ && $longhorn =~ ^(true|false)$ ]] || fail 'Invalid saved operation.'
  [[ $(kube get namespace kube-system -o jsonpath='{.metadata.uid}') == "$(jq -er .cluster_uid "$state_file")" ]] || fail 'Kubeconfig points at a different cluster.'
  current=$(kube get node "$node" --ignore-not-found -o json)
  [[ -z $current || $(jq -r '.metadata.uid' <<<"$current") == "$node_uid" ]] || fail 'Node was already replaced/rejoined; do not resume its old removal.'
else
  load_node
  check_capacity
  if [[ $current_role != worker ]]; then check_server_removal; fi
  capture_storage
  echo "Plan: evict Longhorn replicas, drain $node, retire server membership if present, stop k3s, delete the Node, clean Cilium and uninstall k3s over SSH."
  echo "Affected Longhorn volumes: $(jq -r 'join(", ")' <<<"$affected"). PodDisruptionBudgets remain enforced."
  echo 'The OS, drivers and /var/lib/longhorn remain. A reboot is required before rejoining.'
  $apply || { echo 'Checks completed. Add --apply to perform this removal.'; exit 0; }
  backup_id="$node_uid-$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "$repo/local/node-maintenance"
  state_file="$repo/local/node-maintenance/remove-$node-$backup_id.json"
  jq -n --arg node "$node" --arg ssh_target "$ssh_target" --arg node_uid "$node_uid" --arg machine_id "$machine_id" \
    --arg current_role "$current_role" --arg backup_id "$backup_id" --arg member_name "$member_name" --arg cluster_uid "$cluster_uid" \
    --argjson node_snapshot "$node_json" --argjson affected "$affected" --argjson longhorn "$longhorn" \
    '{node:$node, ssh_target:$ssh_target, node_uid:$node_uid, machine_id:$machine_id, current_role:$current_role,
      backup_id:$backup_id, member_name:$member_name, cluster_uid:$cluster_uid, node_snapshot:$node_snapshot,
      affected:$affected, longhorn:$longhorn, phase:"new"}' >"$state_file"
fi
trap 'rc=$?; if ((rc != 0)); then echo "Stopped at phase $phase. Inspect the cause, then resume using --resume $state_file --apply with the same --node and --ssh. No automatic rollback or uncordon." >&2; fi' EXIT
save_phase() {
  phase=$1
  jq --arg phase "$phase" '.phase=$phase' "$state_file" >"$state_file.tmp"
  mv -- "$state_file.tmp" "$state_file"
}
member_removed() {
  local current
  current=$(kube get node "$node" -o json) || return 1
  jq -e --arg uid "$node_uid" --arg member "$member_name" '.metadata.uid == $uid and .metadata.annotations["etcd.k3s.cattle.io/removed-node-name"] == $member' <<<"$current" >/dev/null
}
password_gone() {
  local secret
  secret=$(kube -n kube-system get secret "$node.node-password.k3s" --ignore-not-found -o name) || return 1
  [[ -z $secret ]]
}
case $phase in new|drained|retired|stopped|deleted|uninstalled|complete) ;; *) fail 'Unknown saved phase.' ;; esac
if [[ $phase == new ]]; then
  remote inspect "$current_role"
  check_capacity
  remote backup "$current_role"
  evacuate_node
  save_phase drained
fi
if [[ $phase == drained ]]; then
  assert_same_node
  if [[ $current_role != worker ]] && ! member_removed; then
    check_server_removal
    # Supported by the pinned k3s managed-etcd controller. Keep the member online until it acknowledges retirement.
    kube annotate node "$node" etcd.k3s.cattle.io/remove=true --overwrite
    wait_until 'k3s to acknowledge etcd member removal' member_removed
  fi
  save_phase retired
fi
if [[ $phase == retired ]]; then
  assert_same_node
  remote stop "$current_role"
  save_phase stopped
fi
if [[ $phase == stopped ]]; then
  remote stopped "$current_role"
  current=$(kube get node "$node" --ignore-not-found -o json)
  if [[ -n $current ]]; then
    assert_same_node
    kube delete node "$node" --wait=true --timeout="${timeout}s"
  fi
  wait_until 'k3s to remove the old node password Secret' password_gone
  kube get --raw=/readyz >/dev/null
  save_phase deleted
fi
if [[ $phase == deleted ]]; then
  # Recheck storage immediately before the irreversible upstream uninstaller.
  wait_until 'CSI detachment before uninstall' attachments_gone
  if $longhorn; then wait_until 'evacuated Longhorn storage before uninstall' storage_evacuated; fi
  remote uninstall "$current_role"
  save_phase uninstalled
fi
if [[ $phase == uninstalled ]]; then
  if $longhorn; then
    kube -n longhorn-system delete nodes.longhorn.io "$node" --ignore-not-found --wait=true --timeout="${timeout}s"
  fi
  save_phase complete
fi
echo "Removed $node. State: $state_file"
echo "Host backup: /var/backups/elektro-k3s/$node/$backup_id"
echo 'Reboot the host, then join it with install-k3s.sh --role worker|hybrid|controller --server ... --token-file ... . Never use --init to rejoin.'
echo 'Restore intended GPU/custom labels after joining. See docs/node-role-changes.md.'

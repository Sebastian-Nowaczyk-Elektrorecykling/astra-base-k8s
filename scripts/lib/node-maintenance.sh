#!/usr/bin/env bash
# Shared CLI helpers, never deployed as a controller or in-cluster workload.
fail() { echo "ERROR: $*" >&2; exit 1; }
kube() { kubectl --request-timeout=30s "$@"; }
ready_filter='any(.status.conditions[]?; .type == "Ready" and .status == "True")'

# The entrypoint scripts consume desired_role, apply and resume after this parser returns.
# shellcheck disable=SC2034
maintenance_args() {
  node='' ssh_target='' apply=false delete_emptydir=false timeout=1800 resume='' desired_role=''
  while (($#)); do
    case $1 in
      --node) node=${2:?}; shift 2 ;;
      --ssh) ssh_target=${2:?}; shift 2 ;;
      --role) desired_role=${2:?}; shift 2 ;;
      --apply) apply=true; shift ;;
      --delete-emptydir-data) delete_emptydir=true; shift ;;
      --timeout) timeout=${2:?}; shift 2 ;;
      --resume) resume=${2:?}; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [[ $node =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#node} -le 63 ]] || fail 'Provide a valid --node name.'
  [[ $ssh_target =~ ^([A-Za-z0-9_-]+@)?[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail 'Provide --ssh USER@HOST (use SSH config for ports/keys).'
  [[ $timeout =~ ^[1-9][0-9]*$ && ${#timeout} -le 6 ]] || fail '--timeout is a positive number of seconds.'
  for cmd in kubectl ssh jq getent; do command -v "$cmd" >/dev/null || fail "Install $cmd on the workstation first."; done
  umask 077
}

# All arguments are deliberately restricted to shell-safe tokens. SSH uses the user's normal host-key verification.
remote() {
  local operation=$1 role=${2:-none} arg
  for arg in "$operation" "$node" "$machine_id" "${backup_id:-$node_uid}" "$role" "$K3S_VERSION"; do
    [[ $arg =~ ^[A-Za-z0-9._+-]+$ ]] || fail 'Invalid remote operation argument.'
  done
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    "$ssh_target" "if [ \"\$(id -u)\" -eq 0 ]; then exec bash -s -- '$operation' '$node' '$machine_id' '${backup_id:-$node_uid}' '$role' '$K3S_VERSION'; else exec sudo -n bash -s -- '$operation' '$node' '$machine_id' '${backup_id:-$node_uid}' '$role' '$K3S_VERSION'; fi" \
    <"${repo:?Caller must set repo}/scripts/lib/node-host.sh"
}

load_node() {
  node_json=$(kube get node "$node" -o json) || fail "Cannot read node $node."
  node_uid=$(jq -er '.metadata.uid' <<<"$node_json")
  machine_id=$(jq -er '.status.nodeInfo.machineID | select(length > 0)' <<<"$node_json")
  current_role=$(jq -r '.metadata.labels["elektro.local/role"] // ""' <<<"$node_json")
  [[ $current_role =~ ^(worker|hybrid|controller)$ ]] || fail 'Node has no recognized Elektro role label.'
  jq -e "$ready_filter" <<<"$node_json" >/dev/null || fail 'This is a healthy-node maintenance tool; recover an unavailable node first.'
  [[ $(jq -r '.status.nodeInfo.kubeletVersion' <<<"$node_json") == "$K3S_VERSION" ]] || fail "Node version must match the reviewed pin $K3S_VERSION."
  cluster_uid=$(kube get namespace kube-system -o jsonpath='{.metadata.uid}')
  [[ -n $cluster_uid ]] || fail 'Cannot identify the cluster.'
  remote inspect "$current_role"
}

assert_same_node() {
  local current
  current=$(kube get node "$node" --ignore-not-found -o json)
  [[ -n $current ]] || fail 'Node disappeared during maintenance; inspect the recorded state before continuing.'
  [[ $(jq -r '.metadata.uid' <<<"$current") == "$node_uid" ]] || fail 'Node was replaced during maintenance; refusing to touch its replacement.'
  [[ $(jq -r '.status.nodeInfo.machineID' <<<"$current") == "$machine_id" ]] || fail 'Node now identifies a different physical machine.'
  node_json=$current
}

check_capacity() {
  local nodes pvs
  nodes=$(kube get nodes -o json)
  jq -e --arg node "$node" "any(.items[]; .metadata.name != \$node and .metadata.labels[\"elektro.local/workloads\"] == \"true\" and (.spec.unschedulable != true) and ($ready_filter))" <<<"$nodes" >/dev/null \
    || fail 'Another Ready, uncordoned workload-capable node is required.'
  pvs=$(kube get persistentvolumes -o json)
  # Local PV affinity can contain arbitrary expressions. Refuse these rather than guess where retained data lives.
  jq -e 'all(.items[]; (.spec.local == null and .spec.hostPath == null))' <<<"$pvs" >/dev/null \
    || fail 'Local/hostPath PVs need a separate data-migration review; this tool handles Longhorn storage only.'
}

safe_endpoint() {
  local endpoint=$1 label=$2 host addresses address
  host=${endpoint#https://}; host=${host%%/*}; host=${host%%:*}
  [[ $host =~ ^[A-Za-z0-9.-]+$ && -n $host ]] || fail "Cannot validate $label endpoint; use this cluster's IPv4/DNS API endpoint."
  addresses=$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u) || fail "Cannot resolve $label endpoint $host."
  [[ -n $addresses ]] || fail "Cannot resolve $label endpoint $host."
  while read -r address; do
    [[ $address != 127.* && $address != 0.0.0.0 ]] || fail "$label uses loopback instead of a surviving API endpoint."
    jq -e --arg ip "$address" 'all(.status.addresses[]; .address != $ip)' <<<"$node_json" >/dev/null \
      || fail "$label still points at $node ($host). Move it to a surviving server or working API VIP first."
  done <<<"$addresses"
}

check_server_removal() {
  local nodes settings ds endpoint observed_member
  nodes=$(kube get nodes -o json)
  jq -e --arg node "$node" "[.items[] | select(.metadata.labels | has(\"node-role.kubernetes.io/etcd\"))] as \$servers | (\$servers | length) >= 2 and all(\$servers[]; ($ready_filter) and (.metadata.annotations[\"etcd.k3s.cattle.io/removed-node-name\"] == null) and (.metadata.name == \$node or .spec.unschedulable != true))" <<<"$nodes" >/dev/null \
    || fail 'Cannot remove the last server or proceed during another server outage/maintenance operation.'
  observed_member=$(jq -er '.metadata.annotations["etcd.k3s.cattle.io/node-name"] | select(length > 0)' <<<"$node_json") \
    || fail 'Missing k3s embedded-etcd member annotation.'
  [[ -z ${member_name:-} || $member_name == "$observed_member" ]] || fail 'Etcd member identity changed during maintenance.'
  member_name=$observed_member
  endpoint=$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  safe_endpoint "$endpoint" 'Administrator kubeconfig'
  settings=$(kube -n flux-system get configmap cluster-settings --ignore-not-found -o json)
  if [[ -n $settings ]]; then safe_endpoint "$(jq -er '.data.API_HOST' <<<"$settings")" 'Flux API_HOST'; fi
  ds=$(kube -n kube-system get daemonset cilium --ignore-not-found -o json)
  if [[ -n $ds ]]; then
    endpoint=$(jq -er '.spec.template.spec.containers[].env[]? | select(.name == "KUBERNETES_SERVICE_HOST") | .value' <<<"$ds")
    safe_endpoint "$endpoint" 'Live Cilium API host'
    kube -n kube-system rollout status daemonset/cilium --timeout="${timeout}s"
  fi
  kube get --raw=/readyz >/dev/null
}

storage_present() {
  local crd
  crd=$(kube get crd nodes.longhorn.io --ignore-not-found -o name) || fail "Cannot determine whether Longhorn is installed."
  [[ -n $crd ]]
}

# Capture affected volumes before cordoning/eviction so a missing volume cannot silently pass the final check.
capture_storage() {
  local replicas volumes
  longhorn=false affected='[]'
  if storage_present; then
    longhorn=true
    replicas=$(kube -n longhorn-system get replicas.longhorn.io -o json)
    volumes=$(kube -n longhorn-system get volumes.longhorn.io -o json)
    affected=$(jq -n --arg node "$node" --argjson r "$replicas" --argjson v "$volumes" \
      '([$r.items[] | select(.spec.nodeID == $node) | .spec.volumeName] + [$v.items[] | select(.spec.nodeID == $node or .status.currentNodeID == $node) | .metadata.name]) | unique')
    jq -e --argjson affected "$affected" 'all(.items[] | select(.metadata.name as $n | $affected | index($n)); .status.robustness != "faulted" and .metadata.deletionTimestamp == null)' <<<"$volumes" >/dev/null \
      || fail 'An affected Longhorn volume is faulted/deleting; recover it before node maintenance.'
  else
    local pvs
    pvs=$(kube get persistentvolumes -o json)
    jq -e 'all(.items[]; .spec.csi.driver != "driver.longhorn.io")' <<<"$pvs" >/dev/null \
      || fail 'Longhorn PVs exist but its CRDs are absent; restore Longhorn before node removal.'
  fi
}

storage_evacuated() {
  local lh_node replicas volumes
  lh_node=$(kube -n longhorn-system get nodes.longhorn.io "$node" --ignore-not-found -o json) || return 1
  replicas=$(kube -n longhorn-system get replicas.longhorn.io -o json) || return 1
  volumes=$(kube -n longhorn-system get volumes.longhorn.io -o json) || return 1
  if [[ -n $lh_node ]]; then
    jq -e 'all((.status.diskStatus // {})[]; ((.scheduledReplica // {}) | length) == 0 and ((.scheduledBackingImage // {}) | length) == 0)' <<<"$lh_node" >/dev/null || return 1
  fi
  jq -e --arg node "$node" 'all(.items[]; .spec.nodeID != $node)' <<<"$replicas" >/dev/null || return 1
  # healthyAt is cleared during rebuilding; failedAt identifies a failed copy. Detached volumes may report unknown robustness.
  jq -en --arg node "$node" --argjson names "$affected" --argjson r "$replicas" --argjson v "$volumes" '
    all($names[]; . as $name |
      [$v.items[] | select(.metadata.name == $name and .metadata.deletionTimestamp == null)] as $vs |
      ($vs | length) == 1 and ($vs[0].status.robustness != "faulted" and $vs[0].status.robustness != "degraded") and
      ([$r.items[] | select(.spec.volumeName == $name and .spec.nodeID != $node and (.spec.nodeID // "") != "" and
        .metadata.deletionTimestamp == null and .spec.active == true and (.spec.healthyAt // "") != "" and (.spec.failedAt // "") == "")] | map(.spec.nodeID) | unique | length) >= $vs[0].spec.numberOfReplicas)' >/dev/null
}

attachments_gone() {
  local attachments volumes
  attachments=$(kube get volumeattachments.storage.k8s.io -o json) || return 1
  jq -e --arg node "$node" 'all(.items[]; .spec.nodeName != $node)' <<<"$attachments" >/dev/null || return 1
  if $longhorn; then
    volumes=$(kube -n longhorn-system get volumes.longhorn.io -o json) || return 1
    jq -e --arg node "$node" 'all(.items[]; .spec.nodeID != $node and .status.currentNodeID != $node and .status.pendingNodeID != $node)' <<<"$volumes" >/dev/null || return 1
  fi
}

wait_until() {
  local description=$1 start=$SECONDS
  shift
  until "$@"; do
    ((SECONDS - start < timeout)) || fail "Timed out waiting for $description. Node remains in maintenance; no forced eviction or data deletion was attempted."
    echo "Waiting for $description..."
    sleep 5
  done
}

evacuate_node() {
  local lh_node
  assert_same_node
  kube cordon "$node" || fail "Cannot cordon $node; evacuation was not started."
  if $longhorn; then
    lh_node=$(kube -n longhorn-system get nodes.longhorn.io "$node" --ignore-not-found -o name) || fail "Cannot read the Longhorn node before evacuation."
    if [[ -n $lh_node ]]; then
      kube -n longhorn-system patch nodes.longhorn.io "$node" --type=merge \
        -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' || fail 'Cannot request Longhorn eviction.'
    fi
    wait_until 'Longhorn replicas and backing images to leave the node' storage_evacuated
  fi
  local drain=(drain "$node" --ignore-daemonsets --timeout="${timeout}s")
  if $delete_emptydir; then drain+=(--delete-emptydir-data); fi
  # Explicit failure propagation also works when the function is invoked in a shell condition.
  kube "${drain[@]}" || fail "Drain of $node failed; resolve its blockers before continuing."
  wait_until 'CSI volumes to detach from the node' attachments_gone
  if $longhorn; then wait_until 'healthy Longhorn copies after draining' storage_evacuated; fi
}

#!/usr/bin/env bash
# Shared local configuration helpers. No controller or background process.
select_cluster() {
  cluster_name=${1:-${CLUSTER_NAME:-laptops}}
  [[ $cluster_name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#cluster_name} -le 63 && $cluster_name != base ]] || {
    echo 'Cluster name must be a DNS label (other than base).' >&2; return 2;
  }
  cluster_dir="${repo:?}/clusters/$cluster_name"
  [[ -f $cluster_dir/settings.yaml ]] || {
    echo "No cluster profile: clusters/$cluster_name. Run scripts/create-cluster.sh first." >&2; return 2;
  }
}

cluster_settings_json() {
  local overrides
  overrides=$(kubectl patch --local --type=merge --patch '{}' -f "${cluster_dir:?}/settings.yaml" -o json) || return
  kubectl patch --local --type=merge --patch "$overrides" -f "${repo:?}/clusters/base/defaults.yaml" -o json
}

check_cluster_target() {
  local configured existing expected
  configured=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') || return
  expected="https://${API_HOST:?}:6443"
  [[ $configured == "$expected" ]] || {
    echo "Current kubeconfig points at $configured; selected cluster expects $expected. Select its kubeconfig first." >&2
    return 1
  }
  existing=$(kubectl -n flux-system get configmap cluster-settings --ignore-not-found -o json) || return
  [[ -z $existing ]] || jq -e --arg cluster "${cluster_name:?}" \
    '(.data.CLUSTER_NAME // $cluster) == $cluster' <<<"$existing" >/dev/null || {
    echo 'The live cluster identifies itself as a different cluster. Refusing bootstrap.' >&2; return 1;
  }
}

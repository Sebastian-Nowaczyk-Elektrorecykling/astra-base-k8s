#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
role='' node_name='' node_ip=auto config='' server='' token_file='' init=false print_config=false
usage() {
  echo 'Use --print-config to review the generated configuration without changing the machine.'
  echo 'Usage: install-k3s.sh --role controller|hybrid|worker --name NAME [--ip auto|IPv4] --config FILE (--init | --server https://HOST:6443 --token-file FILE)'
}
while (($#)); do
  case $1 in
    --role) role=${2:?}; shift 2 ;;
    --name) node_name=${2:?}; shift 2 ;;
    --ip) node_ip=${2:?}; shift 2 ;;
    --config) config=${2:?}; shift 2 ;;
    --server) server=${2:?}; shift 2 ;;
    --token-file) token_file=${2:?}; shift 2 ;;
    --init) init=true; shift ;;
    --print-config) print_config=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $role =~ ^(controller|hybrid|worker)$ && $node_name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#node_name} -le 63 && -f $config ]] || { usage >&2; exit 2; }
if [[ $node_ip != auto ]]; then
  [[ $node_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo 'Use --ip auto or a valid IPv4 address.' >&2; exit 2; }
  IFS=. read -r -a octets <<<"$node_ip"
  for octet in "${octets[@]}"; do
    if [[ ! $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((10#$octet > 255)); then
      echo 'Invalid --ip octet.' >&2; exit 2
    fi
  done
  ((10#${octets[0]} > 0 && 10#${octets[0]} != 127 && 10#${octets[0]} < 224)) || {
    echo '--ip must be a reachable unicast node address.' >&2; exit 2;
  }
fi
# This is an administrator-controlled shell config; never source untrusted input.
# shellcheck source=/dev/null
source "$config"
INTERNAL_DOMAIN=${INTERNAL_DOMAIN:-internal}
[[ $INTERNAL_DOMAIN =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "Invalid INTERNAL_DOMAIN" >&2; exit 2; }
for name in API_HOST POD_CIDR SERVICE_CIDR CLUSTER_DNS; do
  [[ ${!name:-} =~ ^[A-Za-z0-9./-]+$ ]] || { echo "Missing or invalid $name" >&2; exit 2; }
done
if $init; then
  [[ $role != worker && -z $server && -z $token_file ]] || { usage >&2; exit 2; }
else
  [[ $server =~ ^https://[A-Za-z0-9.-]+:6443$ && -s $token_file ]] || { usage >&2; exit 2; }
fi
render_config() {
cat <<EOF
node-name: "$node_name"
node-label:
  - "elektro.local/role=$role"
  - "elektro.local/workloads=$([[ $role == controller ]] && echo false || echo true)"
  - "node.longhorn.io/create-default-disk=$([[ $role == controller ]] && echo false || echo true)"
EOF
if [[ $node_ip != auto ]]; then printf 'node-ip: "%s"\n' "$node_ip"; fi
if [[ $role == controller ]]; then
  cat <<'EOF'
node-taint:
  - "elektro.local/dedicated=control-plane:NoSchedule"
EOF
fi
if [[ $role != worker ]]; then
  cat <<EOF
flannel-backend: none
disable-network-policy: true
disable-kube-proxy: true
disable:
  - traefik
  - servicelb
  - local-storage
cluster-cidr: "$POD_CIDR"
service-cidr: "$SERVICE_CIDR"
cluster-dns: "$CLUSTER_DNS"
egress-selector-mode: cluster
secrets-encryption: true
write-kubeconfig-mode: "0600"
tls-san:
  - "$API_HOST"
  - "$node_name.hosts.$INTERNAL_DOMAIN"
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 12
EOF
fi
if $init; then
  echo 'cluster-init: true'
else
  cat <<EOF
server: "$server"
token-file: /etc/rancher/k3s/join-token
EOF
fi
}
if $print_config; then render_config; exit 0; fi
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
# Refuse to overwrite live configuration or turn an agent into a server in place.
if [[ -e /etc/rancher/k3s/config.yaml || -d /var/lib/rancher/k3s/server/db || -e /etc/systemd/system/k3s-agent.service ]]; then
  echo 'Existing k3s installation found. Use docs/node-role-changes.md for role changes; do not overwrite a live installation.' >&2; exit 1
fi
# A removed Cilium node must reboot to clear any residual kernel/BPF state before rejoining.
reboot_marker=/var/lib/elektro-k3s/rejoin-requires-reboot
if [[ -f $reboot_marker && $(cat "$reboot_marker") == "$(cat /proc/sys/kernel/random/boot_id)" ]]; then
  echo 'Reboot this removed node before rejoining so Cilium starts with clean kernel state.' >&2; exit 1
fi
[[ -z $(swapon --noheadings --show) ]] || { echo 'Disable swap first.' >&2; exit 1; }
install -d -m 0700 /etc/rancher/k3s
umask 077
if ! $init; then install -m 0600 "$token_file" /etc/rancher/k3s/join-token; fi
cfg=/etc/rancher/k3s/config.yaml
render_config >"$cfg"
installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
# Versioned upstream installer; it verifies the release binary against upstream checksums.
curl --fail --silent --show-error --location --retry 3 \
  "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh" -o "$installer"
if [[ $role == worker ]]; then mode=agent; else mode=server; fi
INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="$mode" sh "$installer"
echo 'Installed. Nodes are NotReady until Cilium is bootstrapped. No token has been printed.'

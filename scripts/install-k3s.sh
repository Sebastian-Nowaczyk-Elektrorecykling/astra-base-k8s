#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
role= node_name= node_ip= config= server= token_file= init=false
usage() {
  echo 'Usage: install-k3s.sh --role controller|hybrid|worker --name NAME --ip IPv4 --config FILE (--init | --server https://HOST:6443 --token-file FILE)'
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
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ $role =~ ^(controller|hybrid|worker)$ && $node_name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && $node_ip =~ ^[0-9.]+$ && -f $config ]] || { usage >&2; exit 2; }
# This is an administrator-controlled shell config; never source untrusted input.
# shellcheck source=/dev/null
source "$config"
for name in API_HOST POD_CIDR SERVICE_CIDR CLUSTER_DNS; do
  [[ ${!name:-} =~ ^[A-Za-z0-9./-]+$ ]] || { echo "Missing or invalid $name" >&2; exit 2; }
done
if $init; then
  [[ $role != worker && -z $server && -z $token_file ]] || { usage >&2; exit 2; }
else
  [[ $server =~ ^https://[A-Za-z0-9.-]+:6443$ && -s $token_file ]] || { usage >&2; exit 2; }
fi
# Refuse to overwrite live configuration or turn an agent into a server in place.
if [[ -e /etc/rancher/k3s/config.yaml || -d /var/lib/rancher/k3s/server/db || -e /etc/systemd/system/k3s-agent.service ]]; then
  echo 'Existing k3s installation found. Follow the documented upgrade or role-change procedure.' >&2; exit 1
fi
[[ -z $(swapon --noheadings --show) ]] || { echo 'Disable swap first.' >&2; exit 1; }
install -d -m 0700 /etc/rancher/k3s
umask 077
if ! $init; then install -m 0600 "$token_file" /etc/rancher/k3s/join-token; fi
cfg=/etc/rancher/k3s/config.yaml
cat >"$cfg" <<EOF
node-name: "$node_name"
node-ip: "$node_ip"
node-label:
  - "astra.local/role=$role"
  - "astra.local/workloads=$([[ $role == controller ]] && echo false || echo true)"
  - "node.longhorn.io/create-default-disk=$([[ $role == controller ]] && echo false || echo true)"
EOF
if [[ $role == controller ]]; then
  cat >>"$cfg" <<'EOF'
node-taint:
  - "astra.local/dedicated=control-plane:NoSchedule"
EOF
fi
if [[ $role != worker ]]; then
  cat >>"$cfg" <<EOF
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
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 12
EOF
fi
if $init; then
  echo 'cluster-init: true' >>"$cfg"
else
  cat >>"$cfg" <<EOF
server: "$server"
token-file: /etc/rancher/k3s/join-token
EOF
fi
installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
# Versioned upstream installer; it verifies the release binary against upstream checksums.
curl --fail --silent --show-error --location --retry 3 \
  "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh" -o "$installer"
if [[ $role == worker ]]; then mode=agent; else mode=server; fi
INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="$mode" sh "$installer"
echo 'Installed. Nodes are NotReady until Cilium is bootstrapped. No token has been printed.'

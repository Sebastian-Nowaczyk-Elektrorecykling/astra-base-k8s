#!/usr/bin/env bash
# Real workstation CLIs, isolated local profiles, no API or GitHub writes.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/elektro-clusters-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/clusters"
cp -R "$repo/scripts" "$repo/bootstrap" "$tmp/"
cp -R "$repo/clusters/base" "$repo/clusters/laptops" "$tmp/clusters/"
original=$(sha256sum "$tmp/clusters/laptops/settings.yaml")
for cluster in workshop factory; do
  bash "$tmp/scripts/create-cluster.sh" "$cluster"
  [[ ! -s $tmp/clusters/$cluster/flux-system/gotk-sync.yaml ]]
  [[ ! -e $tmp/clusters/$cluster/secrets/bootstrap.sops.yaml ]]
  kubectl kustomize "$tmp/clusters/$cluster" >"$tmp/$cluster.yaml"
  grep -Fq "path: ./clusters/$cluster/secrets" "$tmp/$cluster.yaml"
  if grep -Fq 'path: ./clusters/laptops/secrets' "$tmp/$cluster.yaml"; then exit 1; fi
  bash "$tmp/scripts/configure-cluster.sh" --export "$cluster" >"$tmp/$cluster.env"
  bash "$tmp/scripts/configure-cluster.sh" --check "$tmp/$cluster.env"
  # shellcheck source=/dev/null
  source "$tmp/$cluster.env"
  [[ $CLUSTER_NAME == "$cluster" && $INTERNAL_DOMAIN == "$cluster.internal" ]]
  [[ $SERVICE_CIDR == 10.53.0.0/16 && $CLUSTER_DNS == 10.53.0.10 ]]
  bash "$tmp/scripts/install-k3s.sh" --role hybrid --name server-a --ip auto \
    --config "$tmp/$cluster.env" --init --print-config >"$tmp/k3s.yaml"
  if grep -q '^node-ip:' "$tmp/k3s.yaml"; then echo 'DHCP auto mode pinned an address.' >&2; exit 1; fi
  grep -Fq "server-a.hosts.$cluster.internal" "$tmp/k3s.yaml"
  grep -Fq 'service-cidr: "10.53.0.0/16"' "$tmp/k3s.yaml"
  digest=$(sha256sum "$tmp/clusters/$cluster/settings.yaml")
  if bash "$tmp/scripts/create-cluster.sh" "$cluster" >"$tmp/repeat.log" 2>&1; then exit 1; fi
  [[ $(sha256sum "$tmp/clusters/$cluster/settings.yaml") == "$digest" ]]
done
[[ $(sha256sum "$tmp/clusters/laptops/settings.yaml") == "$original" ]]
# A selected profile must not bootstrap into the other cluster's current context.
mkdir "$tmp/bin"
export ELEKTRO_REAL_KUBECTL
ELEKTRO_REAL_KUBECTL=$(command -v kubectl)
cat >"$tmp/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == config && $2 == view ]]; then echo 'https://other-cluster.invalid:6443'; exit 0; fi
exec "$ELEKTRO_REAL_KUBECTL" "$@"
EOF
chmod +x "$tmp/bin/kubectl"
export PATH="$tmp/bin:$PATH"
echo 'unused fixture' >"$tmp/age.key"
for script in bootstrap-cilium bootstrap-flux; do
  args=("$tmp/factory.env")
  if [[ $script == bootstrap-flux ]]; then args=("$tmp/age.key" "${args[@]}"); fi
  if bash "$tmp/scripts/$script.sh" "${args[@]}" >"$tmp/wrong-context.log" 2>&1; then exit 1; fi
  grep -Fq 'Current kubeconfig points at' "$tmp/wrong-context.log"
done
echo 'Independent cluster creation, shared reconciliation, network export, DHCP config and wrong-context rejection passed.'

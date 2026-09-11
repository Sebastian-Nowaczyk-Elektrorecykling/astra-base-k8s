#!/usr/bin/env bash
# Create an independent Flux entry point that reuses the shared infrastructure.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
name=${1:-}
domain=${2:-$name.internal}
[[ ( $# == 1 || $# == 2 ) && $name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#name} -le 63 && $name != base ]] || {
  echo 'Usage: create-cluster.sh NAME [INTERNAL_DOMAIN]; default domain is NAME.internal' >&2; exit 2;
}
[[ ! -e $repo/clusters/$name ]] || { echo "clusters/$name already exists; it has not been changed." >&2; exit 1; }
for cmd in flux kubectl jq python3; do command -v "$cmd" >/dev/null; done
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
tmp=$(mktemp -d "$repo/clusters/.create-$name.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/flux-system" "$tmp/secrets"
cp "$repo/bootstrap/cluster-template/kustomization.yaml.tmpl" "$tmp/kustomization.yaml"
cp "$repo/bootstrap/cluster-template/dns-forwarding.yaml" "$tmp/dns-forwarding.yaml"
patch=$(jq -n --arg name "$name" --arg domain "$domain" \
  '{data:{CLUSTER_NAME:$name, INTERNAL_DOMAIN:$domain, IDENTITY_HOST:("keycloak.admin."+$domain)}}')
kubectl patch --local --type=merge --patch "$patch" \
  -f "$repo/bootstrap/cluster-template/settings.yaml" -o yaml >"$tmp/settings.yaml"
overrides=$(kubectl patch --local --type=merge --patch '{}' -f "$tmp/settings.yaml" -o json)
kubectl patch --local --type=merge --patch "$overrides" -f "$repo/clusters/base/defaults.yaml" -o json | \
  python3 "$repo/scripts/validate-cluster.py"
flux install --export --version="$FLUX_VERSION" >"$tmp/flux-system/gotk-components.yaml"
# A fresh bootstrap must not copy another cluster's generated sync or credentials.
touch "$tmp/flux-system/gotk-sync.yaml"
cat >"$tmp/flux-system/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- gotk-components.yaml
- gotk-sync.yaml
EOF
cat >"$tmp/secrets/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
EOF
kubectl kustomize "$tmp" >/dev/null
mv -- "$tmp" "$repo/clusters/$name"
echo "Created clusters/$name using the shared base; no cluster was contacted."
echo 'Edit its example LAN addresses and network ranges, then follow docs/clusters.md.'

#!/usr/bin/env bash
# Run once on the administrator workstation. Only encrypted output is committed.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# == 1 && $1 == age1* ]] || { echo 'Usage: generate-secrets.sh AGE_PUBLIC_RECIPIENT' >&2; exit 2; }
for cmd in kubectl sops openssl; do command -v "$cmd" >/dev/null; done
target="$repo/clusters/laptops/secrets/bootstrap.sops.yaml"
[[ ! -e $target ]] || { echo 'Secrets already exist; use sops to edit or rotate them.' >&2; exit 1; }
umask 077
install -d -m 0700 "$repo/local"
tmp=$(mktemp -d "$repo/local/secrets.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
openssl rand -hex 32 >"$tmp/oidc"
openssl rand -hex 32 >"$tmp/fga"
openssl rand -hex 24 >"$tmp/admin"
# Remove only the trailing newline from credentials created by openssl.
for f in oidc fga admin; do tr -d '\n' <"$tmp/$f" >"$tmp/$f.raw"; done
{
  kubectl create secret generic edge-oidc -n edge --from-file="client-secret=$tmp/oidc.raw" --dry-run=client -o yaml
  printf '\n---\n'
  kubectl create secret generic edge-oidc-import -n identity --from-file="client-secret=$tmp/oidc.raw" --dry-run=client -o yaml
  printf '\n---\n'
  kubectl create secret generic keycloak-bootstrap -n identity --from-file="password=$tmp/admin.raw" --dry-run=client -o yaml
  printf '\n---\n'
  kubectl create secret generic openfga-key -n authorization --from-file="keys=$tmp/fga.raw" --dry-run=client -o yaml
} >"$tmp/bundle.yaml"
# Authorino only watches Secrets carrying this label.
sed -i '/^  name: openfga-key$/a\  labels:\n    authorino.kuadrant.io/managed-by: authorino' "$tmp/bundle.yaml"
sops --encrypt --age "$1" --encrypted-regex '^(data|stringData)$' "$tmp/bundle.yaml" >"$target"
cat >"$repo/clusters/laptops/secrets/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - bootstrap.sops.yaml
EOF
echo 'Encrypted bootstrap secrets created. Commit clusters/laptops/secrets before bootstrapping Flux.'

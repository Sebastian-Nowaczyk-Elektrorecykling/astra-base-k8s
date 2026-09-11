#!/usr/bin/env bash
# Run once on the administrator workstation. Only encrypted output is committed.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ ( $# == 1 || $# == 2 ) && $1 == age1* ]] || { echo 'Usage: generate-secrets.sh AGE_PUBLIC_RECIPIENT [CLUSTER_NAME]' >&2; exit 2; }
for cmd in kubectl sops openssl jq; do command -v "$cmd" >/dev/null; done
# shellcheck source=lib/cluster-settings.sh
source "$repo/scripts/lib/cluster-settings.sh"
select_cluster "${2:-}"
target="$cluster_dir/secrets/bootstrap.sops.yaml"
[[ ! -e $target ]] || { echo 'Secrets already exist; use sops to edit or rotate them.' >&2; exit 1; }
umask 077
install -d -m 0700 "$repo/local"
tmp=$(mktemp -d "$repo/local/secrets.XXXXXX")
encrypted=$(mktemp "$cluster_dir/secrets/.encrypted.XXXXXX")
kustomization=$(mktemp "$cluster_dir/secrets/.kustomization.XXXXXX")
trap 'rm -rf -- "$tmp"; rm -f -- "$encrypted" "$kustomization"' EXIT
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
sops --encrypt --age "$1" --encrypted-regex '^(data|stringData)$' "$tmp/bundle.yaml" >"$encrypted"
[[ -s $encrypted ]] || { echo 'Encryption produced no output; no secrets were installed.' >&2; exit 1; }
# Retain other encrypted resources and Kustomize options in this profile.
patch=$(kubectl patch --local --type=merge --patch '{}' -f "$cluster_dir/secrets/kustomization.yaml" -o json \
  | jq '{resources: ((.resources // []) + ["bootstrap.sops.yaml"] | unique)}')
kubectl patch --local --type=merge --patch "$patch" -f "$cluster_dir/secrets/kustomization.yaml" -o yaml >"$kustomization"
# Publish only complete ciphertext, atomically and without overwriting a concurrent run.
ln -- "$encrypted" "$target"
mv -- "$kustomization" "$cluster_dir/secrets/kustomization.yaml"
echo "Encrypted bootstrap secrets created. Commit clusters/$cluster_name/secrets before bootstrapping Flux."

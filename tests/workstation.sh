#!/usr/bin/env bash
# Runs with the actual installed CLIs in fresh Debian CI containers; no cluster access.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
[[ $(kubectl version --client=true -o json | jq -r '.clientVersion.gitVersion') == "$KUBECTL_VERSION" ]]
[[ $(helm version --template '{{.Version}}') == "$HELM_VERSION" ]]
[[ $(flux version --client) == *"$FLUX_VERSION"* ]]
[[ $(sops --version --disable-version-check) == *"${SOPS_VERSION#v}"* ]]
for cmd in git ssh curl jq openssl age age-keygen dig; do command -v "$cmd" >/dev/null; done

umask 077
tmp=$(mktemp -d /tmp/elektro-workstation-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
age-keygen -o "$tmp/age.agekey" 2>/dev/null
recipient=$(age-keygen -y "$tmp/age.agekey")
printf 'message: elektro-workstation-smoke\n' >"$tmp/plain.yaml"
sops --encrypt --age "$recipient" --encrypted-regex '^message$' "$tmp/plain.yaml" >"$tmp/encrypted.yaml"
SOPS_AGE_KEY_FILE="$tmp/age.agekey" sops --decrypt "$tmp/encrypted.yaml" >"$tmp/decrypted.yaml"
cmp "$tmp/plain.yaml" "$tmp/decrypted.yaml"

# Reproduce the bootstrap sequence: components first, then the generated sync objects.
# Always use an empty sync placeholder first, even after a real bootstrap commits it.
mkdir "$tmp/flux-system"
cp "$repo/clusters/laptops/flux-system/kustomization.yaml" "$tmp/flux-system/"
touch "$tmp/flux-system/gotk-sync.yaml"
flux install --export --version="$FLUX_VERSION" >"$tmp/flux-system/gotk-components.yaml"
kubectl kustomize "$tmp/flux-system" >"$tmp/components.yaml"
awk '/^kind: Deployment$/ {count++} END {exit count < 4}' "$tmp/components.yaml"
{
  flux create source git flux-system --url=ssh://git@github.com/Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s \
    --branch=main --secret-ref=flux-system --export
  printf '\n---\n'
  flux create kustomization flux-system --source=GitRepository/flux-system \
    --path=./clusters/laptops --prune=true --interval=10m --export
} >"$tmp/flux-system/gotk-sync.yaml"
kubectl kustomize "$tmp/flux-system" >"$tmp/complete.yaml"
grep -Fxq 'kind: GitRepository' "$tmp/complete.yaml"
grep -Fxq 'kind: Kustomization' "$tmp/complete.yaml"
# The real cluster root must build too; encrypted data is not decrypted or printed.
kubectl kustomize "$repo/clusters/laptops" >/dev/null
echo 'Pinned CLIs, age/SOPS round trip, initial Flux component build and completed sync build passed.'

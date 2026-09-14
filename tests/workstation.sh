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
for cmd in git ssh curl jq openssl age age-keygen dig python3; do command -v "$cmd" >/dev/null; done

umask 077
tmp=$(mktemp -d /tmp/elektro-workstation-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
age-keygen -o "$tmp/age.agekey" 2>/dev/null
recipient=$(age-keygen -y "$tmp/age.agekey")
printf 'message: elektro-workstation-smoke\n' >"$tmp/plain.yaml"
sops --encrypt --age "$recipient" --encrypted-regex '^message$' "$tmp/plain.yaml" >"$tmp/encrypted.yaml"
SOPS_AGE_KEY_FILE="$tmp/age.agekey" sops --decrypt "$tmp/encrypted.yaml" >"$tmp/decrypted.yaml"
cmp "$tmp/plain.yaml" "$tmp/decrypted.yaml"

# Generate a disposable profile; checked-in profiles may not be bootstrapped yet.
mkdir -p "$tmp/scaffold/clusters" "$tmp/profiles/clusters"
cp -R "$repo/scripts" "$repo/bootstrap" "$tmp/scaffold/"
cp -R "$repo/clusters/base" "$tmp/scaffold/clusters/"
cp -R "$repo/clusters/base" "$tmp/profiles/clusters/"
bash "$tmp/scaffold/scripts/create-cluster.sh" workstation-validation
flux_dir="$tmp/scaffold/clusters/workstation-validation/flux-system"
# Reproduce the bootstrap sequence: components first, then generated sync objects.
kubectl kustomize "$flux_dir" >"$tmp/components.yaml"
awk '/^kind: Deployment$/ {count++} END {exit count < 4}' "$tmp/components.yaml"
{
  flux create source git flux-system --url=ssh://git@github.com/Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s \
    --branch=main --secret-ref=flux-system --export
  printf '\n---\n'
  flux create kustomization flux-system --source=GitRepository/flux-system \
    --path=./clusters/workstation-validation --prune=true --interval=10m --export
} >"$flux_dir/gotk-sync.yaml"
kubectl kustomize "$flux_dir" >"$tmp/complete.yaml"
grep -Fxq 'kind: GitRepository' "$tmp/complete.yaml"
grep -Fxq 'kind: Kustomization' "$tmp/complete.yaml"
# Build every real profile in an isolated copy, filling only fresh Flux directories.
# Existing customizations must build unchanged; encrypted data is never decrypted.
for settings in "$repo"/clusters/*/settings.yaml; do
  profile=$(dirname "$settings")
  name=$(basename "$profile")
  cp -R "$profile" "$tmp/profiles/clusters/"
  target="$tmp/profiles/clusters/$name/flux-system"
  if [[ ! -e $target ]] || [[ -d $target && -z $(find "$target" -mindepth 1 -print -quit) ]]; then
    mkdir -p "$target"
    cp "$flux_dir/gotk-components.yaml" "$flux_dir/kustomization.yaml" "$target/"
    touch "$target/gotk-sync.yaml"
  fi
  kubectl kustomize "$tmp/profiles/clusters/$name" >/dev/null
done
echo 'Pinned CLIs, age/SOPS round trip, initial Flux component build and completed sync build passed.'

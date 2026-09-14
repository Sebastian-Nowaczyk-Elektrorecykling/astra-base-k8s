#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
[[ ( $# == 1 || $# == 2 ) && -s $1 ]] || {
  echo 'Usage: bootstrap-flux.sh local/age.agekey [local/cluster.env]' >&2; exit 2;
}
for cmd in git kubectl flux jq; do command -v "$cmd" >/dev/null; done
config=${2:-$repo/local/cluster.env}
# shellcheck source=/dev/null
source "$config"
# shellcheck source=lib/cluster-settings.sh
source "$repo/scripts/lib/cluster-settings.sh"
select_cluster "${CLUSTER_NAME:?Export a named profile with configure-cluster.sh --export first.}"
cluster_path="clusters/$cluster_name"
# Fail before bootstrap can replace a working CNI with a stale example address.
bash "$repo/scripts/configure-cluster.sh" --check "$config"
check_cluster_target
: "${GITHUB_TOKEN:?Provide a GitHub token with access to this repository for the bootstrap only.}"
[[ -s $cluster_dir/secrets/bootstrap.sops.yaml ]] || { echo 'Generate and commit encrypted secrets first.' >&2; exit 1; }
if [[ -n $(git -C "$repo" status --porcelain --untracked-files=all -- "$cluster_path" clusters/base infrastructure bootstrap/versions.env) ]]; then
  echo 'Commit and push your cluster settings and secrets before bootstrap.' >&2; exit 1
fi
# A local commit is insufficient: Flux clones main from GitHub, not this checkout.
git -C "$repo" fetch origin main
if ! git -C "$repo" diff --quiet HEAD origin/main -- "$cluster_path" clusters/base infrastructure bootstrap/versions.env; then
  echo 'Local cluster configuration differs from origin/main. Push your commits or pull the remote changes before bootstrap.' >&2
  exit 1
fi
# On a fresh profile Flux generates components, installs them directly, then
# generates the sync objects and Kustomization in its own Git checkout.
flux_dir="$cluster_dir/flux-system"
if [[ ! -e $flux_dir ]] || [[ -d $flux_dir && -z $(find "$flux_dir" -mindepth 1 -print -quit) ]]; then
  echo "No Flux manifests yet; Flux will generate and commit $cluster_path/flux-system during bootstrap."
else
  # Existing customizations are applied before gotk-sync.yaml is regenerated.
  # Reject incomplete/empty customizations rather than hiding them with defaults.
  if ! kubectl patch --local --type=merge --patch '{}' -f "$flux_dir/kustomization.yaml" -o json | \
    jq -e '(.resources // []) | contains(["gotk-components.yaml", "gotk-sync.yaml"])' >/dev/null; then
    echo 'Existing Flux Kustomization must reference gotk-components.yaml and gotk-sync.yaml.' >&2
    exit 1
  fi
  if ! kubectl kustomize "$flux_dir" | \
    awk '/^kind: Deployment$/ {found=1} END {exit !found}'; then
    echo 'Existing Flux Kustomization must build controller Deployments. Restore its missing files or fix its customization.' >&2
    exit 1
  fi
fi
origin=$(git -C "$repo" remote get-url origin)
[[ $origin =~ ^(https://github.com/|git@github.com:)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] || {
  echo 'origin must be an HTTPS or SSH GitHub repository URL.' >&2; exit 2;
}
github_owner=${BASH_REMATCH[2]}
github_repository=${BASH_REMATCH[3]%.git}
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic sops-age -n flux-system --from-file="age.agekey=$1" --dry-run=client -o yaml | kubectl apply -f -
flux check --pre
flux bootstrap github --owner="$github_owner" \
  --repository="$github_repository" --branch=main --path="$cluster_path" \
  --version="$FLUX_VERSION" --personal --read-write-key=false
echo 'Flux bootstrapped with a read-only deploy key. Remove GITHUB_TOKEN from your shell.'

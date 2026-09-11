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
select_cluster "${CLUSTER_NAME:-laptops}"
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
# Flux applies an existing Kustomization before generating gotk-sync.yaml.
# Validate the checked-in component references locally before changing the cluster.
if ! kubectl kustomize "$cluster_dir/flux-system" | \
  awk '/^kind: Deployment$/ {found=1} END {exit !found}'; then
  echo 'Flux component Kustomization must build controller Deployments.' >&2
  echo 'Pull the bootstrap fix: gotk-components.yaml and gotk-sync.yaml must both be referenced.' >&2
  exit 1
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

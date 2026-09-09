#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
[[ $# == 1 && -s $1 ]] || { echo 'Usage: bootstrap-flux.sh local/age.agekey' >&2; exit 2; }
: "${GITHUB_TOKEN:?Provide a GitHub token with access to this repository for the bootstrap only.}"
[[ -s $repo/clusters/laptops/secrets/bootstrap.sops.yaml ]] || { echo 'Generate and commit encrypted secrets first.' >&2; exit 1; }
if ! git -C "$repo" diff --quiet HEAD -- clusters/laptops; then
  echo 'Commit and push your cluster settings and secrets before bootstrap.' >&2; exit 1
fi
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic sops-age -n flux-system --from-file="age.agekey=$1" --dry-run=client -o yaml | kubectl apply -f -
flux check --pre
flux bootstrap github --owner=Sebastian-Nowaczyk-Elektrorecykling \
  --repository=astra-base-k8s --branch=main --path=clusters/laptops \
  --version="$FLUX_VERSION" --personal --read-write-key=false
echo 'Flux bootstrapped with a read-only deploy key. Remove GITHUB_TOKEN from your shell.'

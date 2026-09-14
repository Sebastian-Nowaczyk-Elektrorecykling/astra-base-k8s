#!/usr/bin/env bash
# Exercise the wrapper with real local Git/Kustomize; intercept cluster/GitHub writes.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
umask 077
tmp=$(mktemp -d /tmp/elektro-flux-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/repo/clusters" "$tmp/bin"
cp -R "$repo/scripts" "$repo/bootstrap" "$tmp/repo/"
cp -R "$repo/clusters/base" "$tmp/repo/clusters/"
for name in laptops factory; do
  bash "$tmp/repo/scripts/create-cluster.sh" "$name"
  bash "$tmp/repo/scripts/configure-cluster.sh" --export "$name" >"$tmp/$name.env"
  # Only the wrapper's file-presence gate is exercised; nothing is deployed.
  printf 'unused encrypted-bundle fixture\n' >"$tmp/repo/clusters/$name/secrets/bootstrap.sops.yaml"
done
cp -R "$tmp/repo/clusters/laptops/flux-system" "$tmp/flux-fixture"
printf 'unused age-key fixture\n' >"$tmp/age.key"
git init --quiet --initial-branch=main "$tmp/repo"
git init --quiet --bare --initial-branch=main "$tmp/origin.git"
git -C "$tmp/repo" config user.name 'Bootstrap test'
git -C "$tmp/repo" config user.email 'bootstrap-test@example.invalid'
git -C "$tmp/repo" remote add origin https://github.com/test-owner/test-base.git

export ELEKTRO_TEST_REAL_GIT ELEKTRO_TEST_REAL_KUBECTL ELEKTRO_TEST_CALLS ELEKTRO_TEST_ORIGIN ELEKTRO_TEST_API
ELEKTRO_TEST_REAL_GIT=$(command -v git)
ELEKTRO_TEST_REAL_KUBECTL=$(command -v kubectl)
ELEKTRO_TEST_CALLS="$tmp/calls"
ELEKTRO_TEST_ORIGIN="$tmp/origin.git"
ELEKTRO_TEST_API=$(sed -n "s/^API_HOST='\([^']*\)'$/\1/p" "$tmp/laptops.env")
[[ -n $ELEKTRO_TEST_API ]]
cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -C && ${3:-} == fetch ]]; then
  [[ $# == 5 && $4 == origin && $5 == main ]]
  exec "$ELEKTRO_TEST_REAL_GIT" -C "$2" fetch "$ELEKTRO_TEST_ORIGIN" main:refs/remotes/origin/main
fi
exec "$ELEKTRO_TEST_REAL_GIT" "$@"
EOF
cat >"$tmp/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'config view --minify -o jsonpath={.clusters[0].cluster.server}')
    printf 'https://%s:6443\n' "$ELEKTRO_TEST_API"; exit 0 ;;
  '-n flux-system get configmap cluster-settings --ignore-not-found -o json') exit 0 ;;
  'apply -f -') cat >/dev/null; echo apply >>"$ELEKTRO_TEST_CALLS"; exit 0 ;;
esac
case "$1" in
  patch) [[ " $* " == *' --local '* ]] ;;
  create) [[ " $* " == *' --dry-run=client '* ]] ;;
  kustomize) ;;
  *) echo "Unexpected kubectl call: $*" >&2; exit 1 ;;
esac
exec "$ELEKTRO_TEST_REAL_KUBECTL" "$@"
EOF
cat >"$tmp/bin/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'check --pre') echo check >>"$ELEKTRO_TEST_CALLS" ;;
  'bootstrap github') printf '%s\n' "$@" >>"$ELEKTRO_TEST_CALLS" ;;
  *) echo "Unexpected Flux call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export GITHUB_TOKEN=unused-test-fixture

commit_fixture() {
  git -C "$tmp/repo" add --all
  git -C "$tmp/repo" commit --quiet --allow-empty -m 'Update fixture'
  git -C "$tmp/repo" push --quiet "$ELEKTRO_TEST_ORIGIN" main
}

for state in no-directory empty-directory customized missing-sync empty-kustomization malformed; do
  name=factory
  if [[ $state == no-directory ]]; then name=laptops; fi
  flux_dir="$tmp/repo/clusters/$name/flux-system"
  rm -rf -- "$flux_dir"
  case "$state" in
    no-directory) ;;
    empty-directory) mkdir "$flux_dir" ;;
    *)
      cp -R "$tmp/flux-fixture" "$flux_dir"
      case "$state" in
        customized) printf 'commonAnnotations:\n  test.elektro.io/fixture: preserved\n' >>"$flux_dir/kustomization.yaml" ;;
        missing-sync) rm "$flux_dir/gotk-sync.yaml" ;;
        empty-kustomization) printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' >"$flux_dir/kustomization.yaml" ;;
        malformed) printf 'resources: [\n' >"$flux_dir/kustomization.yaml" ;;
      esac
      ;;
  esac
  commit_fixture
  : >"$ELEKTRO_TEST_CALLS"
  if bash "$tmp/repo/scripts/bootstrap-flux.sh" "$tmp/age.key" "$tmp/$name.env" >"$tmp/bootstrap.log" 2>&1; then
    [[ $state == no-directory || $state == empty-directory || $state == customized ]]
    grep -Fxq -- "--path=clusters/$name" "$ELEKTRO_TEST_CALLS"
    grep -Fxq -- '--owner=test-owner' "$ELEKTRO_TEST_CALLS"
    grep -Fxq -- '--repository=test-base' "$ELEKTRO_TEST_CALLS"
    grep -Fxq -- '--read-write-key=false' "$ELEKTRO_TEST_CALLS"
    [[ $(grep -c '^apply$' "$ELEKTRO_TEST_CALLS") == 2 ]]
  else
    [[ $state == missing-sync || $state == empty-kustomization || $state == malformed ]] || {
      cat "$tmp/bootstrap.log" >&2; exit 1;
    }
    grep -Fq 'Existing Flux Kustomization must' "$tmp/bootstrap.log"
    [[ ! -s $ELEKTRO_TEST_CALLS ]]
  fi
  [[ -z $(git -C "$tmp/repo" status --porcelain --untracked-files=all) ]]
  if [[ $state == no-directory ]]; then [[ ! -e $flux_dir ]]; fi
  if [[ $state == empty-directory ]]; then [[ -z $(find "$flux_dir" -mindepth 1 -print) ]]; fi
  echo "Flux bootstrap wrapper passed: $state ($name)"
done

# Fresh profiles must still reject uncommitted and unpushed configuration.
printf '\n# uncommitted fixture\n' >>"$tmp/repo/clusters/laptops/settings.yaml"
for state in uncommitted unpushed; do
  if [[ $state == unpushed ]]; then
    git -C "$tmp/repo" add --all
    git -C "$tmp/repo" commit --quiet -m 'Local-only configuration'
  fi
  : >"$ELEKTRO_TEST_CALLS"
  if bash "$tmp/repo/scripts/bootstrap-flux.sh" "$tmp/age.key" "$tmp/laptops.env" >"$tmp/guard.log" 2>&1; then
    echo "Accepted $state configuration" >&2; exit 1
  fi
  [[ ! -s $ELEKTRO_TEST_CALLS ]]
  if [[ $state == uncommitted ]]; then
    grep -Fq 'Commit and push your cluster settings' "$tmp/guard.log"
  else
    grep -Fq 'Local cluster configuration differs from origin/main' "$tmp/guard.log"
  fi
done
echo 'Fresh bootstrap handoff, customization preservation and preflight guards passed without cluster/GitHub writes.'

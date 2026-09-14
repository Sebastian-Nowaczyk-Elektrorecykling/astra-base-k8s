#!/usr/bin/env bash
# Real SOPS/age/kubectl generation, isolated files, no cluster or GitHub writes.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
umask 077
tmp=$(mktemp -d /tmp/elektro-secret-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/clusters" "$tmp/bin"
cp -R "$repo/scripts" "$tmp/"
age-keygen -o "$tmp/age.agekey" 2>/dev/null
recipient=$(age-keygen -y "$tmp/age.agekey")
cat >"$tmp/bin/sops" <<'EOF'
#!/usr/bin/env bash
echo 'Simulated encryption failure' >&2
exit 42
EOF
chmod +x "$tmp/bin/sops"

# Fixtures do not depend on the real profile having initialized secrets.
for name in no-directory empty-directory empty-resources existing-resources; do
  profile="$tmp/clusters/$name"
  mkdir -p "$profile"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cluster-settings\ndata:\n  CLUSTER_NAME: %s\n' "$name" \
    >"$profile/settings.yaml"
  case "$name" in
    no-directory) ;;
    empty-directory) mkdir "$profile/secrets" ;;
    empty-resources | existing-resources)
      mkdir "$profile/secrets"
      printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' \
        >"$profile/secrets/kustomization.yaml"
      if [[ $name == existing-resources ]]; then
        # Include a pre-existing bootstrap reference to check it is not duplicated.
        printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamePrefix: kept-\nresources: [other.yaml, bootstrap.sops.yaml]\n' \
          >"$profile/secrets/kustomization.yaml"
        printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: unrelated-resource\n' \
          >"$profile/secrets/other.yaml"
      fi
      ;;
  esac
  target="$profile/secrets/bootstrap.sops.yaml"
  config="$profile/secrets/kustomization.yaml"
  original=''
  if [[ -e $config ]]; then original=$(sha256sum "$config"); fi
  if PATH="$tmp/bin:$PATH" bash "$tmp/scripts/generate-secrets.sh" "$recipient" "$name" >"$tmp/failed.log" 2>&1; then
    echo "Failed encryption unexpectedly succeeded: $name" >&2; exit 1
  fi
  grep -Fq 'Simulated encryption failure' "$tmp/failed.log"
  [[ ! -e $target ]]
  if [[ -n $original ]]; then
    [[ $(sha256sum "$config") == "$original" ]]
  else
    [[ ! -e $config ]]
  fi
  [[ -z $(find "$tmp/local" -mindepth 1 -print) ]]
  [[ -z $(find "$profile/secrets" -name '.*' -print) ]]

  # Retry with actual tools: no stale destination or partial configuration may block it.
  bash "$tmp/scripts/generate-secrets.sh" "$recipient" "$name"
  [[ $(stat -c '%a' "$target") == 600 ]]
  SOPS_AGE_KEY_FILE="$tmp/age.agekey" sops --decrypt "$target" >"$tmp/plain.yaml"
  kubectl patch --local --type=merge --patch '{}' -f "$tmp/plain.yaml" -o json | jq -s '.' >"$tmp/secrets.json"
  jq -e '
    length == 4 and
    (map(select(.metadata.name == "edge-oidc"))[0].data["client-secret"] ==
     map(select(.metadata.name == "edge-oidc-import"))[0].data["client-secret"]) and
    (map(select(.metadata.name == "openfga-key"))[0].metadata.labels["authorino.kuadrant.io/managed-by"] == "authorino") and
    (map(.data[]) | unique | length == 3) and
    (all(.[]; all(.data[]; (@base64d | test("^[a-f0-9]{48,64}$")))))
  ' "$tmp/secrets.json" >/dev/null
  kubectl patch --local --type=merge --patch '{}' -f "$config" -o json >"$tmp/config.json"
  jq -e '[.resources[] | select(. == "bootstrap.sops.yaml")] | length == 1' "$tmp/config.json" >/dev/null
  kubectl kustomize "$profile/secrets" >"$tmp/built.yaml"
  if [[ $name == existing-resources ]]; then
    jq -e '.namePrefix == "kept-" and (.resources | index("other.yaml") != null)' "$tmp/config.json" >/dev/null
    grep -Fq 'name: kept-unrelated-resource' "$tmp/built.yaml"
  fi
  [[ -z $(find "$tmp/local" -mindepth 1 -print) ]]
  [[ -z $(find "$profile/secrets" -name '.*' -print) ]]
  before=$(sha256sum "$target" "$config")
  if bash "$tmp/scripts/generate-secrets.sh" "$recipient" "$name" >"$tmp/repeat.log" 2>&1; then
    echo "Existing credentials were not rejected: $name" >&2; exit 1
  fi
  grep -Fq 'Secrets already exist' "$tmp/repeat.log"
  [[ $(sha256sum "$target" "$config") == "$before" ]]
  echo "Secret generation passed: $name"
done

# An invalid existing resource list must not be silently replaced with a fresh one.
profile="$tmp/clusters/malformed"
mkdir -p "$profile/secrets"
cp "$tmp/clusters/no-directory/settings.yaml" "$profile/settings.yaml"
printf 'resources: [\n' >"$profile/secrets/kustomization.yaml"
original=$(sha256sum "$profile/secrets/kustomization.yaml")
if bash "$tmp/scripts/generate-secrets.sh" "$recipient" malformed >"$tmp/malformed.log" 2>&1; then
  echo 'Malformed Kustomization unexpectedly succeeded.' >&2; exit 1
fi
[[ ! -e $profile/secrets/bootstrap.sops.yaml ]]
[[ $(sha256sum "$profile/secrets/kustomization.yaml") == "$original" ]]
[[ -z $(find "$tmp/local" -mindepth 1 -print) ]]
[[ -z $(find "$profile/secrets" -name '.*' -print) ]]
echo 'Secret generation: fresh profiles initialize, failures clean up, retries succeed and existing configuration/credentials are preserved.'

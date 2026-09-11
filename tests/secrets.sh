#!/usr/bin/env bash
# Real SOPS/age/kubectl generation, isolated files, no cluster or GitHub writes.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
umask 077
tmp=$(mktemp -d /tmp/elektro-secret-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/clusters" "$tmp/bin"
cp -R "$repo/scripts" "$tmp/"
cp -R "$repo/clusters/laptops" "$tmp/clusters/"
target="$tmp/clusters/laptops/secrets/bootstrap.sops.yaml"
# Test fixtures must not reuse a future profile's real encrypted credentials.
rm -f -- "$target"
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [other.yaml]\n' \
  >"$tmp/clusters/laptops/secrets/kustomization.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: unrelated-resource\n' \
  >"$tmp/clusters/laptops/secrets/other.yaml"
original=$(sha256sum "$tmp/clusters/laptops/secrets/kustomization.yaml")
age-keygen -o "$tmp/age.agekey" 2>/dev/null
recipient=$(age-keygen -y "$tmp/age.agekey")
cat >"$tmp/bin/sops" <<'EOF'
#!/usr/bin/env bash
echo 'Simulated encryption failure' >&2
exit 42
EOF
chmod +x "$tmp/bin/sops"
if PATH="$tmp/bin:$PATH" bash "$tmp/scripts/generate-secrets.sh" "$recipient" laptops >"$tmp/failed.log" 2>&1; then
  echo 'Failed encryption unexpectedly succeeded.' >&2; exit 1
fi
[[ ! -e $target && $(sha256sum "$tmp/clusters/laptops/secrets/kustomization.yaml") == "$original" ]]
[[ -z $(find "$tmp/local" -type f -print) ]]
[[ -z $(find "$tmp/clusters/laptops/secrets" -name '.encrypted.*' -print) ]]
# Retry with actual tools: no stale empty destination may block it.
bash "$tmp/scripts/generate-secrets.sh" "$recipient" laptops
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
kubectl kustomize "$tmp/clusters/laptops/secrets" >"$tmp/built.yaml"
grep -Fq 'name: unrelated-resource' "$tmp/built.yaml"
[[ -z $(find "$tmp/local" -type f -print) ]]
before=$(sha256sum "$target")
if bash "$tmp/scripts/generate-secrets.sh" "$recipient" laptops >"$tmp/repeat.log" 2>&1; then exit 1; fi
[[ $(sha256sum "$target") == "$before" ]]
echo 'Secret generation: failed encryption leaves no target/plaintext, retry succeeds and existing credentials are preserved.'

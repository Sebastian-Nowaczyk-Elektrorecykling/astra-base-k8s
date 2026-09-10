#!/usr/bin/env bash
# One-shot calls to the upstream API; no running custom component.
# Terminal 1: kubectl -n authorization port-forward svc/openfga 8080:8080
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# == 1 && -s $1 ]] || { echo 'Usage: bootstrap-openfga.sh local/openfga.key (port-forward localhost:8080 first)' >&2; exit 2; }
state="$repo/local/openfga-state.json"
[[ ! -e $state ]] || { echo 'Store already recorded in local/openfga-state.json; do not create another on reruns.' >&2; exit 1; }
umask 077
install -d -m 0700 "$repo/local"
tmp=$(mktemp -d "$repo/local/fga.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf 'Authorization: Bearer %s\n' "$(cat "$1")" >"$tmp/header"
curl --fail-with-body --silent --show-error --header @"$tmp/header" \
  --header 'Content-Type: application/json' --data '{"name":"elektro-platform"}' \
  http://127.0.0.1:8080/stores >"$tmp/store.json"
store_id=$(jq -er .id "$tmp/store.json")
# Persist immediately: if the next step fails, recover this store instead of losing its ID.
jq -n --arg store "$store_id" '{store_id:$store,authorization_model_id:null}' >"$state"
curl --fail-with-body --silent --show-error --header @"$tmp/header" \
  --header 'Content-Type: application/json' --data-binary @"$repo/infrastructure/access/model.json" \
  "http://127.0.0.1:8080/stores/$store_id/authorization-models" >"$tmp/model.json"
model_id=$(jq -er .authorization_model_id "$tmp/model.json")
jq -n --arg store "$store_id" --arg model "$model_id" '{store_id:$store,authorization_model_id:$model}' >"$state"
printf 'Set FGA_STORE_ID=%s and FGA_MODEL_ID=%s in clusters/laptops/settings.yaml; commit and push.\n' "$store_id" "$model_id"
echo 'No access has been granted. Add the first explicit principal tuple as described in docs/identity-access.md.'

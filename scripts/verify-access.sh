#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && $1 =~ ^[A-Za-z0-9.-]+$ && -s $2 ]] || { echo 'Usage: verify-access.sh longhorn.admin.internal local/platform-ca.crt' >&2; exit 2; }
host=$1 ca=$2
for spoof in '' 'Authorization: Bearer invalid' 'X-Auth-Request-User: administrator' 'X-Forwarded-User: administrator'; do
  args=()
  [[ -z $spoof ]] || args+=(--header "$spoof")
  code=$(curl --silent --show-error --max-time 15 --cacert "$ca" --output /dev/null \
    --write-out '%{http_code}' "${args[@]}" "https://$host/")
  case $code in
    302|303|401|403) printf 'Denied or login required: HTTP %s\n' "$code" ;;
    *) echo "Unexpected HTTP $code; inspect before relying on this endpoint." >&2; exit 1 ;;
  esac
done
echo 'Anonymous and spoofed requests did not reach the dashboard. Complete the authenticated and outage checks in docs/validation.md.'

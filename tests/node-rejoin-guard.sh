#!/usr/bin/env bash
# Only in the fresh Debian CI container. Never installs k3s or contacts a cluster.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && $EUID == 0 && ! -e /etc/rancher/k3s/config.yaml ]] || { echo 'Requires fresh root Debian CI container.' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
marker=/var/lib/elektro-k3s/rejoin-requires-reboot
[[ ! -e $marker ]] || { echo 'Refusing to replace an existing maintenance marker.' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -f -- "$marker"; rm -rf -- "$tmp"' EXIT
mkdir -p /var/lib/elektro-k3s
cat /proc/sys/kernel/random/boot_id >"$marker"
# The next gate after reboot is swap validation. Stub it to stop before any host configuration or downloads.
cat >"$tmp/swapon" <<'SH'
#!/bin/sh
echo 'synthetic active swap for an installer preflight test'
SH
chmod +x "$tmp/swapon"
export PATH="$tmp:$PATH"
args=(--role hybrid --name rejoin-test --ip 192.0.2.12 --config "$repo/bootstrap/cluster.env.example" --init)
if bash "$repo/scripts/install-k3s.sh" "${args[@]}" >"$tmp/output" 2>&1; then echo 'Same-boot rejoin was permitted.' >&2; exit 1; fi
grep -q 'Reboot this removed node' "$tmp/output"
printf 'different-boot\n' >"$marker"
if bash "$repo/scripts/install-k3s.sh" "${args[@]}" >"$tmp/output" 2>&1; then echo 'Test failed to stop at the swap gate.' >&2; exit 1; fi
grep -q 'Disable swap first' "$tmp/output"
[[ ! -e /etc/rancher/k3s/config.yaml ]]
echo 'Fresh installer rejects same-boot rejoin and advances after boot ID changes.'

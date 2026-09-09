#!/usr/bin/env bash
# Optional vendor-specific preparation. Run before k3s, or drain before the later restart.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
command -v nvidia-smi >/dev/null || { echo 'Install a Debian-supported NVIDIA driver, enroll its Secure Boot key if needed, and reboot first. See docs/gpu.md.' >&2; exit 1; }
nvidia-smi --query-gpu=name,driver_version --format=csv
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl --fail --silent --show-error --location https://nvidia.github.io/libnvidia-container/gpgkey -o "$tmp/key"
gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg "$tmp/key"
curl --fail --silent --show-error --location \
  https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o "$tmp/repo"
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  "$tmp/repo" >/etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
toolkit_version=1.20.0-1
apt-get install -y "nvidia-container-toolkit=$toolkit_version" \
  "nvidia-container-toolkit-base=$toolkit_version" "libnvidia-container-tools=$toolkit_version" \
  "libnvidia-container1=$toolkit_version"
command -v nvidia-container-runtime
echo 'k3s detects nvidia-container-runtime at startup and creates RuntimeClass nvidia.'
echo 'If k3s is already running: drain this node, restart its k3s or k3s-agent service, verify the runtime, then uncordon.'
echo 'Do not edit /etc/containerd/config.toml: k3s manages its own containerd configuration.'

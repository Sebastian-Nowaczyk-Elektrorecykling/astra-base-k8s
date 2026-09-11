#!/usr/bin/env bash
# Administrator CLI tools for Debian. Run host preparation separately on cluster nodes.
set -euo pipefail
usage() {
  echo 'Usage: sudo bash scripts/prepare-workstation.sh'
  echo 'Installs Git, SSH client, curl, jq, OpenSSL, age, dig, kubectl, Helm, Flux and SOPS.'
  echo 'Supports Debian 12/13 on amd64 and arm64; binary pins are in bootstrap/versions.env.'
}
case ${1:-} in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { usage >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo 'Run as root (sudo bash scripts/prepare-workstation.sh).' >&2; exit 1; }
# shellcheck source=/dev/null
source /etc/os-release
[[ $ID == debian && ( $VERSION_ID == 12 || $VERSION_ID == 13 ) ]] || {
  echo 'This installer supports Debian 12 and 13.' >&2; exit 1;
}
arch=$(dpkg --print-architecture)
case $arch in
  amd64|arm64) ;;
  *) echo "Unsupported architecture: $arch (use amd64 or arm64)." >&2; exit 1 ;;
esac
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bootstrap/versions.env
source "$repo/bootstrap/versions.env"
[[ $KUBECTL_VERSION == "${K3S_VERSION%%+*}" ]] || {
  echo 'KUBECTL_VERSION must match the Kubernetes release in K3S_VERSION.' >&2; exit 1;
}
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git openssh-client \
  jq openssl age dnsutils python3 tar gzip coreutils

umask 077
tmp=$(mktemp -d /tmp/elektro-workstation.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
download() {
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 \
    --max-time 300 --proto '=https' --proto-redir '=https' --tlsv1.2 "$1" --output "$2"
}
verify_digest() {
  local file=$1 expected=$2
  [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || {
    echo "Missing or invalid upstream SHA-256 for $file." >&2; exit 1;
  }
  if ! (cd "$tmp" && printf '%s  %s\n' "$expected" "$file" | sha256sum --check --status); then
    echo "SHA-256 verification failed for $file; no downloaded tools have been installed." >&2
    exit 1
  fi
  echo "Verified SHA-256: $file"
}
verify_manifest() {
  local file=$1 manifest=$2 expected
  expected=$(awk -v file="$file" '$2 == file || $2 == "*" file {print $1}' "$manifest")
  verify_digest "$file" "$expected"
}

echo "Downloading the pinned workstation tools for linux/$arch."
base="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$arch"
download "$base/kubectl" "$tmp/kubectl"
download "$base/kubectl.sha256" "$tmp/kubectl.sha256"
verify_digest kubectl "$(tr -d '[:space:]' <"$tmp/kubectl.sha256")"

helm_archive="helm-$HELM_VERSION-linux-$arch.tar.gz"
download "https://get.helm.sh/$helm_archive" "$tmp/$helm_archive"
download "https://get.helm.sh/$helm_archive.sha256" "$tmp/helm.sha256"
verify_digest "$helm_archive" "$(tr -d '[:space:]' <"$tmp/helm.sha256")"

flux_archive="flux_${FLUX_VERSION#v}_linux_$arch.tar.gz"
base="https://github.com/fluxcd/flux2/releases/download/$FLUX_VERSION"
download "$base/$flux_archive" "$tmp/$flux_archive"
download "$base/flux_${FLUX_VERSION#v}_checksums.txt" "$tmp/flux-checksums.txt"
verify_manifest "$flux_archive" "$tmp/flux-checksums.txt"

sops_binary="sops-$SOPS_VERSION.linux.$arch"
base="https://github.com/getsops/sops/releases/download/$SOPS_VERSION"
download "$base/$sops_binary" "$tmp/$sops_binary"
download "$base/sops-$SOPS_VERSION.checksums.txt" "$tmp/sops-checksums.txt"
verify_manifest "$sops_binary" "$tmp/sops-checksums.txt"

# Verify every download before extracting or replacing a CLI. Never run downloaded installers.
tar -xzf "$tmp/$helm_archive" -C "$tmp" "linux-$arch/helm"
tar -xzf "$tmp/$flux_archive" -C "$tmp" flux
install -d -m 0755 /usr/local/bin
install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
install -m 0755 "$tmp/linux-$arch/helm" /usr/local/bin/helm
install -m 0755 "$tmp/flux" /usr/local/bin/flux
install -m 0755 "$tmp/$sops_binary" /usr/local/bin/sops

/usr/local/bin/kubectl version --client=true -o json | jq -r '.clientVersion.gitVersion | "kubectl: " + .'
/usr/local/bin/helm version --short
/usr/local/bin/flux version --client
/usr/local/bin/sops --version --disable-version-check
age --version
echo 'Workstation tools installed. Keep /usr/local/bin in PATH and run: hash -r'
echo 'Continue with docs/bootstrap.md as your regular user; supply your own kubeconfig and age key.'

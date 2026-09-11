#!/usr/bin/env bash
# Host preparation only. Does not partition, format disks, or install GPU drivers.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
disable_sleep=false
case ${1:-} in
  --disable-sleep) disable_sleep=true ;;
  '') ;;
  *) echo 'Usage: sudo bash scripts/prepare-debian.sh [--disable-sleep]' >&2; exit 2 ;;
esac
# shellcheck source=/dev/null
source /etc/os-release
[[ $ID == debian && ( $VERSION_ID == 12 || $VERSION_ID == 13 ) ]] || {
  echo 'This preparation supports Debian 12 and 13.' >&2; exit 1;
}
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || {
  echo 'Enable cgroup v2 and reboot before continuing.' >&2; exit 1;
}
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq git openssl iproute2 iptables \
  open-iscsi nfs-common cryptsetup dmsetup util-linux conntrack ethtool \
  socat chrony pciutils
install -d -m 0755 /etc/modules-load.d /etc/sysctl.d /var/lib/longhorn
cat >/etc/modules-load.d/elektro-k8s.conf <<'EOF'
overlay
br_netfilter
iscsi_tcp
dm_crypt
wireguard
EOF
for module in overlay br_netfilter iscsi_tcp dm_crypt wireguard; do modprobe "$module"; done
cat >/etc/sysctl.d/90-elektro-k8s.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
EOF
sysctl --system
swapoff -a
[[ -e /etc/fstab.elektro-before-swap ]] || cp -a /etc/fstab /etc/fstab.elektro-before-swap
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# elektro-disabled-swap: /' /etc/fstab
systemctl enable --now iscsid chrony
cat >/etc/systemd/system/elektro-mount-propagation.service <<'EOF'
[Unit]
Description=Shared mount propagation for Kubernetes CSI
Before=k3s.service k3s-agent.service
[Service]
Type=oneshot
ExecStart=/bin/mount --make-rshared /
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now elektro-mount-propagation.service
if $disable_sleep; then
  install -d /etc/systemd/logind.conf.d
  cat >/etc/systemd/logind.conf.d/90-elektro-laptop.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
fi
echo 'Host prepared. Reboot, then check swap stays disabled and time is synchronized.'
echo 'Keep controller/API addresses stable; workers may use DHCP. Review LAN firewall ports in docs/bootstrap.md.'

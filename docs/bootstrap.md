# Bootstrap from fresh Debian

For a replacement of a wiped cluster, first follow [the rebuild checklist](rebuild.md) to retire old credentials and state.

## 1. Make the local choices

Use Debian 12/13 with a current kernel, SSDs, synchronized time, working DNS and preferably wired Ethernet. The scripts disable swap, load the required kernel modules, install iSCSI/NFS tools and make mounts shared. `--disable-sleep` handles lids and suspend targets. Reboot and verify no desktop power manager or zram service re-enables swap/suspend. Have enough free RAM for the platform and your workloads; measure actual use before loading models. The default requests favor a small cluster; Keycloak alone requests 768 MiB.

Reserve, for example:

| Purpose | Example |
| --- | --- |
| Initial controller k8s1 | Stable `192.168.2.153`; workers may use ordinary DHCP |
| Initial Kubernetes API | `192.168.2.153:6443` |
| Optional future API VIP | `192.168.2.10` (outside service pool) |
| Cilium service pool | `192.168.2.240`–`.249`, outside DHCP |
| Gateway IP | `192.168.2.240` |
| LAN DNS IP | `192.168.2.242` (distinct IP within the excluded service pool) |
| Application DNS | `*.internal`, `*.admin.internal`, `*.test.internal`, `*.staging.internal` → private gateway IP |
| Machine DNS | `NODE.hosts.internal` → each registered node's reported LAN IP, discovered automatically |
| Pod / Service CIDRs | `10.42.0.0/16` / `10.43.0.0/16` |

Change the LAN addresses in `clusters/laptops/settings.yaml`; [the settings reference](clusters.md#what-to-put-in-settingsyaml) explains every field. These examples must match your actual subnet. Keep `INTERNAL_DOMAIN: internal`, `IDENTITY_HOST: keycloak.admin.internal` and the shared `PUBLIC_EDGE_IP: NOT_CONFIGURED` default for the private setup. Configure the [LAN DNS service](dns.md), including `DNS_IP`, `DNS_CLIENT_CIDR` and `DNS_UPSTREAMS`; no node inventory is needed. Set the real interface regex for L2 announcements (`ip -br link`), not a guessed Wi-Fi interface. Keep working external DNS during bootstrap; after Flux starts CoreDNS, point client machines at `DNS_IP`. Keep cluster hosts' bootstrap DNS independent as explained in the DNS runbook. L2 requires a shared broadcast domain and ARP announcements to pass; wireless client isolation often breaks it. The [EdgeRouter guide](bgp.md) gives the minimum router setup and an optional BGP configuration. BGP is disabled by default.

Prepare the administrator workstation from a checkout of this repository:

```sh
sudo bash scripts/prepare-workstation.sh
hash -r
```

On a fresh Debian machine without Git, first run `sudo apt-get update` and `sudo apt-get install -y git ca-certificates`, then clone this repository. If Debian has no sudo configured, perform the package installation and workstation script as root with `su -`; run the remaining bootstrap commands as your regular user.

The installer supports Debian 12/13 on amd64 and arm64. It installs Git, the SSH client, curl, jq, Python 3 (for configuration validation), OpenSSL, age and `dig` from Debian, then checksum-verifies and installs kubectl, Helm, Flux and SOPS from their official release archives into `/usr/local/bin`. Their versions are pinned in `bootstrap/versions.env`; kubectl matches k3s's Kubernetes version. Re-running the script installs those same pins, including replacing an existing copy in `/usr/local/bin`. Keep that directory in PATH before older copies of these commands.

The script prepares administration tools only. Cluster-node preparation remains `scripts/prepare-debian.sh`; workstation installation does not configure kubeconfig, generate credentials, change swap, install a container runtime or join a cluster.

With the workstation tools installed and the tracked settings edited, export the shared bootstrap values:

```sh
mkdir -p local
bash scripts/configure-cluster.sh --export laptops > local/cluster.env
```

Copy this env file to each node. All servers must receive identical critical k3s options. CIDRs must not overlap LAN/VPN networks. Do not change them on a running cluster. For a second cluster, [create its own profile](clusters.md#create-a-second-profile) and use its name in the export command; do not copy another cluster's secrets or generated Flux sync.

## 2. Prepare and start nodes

On each machine:

```sh
git clone https://github.com/Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s.git
cd astra-base-k8s
mkdir -p local
# Copy the exported cluster.env from the workstation into local/cluster.env.
sudo bash scripts/prepare-debian.sh --disable-sleep
sudo reboot
```

After reconnecting, initialize **exactly one** server:

```sh
sudo bash scripts/install-k3s.sh --role hybrid --name k8s1 --ip 192.168.2.153 \
  --config local/cluster.env --init
```

Use `--role controller` for a dedicated controller. It still runs a kubelet and Cilium so it participates in networking, but receives a dedicated NoSchedule taint and no Longhorn disk/workload label. At least one worker or hybrid must exist to run platform services. A cluster with only a dedicated controller has no place to schedule the platform.

Transfer `/var/lib/rancher/k3s/server/token` from k8s1 to a root-readable file on joining nodes over your existing SSH/admin channel. Do not paste it into shell arguments, Git or issues. It is a privileged server-join credential. You can instead configure an agent-only token for workers; that token cannot add controllers.

```sh
# On k8s2 (repeat with any unique name for additional workers):
sudo bash scripts/install-k3s.sh --role worker --name k8s2 --ip auto \
  --config local/cluster.env --server https://192.168.2.153:6443 \
  --token-file /root/k3s-join-token
```

The nodes are expected to be NotReady until Cilium is installed. `--ip auto` omits `node-ip` and lets k3s choose the address at startup; it is also the default if `--ip` is omitted. See [DHCP limits](clusters.md#dhcp-and-dynamic-node-dns) before changing a running node's address. The installer refuses to overwrite an existing installation. It is for fresh nodes or cleaned, rebooted nodes rejoining after [the removal procedure](node-role-changes.md), not for overwriting a live installation.

## 3. Bootstrap Cilium

Securely copy `/etc/rancher/k3s/k3s.yaml` from k8s1 to `local/kubeconfig` on the workstation. Replace only its API server address (`127.0.0.1`) with the reachable initial API address, retain its CA, and set mode 0600. This is a cluster-admin credential.

```sh
export KUBECONFIG="$PWD/local/kubeconfig"
bash scripts/bootstrap-cilium.sh local/cluster.env
kubectl get nodes -o wide
```

The normal Helm release is installed once to solve the CNI/bootstrap dependency. Flux later reconciles that same release, namespace, version and shared values file. There is no k3s HelmChart resource racing Flux. Do not re-enable Flannel, kube-proxy, Traefik, ServiceLB or local-path storage.

Review the settings file and include it in the commit below. Flux cannot read your ignored `local/cluster.env`: it uses the merged tracked settings ConfigMap. Prefer editing the profile and re-exporting its env. For an existing env file, `bash scripts/configure-cluster.sh local/cluster.env` imports its API, Pod/Service networks, kube-dns IP and private suffix into the selected profile; review, commit and push that change. Load-balancer/DNS values remain in `settings.yaml` unless explicitly included in that trusted env file. The exported file must include `CLUSTER_NAME` and `INTERNAL_DOMAIN`.

If Flux already manages Cilium, the bootstrap script stops before running Helm against that managed release. For an API endpoint change, use the [HA runbook](high-availability.md#add-controllers).

## 4. Encrypt secrets and bootstrap Flux

From your workstation checkout with the real settings:

```sh
umask 077
age-keygen -o local/age.agekey
age-keygen -y local/age.agekey  # public recipient, safe to copy
bash scripts/generate-secrets.sh age1YOUR_PUBLIC_RECIPIENT
git add clusters/laptops
git commit -m 'Configure laptop cluster and encrypted bootstrap secrets'
git push origin main

# Set GITHUB_TOKEN securely in your local shell; do not commit it.
bash scripts/bootstrap-flux.sh local/age.agekey
unset GITHUB_TOKEN
git pull --ff-only
```

The GitHub token bootstraps Flux's read-only SSH deploy key; the token is not stored in the cluster. Back up the age private key offline. `sops-age` must be restored before Flux can recover encrypted resources. The cluster's `.sops.yaml` can be added with your public recipient if you want convenient `sops` edits. Never commit decrypted copies.

Before making cluster changes, `bootstrap-flux.sh` verifies that bootstrap values agree with the selected profile, that kubeconfig points at its API, and that the profile and shared infrastructure match `origin/main`. This prevents Flux from replacing the working Cilium API address with an old Git value or bootstrapping the wrong selected cluster. If your local config has a different path, pass it as the second argument: `bash scripts/bootstrap-flux.sh local/age.agekey /path/to/cluster.env`.

The checked-in Flux resource list includes its generated controllers and sync configuration, following [Flux bootstrap customization](https://fluxcd.io/flux/installation/configuration/bootstrap-customization/). Keep both references when customizing a profile.

Flux starts prerequisites before consumers. `foundation → cilium → controllers → admission → storage → databases → identity/authorization → edge → access → routes` is the main chain; certificates and secrets have their own prerequisites. Helm installation/remediation uses upstream chart jobs and service accounts without a handcrafted fixup controller.

```sh
flux get kustomizations
flux get helmreleases -A
kubectl get clusters.postgresql.cnpg.io -A
```

Empty/missing secrets leave dependent pods unready. Missing FGA store/model IDs leave application authorization denied; they never grant access. First reconciliation can take several minutes for images, volumes and the databases.

## 5. Trust TLS, initialize permissions, log in

The default cert-manager issuer creates a private root and a certificate with all four internal application wildcards, including the administration group. Export **only its public certificate**:

```sh
kubectl -n cert-manager get secret platform-root-ca -o jsonpath='{.data.ca\.crt}' \
  | base64 --decode > local/platform-ca.crt
```

Install this public CA in each client's trust store. [Windows setup](windows-clients.md) gives minimally invasive DNS options and a per-user certificate import; [the TLS runbook](tls.md) includes DER export, fingerprint verification and root renewal/recovery. Do not use `curl -k` or turn off certificate validation. Internal names keep the private CA. Optional public exposure uses a separate public certificate and gateway; follow [the opt-in procedure](../examples/public-exposure/README.md). OIDC token/JWKS calls stay on restricted cluster Service endpoints so private-root trust is not a bootstrap dependency for the gateway controllers.

Visit `https://keycloak.admin.internal/admin`. Retrieve the initial bootstrap-admin password from your encrypted secret using your secure local tools. Create a permanent, MFA-protected admin account in the master realm, verify it, then remove the temporary bootstrap administrator. Create an `elektro` realm user with a password (and preferably MFA). Realm import creates no human user and enables no public registration.

Continue with [OpenFGA initialization and the first grant](identity-access.md#initialize-openfga). After the first grant, Longhorn will be accessible through the protected host. Run the access acceptance checks before using real data.

## Firewall and recovery access

Configure your existing host/router firewall; the preparation script does not replace it or risk locking out SSH. Permit these flows only from the described sources:

| Port/protocol | Source → destination |
| --- | --- |
| TCP 22 | Admin network → nodes |
| TCP 6443 | Admins and all nodes → server nodes / API VIP |
| TCP 2379–2380 | Server nodes ↔ server nodes |
| TCP 10250 | Trusted cluster nodes → kubelets |
| UDP 8472 | Cluster nodes ↔ cluster nodes, Cilium VXLAN |
| UDP 51871 | Cluster nodes ↔ cluster nodes, Cilium WireGuard |
| TCP 4240, ICMP | Cluster nodes ↔ cluster nodes, Cilium health |
| TCP 4244 | Hubble relay / trusted nodes → Cilium agents |
| TCP 443 | LAN/VPN clients → private `EDGE_IP`; Internet clients → separate `PUBLIC_EDGE_IP` only after explicit opt-in |
| TCP/UDP 53 | Trusted LAN → `DNS_IP`; DNS pods → configured upstream resolvers |
| DNS/NTP/HTTPS egress | Nodes/pods → your resolvers, time service, registries and Git/chart sources |

Longhorn also needs its documented internal manager/engine/replica traffic between cluster nodes; permit trusted cluster-node traffic on the private LAN, or derive a full host firewall allowlist from the pinned Longhorn release before restricting it. Do not present the above as an exhaustive Longhorn firewall policy. The external boundary must not expose these internal ports or the full NodePort range.

Keep an offline recovery kubeconfig and console/SSH access. Port-forward permissions are privileged and bypass the public gateway by design. An IdP failure must not be able to lock administrators out of repairing the IdP.

## Metrics after bootstrap

The shared base also installs the metrics stack. Grant access to `grafana.admin.internal` following [metrics setup](monitoring.md#enable-access). The realm import includes the callback; no grants or external alert notifications are automatic.

# Bootstrap from fresh Debian

## 1. Make the local choices

Use Debian 12/13 with a current kernel, SSDs, synchronized time, working DNS and preferably wired Ethernet. The scripts disable swap, load the required kernel modules, install iSCSI/NFS tools and make mounts shared. `--disable-sleep` handles lids and suspend targets. Reboot and verify no desktop power manager or zram service re-enables swap/suspend. Have enough free RAM for the platform and your workloads; measure actual use before loading models. The default requests favor a small cluster; Keycloak alone requests 768 MiB.

Reserve, for example:

| Purpose | Example |
| --- | --- |
| k8s1 / k8s2 / k8s3 | `192.168.50.11` / `.12` / `.13` |
| Initial Kubernetes API | `192.168.50.11:6443` |
| Optional future API VIP | `192.168.50.10` (outside service pool) |
| Cilium service pool | `192.168.50.240`–`.249`, outside DHCP |
| Gateway IP | `192.168.50.240` |
| DNS | `id.YOUR_DOMAIN` and `*.apps.YOUR_DOMAIN` → gateway IP |
| Pod / Service CIDRs | `10.42.0.0/16` / `10.43.0.0/16` |

Change `clusters/laptops/settings.yaml`. Set the real interface regex for L2 announcements (`ip -br link`), not a guessed Wi-Fi interface. Set up DNS on a resolver your laptops **and client machines** use. L2 requires a shared broadcast domain and ARP announcements to pass; wireless client isolation often breaks it. For routed networks use Cilium BGP instead, as a reviewed replacement of the L2 policy.

Copy `bootstrap/cluster.env.example` to `local/cluster.env` on each host and the administrator workstation. Set the reachable API address there. `bootstrap-cilium.sh` copies `API_HOST` and `POD_CIDR` into `clusters/laptops/settings.yaml` before installing Cilium. All servers must receive identical critical k3s options. CIDRs must not overlap LAN/VPN networks. Do not change them on a running cluster.

Prepare the administrator workstation from a checkout of this repository:

```sh
sudo bash scripts/prepare-workstation.sh
hash -r
```

On a fresh Debian machine without Git, first run `sudo apt-get update` and `sudo apt-get install -y git ca-certificates`, then clone this repository. If Debian has no sudo configured, perform the package installation and workstation script as root with `su -`; run the remaining bootstrap commands as your regular user.

The installer supports Debian 12/13 on amd64 and arm64. It installs Git, the SSH client, curl, jq, OpenSSL and age from Debian, then checksum-verifies and installs kubectl, Helm, Flux and SOPS from their official release archives into `/usr/local/bin`. Their versions are pinned in `bootstrap/versions.env`; kubectl matches k3s's Kubernetes version. Re-running the script installs those same pins, including replacing an existing copy in `/usr/local/bin`. Keep that directory in PATH before older copies of these commands.

The script prepares administration tools only. Cluster-node preparation remains `scripts/prepare-debian.sh`; workstation installation does not configure kubeconfig, generate credentials, change swap, install a container runtime or join a cluster.

If you already installed nodes with the original `astra.local` labels, follow [the Elektro naming update](rename-elektro.md) before continuing with Flux.

## 2. Prepare and start nodes

On each machine:

```sh
git clone https://github.com/Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s.git
cd astra-base-k8s
mkdir -p local
cp bootstrap/cluster.env.example local/cluster.env
# Edit local/cluster.env.
sudo bash scripts/prepare-debian.sh --disable-sleep
sudo reboot
```

After reconnecting, initialize **exactly one** server:

```sh
sudo bash scripts/install-k3s.sh --role hybrid --name k8s1 --ip 192.168.50.11 \
  --config local/cluster.env --init
```

Use `--role controller` for a dedicated controller. It still runs a kubelet and Cilium so it participates in networking, but receives a dedicated NoSchedule taint and no Longhorn disk/workload label. At least one worker or hybrid must exist to run platform services. A cluster with only a dedicated controller has no place to schedule the platform.

Transfer `/var/lib/rancher/k3s/server/token` from k8s1 to a root-readable file on joining nodes over your existing SSH/admin channel. Do not paste it into shell arguments, Git or issues. It is a privileged server-join credential. You can instead configure an agent-only token for workers; that token cannot add controllers.

```sh
# On k8s2 (same pattern for k8s3 with .13):
sudo bash scripts/install-k3s.sh --role worker --name k8s2 --ip 192.168.50.12 \
  --config local/cluster.env --server https://192.168.50.11:6443 \
  --token-file /root/k3s-join-token
```

The nodes are expected to be NotReady until Cilium is installed. The installer refuses to overwrite an existing installation. It is for fresh nodes, not an upgrade or role-conversion tool.

## 3. Bootstrap Cilium

Securely copy `/etc/rancher/k3s/k3s.yaml` from k8s1 to `local/kubeconfig` on the workstation. Replace only its API server address (`127.0.0.1`) with the reachable initial API address, retain its CA, and set mode 0600. This is a cluster-admin credential.

```sh
export KUBECONFIG="$PWD/local/kubeconfig"
bash scripts/bootstrap-cilium.sh local/cluster.env
kubectl get nodes -o wide
```

The normal Helm release is installed once to solve the CNI/bootstrap dependency. Flux later reconciles that same release, namespace, version and shared values file. There is no k3s HelmChart resource racing Flux. Do not re-enable Flannel, kube-proxy, Traefik, ServiceLB or local-path storage.

Review the settings file updated by this step and include it in the commit below. Flux cannot read your ignored `local/cluster.env`: it uses `API_HOST` from the tracked settings ConfigMap. For later address changes, run `bash scripts/configure-cluster.sh local/cluster.env`, then commit and push the resulting settings change. The helper only copies the shared API address and pod CIDR; configure your domain, load-balancer addresses and other platform values in `settings.yaml`.

If Flux already manages Cilium, the bootstrap script stops before running Helm against that managed release. Use [Cilium API-address recovery](cilium-api-recovery.md) if pods are already connecting to the wrong server.

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

Before making cluster changes, `bootstrap-flux.sh` verifies that `API_HOST` and `POD_CIDR` agree with `local/cluster.env` and that the committed cluster configuration matches `origin/main`. This prevents Flux from replacing the working Cilium API address with an old Git value. If your local config has a different path, pass it as the second argument: `bash scripts/bootstrap-flux.sh local/age.agekey /path/to/cluster.env`.

The checked-in `flux-system/kustomization.yaml` references both `gotk-components.yaml` and `gotk-sync.yaml`. The latter starts as a comment-only placeholder, then Flux writes the real GitRepository and Kustomization during bootstrap. Flux preserves an existing Kustomization's resource list: leaving it empty causes `no Kubernetes objects found` even after the controllers' YAML has been generated. This layout follows [Flux's bootstrap customization procedure](https://fluxcd.io/flux/installation/configuration/bootstrap-customization/).

To resume the previously failed attempt, pull this fix and rerun `bash scripts/bootstrap-flux.sh local/age.agekey` with the same key and temporary GitHub token. The [recovery guide](rename-elektro.md) includes the node-label update. Preserve your existing encrypted secrets and generated component manifests; there is no need to reinstall k3s or regenerate credentials.

Flux starts prerequisites before consumers. `foundation → cilium → controllers → admission → storage → databases → identity/authorization → edge → access → routes` is the main chain; certificates and secrets have their own prerequisites. Helm installation/remediation uses upstream chart jobs and service accounts without a handcrafted fixup controller.

```sh
flux get kustomizations
flux get helmreleases -A
kubectl get clusters.postgresql.cnpg.io -A
```

Empty/missing secrets leave dependent pods unready. Missing FGA store/model IDs leave application authorization denied; they never grant access. First reconciliation can take several minutes for images, volumes and the databases.

## 5. Trust TLS, initialize permissions, log in

The default cert-manager issuer creates a private root and a certificate for the identity host and application wildcard. Export **only its public certificate**:

```sh
kubectl -n cert-manager get secret platform-root-ca -o jsonpath='{.data.ca\.crt}' \
  | base64 --decode > local/platform-ca.crt
```

Install this public CA in each client OS/browser trust store using your normal administration process. Do not use `curl -k` or turn off certificate validation. For public certificates, use the DNS-01 example and change the edge Certificate issuer; do not run two issuers against the same secret. OIDC token/JWKS calls stay on restricted cluster Service endpoints so private-root trust is not a bootstrap dependency for the gateway controllers.

Visit `https://id.YOUR_DOMAIN/admin`. Retrieve the initial bootstrap-admin password from your encrypted secret using your secure local tools. Create a permanent, MFA-protected admin account in the master realm, verify it, then remove the temporary bootstrap administrator. Create an `elektro` realm user with a password (and preferably MFA). Realm import creates no human user and enables no public registration.

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
| TCP 443 | Clients → gateway IP |
| DNS/NTP/HTTPS egress | Nodes/pods → your resolvers, time service, registries and Git/chart sources |

Longhorn also needs its documented internal manager/engine/replica traffic between cluster nodes; permit trusted cluster-node traffic on the private LAN, or derive a full host firewall allowlist from the pinned Longhorn release before restricting it. Do not present the above as an exhaustive Longhorn firewall policy. The external boundary must not expose these internal ports or the full NodePort range.

Keep an offline recovery kubeconfig and console/SSH access. Port-forward permissions are privileged and bypass the public gateway by design. An IdP failure must not be able to lock administrators out of repairing the IdP.

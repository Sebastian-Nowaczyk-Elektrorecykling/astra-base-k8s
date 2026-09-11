# Elektro base Kubernetes

A reusable GitOps base for Debian clusters. The `laptops` profile starts with `k8s1` as a controller/worker hybrid and `k8s2` / `k8s3` as workers; these are examples, not a fixed node list. Any number of nodes can join with their own names. All installed services are existing upstream projects; there is no custom controller, authentication server, operator framework, or application runtime in this repository.

| Layer | Choice | Behavior |
| --- | --- | --- |
| Kubernetes | k3s, embedded etcd | One server initially; add two servers for quorum HA |
| Network | Cilium | CNI, kube-proxy replacement, policies, WireGuard, LAN load-balancer IP allocation and L2 announcements, Hubble relay |
| LAN DNS | CoreDNS | Dynamic k3s node records, application wildcards and configurable upstream forwarding on a stable Cilium IP |
| GitOps | Flux | Helm's normal lifecycle, explicit dependency stages, SOPS-encrypted secrets |
| Volumes | Longhorn V1 engine | Ordinary `/var/lib/longhorn` directory; no raw partition |
| Databases | CloudNativePG | PostgreSQL for Keycloak and OpenFGA; reusable cluster example |
| Identity | Keycloak | Local accounts, external identity brokering such as Google, MFA, service accounts and supported token exchange |
| HTTP entry | Envoy Gateway | TLS, OIDC browser login, bearer JWTs and fail-closed external authorization |
| Permissions | OpenFGA + Authorino | Authorino verifies JWTs and calls OpenFGA's Check API using its supported HTTP metadata configuration |
| Admission | Kubernetes CEL policies + Kyverno | Block alternate exposure paths; default CNPG storage before PVC creation |
| Certificates | cert-manager | Private CA by default; public DNS-01 issuer example |
| Metrics | Prometheus, Alertmanager, Grafana | Cluster-administrator dashboards at `grafana.admin.internal`; persistent bounded retention |
| GPU | Optional upstream device plugin | NVIDIA preparation provided; no vendor driver is installed on ordinary nodes |

Envoy Gateway supplies a supported OIDC/external-auth policy API. Cilium remains the cluster network and load-balancer implementation. Using handwritten Cilium Envoy filter patches for the authentication boundary would make this foundation harder to maintain.

## Start here

Follow [the bootstrap runbook](docs/bootstrap.md). It covers DNS/IP choices, host preparation, joining nodes, the one-time Cilium install, encrypted secrets, Flux bootstrap and first login. Review [the access model](docs/identity-access.md) before granting the first dashboard permission.

Read [cluster settings and reuse](docs/clusters.md) for a field-by-field IP explanation, DHCP workers and creating another cluster. Profiles share `infrastructure/` and `clusters/base/`, while keeping independent settings, secrets and Flux entry points. Generate a second profile with `bash scripts/create-cluster.sh production`.

On a fresh Debian administrator workstation, run `sudo bash scripts/prepare-workstation.sh` to install the required command-line tools. The setup is named **Elektro**; its existing GitHub repository remains `astra-base-k8s`.

For another clean installation of the same profile, follow [rebuild laptops from scratch](docs/rebuild.md). The default networking uses Cilium L2; [optional EdgeRouter BGP](docs/bgp.md) uses only stable controller peers.

```sh
# On each freshly installed Debian host, from this repository:
sudo bash scripts/prepare-debian.sh --disable-sleep
# Reboot. Export the edited profile's env on the workstation and copy it here:
# bash scripts/configure-cluster.sh --export laptops > local/cluster.env

# On k8s1:
sudo bash scripts/install-k3s.sh --role hybrid --name k8s1 --ip 192.168.2.153 \
  --config local/cluster.env --init
```

Continue with the runbook; this command alone does not install the platform. Supply secrets and reserve a small LAN pool for service IPs before deployment. Keep the controller/API address stable; workers can use DHCP with `--ip auto` (the default). The existing cluster retains `.internal`; another profile can use a suffix such as `production.internal`.

## DNS and exposure

| Purpose | Name examples | Destination |
| --- | --- | --- |
| LAN machines | `k8s1.hosts.internal`, `k8s2.hosts.internal`, `k8s3.hosts.internal` | Each machine's LAN IP |
| Test deployments | `foo-a7c92e.test.internal`, `foo-b41d08.test.internal` | Private gateway `EDGE_IP` |
| Staging | `foo.staging.internal` | Private gateway `EDGE_IP` |
| Administration | `keycloak.admin.internal`, `longhorn.admin.internal`, `grafana.admin.internal` | Private gateway `EDGE_IP` |
| Applications / production | `foo.internal`, `bar.internal` | Private gateway `EDGE_IP` |

Prefer keeping clients on their existing router DNS and [forwarding only `.internal`](docs/dns.md#edgerouter-conditional-forwarding) to the CoreDNS service's **LAN** `DNS_IP`. Direct client/DHCP use of `DNS_IP` also works. Configure `DNS_IP`, `DNS_CLIENT_CIDR` and `DNS_UPSTREAMS` in `clusters/laptops/settings.yaml`; see [LAN DNS setup](docs/dns.md). Registered node addresses are discovered automatically from k3s; unknown machine names return NXDOMAIN. Wildcard DNS supports new application names; each application needs an exact route, callback and permission grant. Grouped TLS wildcards cover random tests and admin/staging names; direct `foo.internal` names also need [an exact certificate SAN](docs/tls.md#exact-names-for-applications-directly-under-internal). The separate application-platform Flux repository owns deployment naming and lifecycle.

[Windows clients](docs/windows-clients.md) use the same DNS and private-root trust with BGP on or off. Keep L2 enabled for this on-link IP pool. [Private TLS operations](docs/tls.md) covers CA export, renewal and trust after a rebuild; public CAs cannot issue for `.internal`.

Internet exposure is **off by default**. An optional separate public gateway has its own IP, certificate and exact routes. `fuzzy.elektrorecykling.pl` can target the same Service as `foo.internal`; `bar.internal` remains private. Forwarding the private gateway to the Internet would defeat this boundary. See [Internal domains](docs/domains.md) and [explicit public exposure](examples/public-exposure/README.md).

## Storage defaults

| StorageClass | Longhorn copies | Default for | Reclaim |
| --- | ---: | --- | --- |
| `longhorn` | 1 | Ordinary PVCs without a class | Retain |
| `longhorn-3` | 3, on distinct nodes/disks | Explicitly selected durable volumes | Retain |
| `longhorn-cnpg` | 1 per PostgreSQL instance | CNPG data and optional WAL storage when the class is omitted | Retain |

The chart does not create its own StorageClass. Kyverno mutates **CNPG Cluster resources**, before CNPG creates PVCs, preserving explicit nonempty choices. Three database instances on `longhorn-cnpg` have three PostgreSQL copies, rather than nine underlying Longhorn copies. Start with one database instance; use [the HA procedure](docs/high-availability.md) to change that. A one-copy volume can lose its data when its disk fails. Replication, retained PVs and snapshots are not off-cluster backups.

## Access defaults

`https://longhorn.admin.internal` and `https://grafana.admin.internal` require Keycloak login **and** an OpenFGA `service:<hostname>#access` grant. No grants are installed automatically. Keycloak itself is the explicit native-authentication exception at `https://keycloak.admin.internal`; putting the login service behind its own login requirement would create a loop. Databases, the Kubernetes API and cluster management protocols use their native credentials and network boundaries.

Routes are centrally managed in `edge`. New application routes inherit their selected internal listener's security policy. Kubernetes admission permits the restricted LAN DNS service and managed gateways, and blocks NodePort/other LoadBalancer services, external IPs, alternate ingress APIs and per-route security overrides. Cilium blocks direct ingress into application pods and restricts the Longhorn UI, identity and authorization services. Kubernetes administrators, node root access and permission to port-forward are trusted infrastructure administration paths.

The default is for a trusted private LAN; cluster-internal identity requests use restricted Service endpoints. Cilium encrypts pod traffic between nodes. Do not expose node management ports to the Internet. Application egress remains allowed: this is not a complete hostile multitenancy sandbox.

## Operations and extension

- [Contract for downstream repositories and their authors](docs/platform-contract.md)
- [Standalone application Flux repository starter](examples/downstream-repository/README.md)
- [Administration script reference](docs/scripts.md)
- [Bootstrap](docs/bootstrap.md)
- [Cluster settings, DHCP and multiple clusters](docs/clusters.md)
- [LAN DNS](docs/dns.md)
- [Windows DNS, ordinary browsers and CA trust](docs/windows-clients.md)
- [Private TLS, certificates and root recovery](docs/tls.md)
- [EdgeRouter and optional BGP](docs/bgp.md)
- [Rebuild laptops from scratch](docs/rebuild.md)
- [Metrics, Grafana access and retention](docs/monitoring.md)
- [Identity, dynamic projects, agents and OpenFGA](docs/identity-access.md)
- [HA and node roles](docs/high-availability.md)
- [Change roles, remove nodes and rejoin](docs/node-role-changes.md)
- [Storage, backups, recovery and upgrades](docs/operations.md)
- [GPU preparation](docs/gpu.md)
- [Validation and security acceptance checks](docs/validation.md)
- [Upstream release pins and references](docs/upstream.md)

The `examples/` directory is **not reconciled**. It contains the downstream repository starter and its base attachment, a CNPG cluster with required network allowances, a GPU smoke job, optional BGP/kube-vip/NVIDIA reconciliation, public certificates, explicit public exposure and backup examples. Enable only the pieces you need. Flux infrastructure namespaces and their RBAC are reserved for platform administrators; do not grant applications namespace-admin access there.

For services on top of this base, use a separate Git source and reconciliation attached from `clusters/NAME`. Reuse the installed Flux controllers. The contract describes resource ownership, dependencies, per-profile substitutions, identity grants, network policies, SOPS, data retention and acceptance checks; the starter includes `AGENTS.md` for future human and AI authors.

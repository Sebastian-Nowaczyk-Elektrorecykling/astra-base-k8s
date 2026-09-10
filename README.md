# Elektro base Kubernetes

A small, GitOps-managed cluster for Debian machines. Start with `k8s1` as a controller/worker hybrid and `k8s2` / `k8s3` as workers. Hostnames carry no hardware assumptions. All installed services are existing upstream projects; there is no custom controller, authentication server, operator framework, or application runtime in this repository.

| Layer | Choice | Behavior |
| --- | --- | --- |
| Kubernetes | k3s, embedded etcd | One server initially; add two servers for quorum HA |
| Network | Cilium | CNI, kube-proxy replacement, policies, WireGuard, LAN load-balancer IP allocation and L2 announcements, Hubble relay |
| GitOps | Flux | Helm's normal lifecycle, explicit dependency stages, SOPS-encrypted secrets |
| Volumes | Longhorn V1 engine | Ordinary `/var/lib/longhorn` directory; no raw partition |
| Databases | CloudNativePG | PostgreSQL for Keycloak and OpenFGA; reusable cluster example |
| Identity | Keycloak | Local accounts, external identity brokering such as Google, MFA, service accounts and supported token exchange |
| HTTP entry | Envoy Gateway | TLS, OIDC browser login, bearer JWTs and fail-closed external authorization |
| Permissions | OpenFGA + Authorino | Authorino verifies JWTs and calls OpenFGA's Check API using its supported HTTP metadata configuration |
| Admission | Kubernetes CEL policies + Kyverno | Block alternate exposure paths; default CNPG storage before PVC creation |
| Certificates | cert-manager | Private CA by default; public DNS-01 issuer example |
| GPU | Optional upstream device plugin | NVIDIA preparation provided; no vendor driver is installed on ordinary nodes |

Envoy Gateway supplies a supported OIDC/external-auth policy API. Cilium remains the cluster network and load-balancer implementation. Using handwritten Cilium Envoy filter patches for the authentication boundary would make this foundation harder to maintain.

## Start here

Follow [the bootstrap runbook](docs/bootstrap.md). It covers DNS/IP choices, host preparation, joining nodes, the one-time Cilium install, encrypted secrets, Flux bootstrap and first login. Review [the access model](docs/identity-access.md) before granting the first dashboard permission.

On a fresh Debian administrator workstation, run `sudo bash scripts/prepare-workstation.sh` to install the required command-line tools. The setup is named **Elektro**; its existing GitHub repository remains `astra-base-k8s`.

If an earlier bootstrap failed with `no Kubernetes objects found`, follow [the recovery and node-label update](docs/rename-elektro.md) before retrying.

If Cilium is contacting an old API address, follow [API-address recovery](docs/cilium-api-recovery.md). Flux reads the tracked settings, so a change only in `local/cluster.env` must be copied with `scripts/configure-cluster.sh` and committed.

```sh
# On each freshly installed Debian host, from this repository:
sudo bash scripts/prepare-debian.sh --disable-sleep
# Reboot. Copy bootstrap/cluster.env.example to local/cluster.env and edit it.

# On k8s1:
sudo bash scripts/install-k3s.sh --role hybrid --name k8s1 --ip 192.168.50.11 \
  --config local/cluster.env --init
```

Continue with the runbook; this command alone does not install the platform. Supply secrets and LAN address reservations before deployment. Internal DNS uses the fixed `.internal` scheme described below; keep your actual API and load-balancer addresses in the settings file.

## DNS and exposure

| Purpose | Name examples | Destination |
| --- | --- | --- |
| LAN machines | `k8s1.hosts.internal`, `k8s2.hosts.internal`, `k8s3.hosts.internal` | Each machine's LAN IP |
| Test deployments | `foo-a7c92e.test.internal`, `foo-b41d08.test.internal` | Private gateway `EDGE_IP` |
| Staging | `foo.staging.internal` | Private gateway `EDGE_IP` |
| Administration | `keycloak.admin.internal`, `longhorn.admin.internal` | Private gateway `EDGE_IP` |
| Applications / production | `foo.internal`, `bar.internal` | Private gateway `EDGE_IP` |

Configure these zones on your existing LAN resolver. Wildcard DNS and certificates support new names; each deployed application still needs an exact route, callback and permission grant. The separate application-platform Flux repository owns deployment naming and lifecycle. This base adds no developer-platform components or DNS server.

Internet exposure is **off by default**. An optional separate public gateway has its own IP, certificate and exact routes. `fuzzy.elektrorecykling.pl` can target the same Service as `foo.internal`; `bar.internal` remains private. Forwarding the private gateway to the Internet would defeat this boundary. See [DNS and migration](docs/domains.md) and [explicit public exposure](examples/public-exposure/README.md).

## Storage defaults

| StorageClass | Longhorn copies | Default for | Reclaim |
| --- | ---: | --- | --- |
| `longhorn` | 1 | Ordinary PVCs without a class | Retain |
| `longhorn-3` | 3, on distinct nodes/disks | Explicitly selected durable volumes | Retain |
| `longhorn-cnpg` | 1 per PostgreSQL instance | CNPG data and optional WAL storage when the class is omitted | Retain |

The chart does not create its own StorageClass. Kyverno mutates **CNPG Cluster resources**, before CNPG creates PVCs, preserving explicit nonempty choices. Three database instances on `longhorn-cnpg` have three PostgreSQL copies, rather than nine underlying Longhorn copies. Start with one database instance; use [the HA procedure](docs/high-availability.md) to change that. A one-copy volume can lose its data when its disk fails. Replication, retained PVs and snapshots are not off-cluster backups.

## Access defaults

`https://longhorn.admin.internal` requires Keycloak login **and** an OpenFGA `service:<hostname>#access` grant. No grants are installed automatically. Keycloak itself is the explicit native-authentication exception at `https://keycloak.admin.internal`; putting the login service behind its own login requirement would create a loop. Databases, the Kubernetes API and cluster management protocols use their native credentials and network boundaries.

Routes are centrally managed in `edge`. New application routes inherit their selected internal listener's security policy. Kubernetes admission blocks NodePort/extra LoadBalancer services, external IPs, alternate ingress APIs and per-route security overrides. Cilium blocks direct ingress into application pods and restricts the Longhorn UI, identity and authorization services. Kubernetes administrators, node root access and permission to port-forward are trusted infrastructure administration paths.

The default is for a trusted private LAN; cluster-internal identity requests use restricted Service endpoints. Cilium encrypts pod traffic between nodes. Do not expose node management ports to the Internet. Application egress remains allowed: this is not a complete hostile multitenancy sandbox.

## Operations and extension

- [Bootstrap](docs/bootstrap.md)
- [Identity, dynamic projects, agents and OpenFGA](docs/identity-access.md)
- [HA and node roles](docs/high-availability.md)
- [Storage, backups, recovery and upgrades](docs/operations.md)
- [GPU preparation](docs/gpu.md)
- [Validation and security acceptance checks](docs/validation.md)
- [Upstream release pins and references](docs/upstream.md)

The `examples/` directory is **not reconciled**. It contains a CNPG cluster, a protected application route, a GPU smoke job, optional kube-vip reconciliation, public certificates, explicit public exposure and backup examples. Enable only the pieces you need. Flux infrastructure namespaces and their RBAC are reserved for platform administrators; do not grant applications namespace-admin access there.

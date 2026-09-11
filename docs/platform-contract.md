# Contract for repositories built on the Elektro base

**Contract version 1.** This document describes the deployed base and the
obligations of another Flux repository adding services. It applies to `laptops`
and every profile reusing `clusters/base`. The live version is
`flux-system/cluster-settings.data.BASE_CONTRACT_VERSION`; this marker is not an
automatic compatibility negotiation mechanism. Record the base Git revision and
contract version tested by your repository, and review changes before promotion.

Start with the [standalone repository example](../examples/downstream-repository/README.md).
Its `AGENTS.md` carries the essential constraints into a new repository for human
and AI authors. The base contains identity infrastructure; the future **internal
developer platform**, project lifecycle, application code and deployments remain
outside this repository.

## Ownership and trust

| Owner | Resources and responsibilities |
| --- | --- |
| This base | k3s/Cilium, Flux controllers and `flux-system` sync, shared operators/CRDs, admission/network guards, storage classes, private DNS/CA/gateway, Keycloak/OpenFGA/Authorino and their databases, infrastructure metrics |
| Cluster administrator in this base profile | LAN/API/pool settings, optional BGP/API VIP/GPU, downstream Git source/attachment, credentials that let Flux read/decrypt the new repository, approval of public exposure |
| Downstream trusted platform repository | Application namespaces/workloads/Services, application databases/PVCs, narrowly scoped network allowances, exact HTTPRoutes and named ReferenceGrants, application Secrets and supported identity/permission provisioning |
| Human/upstream identity administration | Initial users/MFA, exact callback registration, service accounts, deliberate OpenFGA membership/grants and backup/restore of identity state |

Never apply an object already owned by another Flux Kustomization or Helm release.
In particular, do not copy `clusters/base`, foundation namespaces, the root
`cluster-settings`, operators, storage classes, `edge/platform`, `edge-tls`,
`protected-access`, `authorization/protected-apps`, or the base database Clusters.
To customize a base-owned HelmRelease, patch its **base Flux Kustomization's**
`spec.patches` in the selected base profile; a downstream Kustomization cannot
patch a file it does not build. Do not create a second owner of the live object.

The supplied attachment is for a **trusted platform repository**. A repository
that can submit Flux Kustomizations/HelmReleases with unrestricted reconciliation
has cluster-administration authority. This is not tenant isolation. Route authors
are also trusted: route ownership controls which backend a granted hostname means.
Branch protection and review therefore protect cluster access. For untrusted team
repositories, first design and enforce Flux service-account impersonation,
namespace/RBAC boundaries and restrictions on nested reconciliation objects;
setting a service account on a child that an unrestricted parent can rewrite is
not isolation. See [Flux multitenancy](https://fluxcd.io/flux/installation/configuration/multitenancy/).

Reserved infrastructure namespaces are `kube-system`, `kube-public`,
`kube-node-lease`, `flux-system`, `longhorn-system`, `cnpg-system`, `cert-manager`,
`kyverno`, `envoy-gateway-system`, `gpu-system`, `identity`, `authorization`, `edge`
and `monitoring`. They have exceptions to application isolation for platform
operations. Do not put application pods there to bypass a missing allowance.

## Attach once; reuse the existing Flux installation

Do **not** run `flux bootstrap github` for the application repository on this
cluster. The existing `flux-system` GitRepository/Kustomization must continue
pointing at the base. Add a uniquely named `GitRepository` and Flux `Kustomization`
using [downstream-source.yaml](../examples/downstream-source.yaml). The starter
uses `applications`, `applications-workloads` and `applications-routes`; use a
different prefix for another independently attached repository in the same cluster.

The Git source credential is a per-repository read-only deploy key in
`flux-system/applications-git`. Give GitHub only its public key. The Secret and
known-host data must exist before successful source reconciliation. The root path
is a literal `./clusters/NAME` selected in the base attachment. Base profile roots
do not perform Flux post-build substitution, so writing `${CLUSTER_NAME}` in that
attachment's root path does not automatically choose a profile.

The attachment's `postBuild.substituteFrom` supplies the live base settings when
building the downstream root. Each child Kustomization separately declares
`substituteFrom`; substitution and SOPS decryption are **not inherited**. Keep the
objects in `flux-system` for the demonstrated ConfigMap/Secret/dependency names.
Kustomize namespace/name transformers also transform nested object metadata: do
not blindly add `namespace:` or `namePrefix:` over mixed `edge`, application and
Flux resources. Use explicit namespaces and unique names.

Dependencies are names of live Flux Kustomizations, not file paths or repository
names. A child can depend on `access` even though it comes from the base source,
because both objects live in this cluster's `flux-system` namespace. Do not make
the base depend on downstream resources or a child depend on a parent waiting
for that child. [Flux Kustomization behavior](https://fluxcd.io/flux/components/kustomize/kustomizations/)

| Base readiness dependency | What it supplies |
| --- | --- |
| `controllers` | Longhorn, CNPG, cert-manager, Kyverno and Envoy Gateway controllers/CRDs |
| `admission` | Exposure guards and CNPG storage mutation, with an explicit check of Kyverno's nested readiness status |
| `storage` | All three Longhorn StorageClasses, after admission/controllers |
| `network` | Service pool, L2 announcements and default application ingress policy |
| `cluster-dns` | Pod resolution of the profile's internal suffix, after LAN DNS |
| `access` | Private gateway/identity/authorization dependencies and accepted security policy on all four application listeners |
| `monitoring` | Prometheus/Grafana/operator before additional monitors/rules |

Use `storage`, `network` and `cluster-dns` for ordinary workload/database stages;
use `access` **and the application workload stage** for routes. Add a separate
operator/CRD stage before a new Helm chart's custom resources. HelmRelease Ready
does not necessarily mean its operator-managed database/workload is Ready; wait
on the resources consumers actually need. The starter adds explicit HTTPRoute
Accepted/ResolvedRefs checks. None of these readiness conditions creates users,
callbacks, OpenFGA store/model IDs or grants. Finish base bootstrap part 5 before
expecting application access.

## Settings, names and APIs

Read `cluster-settings` or [the profile settings reference](clusters.md) instead
of copying LAN addresses, node names or `laptops` into application manifests.

| Value/interface | Downstream use |
| --- | --- |
| `BASE_CONTRACT_VERSION` | Check the supported contract before onboarding/upgrading |
| `CLUSTER_NAME` | Select the downstream `clusters/NAME` overlay; also the metrics cluster label |
| `INTERNAL_DOMAIN` | Build application hostnames; `internal` on laptops, possibly `production.internal` elsewhere |
| `IDENTITY_HOST` | Canonical issuer host, which may differ from the private Keycloak administration host after public opt-in |
| `FGA_STORE_ID`, `FGA_MODEL_ID` | Base gateway's store/model; not secrets, but must be initialized on this cluster |
| `PG_IMAGE` | Reviewed CNPG PostgreSQL image pin; using it opts into that shared pin's future changes. Own a separate reviewed pin when a database needs independent upgrades |
| `EDGE_IP`, `DNS_IP`, `LAN_CIDR`, `POD_CIDR`, `SERVICE_CIDR`, `CLUSTER_DNS` | Platform network settings, normally consumed through DNS/Services rather than embedded in applications |
| HTTPRoute / ReferenceGrant | `gateway.networking.k8s.io/v1` / `v1beta1` respectively |
| CNPG Cluster | `postgresql.cnpg.io/v1`; no additional PostgreSQL operator is needed |
| CiliumNetworkPolicy | `cilium.io/v2`, in the application's namespace |
| ServiceMonitor / PodMonitor / PrometheusRule | `monitoring.coreos.com/v1`; infrastructure monitoring restrictions apply |

No KeycloakRealm, OpenFGA-store or project-lifecycle CRD is installed. Keycloak
Admin API and OpenFGA REST API are the supported interfaces, with privileged
provisioning performed through a separately designed and scoped administration
flow. Do not invent CRDs or assume a ConfigMap import reconciles existing users.

Use one lowercase DNS label of at most 63 characters before the chosen group.
The [domain runbook](domains.md) defines reserved labels and randomized test names.

| Workload | Example for any profile | Gateway parent / listener |
| --- | --- | --- |
| Normal/production application | `demo.${INTERNAL_DOMAIN}` | `edge/platform`, `apps` |
| Test deployment | `demo-a7c92e.test.${INTERNAL_DOMAIN}` | `edge/platform`, `test` |
| Staging | `demo.staging.${INTERNAL_DOMAIN}` | `edge/platform`, `staging` |
| Administration | `tool.admin.${INTERNAL_DOMAIN}` | `edge/platform`, `admin` |
| Registered node | `NODE.hosts.${INTERNAL_DOMAIN}` | No application route; discovered node LAN IP |

`dns.admin.${INTERNAL_DOMAIN}` is reserved for the resolver and resolves to
`DNS_IP`. Existing Keycloak, Longhorn and Grafana hostnames are base-owned. Do not
reuse a hostname/path owned by another route: Gateway precedence is not a safe
ownership or random-name collision mechanism. Allocate test suffixes and clean
up route, callback and permission objects together in the downstream lifecycle.

## HTTP entry and identity

An application exposes a **ClusterIP Service**, an exact-host HTTPRoute in `edge`
with one parent/listener, and a ReferenceGrant in its own namespace naming that
Service. Routes must directly reference Services and contain no route/backend
filters. Header mutation/mirroring can undermine verified identity; rewrites,
redirects, CORS filters and other route extensions need a reviewed base design.
There is no HTTP port 80 redirect listener. Bind the container on a reachable pod
interface, choose the Service's correct targetPort and supply readiness probes.

Every ordinary request uses the base Keycloak issuer
`https://${IDENTITY_HOST}/realms/elektro`, audience `elektro-edge`, and OpenFGA check
`principal:<sub> access service:<lowercase hostname without port>`. Browser login
requires the **exact** `https://HOST/oauth2/callback` on Keycloak client
`elektro-edge`. Preserve its other callbacks and its existing secret. Then grant
the intended subjects/groups that exact hostname in OpenFGA. A route, DNS answer,
Keycloak login, `platform-admin` realm role or email address alone grants nothing.
Keycloak groups are not synchronized to OpenFGA groups.

The backend receives verified `X-Elektro-Subject` and the noncredential
`Authorization: GatewayAuthenticated` marker. Never trust client-supplied identity
headers on another entry path. Do not log cookies or authorization material; the
gateway's OIDC cookies remain sensitive even though the Authorization bearer is
replaced. The base admits a subject to a service; it does **not** enforce business
operations, object ownership, delegation intersections, token exchange policies,
CSRF protection or session revocation inside arbitrary applications. WebSocket or
streaming authorization occurs on the HTTP request/handshake, not every message.
See [identity and agents](identity-access.md).

Only Keycloak has a configured native-auth exception. A downstream annotation
cannot turn gateway authentication off for another OIDC-capable product.
Native integration needs explicit base listener/backend/admission changes and
its own audience, callbacks and authorization acceptance tests. A realm per
project is also not supported by the single-issuer gateway contract.

Application namespaces do not have default direct access to Keycloak's internal
Service or OpenFGA's API. The base FGA preshared key has broad administrative power;
do not distribute it, the gateway client secret, bootstrap-admin password, kubeconfig
or node join token to applications/agents. For fine-grained application FGA checks,
design the network/API authorization and credential scope explicitly; a new store
ID alone does not isolate the shared server API. Delegation/resource gateways must
use the application's existing supported integration and separately scoped identities.

## Network, TLS and public exposure

The cluster-wide application policy **isolates ingress** in non-infrastructure
namespaces and allows the Envoy namespace. It does not automatically allow
same-namespace application/database traffic, operator instance-manager requests,
scrapes, queues or replication. Add Cilium policy for each required caller and
port. Policies combine additively: a narrower allow does not remove an existing
broader allow. Namespace policy-editing authority is therefore trusted.
[Cilium policy semantics](https://docs.cilium.io/en/stable/security/policy/language/)

Use Service DNS (`SERVICE.NAMESPACE.svc.cluster.local`), not pod or node IP lists.
DNS egress is allowed by default; if you add egress isolation, allow cluster DNS
UDP/TCP 53 and required API/identity/registry/external flows. Ordinary egress is
otherwise allowed. NetworkPolicy is not a service identity system and this base
does not install a service mesh, SPIFFE identities or a hostile-tenant sandbox.

Wildcard DNS/certificates cover the four application groups automatically. The
LAN resolver uses a stable service IP, while Node records follow k3s discovery.
Pods can resolve internal names once `cluster-dns` is ready. DNS does not install
the private CA into clients or application containers. Distribute **only the CA's
public certificate** when a container must call internal HTTPS, preserving its
normal public trust store. Never mount the root CA private-key Secret in an app
or disable TLS verification. Workstation/node bootstrap DNS must remain usable
without this cluster.

Ingress, NodePort, arbitrary LoadBalancer/externalIPs, alternate route kinds,
hostNetwork/hostPort/hostPath/privileged application pods and route security
overrides are blocked. Disable these defaults in third-party Helm charts instead
of weakening admission. Kubernetes administrators, host root and port-forward
permissions remain privileged access paths; not every intra-cluster protocol is
an OIDC HTTP endpoint.

BGP is optional private LAN routing, not Internet publication. A public alias
requires the separate public gateway/IP/certificate, approved exact route and
AuthConfig host, callback/grant, reachable canonical issuer, external DNS and
deliberate firewall/NAT action. Follow [public exposure](../examples/public-exposure/README.md).
Internal and public hostnames are separate FGA objects even when sharing a backend.
Do not forward the private gateway from the Internet or place infrastructure
metrics behind a public application alias.

## Storage and databases

| StorageClass | Longhorn replicas | Use |
| --- | ---: | --- |
| `longhorn` | 1 | Cluster default for ordinary PVCs |
| `longhorn-3` | 3 | Explicit durable volumes; requires enough distinct storage nodes |
| `longhorn-cnpg` | 1 per PostgreSQL instance | Kyverno default for new CNPG data/WAL storage when the class is omitted |

All three reclaim policies are `Retain`. CNPG defaulting occurs on the Cluster CR,
not by guessing PVC labels. Explicit nonempty classes are preserved. Application
databases belong in application namespaces, with separate credentials; never use
the Keycloak/OpenFGA databases as shared application servers. Disable bundled
PostgreSQL charts when adopting CNPG.

Apply [cnpg-cluster.yaml](../examples/cnpg-cluster.yaml) together with
[cnpg-network.yaml](../examples/cnpg-network.yaml), adapting both selectors.
Allow the application and same-cluster PostgreSQL peers on TCP 5432, and the
`cnpg-system` operator on TCP 8000/5432. A schema-valid Cluster without this policy
is insufficient under the base ingress isolation. Use `CLUSTER-rw` as the write
Service; CNPG creates the application Secret `CLUSTER-app` and CA Secret
`CLUSTER-ca` in that namespace. Configure client TLS verification against the CA
where supported. Wait for the database and generated Secret before starting its
consumer. Review the [CNPG API](https://cloudnative-pg.io/docs/1.30/cloudnative-pg.v1/)
when selecting additional functionality.

One CNPG instance and one Longhorn replica are the small-cluster baseline, not
database HA. Add database replicas, anti-affinity, capacity and synchronous
replication deliberately. Do not scale a Deployment across nodes with one RWO
PVC and expect shared storage. The host path `/var/lib/longhorn` belongs to the
storage system; applications use PVCs, never direct host mounts.

Backups are optional and unconfigured until an external target/credentials and
schedules are supplied. Use the supported Barman plugin for CNPG and Longhorn
backup targets; snapshots/replicas on these same laptops are not external backups.
Keep one owner for operator and database backup patches. Protect Namespace,
database Cluster and important PVC resources from accidental pruning, and retain
encrypted credentials needed to recover them. `Retain` on a PV cannot prevent
data deletion caused by namespace/CR retirement, host wiping or application logic.

## Scheduling, GPU, metrics and lifecycle

Target application workloads with `elektro.local/workloads: 'true'`. Do not select
`k8s1/2/3` or add the dedicated-controller toleration to ordinary charts. Controller
nodes still run networking and the monitoring node exporter. The node installer
accepts DNS-label names up to 63 characters; workers may use DHCP. Stable server
addresses are an etcd/API prerequisite. Neither node count nor controller HA
implies application, storage, gateway or identity HA.

No inference server is installed. NVIDIA is optional: after driver/toolkit/device
plugin preparation, request `nvidia.com/gpu`, select the intended GPU labels and
use RuntimeClass `nvidia` where required. Other vendors need their own supported
plugin/runtime. Check allocatable resources and run [the GPU smoke job](../examples/gpu-smoke.yaml);
a label alone does not prove a functioning GPU. Model downloads, caches and PVCs
belong to the application repository.

The shared Grafana/Prometheus is for **cluster administrators**, not per-application
data isolation. Additional monitors/rules must be platform-reviewed objects in
`monitoring`, labelled `release: metrics`; monitors select the application namespace
explicitly and need a corresponding ingress allowance from the Prometheus pods.
Do not broaden discovery to arbitrary namespaces or grant ordinary users this
Grafana via folder/dashboard permissions. Use a separately designed isolated
metrics backend for application users. Alerts have no external notifications by
default. Logs/traces, CI runners, registries, autoscaling add-ons and application
secret-provider operators are not supplied by this base.

Use SOPS encryption and declare decryption on every consuming Flux Kustomization.
Only the public age recipient is needed to encrypt; keep private keys outside Git.
The starter reuses `sops-age`; a separately provisioned key may replace that reference.
Prefer encrypted Secret `data` values, or disable Flux substitution on objects
whose literal contents contain `${...}`. Kustomize itself does not perform Flux
substitution; preview with `flux envsubst --strict` before applying.

Retire routes first, then callbacks/grants, then stateless workloads. Back up and
explicitly retire stateful resources last. Deleting the downstream root with
pruning enabled can delete its child Kustomizations and their inventories; a
retained Namespace can still contain other resources being pruned. A host/data
wipe creates a new cluster identity: restore from backups intentionally or issue
new CA trust, credentials, user UUIDs and FGA IDs. Do not reuse a retired
`local/NAME/openfga-state.json` merely because the profile/hostnames are unchanged.

Before onboarding, validate the downstream overlays for at least two profiles,
dry-run against the pinned CRDs/admission, check one object owner per resource,
confirm DNS/TLS/backend readiness and test anonymous, invalid-token, no-grant and
granted access. Test direct-service denial from an ordinary pod, database
connectivity/backup restoration and GPU use where relevant. Base CI validates
this starter and its contract; it cannot validate an unseen application or your
physical LAN/storage. Use [the acceptance runbook](validation.md).

# Internal domains

## Naming contract

| Group | Example | Gateway listener | DNS address |
| --- | --- | --- | --- |
| Machines | `k8s1.hosts.internal` | None | That node's LAN IP |
| Test | `foo-a7c92e.test.internal` | `test` | `EDGE_IP` |
| Staging | `foo.staging.internal` | `staging` | `EDGE_IP` |
| Administration | `longhorn.admin.internal` | `admin` | `EDGE_IP` |
| Identity administration | `keycloak.admin.internal` | `identity` (native authentication) | `EDGE_IP` |
| Other / production applications | `foo.internal` | `apps` | `EDGE_IP` |

The table shows the existing `laptops` profile with `INTERNAL_DOMAIN: internal`. A [second profile](clusters.md) can use `production.internal`, preserving the same hosts/test/staging/admin groups beneath that suffix. Private certificates and admission rules use the chosen suffix; public exposure remains a separate opt-in.

The base deploys CoreDNS on a stable LAN `DNS_IP`. Configure the upstream resolvers in the tracked settings, then point clients or your router's conditional `.internal` forwarding at it. Node names and IPs come from k3s's automatically maintained `NodeHosts` data. See [LAN DNS setup](dns.md). The four application wildcards resolve to `EDGE_IP`; the reserved `dns.admin.internal` record resolves to `DNS_IP`.

CoreDNS serves `hosts.internal` as a separate authoritative zone containing only exact machine records; unknown names return NXDOMAIN. Never point `*.hosts.internal` at the gateway. Configure workstation/client DNS, including over VPN, as described in the DNS runbook. Cluster hosts should retain independent bootstrap DNS; pods receive the supported k3s internal-zone import. Applications using encrypted/public DNS may need an internal-zone exception. `/etc/hosts` can bootstrap a few exact names but cannot implement wildcard DNS.

Node names may be any valid unique Kubernetes node names; `k8s1`, `k8s2`, `k8s3` are examples. These DNS aliases do not rename Kubernetes Nodes. Server installs include `NODE.hosts.INTERNAL_DOMAIN` in their API certificate SANs. Keep the bootstrap API address independently reachable; in-cluster DNS is not available before bootstrap. Worker DNS records do not make workers API servers. Kubernetes Service discovery remains `*.svc.cluster.local`.

## Deployments in the separate application repository

Use one DNS label before the chosen suffix: lowercase letters, digits and hyphens, at most 63 characters. `hosts`, `admin`, `test` and `staging` are reserved under `.internal`. HTTPRoutes are exact-host resources in namespace `edge`, with one parent reference to `platform` and the corresponding listener above. Application Services and a narrowly named ReferenceGrant live in the application's namespace. The [downstream repository starter](../examples/downstream-repository/README.md) shows that contract for any profile. Route/backend filters are blocked because they can alter verified identity or mirror requests; extensions such as rewrites or CORS need a reviewed base design.

For tests, the separate application platform can allocate `APP-RANDOM.test.internal`, for example two simultaneous `foo-a7c92e.test.internal` and `foo-b41d08.test.internal` deployments. Generate a DNS-safe suffix, check uniqueness and retry collisions; truncate the application prefix to fit the label limit. A random name is not an authorization mechanism. Each deployment has its own exact HTTPRoute, Keycloak callback and OpenFGA service object. Delete its route, callback and grants when retiring it. The base does not allocate names or install a lifecycle controller.

For staging, start with a deliberate name such as `foo.staging.internal`; an additional candidate can use `foo-candidate.staging.internal`. Renaming is supported by adding the new exact route/callback/grants, migrating users, and retiring the old entries. Production uses a selected name such as `foo.internal`. All groups inherit the same fail-closed login/permission policy. Sibling cookies are host-only; staging/test do not acquire production grants.

Gateway API wildcard hostname matching can span multiple labels, while TLS wildcard certificates cover a single label. The admission policy therefore enforces the group and label depth on every route. Certificates include all four wildcards rather than assuming `*.internal` also covers `foo.test.internal`. See the [Gateway API hostname specification](https://gateway-api.sigs.k8s.io/docs/concepts/hostnames/).

The application platform's Flux reconciliation should depend on the base `access` Kustomization before adding routes. Its lifecycle integration uses Keycloak/OpenFGA's supported APIs; changing identity records alone does not create Kubernetes routes. Keep those deployment/platform resources in its own repository. Access to `edge`, ReferenceGrants and identity administration is a trusted platform permission, not a permission for arbitrary application pods.

Internet access is a separate, explicit configuration change; see [public exposure](../examples/public-exposure/README.md).

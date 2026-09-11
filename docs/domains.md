# Internal DNS and existing-cluster migration

## Naming contract

| Group | Example | Gateway listener | DNS address |
| --- | --- | --- | --- |
| Machines | `k8s1.hosts.internal` | None | That node's LAN IP |
| Test | `foo-a7c92e.test.internal` | `test` | `EDGE_IP` |
| Staging | `foo.staging.internal` | `staging` | `EDGE_IP` |
| Administration | `longhorn.admin.internal` | `admin` | `EDGE_IP` |
| Existing identity administration | `keycloak.admin.internal` | `identity` (native authentication) | `EDGE_IP` |
| Other / production applications | `foo.internal` | `apps` | `EDGE_IP` |

The table shows the existing `laptops` profile with `INTERNAL_DOMAIN: internal`. A [second profile](clusters.md) can use `production.internal`, preserving the same hosts/test/staging/admin groups beneath that suffix. Private certificates and admission rules use the chosen suffix; public exposure remains a separate opt-in.

The base deploys CoreDNS on a stable LAN `DNS_IP`. Configure the upstream resolvers in the tracked settings, then point clients or your router's conditional `.internal` forwarding at it. Node names and IPs come from k3s's automatically maintained `NodeHosts` data. See [LAN DNS setup](dns.md). The four application wildcards resolve to `EDGE_IP`; the reserved `dns.admin.internal` record resolves to `DNS_IP`.

CoreDNS serves `hosts.internal` as a separate authoritative zone containing only exact machine records; unknown names return NXDOMAIN. Never point `*.hosts.internal` at the gateway. Configure workstation/client DNS, including over VPN, as described in the DNS runbook. Cluster hosts should retain independent bootstrap DNS; pods receive the supported k3s internal-zone import. Applications using encrypted/public DNS may need an internal-zone exception. `/etc/hosts` can bootstrap a few exact names but cannot implement wildcard DNS.

Node names may be any valid unique Kubernetes node names; `k8s1`, `k8s2`, `k8s3` are examples. These DNS aliases do not rename Kubernetes Nodes. Fresh server installs include `NODE.hosts.INTERNAL_DOMAIN` in their API certificate SANs. Existing servers continue using their configured API address. Do not reinstall them merely to add a DNS alias; add a SAN using the normal k3s configuration and certificate-maintenance procedure before changing a kubeconfig to that alias. Worker DNS records do not make workers API servers. Kubernetes Service discovery remains `*.svc.cluster.local`.

## Deployments in the separate application repository

Use one DNS label before the chosen suffix: lowercase letters, digits and hyphens, at most 63 characters. `hosts`, `admin`, `test` and `staging` are reserved under `.internal`. HTTPRoutes are exact-host resources in namespace `edge`, with one parent reference to `platform` and the corresponding listener above. Application Services and a narrowly named ReferenceGrant live in the application's namespace. The existing `examples/protected-app` shows that contract.

For tests, the separate application platform can allocate `APP-RANDOM.test.internal`, for example two simultaneous `foo-a7c92e.test.internal` and `foo-b41d08.test.internal` deployments. Generate a DNS-safe suffix, check uniqueness and retry collisions; truncate the application prefix to fit the label limit. A random name is not an authorization mechanism. Each deployment has its own exact HTTPRoute, Keycloak callback and OpenFGA service object. Delete its route, callback and grants when retiring it. The base does not allocate names or install a lifecycle controller.

For staging, start with a deliberate name such as `foo.staging.internal`; an additional candidate can use `foo-candidate.staging.internal`. Renaming is supported by adding the new exact route/callback/grants, migrating users, and retiring the old entries. Production uses a selected name such as `foo.internal`. All groups inherit the same fail-closed login/permission policy. Sibling cookies are host-only; staging/test do not acquire production grants.

Gateway API wildcard hostname matching can span multiple labels, while TLS wildcard certificates cover a single label. The admission policy therefore enforces the group and label depth on every route. Certificates include all four wildcards rather than assuming `*.internal` also covers `foo.test.internal`. See the [Gateway API hostname specification](https://gateway-api.sigs.k8s.io/docs/concepts/hostnames/).

The application platform's Flux reconciliation should depend on the base `access` Kustomization before adding routes. Its lifecycle integration uses Keycloak/OpenFGA's supported APIs; changing identity records alone does not create Kubernetes routes. Keep those deployment/platform resources in its own repository. Access to `edge`, ReferenceGrants and identity administration is a trusted platform permission, not a permission for arbitrary application pods.

## Migrate an existing bootstrap

This update preserves the configured API address, pod CIDR and load-balancer IPs. Check that `EDGE_IP`, `LB_START` and `LB_STOP` are on your real LAN and outside DHCP; DNS records must use your chosen values, not copied documentation addresses.

1. Configure internal DNS first and retain your admin kubeconfig/SSH recovery access. Keep the current public root CA trusted; the existing CA issues a replacement `edge-tls` certificate with the new SANs.
2. Before switching, open the current Keycloak admin URL. In realm `elektro`, client `elektro-edge`, add `https://longhorn.admin.internal/oauth2/callback` to **Valid redirect URIs**, preserving other callbacks still in use. Do the same for applications moving names. An existing realm is not updated by the first-start ConfigMap import. If you have not created the realm yet, the new import already contains the Longhorn callback.
3. If OpenFGA is initialized, grant the intended subjects/groups `access` on `service:longhorn.admin.internal` and the exact new application names. Preserve the existing store/model IDs. Old hostname grants do not automatically apply to new names. If you have not done bootstrap part 5, use the updated first-grant instructions there.
4. Pull the change, retain your cluster-specific settings and encrypted secrets, then let Flux reconcile. `IDENTITY_HOST` defaults to `keycloak.admin.internal`; `PUBLIC_EDGE_IP` stays `NOT_CONFIGURED`. If the old `BASE_DOMAIN` key remains in a local branch after merging, remove it: the new manifests do not use it.

```sh
git pull --ff-only
flux reconcile source git flux-system
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization admission
flux reconcile kustomization certificates
flux reconcile kustomization identity
flux reconcile kustomization edge
flux reconcile kustomization access
flux reconcile kustomization routes
flux get kustomizations
```

The dependency graph provides the same ordering during normal reconciliation. Check the access policy is Accepted on all four protected listeners before diagnosing application access. Existing browser sessions/tokens use the old issuer; sign in again at the new names. Keycloak administration is `https://keycloak.admin.internal/admin`; Longhorn is `https://longhorn.admin.internal`. Run `scripts/verify-access.sh` with the new name. Retire old DNS, callbacks and FGA grants after migration. Expect a maintenance interruption while certificates, issuer and routes converge; no authentication bypass is needed.

Internet access is a separate, explicit configuration change; see [public exposure](../examples/public-exposure/README.md).

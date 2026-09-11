# Explicit public exposure (disabled by default)

Nothing in this directory is included by `clusters/laptops`. It contains configuration for the **existing** Envoy Gateway, cert-manager, Keycloak and Authorino, not a new software stack or application platform. Copy and adapt these resources in your separate application/infrastructure Flux repository when public exposure is actually wanted.

## Independent names and entry points

| Client hostname | Gateway / IP | Backend in this example |
| --- | --- | --- |
| `foo.internal` | `platform` / private `EDGE_IP` | `app-foo/foo:8080` |
| `fuzzy.elektrorecykling.pl` | `public` / separate `PUBLIC_EDGE_IP` | The same `app-foo/foo:8080` |
| `bar.internal` | `platform` / private `EDGE_IP` | Its own private Service; no public route |
| `login.elektrorecykling.pl` | `public` / `PUBLIC_EDGE_IP` | Keycloak's `elektro` login endpoints only |
| `keycloak.admin.internal` | `platform` / private `EDGE_IP` | Keycloak administration, available through LAN/VPN |

Private and public names need not have matching labels. Applications must support their chosen external origins, redirects and cookie behavior; the example does not rewrite a public Host into its private alias. Permissions use the hostname the client requested, so internal access does not automatically grant public access.

Use a second reserved LAN load-balancer address from the Cilium pool, distinct from `EDGE_IP`. Cilium already allocates and advertises services belonging to the two managed gateways. Envoy Gateway creates a separate proxy for each Gateway; the existing controller manages both. `PUBLIC_EDGE_IP` is the public proxy's **LAN** address when a router performs NAT, not the router's WAN address. Exposing the private proxy instead is unsafe: clients can send an internal SNI/Host even if that name is absent from public DNS.

## Enable deliberately

1. Pick the exact aliases and reserve the second IP outside DHCP. In the base repository's `clusters/laptops/settings.yaml`, eventually set `PUBLIC_EDGE_IP` to it. Leave `EDGE_IP` private. Check both IPs are within `LB_START`–`LB_STOP` and are unused. The sample `192.168.2.241` is suitable only if that is your configured LAN/pool.
2. Prepare the existing cert-manager [DNS-01 issuer](../public-certificates/README.md), encrypted provider secret and exact public certificate SANs. `certificate/resources.yaml` requests a separate `public-edge-tls`; private `edge-tls` remains signed by the private CA. Do not enable NAT yet.
3. Plan the canonical login-host migration below, then set `IDENTITY_HOST: login.elektrorecykling.pl` (or your selected login name) in the base settings. Reconcile base `admission`, `identity` and `access` as part of this maintenance change. Public objects are denied while `PUBLIC_EDGE_IP` is `NOT_CONFIGURED`, equals `EDGE_IP`, or the identity host is still internal. Setting these values alone installs no public gateway or route.
4. Copy this directory to `infrastructure/public-exposure` in your separate repository. Adapt all example aliases and the Service/ReferenceGrant in `routes/resources.yaml` to a deployed application. No `foo` workload or Service is installed here. Use `reconciliation.yaml` as the Flux dependency example; its `GitRepository` source is named `applications`. Change that source name/path to your repository's actual values. Add these four Flux Kustomizations to that repository's reconciled root only when ready to opt in. Keep one owner of each resource: if `foo.internal` already has a route and grant, retain those in their existing owner and add only its public route here.
5. Register exact callbacks `https://foo.internal/oauth2/callback` and `https://fuzzy.elektrorecykling.pl/oauth2/callback` on `elektro-edge`, preserving existing ones. Add the external alias to `protected-public-apps.spec.hosts`. Grant appropriate subjects/groups `access` on each intended `service:HOST` in OpenFGA. An omitted public AuthConfig host or missing tuple denies access. Neither wildcard DNS nor an internal grant publishes an application.
6. Wait for certificate Ready, Gateway Programmed, both security policies Accepted and route references resolved. The example orders certificate → public gateway → public access → routes; routes also depend on base `access`. Validate the login flow, valid/invalid tokens, FGA denials, and the private/public boundary from the LAN using exact test DNS records first.
7. **Last**, publish only the chosen public DNS records pointing at your WAN address and permit/forward TCP 443 to `PUBLIC_EDGE_IP`. With routed public IPs, apply the equivalent firewall rule to the public proxy only. No port 80 is needed with DNS-01. Expose no management ports and no private `EDGE_IP`. If IPv6 is enabled, apply the same boundary there; absence of IPv4 NAT is not an IPv6 firewall. Test from outside your LAN before handing out links.

Creating each exact HTTPRoute with `elektro.local/exposure: public` is an explicit per-application exposure decision. Admission rejects wildcard/public-internal routes, missing labels, infrastructure backends on the public apps listener, and route-specific authentication overrides. The public `apps` listener has no wildcard domain allowlist because unrelated real domains may be used; exact HTTPRoutes, certificate SANs, public AuthConfig hosts and FGA grants control which names work. Adding a DNS record alone creates none of these.

## Canonical identity and private administration

An internet browser cannot log in at a LAN-only `.internal` issuer. Use one canonical externally reachable `IDENTITY_HOST` for realm `elektro`; both gateways validate that exact issuer. Keycloak's admin hostname remains `https://keycloak.admin.internal`. Configure LAN clients to resolve the public login name to `PUBLIC_EDGE_IP` (split DNS) if your router cannot hairpin its WAN address. Do not point the public login name at the private proxy, whose listeners and certificate contain only internal names.

Before changing the global hostname, set the **master realm's Frontend URL** to `https://keycloak.admin.internal` through Keycloak's supported administration settings/API. This keeps administrative authentication on the private hostname as well as the admin console/API. Check any explicit realm `elektro` Frontend URL is unset or matches the selected public issuer. Preserve recovery kubeconfig/SSH access, and verify master-realm login through the private hostname after switching. Existing tokens/sessions reference the old issuer and need a new login. Clients using discovery must use the new issuer; update Google/social-provider callback URLs and any native OIDC clients at the same time. These are existing-Keycloak configuration changes, not an additional identity service or reconciler.

The public identity route forwards only `/realms/elektro` and `/resources` to Keycloak. It does not expose `/admin`, `/realms/master`, `/health` or `/metrics`; `hostname-admin` alone would not provide that restriction. OIDC discovery is available under `/realms/elektro/.well-known/openid-configuration`. Other protocols requiring root `/.well-known` or additional realms need an explicit path/guard review. See [Keycloak hostname configuration](https://www.keycloak.org/server/hostname) and [reverse-proxy path restrictions](https://www.keycloak.org/server/reverseproxy).

## Check and retire exposure

Use a test host that resolves both application names to their intended gateways. Confirm the approved alias reaches the intended Service only after login and an exact FGA grant. Then explicitly send `foo.internal`, `bar.internal`, `longhorn.admin.internal` and `keycloak.admin.internal` as SNI/Host to `PUBLIC_EDGE_IP`; none may return private application/admin data. Test the restricted Keycloak paths on the public login hostname. A TLS error, unknown-host response or denial is expected for private names; DNS secrecy alone is not a test.

To unpublish one application, remove its public route first; remove its public AuthConfig host, callback, grants, DNS and unused certificate SAN afterward. Its internal route can remain. To retire all exposure, remove WAN firewall/NAT access, delete public routes and gateway, then retire its policy/certificate. The existing admission guard prevents deleting SecurityPolicies until you deliberately adjust that guard after the gateway is gone; the policy also opts out of Flux pruning. Leaving an unused protective policy in place is safe. Revert the canonical issuer only as a coordinated identity migration, not as a side effect of deleting an application.

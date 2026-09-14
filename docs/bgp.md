# BGP-only access from the node LAN

Cilium allocates service IPs and advertises only the private gateway and LAN DNS
as two `/32` routes to the directly connected LAN router. L2 service and pod
announcements are disabled. Every profile inherits the `bgp` Flux stage; there
is no optional attachment or enable flag to maintain.

Only stable control-plane nodes peer with the router. Workers can join, leave
and use DHCP without router edits. A controller can forward to a backend on any
worker using the existing VXLAN tunnel, `externalTrafficPolicy: Cluster` and
SNAT. BGP does not replace the CNI, install node routes or advertise Pod CIDRs,
ClusterIPs, the entire pool, or the optional public gateway. Both advertisements
carry `no-advertise` so the receiving router must not propagate them to other
BGP peers. Keep the LAN router's firewall private and WAN forwarding disabled;
BGP communities are routing policy, not a client firewall.

[Cilium BGP resources](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/)
define these selectors, host routes, communities and forwarding semantics.

## Address plan

| Setting | laptops example | Purpose |
| --- | --- | --- |
| `LAN_CIDR` | `192.168.2.0/24` | Existing physical node/client LAN |
| `API_HOST` | `192.168.2.153` | Stable initial controller; separate from service VIPs |
| `BGP_ROUTER_IP` | `192.168.2.1` | Actual BGP router on that same LAN |
| `BGP_PEER_ASN` / `BGP_LOCAL_ASN` | `64512` / `64513` | Router / cluster private ASNs |
| `LB_CIDR` | `10.44.0.0/24` | Unused routed service subnet, off-link for clients |
| `LB_START`–`LB_STOP` | `10.44.0.240`–`10.44.0.249` | Cilium allocation range within that subnet |
| `EDGE_IP` / `DNS_IP` | `10.44.0.240` / `10.44.0.242` | Distinct HTTPS / DNS service VIPs |

These are example inputs, not discovered router settings or free addresses.
Verify the actual mask, router ASN, DHCP reservations and all LAN/VPN/routed
networks. `LB_CIDR` must not overlap any of them, or the installed Pod/Service
ranges. Do not put the service subnet on a router/node interface or distribute
it as a client connected subnet. It needs no DHCP scope or per-client routes.
The router learns only the two host routes, not the whole `LB_CIDR`.

With L2 disabled, an on-link VIP would fail: a client would ARP directly for it
instead of consulting the router's BGP route. The off-link VIPs make normal LAN
clients use their existing default gateway. That gateway must be the configured
BGP router (or already route to it). Windows needs no BGP software or routes to
individual nodes. Existing DHCP, router DNS and private-CA trust suffice.

`scripts/validate-cluster.py` checks the complete pool, disjoint ranges, VIP/API
separation, directly connected router and private ASNs whenever a profile is
exported, imported or bootstrapped. It cannot discover other networks or leases.
Do not change a running cluster's Pod/Service CIDRs to adopt these examples.

## Generate the router setup

The supplied generator targets an EdgeRouter Pro using EdgeOS, following
[Ubiquiti's BGP configuration](https://help.uisp.com/hc/en-us/articles/22591213900823-EdgeRouter-Border-Gateway-Protocol-BGP).
It adds no router software, controller or background process. Different router
platforms require equivalent native configuration. EdgeOS dynamic neighbor ranges
are not assumed; only stable controllers need explicit neighbors.

Edit `clusters/laptops/settings.yaml` once, then on the administrator workstation:

```sh
mkdir -p local/laptops
bash scripts/configure-cluster.sh --export laptops > local/laptops/cluster.env
# Before a cluster exists, specify each real, stable controller address:
python3 scripts/configure-bgp.py laptops --node-ip 192.168.2.153 \
  > local/laptops/edgerouter-bgp.txt
# Or, with this cluster's kubeconfig, discover all control-plane InternalIPs:
python3 scripts/configure-bgp.py laptops --discover > local/laptops/edgerouter-bgp.txt
```

Choose one generator invocation. `--node-ip` is repeatable for HA controllers
and contacts no cluster. `--discover` verifies the kubeconfig API endpoint and,
when present, the live cluster's profile identity before listing controllers.
It accepts one IPv4 InternalIP per controller and rejects missing, duplicate or
off-LAN peers. Discovery does not prove DHCP stability; reserve those addresses.
Neither mode modifies the router, cluster or tracked profile.

Review the generated file against a backup of the router's configuration. It
stages exact import filters for `EDGE_IP/32` and `DNS_IP/32`, a deny-all export
filter, passive controller neighbors and a two-prefix limit. Use the router's
existing ASN and router-id if BGP is already configured; omit the generated
router-id command if preserving a different existing ID. Generated policy names
`ELEKTRO-<PROFILE>-IN/OUT` must be reserved for this cluster, with no extra permit
rules. Apply the file's commands in the EdgeOS CLI. They end at `compare` so you
can inspect the diff, then execute `commit`, `save`, `exit` yourself.

The generated configuration has no redistribution, default/Pod/Service route,
static route, NAT, WAN firewall change, or eBGP multihop. If a LAN-local router
firewall drops BGP, allow TCP 179 **from the configured controller IPs to the
router's LAN IP**, with established return traffic, in the existing LAN-local
rule set before its drop rule. Forward DNS/HTTPS from the node LAN to the routed
VIPs through your existing LAN firewall; do not open these addresses to the WAN
or other client networks. Cilium initiates sessions; nodes need no listening BGP
port. Preserve other neighbors and their policies, including export filtering.

Bootstrap Cilium and Flux using [the main runbook](bootstrap.md). Both use the
same BGP-enabled, L2-disabled values. Flux watches the Cilium values ConfigMap;
the chart rolls agents/operators when configuration changes. No separate Helm
upgrade or manual restart is needed during normal reconciliation. The `bgp`
stage waits for `network`/Cilium CRDs, but does not wait for peer establishment:
DNS/gateway Services must be created before their routes can be advertised.
A green Flux stage alone therefore does not prove LAN connectivity.

After direct DNS acceptance, use `--dns-forwarding` to include the router's
conditional forwarder for this profile's suffix, or follow [the DNS runbook](dns.md#edgerouter-conditional-forwarding).
Keep clients on router DNS and keep cluster hosts' bootstrap DNS independent.
If the router rejects private DNS responses, use the existing suffix-specific
DNS rebind exception procedure; do not disable protection globally.

## Migrate an existing L2 installation

This changes service addresses and rolls Cilium; schedule an interruption and
keep administrative access through the physical controller/API endpoint.
Do not merge/promote the change into the branch watched by Flux until the router
and client routing prerequisites are ready.

1. Record current `EDGE_IP`, `DNS_IP`, LB pool, Cilium values and router/DNS
   configuration for rollback. Verify a direct node/API connection and reserve
   an unused off-link `LB_CIDR`. Keep installed Pod/Service networks unchanged.
2. Update the profile with that subnet, pool, two distinct VIPs and actual router
   IP/ASNs. Remove retired `BGP_ENABLED` and `LAN_INTERFACE_REGEX` overrides. If
   optional BGP was previously attached as `clusters/NAME/bgp.yaml`, remove that
   file/resource while adopting the shared stage of the same name; never retain
   two Kustomize definitions/owners of `flux-system/bgp`.
3. Generate and stage the router configuration for the new VIPs and stable
   controller peers. Confirm the router's existing policies and TCP 179 access,
   then commit/save the router changes. Routes appear after Cilium advertises them.
4. Promote the reviewed Git change and reconcile through the direct API:

   ```sh
   flux reconcile kustomization flux-system --with-source
   flux reconcile kustomization cilium --timeout=20m
   kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
   kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m
   flux reconcile kustomization network
   flux reconcile kustomization bgp
   flux reconcile kustomization dns
   flux reconcile kustomization edge --timeout=20m
   ```

   Flux prunes its former `CiliumL2AnnouncementPolicy/lan`. Other manually managed
   L2 policies must be retired by their owner; the disabled agent feature prevents
   all Cilium L2 announcements. Pool updates can reassign Service IPs; wait for
   the actual DNS and gateway allocations to match the profile.
5. Verify both BGP `/32`s and direct DNS/HTTPS using the new VIPs. Update router
   suffix forwarding and any direct-DNS DHCP/NRPT/client settings from the old
   `DNS_IP` to the new one. Remove the exact old conditional-forwarding entry
   before adding the replacement; do not leave both servers for the same suffix.
   Re-export ignored env files and clear client DNS caches. Internal DNS records
   follow `EDGE_IP`; hostname-based certificates and application routes remain
   usable. Keep existing CA/identity state.
6. Remove obsolete service routes/filters after acceptance. If migration fails,
   revert the Git change and restore the recorded router/client DNS configuration
   together, then verify old Service allocations and reachability. Do not rebuild
   the cluster or reuse a guessed old VIP as a rollback method.

The optional kube-vip API example is a separate **ARP-based API HA** mechanism
and is not enabled by this setup. If all virtual IPs must avoid ARP announcements,
use the physical API endpoint or an existing external TCP load balancer for HA;
see [HA operations](high-availability.md).

## Addresses, DNS and acceptance

On EdgeOS, using your profile values:

```text
show ip bgp summary
show ip bgp neighbors 192.168.2.153
show ip route 10.44.0.240
show ip route 10.44.0.242
```

Expect established controller peers and exactly the two `/32` routes via their
physical LAN IPs, with `no-advertise` preserved. Verify no propagation to other
BGP peers and no public gateway/Pod/ClusterIP routes. Cilium requests 9-second
hold/3-second keepalive timers and disables graceful restart; check the negotiated
timers and disable stale-route retention for these peers on the router. These
bound one detection delay, not end-to-end recovery time.

```sh
kubectl -n kube-system get service lan-dns -o wide
kubectl -n envoy-gateway-system get services -o wide
kubectl get ciliumbgpclusterconfigs,ciliumbgpnodeconfigs
kubectl get ciliuml2announcementpolicies
kubectl -n kube-system get configmap cilium-config \
  -o jsonpath='{.data.enable-bgp-control-plane}{"\n"}{.data.enable-l2-announcements}{"\n"}'
dig @10.44.0.242 grafana.admin.internal +short
dig @10.44.0.242 k8s2.hosts.internal +short
dig @192.168.2.1 grafana.admin.internal +short
```

Expect BGP `true`, L2 `false` (or an absent false key), no old `lan` L2 policy,
gateway DNS `10.44.0.240`, and the node's current LAN address. Test HTTPS by
hostname with the existing trusted private CA from an ordinary LAN client.
Unlike the former on-link pool, that client's traffic now uses the router.
Confirm an unapproved network cannot query DNS or reach the private gateway.

During an approved hardware acceptance window with surviving API quorum and
backends, test a controller loss and observe route withdrawal/new next hop and
fresh DNS/HTTPS requests. There is **no L2 fallback** if all peers fail. A lone
controller is not HA; add two stable controllers and regenerate the router
snippet with `--discover` for quorum/failover. Existing connections can break.
`Cluster` advertisement does not withdraw just because an application has no
ready endpoints. Remove retired controller neighbors explicitly; regeneration
never deletes router configuration. Consult [Cilium failure scenarios](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/#failure-scenarios).

Repository checks cover configuration and manifests. They do not execute EdgeOS
commands or test sessions, switches, client firewalls or physical failover.

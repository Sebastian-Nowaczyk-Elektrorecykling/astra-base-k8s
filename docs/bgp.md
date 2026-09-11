# EdgeRouter Pro and optional BGP

The EdgeRouter Pro supports ordinary IPv4 eBGP in EdgeOS. Ubiquiti's
[v2.0.9 release notes](https://dl.ui.com/firmwares/edgemax/v2.0.9/changenotes-v2.0.9.txt)
include BGP fixes, its [hotfix.2 notes](https://dl.ui.com/firmwares/edgemax/v2.0.9-hotfix.2/changelog.txt)
list the ERPro-8, and its [EdgeRouter BGP guide](https://help.uisp.com/hc/en-us/articles/22591213900823-EdgeRouter-Border-Gateway-Protocol-BGP)
documents static neighbors, prefix lists and passive peers. This setup uses that
subset. These are EdgeOS commands; UniFi's FRR upload instructions do not apply.
The configuration has not been exercised on your physical router.

Dynamic DHCP neighbor ranges on this firmware have not been verified. The
optional configuration therefore peers only with **stable controller/hybrid
addresses**. You already need those stable for etcd/API access. Start with one
router neighbor for k8s1; add two when adding HA controllers. Ordinary workers can
join, leave and use DHCP without BGP or router edits. No FRR installation, router
boot script, routing operator or custom controller is needed.

## Minimum router configuration: default L2

BGP is **off by default** and its reconciliation example is not included in any
profile. For machines on the same wired LAN, the minimum is:

1. Keep the initial controller/API address stable, initially `192.168.2.153`.
2. Exclude `192.168.2.240`–`192.168.2.249` from all DHCP ranges and other static
   allocations. It is one pool exclusion, not a reservation for every worker or
   virtual IP. Verify existing leases have released those addresses before use.
3. After DNS passes the bootstrap checks, preferably keep clients using the
   router's DNS and add [conditional forwarding for `.internal`](dns.md#edgerouter-conditional-forwarding).
   A single test workstation can instead use a [Windows suffix rule](windows-clients.md#option-b-one-workstation-with-a-suffix-rule)
   or `192.168.2.242` as its resolver. Keep external DNS independent of the cluster
   so hosts can boot while it is absent.

Those addresses assume **`192.168.2.0/24`**. For a different `192.168.x.x` network,
edit the profile to match the actual prefix/mask; `/16` is not implied by the
address beginning with `192.168`. Keep Pod and Service ranges on `10.42.0.0/16`
and `10.43.0.0/16` unless another routed network already uses them.
The [settings validator](../scripts/validate-cluster.py) checks overlaps and the
entire pool against `LAN_CIDR`. It cannot inspect router leases or detect a free IP.

The router's existing DHCP service suffices; see its [official DHCP settings](https://help.uisp.com/hc/en-us/articles/22591175599639-EdgeRouter-DHCP-Server).
Do not add a public secondary DNS resolver on clients expecting internal names:
clients may query either server. Use the cluster's `DNS_UPSTREAMS` for external
queries. Leave WAN port forwarding and inbound access disabled. There are no
required BGP, static service-route or per-application DNS entries for this mode.

## L2 and BGP together on this LAN

Both mechanisms can deliver traffic to the same Service VIP in this design.
They operate at different points in the path; this is not two competing ARP
responders. The following assumes the profile's pool is on the nodes' wired LAN
and the client's actual subnet mask/routes agree with the router:

| Client path | BGP off | BGP established |
| --- | --- | --- |
| Windows on the VIP's subnet | ARP selects the L2 lease holder | Still ARP to the L2 holder; normally bypasses the router |
| Router itself, including forwarded DNS queries | Connected LAN route, then ARP for the VIP | More-specific `/32` selects a controller next hop |
| Allowed client on another VLAN/VPN | Router's connected LAN route, then ARP | Router's BGP `/32`, then the selected controller |

L2 may select a worker while BGP selects a controller. Both can forward to any
ready Service backend: keep `externalTrafficPolicy: Cluster`, the current VXLAN
tunnel and explicit `loadBalancer.mode: snat`. Do not set `loadBalancerClass` to
either announcement implementation: leaving it unset allows both to select the
Service. `Local` is incompatible with Cilium L2; a dedicated controller may have
no local DNS/gateway pod. See [L2 requirements](https://docs.cilium.io/en/stable/network/l2-announcements/)
and [BGP Service selection](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/#load-balancer-class).

SNAT sends cross-node replies back through the receiving node, avoiding a direct
server-return dependency. The backend may see a node IP; access decisions use the
verified identity, not the original client IP. Do not introduce DSR or use backend
source IPs as an authorization boundary without redesigning/testing that path.
See [Cilium forwarding modes](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#direct-server-return-dsr).

There is one significant failover trap: a stale BGP `/32` still wins over the
connected LAN route. A working L2 holder cannot rescue router-originated/routed
traffic until that route is withdrawn. The optional peer now requests a 9-second
hold time and 3-second keepalive, replacing 90/30; confirm the negotiated values
with `show ip bgp neighbors 192.168.2.153`. Graceful restart is disabled on Cilium
to avoid retaining stale routes through a hard laptop failure. Leave stale-route
retention disabled for these peers on the router too. These settings reduce one
failure-detection delay; they do not promise nine-second application recovery.
See [BGP timers](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/#timers)
and [failure scenarios](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/#failure-scenarios).

With no remaining BGP route, this router can use its connected LAN route and L2
again, provided another eligible Cilium node and the backends remain healthy.
L2 election also requires a working Kubernetes API; one-controller loss is not
quorum HA. Existing connections can break when their ingress node changes.
Neither mechanism checks the whole application: `Cluster` BGP advertisements
remain present even when the Service has no ready endpoints.

Keep the pool excluded from DHCP, allow ARP/gratuitous ARP on the nodes' VLAN,
and ensure `LAN_INTERFACE_REGEX` matches a Cilium-selected wired interface on
every possible L2 holder. Workers joining on an unrelated VLAN are not covered
by this single-LAN policy. Do not add a second ARP speaker or assign these VIPs to
NICs. The optional kube-vip API address uses a separate address outside this pool.
Wi-Fi Windows clients can use a bridged LAN if the AP permits access to these
wired hosts; guest isolation can block it. BGP does not bypass that isolation.

For a single LAN, BGP remains optional and adds little to direct workstation
traffic. It is useful for explicit router paths and eventual routed networks;
it does not remove DNS/CA setup or make a service Internet-accessible.

## Enable optional BGP in one profile

Keep L2 and its on-link pool enabled while testing BGP. Use the router's actual
LAN address below; `.1` is an example, not discovery. The defaults use private
ASNs 64512 for the router and 64513 for the cluster. If the router already runs
BGP, use its existing ASN and preserve its routing policies. Use another cluster
ASN and distinct service IPs for a second cluster.

Add to `clusters/laptops/settings.yaml` under `data`:

```yaml
  BGP_ENABLED: 'true'
  BGP_ROUTER_IP: 192.168.2.1
  # Optional overrides; these are already the shared defaults:
  BGP_LOCAL_ASN: '64513'
  BGP_PEER_ASN: '64512'
```

Copy `examples/bgp-reconciliation.yaml` into `clusters/laptops/bgp.yaml` and add
`- bgp.yaml` to that profile's `kustomization.yaml` resources. Export/check the
settings, commit and push. Flux enables Cilium's built-in BGP capability and
applies the three upstream Cilium BGP resources. The first Cilium bootstrap uses
the same flag if enabled before installation.

For an already installed cluster, reconcile Cilium and follow its documented
agent restart when activating the feature:

```sh
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization cilium --timeout=20m
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
flux reconcile kustomization bgp
```

Enabling an agent feature is a rollout, not a claim of zero disruption. With no
configured router neighbor, Cilium's connection attempts cannot establish a
session and the router learns no routes. L2 continues serving the same VIPs;
unestablished BGP is not a dependency of storage, identity, DNS or applications.
Cilium initiates the connection, so there is no laptop BGP listening port to open.
See [Cilium BGP activation](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/index.html).

## EdgeOS configuration for one controller

Use the router CLI. First inspect its existing BGP configuration and keep a
backup of the router configuration. Adapt the ASN/IPs and policy names below to
the profile; these commands are for a router that does not already use these
names. Apply all filters before committing the new neighbor.

```text
configure
set policy prefix-list ELEKTRO-LAPTOPS-IN rule 10 action permit
set policy prefix-list ELEKTRO-LAPTOPS-IN rule 10 prefix 192.168.2.240/32
set policy prefix-list ELEKTRO-LAPTOPS-IN rule 20 action permit
set policy prefix-list ELEKTRO-LAPTOPS-IN rule 20 prefix 192.168.2.242/32
set policy prefix-list ELEKTRO-LAPTOPS-OUT rule 10 action deny
set policy prefix-list ELEKTRO-LAPTOPS-OUT rule 10 prefix 0.0.0.0/0
set policy prefix-list ELEKTRO-LAPTOPS-OUT rule 10 le 32
set protocols bgp 64512 parameters router-id 192.168.2.1
set protocols bgp 64512 neighbor 192.168.2.153 remote-as 64513
set protocols bgp 64512 neighbor 192.168.2.153 passive
set protocols bgp 64512 neighbor 192.168.2.153 prefix-list import ELEKTRO-LAPTOPS-IN
set protocols bgp 64512 neighbor 192.168.2.153 prefix-list export ELEKTRO-LAPTOPS-OUT
set protocols bgp 64512 neighbor 192.168.2.153 maximum-prefix 2
compare
commit
save
exit
```

The import list accepts only the two exact service host routes; unmatched routes
are denied. The export list sends no routes to the laptops. There is no default
route, Pod/Service CIDR, full service-pool advertisement, redistribution, static
blackhole route or eBGP multihop. If the router already peers with other routers
or an ISP, also exclude these two prefixes from those peers' export policies;
this neighbor's export filter does not filter other sessions.

Where an existing LAN-to-router firewall drops connections, allow **TCP 179 from
the configured controller IPs to this router's LAN IP**, with established return
traffic. Use the existing rule set bound to that LAN's `local` direction, before
its drop rule. Interface and rule-set names depend on the router's configuration;
do not replace its firewall or open BGP on the WAN. Direct LAN routing needs no NAT.

For each additional stable controller/hybrid, repeat the five `neighbor` lines
with its IP. Cilium selects control-plane Nodes by Kubernetes label, with no
three-node inventory. One best route is enough for failover; ECMP is optional
and is not required in this minimal example. Remove a retired controller's
router neighbor as part of its [node maintenance](node-role-changes.md).

## Addresses, DNS and acceptance

Cilium advertises the **assigned LoadBalancer IPs** of only `kube-system/lan-dns`
and the private `edge/platform` gateway. Both use `externalTrafficPolicy: Cluster`,
so the ingress controller node can send traffic to a healthy backend on a worker.
The public gateway is excluded. Cilium's [BGP resource semantics](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/)
describe these selectors and host-route advertisements.

DNS remains correct without per-node or per-peer edits: application wildcards
and the gateway's IP reservation use the same `EDGE_IP` setting; DNS itself uses
the same `DNS_IP` as its Service reservation. Node records continue following
Kubernetes addresses. BGP transports those stable service IPs; it does not allocate
them or register DNS names. Moving a pod/node or adding a BGP peer requires no DNS
change. Choosing a different VIP still requires updating its single profile value
and the router's exact import filter. Keeping two stable service IPs is deliberate:
clients and bootstrap cannot discover their DNS server through that same DNS server.

After committing the router configuration, check:

```text
show ip bgp summary
show ip bgp
show ip route 192.168.2.240
show ip route 192.168.2.242
```

The neighbor must be Established, with only the two intended `/32` routes and a
controller next hop. On the workstation check the Service allocations and DNS:

```sh
kubectl -n kube-system get service lan-dns -o wide
kubectl -n envoy-gateway-system get services -o wide
kubectl get ciliumbgpclusterconfigs,ciliumbgpnodeconfigs
dig @192.168.2.242 grafana.admin.internal +short
dig @192.168.2.242 k8s2.hosts.internal +short
```

A same-subnet DNS/HTTPS test may use L2 directly; it does not prove BGP works.
If using router conditional DNS, query both `@192.168.2.242` and `@192.168.2.1`;
the router's upstream lookup exercises its selected VIP route. Verify the router's
selected routes and test HTTPS from an allowed routed client if available.
In a maintenance window with surviving API quorum/backends, compare new requests
from same-subnet and routed clients while one peer/holder is lost. Observe route
withdrawal, the replacement next hop (or connected-route fallback), L2 lease
movement and recovery independently. A graceful BGP shutdown alone does not test
a silent node failure. Restore the node/peer and confirm only the intended two
prefixes are learned. See [Windows acceptance](windows-clients.md#verify-and-troubleshoot).
Do not remove L2 or move the pool off-link as part of this optional setup. BGP
route reachability also does not grant a routed subnet DNS access: extend DNS's
source ranges, Cilium policy and admission together if adding another client LAN.

To disable BGP, first remove this profile's `bgp.yaml` resource and let Flux prune
its BGP resources, verifying route withdrawal while L2 still works. Remove only
this cluster's neighbors/unused lists from EdgeOS. Then set `BGP_ENABLED: 'false'`
and reconcile/restart Cilium as above. Internet exposure remains a separate
[explicit operation](../examples/public-exposure/README.md).

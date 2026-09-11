# LAN DNS

The base deploys upstream **CoreDNS 1.14.7** as `dns-system/lan-dns`. Point a client machine's DNS setting at **`DNS_IP`**, or advertise that address through your router's DHCP DNS option. It answers internal names and forwards other queries to the configured upstream resolvers. TCP and UDP port 53 use the same stable Cilium LoadBalancer IP. There is no DNS controller, web UI, database or persistent volume.

## Configure and reconcile

Edit the tracked `clusters/laptops/settings.yaml`, retaining your actual API and other cluster settings:

```yaml
  EDGE_IP: 192.168.50.240
  DNS_IP: 192.168.50.242
  DNS_CLIENT_CIDR: 192.168.50.0/24
  DNS_UPSTREAMS: '1.1.1.1 9.9.9.9'
  K8S1_IP: 192.168.50.11
  K8S2_IP: 192.168.50.12
  K8S3_IP: 192.168.50.13
```

These are **examples**, not discovered LAN addresses. Reserve `DNS_IP` outside DHCP and inside your existing `LB_START`–`LB_STOP` pool, distinct from `EDGE_IP`, any public gateway, API VIP and physical machine. `DNS_CLIENT_CIDR` is the IPv4 subnet allowed to query the resolver; set it to your real LAN. Cilium's LoadBalancer source filtering and a pod ingress policy enforce this boundary. Do not forward TCP/UDP 53 from the Internet. To admit a separate routed VPN subnet, extend the Service source ranges, DNS network policy and the corresponding admission validation together through Git.

`DNS_UPSTREAMS` is a space-separated list of **IPv4 resolver addresses**, optionally `IP:port`, in preference order. You can use your router or company DNS instead of the example public resolvers, provided it does not forward these same queries back to `DNS_IP`. Do not use `DNS_IP`, kube-dns, loopback addresses or `/etc/resolv.conf` as upstreams. CoreDNS forwards to these explicit addresses; it does not inherit a client's DNS or recursively forward through itself. It tries another upstream on transport failure; configure resolvers with consistent answers, since an upstream NXDOMAIN is an answer, not a failover signal.

The three machine addresses are independent of `API_HOST`, which may later become an API VIP. Add other LAN machines as exact records in `infrastructure/dns/hosts.db`; this is a Git-managed inventory, not automatic discovery. No wildcard belongs in that file.

Commit/push the settings and reconcile from your workstation:

```sh
flux reconcile source git flux-system
flux reconcile kustomization flux-system
flux reconcile kustomization foundation
flux reconcile kustomization admission
flux reconcile kustomization network
flux reconcile kustomization dns
flux reconcile kustomization cluster-dns
kubectl -n dns-system rollout status deployment/lan-dns --timeout=5m
kubectl -n dns-system get service lan-dns
```

The normal Flux dependency graph performs this ordering automatically. Existing clusters do not need another Cilium/Flux bootstrap. `local/cluster.env` does not configure this service; Flux reads the tracked settings. Wait for the Service's `EXTERNAL-IP` to equal `DNS_IP`, then test it before changing client DNS. A pending IP usually means the address is outside the pool, already allocated, or the updated network resources have not reconciled.

## Answers and client setup

| Query | Answer |
| --- | --- |
| `k8s1.hosts.internal` (and other exact inventory entries) | That machine's configured address |
| `missing.hosts.internal` | NXDOMAIN, never the gateway |
| `foo.internal`, `longhorn.admin.internal`, `foo.staging.internal` | `EDGE_IP` |
| `foo-a7c92e.test.internal`, `foo-b41d08.test.internal` | `EDGE_IP`; no DNS edit per test deployment |
| `dns.admin.internal` | `DNS_IP`, reserved for this resolver |
| Other domains, including your public domain | Answers from `DNS_UPSTREAMS` |

The application wildcards currently provide IPv4 A records. An AAAA/TXT/HTTPS query for an existing internal name returns an empty successful answer when that record type is absent. Internal queries stay local, including negative answers. DNS wildcards follow DNS zone semantics; the existing route admission and certificates still restrict applications to the documented single-label groups. A DNS answer neither creates an HTTPRoute nor grants access. Internet exposure still requires the separate explicit public configuration.

`prepare-workstation.sh` installs `dig` through Debian's `dnsutils` package. Test both transports (replace the example address):

```sh
dig @192.168.50.242 k8s1.hosts.internal A
dig @192.168.50.242 foo-a7c92e.test.internal A
dig @192.168.50.242 foo-b41d08.test.internal A +tcp
dig @192.168.50.242 missing.hosts.internal A
dig @192.168.50.242 longhorn.admin.internal AAAA
dig @192.168.50.242 example.org A
```

On a Debian desktop using NetworkManager, select your connection under network settings, disable automatic DNS and enter `DNS_IP`. A CLI equivalent is:

```sh
nmcli connection show
# Replace the connection name and example IP below.
sudo nmcli connection modify 'Wired connection 1' \
  ipv4.ignore-auto-dns yes ipv4.dns '192.168.50.242' ipv6.ignore-auto-dns yes
sudo nmcli connection up 'Wired connection 1'
getent ahostsv4 longhorn.admin.internal
```

Reactivating a connection briefly interrupts it. On other operating systems use the adapter's DNS setting, or let DHCP distribute `DNS_IP`. Remove unwanted manually configured IPv6 DNS servers too. Do not add a public DNS address as a client-side “secondary”: clients can use it even while the internal resolver is healthy, causing intermittent `.internal` failures. For redundancy use another resolver serving the same internal zones. Browsers/VPNs with their own encrypted DNS must use the OS resolver or an internal-zone exception.

DNS does not install the private TLS root on clients. Complete the [CA trust step](bootstrap.md#5-trust-tls-initialize-permissions-log-in) before using internal HTTPS services.

## Pods, updates and availability

The `cluster-dns` reconciliation supplies the **supported k3s `coredns-custom` import** for `internal`, forwarding only that zone to `DNS_IP`. Pods continue using kube-dns for `*.svc.cluster.local` and their normal external forwarding. The LAN resolver does not expose Kubernetes Service discovery. If you already maintain a `kube-system/coredns-custom` ConfigMap outside this repository, merge its existing custom keys into this repository's manifest before reconciliation. Do not replace k3s's main `coredns` ConfigMap.

CoreDNS reloads the Corefile and zone files automatically after ConfigMap projection reaches the pods. The pinned `file` plugin uses `reload_by_mtime`, so editing addresses needs no manual SOA serial increment or pod restart. Allow a few minutes for Flux, volume projection and cached answers; the internal cache is capped at 30 seconds. An invalid configuration is logged and does not become a valid DNS change. Check `kubectl -n dns-system logs deployment/lan-dns` and query the actual answer after editing.

Two small replicas prefer different workload-capable nodes and a PDB retains one during voluntary maintenance. Both may run on a single eligible node, which provides no node-failure redundancy. Cilium announces the stable IP from one node at a time and can move it after a node failure. Test that failover on your LAN; CI does not test your switches, ARP or firewall.

Client DNS depends on cluster availability. **Keep cluster hosts' bootstrap/public DNS independent of the cluster**, and retain a numeric node/API VIP address for API recovery. Otherwise a full shutdown can create a dependency cycle while k3s/Cilium/Flux need DNS to recover. You can leave nodes on an external LAN resolver which conditionally forwards only `.internal` here; keep its other upstream independent. Pods receive the internal-zone import regardless of the nodes' resolver choice. For a first bootstrap, retain working external DNS until Flux has brought up this service.

Implementation references: [CoreDNS zone files and reloads](https://coredns.io/plugins/file/), [forwarding](https://coredns.io/plugins/forward/), [k3s custom CoreDNS imports](https://docs.k3s.io/advanced#coredns-custom-configuration-imports), and [Cilium source-range filtering](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#loadbalancer-source-ranges-checks).

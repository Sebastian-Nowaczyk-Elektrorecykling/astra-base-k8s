# Reusing the base for another cluster

`laptops` is a **cluster profile name**, not a node count or hardware requirement. The base supports any number of registered nodes. The installer accepts node names consisting of one lowercase DNS label, at most 63 characters. Each Kubernetes cluster independently runs the same manifests in `infrastructure/` and the same Flux reconciliation graph in `clusters/base/`.

| Location | Ownership |
| --- | --- |
| `infrastructure/` | Shared software, policies and manifests |
| `clusters/base/defaults.yaml` | Shared version/default values; override a value in an individual profile when needed |
| `clusters/base/reconciliation.yaml` | Shared Flux stages and dependencies |
| `clusters/NAME/settings.yaml` | That cluster's name, network and private DNS suffix |
| `clusters/NAME/dns-forwarding.yaml` | Optional forwarding to other clusters and non-Kubernetes LAN host entries |
| `clusters/NAME/secrets/` | That cluster's encrypted bootstrap credentials |
| `clusters/NAME/flux-system/` | Flux's generated controllers/sync entry point; an absent/empty directory is generated during bootstrap |
| `local/NAME/` | Ignored local kubeconfig, age key, exported env file and operation state |

The settings file is a Kustomize patch over the shared defaults. Flux sees one merged `flux-system/cluster-settings` ConfigMap. The profile's `CLUSTER_NAME` selects its own secrets directory through a Kustomize replacement. Shared resource names stay the same inside each independent Kubernetes API; they do not need per-cluster prefixes.

## What to put in settings.yaml

Use a **LAN address** for the API and distinct **off-link service VIPs** for DNS and the gateway. `Node.status.addresses` calls a node's LAN IP an `InternalIP`; that does **not** mean a Pod or Service address.

| Setting | What it means and what to enter |
| --- | --- |
| `CLUSTER_NAME` | The directory name, currently `laptops`. Set by the profile creator. |
| `BASE_CONTRACT_VERSION` | Shared downstream interface version, currently `1`. Maintained by the base; do not override it to imply compatibility. See [the contract](platform-contract.md). |
| `API_HOST` | Reachable controller LAN IP, initially your working `192.168.2.153`, or a tested stable API VIP/name. No scheme or port. It must be covered by the API certificate. |
| `LAN_CIDR` | The actual wired LAN subnet and mask, initially `192.168.2.0/24`. The BGP router and controller peers must be inside it; the service subnet must be outside it. |
| `EDGE_IP` | An unused **routed virtual IP** for internal HTTPS applications. Cilium advertises it; do not assign it to a laptop interface. |
| `DNS_IP` | A different unused **routed virtual IP** for TCP/UDP DNS. This is the DNS server address to put on client machines. |
| `LB_CIDR` | An unused RFC1918 service subnet routed via BGP, e.g. `10.44.0.0/24`. Keep it disjoint from node/client LANs, VPNs and Pod/Service networks. Do not assign it to an interface or DHCP scope. |
| `LB_START`, `LB_STOP` | Allocation range inside `LB_CIDR`, excluding network/broadcast addresses. Include both VIPs. No DHCP exclusion on the node LAN is needed for this off-link range. |
| `DNS_CLIENT_CIDR` | The client LAN subnet allowed to query DNS, for example `192.168.2.0/24` **if that is your actual subnet**. |
| `DNS_UPSTREAMS` | Space-separated upstream DNS server IPs, optionally `IP:port`; for example your router, or `1.1.1.1 9.9.9.9`. No forwarding loop back to this resolver. |
| `POD_CIDR` | Cluster-private Pod address range; default for the existing cluster is `10.42.0.0/16`. Keep the value with which k3s was installed. |
| `SERVICE_CIDR` | Cluster-private Service address range; existing default is `10.43.0.0/16`. Keep the installed value. |
| `CLUSTER_DNS` | kube-dns's **Service IP**, existing default `10.43.0.10`. This is for pods/k3s, not the DNS address for LAN clients. It must belong to `SERVICE_CIDR`. |
| `INTERNAL_DOMAIN` | `internal` preserves current names. A second cluster can use `production.internal`, producing `*.hosts.production.internal`, `*.admin.production.internal`, `*.test.production.internal`, etc. |
| `IDENTITY_HOST` | `keycloak.admin.INTERNAL_DOMAIN` for private access. Existing cluster: `keycloak.admin.internal`. The public-exposure runbook covers changing the canonical issuer later. |
| `PUBLIC_EDGE_IP` | Leave the shared default `NOT_CONFIGURED` until deliberately enabling the separate public gateway. |
| `BGP_ROUTER_IP`, `BGP_LOCAL_ASN`, `BGP_PEER_ASN` | Actual directly connected LAN router and cluster/router private ASNs. BGP is always enabled and reconciled; see [generated EdgeRouter setup](bgp.md#generate-the-router-setup). |
| `API_VIP`, `API_VIP_INTERFACE` | Optional **ARP-based API HA exception**, independent of Cilium; set both only when deliberately enabling the [API VIP example](high-availability.md#optional-arp-api-vip). Prefer an external TCP load balancer for API HA without ARP VIP announcements. The VIP must be on the LAN and outside the entire Cilium service pool. |
| `PG_IMAGE` | Shared PostgreSQL image pin; normally leave the default. |
| `FGA_STORE_ID`, `FGA_MODEL_ID` | Start with the shared `NOT_CONFIGURED` defaults. After initializing OpenFGA **on this cluster**, put its returned IDs in this profile. Do not reuse another cluster's IDs. |

The laptops defaults are internally consistent for **`192.168.2.0/24`**: API `192.168.2.153`, router `192.168.2.1`, gateway `10.44.0.240`, DNS `10.44.0.242`, and pool `10.44.0.240`–`10.44.0.249` inside `LB_CIDR: 10.44.0.0/24`. Determine your actual subnet with `ip -4 addr` and `ip -4 route`; `192.168.x.x` does not imply a particular mask. For another LAN, change `LAN_CIDR`, `API_HOST`, `BGP_ROUTER_IP` and `DNS_CLIENT_CIDR` together; keep or choose a disjoint routed service subnet and VIPs. Leave the `10.42.0.0/16` Pod and `10.43.0.0/16` Service ranges alone unless they overlap a real VPN/routed network.

Use those service addresses only after checking that their subnet is unused throughout your routed networks. They need no DHCP scope or reservation. Reserve stable addresses for the control-plane machines/API endpoint. Workers can use ordinary DHCP.

Do not change a running cluster's Pod CIDR, Service CIDR or kube-dns Service IP to match examples for a new cluster. The configuration validator catches overlaps and addresses in the wrong range; it cannot discover your router's DHCP pool, prove an IP is free, or validate wiring.

## Create a second profile

On the administrator workstation, with the tools from `prepare-workstation.sh`:

```sh
bash scripts/create-cluster.sh production
# Creates clusters/production with production.internal and example network values.
# Edit clusters/production/settings.yaml for the actual second cluster.
mkdir -p local/production
bash scripts/configure-cluster.sh --export production > local/production/cluster.env
```

The creator installs nothing and contacts no cluster. It builds a new entry point from the template, reuses the shared base and generates the pinned Flux controller manifests. It refuses to overwrite an existing profile, and copies no age keys, kubeconfig, encrypted credentials, OpenFGA state or generated sync from `laptops`.

Use the exported env file on that cluster's nodes. It contains `CLUSTER_NAME`, API endpoint, Pod/Service networks, kube-dns IP, the private suffix, and the LAN/BGP/service-pool settings. `--check` therefore detects stale router and VIP values as well as bootstrap network changes. Editing the tracked profile and re-exporting avoids maintaining these values twice. `configure-cluster.sh FILE` can import a trusted exported env file when deliberately changing an API endpoint. `CLUSTER_NAME` and `INTERNAL_DOMAIN` are required, so an unnamed old file cannot select a cluster implicitly.

Follow the normal [bootstrap runbook](bootstrap.md) with your new node names and files. For example:

```sh
# On the new controller: choose its actual stable LAN IP.
sudo bash scripts/install-k3s.sh --role hybrid --name control-a --ip 192.168.60.11 \
  --config local/production/cluster.env --init

# On any freshly prepared DHCP worker, with the new cluster's token file:
sudo bash scripts/install-k3s.sh --role worker --name inference-east --ip auto \
  --config local/production/cluster.env --server https://192.168.60.11:6443 \
  --token-file /root/k3s-join-token
```

Use `--role controller` for a dedicated server or `--role hybrid` for workload capacity; additional servers use `--server` and the server token, never another `--init`. `--print-config` prints the generated configuration without installing anything. Node names do not imply a GPU vendor.

Back on the workstation, copy the new cluster's admin kubeconfig into `local/production/kubeconfig` and set its API server address correctly:

```sh
export KUBECONFIG="$PWD/local/production/kubeconfig"
bash scripts/bootstrap-cilium.sh local/production/cluster.env
python3 scripts/configure-bgp.py production --discover > local/production/edgerouter-bgp.txt
# Review/apply this cluster's router neighbors and filters; see docs/bgp.md.
age-keygen -o local/production/age.agekey
bash scripts/generate-secrets.sh "$(age-keygen -y local/production/age.agekey)" production
# Commit/push the new profile and any intentional shared changes.
bash scripts/bootstrap-flux.sh local/production/age.agekey local/production/cluster.env
```

Generate the age key **once** and keep a secure recovery copy. Complete [BGP/DNS acceptance](bgp.md#addresses-dns-and-acceptance) and the CA trust/OpenFGA steps for this cluster; `bootstrap-openfga.sh KEYFILE production` records state under `local/production`. Both Cilium and Flux bootstrap check the selected API endpoint against the current kubeconfig, and refuse a different live cluster name. Flux's GitHub owner/repository is read from `origin`; each cluster gets its own read-only deploy key.

Shared changes reconcile into every cluster following that Git revision. Use a separate branch/pinned revision when deliberately staging an upgrade; sharing manifests does not itself create an upgrade promotion process.

## DHCP and dynamic node DNS

The existing k3s node controller watches Node additions, changes and removals and updates `kube-system/coredns.data.NodeHosts`. The LAN CoreDNS pods mount only that key read-only and expose each node as `NODE.hosts.INTERNAL_DOMAIN`. There is no three-node list, periodic kubectl writer, additional operator or ExternalDNS database. This specifically uses the k3s component already installed by the base. [Pinned upstream controller](https://github.com/k3s-io/k3s/blob/v1.36.4%2Bk3s1/pkg/node/controller.go)

`--ip auto` is the installer default: it omits `node-ip` so k3s selects the node address at startup. A DHCP worker can rejoin after reboot with a new address; DNS follows the address reported by Kubernetes. It does not read DHCP leases directly. If DHCP changes an address while k3s/Cilium is running, use a maintenance window to drain and restart/reboot that worker and verify networking; DNS does not reconfigure a running kubelet, Cilium or etcd. Existing installations with a literal `node-ip:` remain pinned until deliberately changed. Use the node maintenance runbook before changing an active storage/workload node.

Keep stable addresses for servers and the API endpoint. DNS discovery cannot remove the API's bootstrap dependency or make changing live etcd peer addresses harmless. A NotReady/cordoned node retains its DNS name for administration; deleting its Kubernetes Node removes the record after reconciliation and caching. Deleting a Node is still a storage-aware operation, not a substitute for the [removal script](node-role-changes.md).

Only machines registered with this Kubernetes API are discovered this way. For an ordinary LAN machine outside Kubernetes, optionally add a `manual.hosts` key to that profile's `dns-forwarding.yaml`, using bare names because the resolver adds the `hosts.INTERNAL_DOMAIN` suffix:

```yaml
  manual.hosts: |
    192.168.2.1 router
```

## Two clusters on the same LAN

Use distinct off-link service subnets, VIPs and cluster ASNs. For example:

| Setting | laptops | production on the same LAN |
| --- | --- | --- |
| `LAN_CIDR` / `DNS_CLIENT_CIDR` | `192.168.2.0/24` | `192.168.2.0/24` |
| `API_HOST` | `192.168.2.153` | `192.168.2.154` |
| `BGP_ROUTER_IP` / `BGP_PEER_ASN` | `192.168.2.1` / `64512` | `192.168.2.1` / `64512` |
| `BGP_LOCAL_ASN` | `64513` | `64514` |
| `LB_CIDR` | `10.44.0.0/24` | `10.54.0.0/24` |
| `LB_START`–`LB_STOP` | `10.44.0.240`–`10.44.0.249` | `10.54.0.240`–`10.54.0.249` |
| `EDGE_IP` / `DNS_IP` | `10.44.0.240` / `10.44.0.242` | `10.54.0.240` / `10.54.0.242` |
| `POD_CIDR` / `SERVICE_CIDR` | `10.42.0.0/16` / `10.43.0.0/16` | `10.52.0.0/16` / `10.53.0.0/16` |
| `CLUSTER_DNS` | `10.43.0.10` | `10.53.0.10` |

These are examples, not discovered free networks. Edit the second profile's
node LAN/API/router/ASN from its template values before exporting or installing.
The template is reused for every new profile; it cannot allocate a unique subnet
or ASN for you. Check all cluster, LAN and VPN ranges together. No service-pool
DHCP exclusion or on-link VIP is used. Reserve the controller IPs only.

Generate each profile's router snippet and apply both sets of named filters and
neighbors to the same router. Preserve its existing global ASN/router ID; do not
pass `--router-id` when adding the second cluster. The router must learn all four
private service `/32`s before relying on cross-cluster DNS or HTTPS.

The same hostname cannot select two different clusters in one DNS view. Keep `internal` on `laptops` and choose `production.internal` for the second cluster, or use isolated LAN/VPN resolver views. To have clients use the laptops DNS IP for both, add a conditional forwarding block to **`clusters/laptops/dns-forwarding.yaml`**:

```yaml
data:
  production.server: |
    production.internal:1053 {
        errors
        cache 30
        forward . 10.54.0.242
    }
```

Replace `10.54.0.242` with the production cluster's routed `DNS_IP` and permit the first cluster's node addresses through its `DNS_CLIENT_CIDR`. The more specific forwarded zone takes precedence over `*.internal`; new production application/node names then work without adding individual records. `kube-system/lan-dns` reloads this ConfigMap through CoreDNS's supported import. Do not configure reciprocal forwarding of the same zone. Both resolvers can keep independent upstreams for public DNS.

Do not list two cluster resolvers as client-side primary/secondary unless they serve the same DNS view. Import the public root certificate from each cluster on clients that access both. DNS forwarding creates no public route, Internet port-forward, identity permission or application deployment.

# Reusing the base for another cluster

`laptops` is a **cluster profile name**, not a node count or hardware requirement. The base supports any number of registered nodes and any valid node names. Each Kubernetes cluster independently runs the same manifests in `infrastructure/` and the same Flux reconciliation graph in `clusters/base/`.

| Location | Ownership |
| --- | --- |
| `infrastructure/` | Shared software, policies and manifests |
| `clusters/base/defaults.yaml` | Shared version/default values; override a value in an individual profile when needed |
| `clusters/base/reconciliation.yaml` | Shared Flux stages and dependencies |
| `clusters/NAME/settings.yaml` | That cluster's name, network and private DNS suffix |
| `clusters/NAME/dns-forwarding.yaml` | Optional forwarding to other clusters and non-Kubernetes LAN host entries |
| `clusters/NAME/secrets/` | That cluster's encrypted bootstrap credentials |
| `clusters/NAME/flux-system/` | Flux's generated controllers/sync entry point for that cluster |
| `local/NAME/` | Ignored local kubeconfig, age key, exported env file and operation state |

The settings file is a Kustomize patch over the shared defaults. Flux sees one merged `flux-system/cluster-settings` ConfigMap. The profile's `CLUSTER_NAME` selects its own secrets directory through a Kustomize replacement. Shared resource names stay the same inside each independent Kubernetes API; they do not need per-cluster prefixes.

## What to put in settings.yaml

Use **LAN addresses** for the API, DNS and gateway. `Node.status.addresses` calls a node's LAN IP an `InternalIP`; that does **not** mean a Pod or Service address.

| Setting | What it means and what to enter |
| --- | --- |
| `CLUSTER_NAME` | The directory name, currently `laptops`. Set by the profile creator. |
| `API_HOST` | Reachable controller LAN IP, initially your working `192.168.2.153`, or a tested stable API VIP/name. No scheme or port. It must be covered by the API certificate. |
| `EDGE_IP` | An unused **LAN virtual IP** for internal HTTPS applications. Cilium advertises it; do not assign it to a laptop interface. |
| `DNS_IP` | A different unused **LAN virtual IP** for TCP/UDP DNS. This is the DNS server address to put on client machines. |
| `LB_START`, `LB_STOP` | The start/end of a small LAN range Cilium can allocate. Include the DNS and gateway IPs. Exclude this whole range from DHCP and other static allocations. |
| `DNS_CLIENT_CIDR` | The client LAN subnet allowed to query DNS, for example `192.168.2.0/24` **if that is your actual subnet**. |
| `DNS_UPSTREAMS` | Space-separated upstream DNS server IPs, optionally `IP:port`; for example your router, or `1.1.1.1 9.9.9.9`. No forwarding loop back to this resolver. |
| `LAN_INTERFACE_REGEX` | Names of the wired node interfaces on which Cilium announces virtual IPs. Inspect `ip -br link`; `^(en.*|eth.*)$` covers common Ethernet names. |
| `POD_CIDR` | Cluster-private Pod address range; default for the existing cluster is `10.42.0.0/16`. Keep the value with which k3s was installed. |
| `SERVICE_CIDR` | Cluster-private Service address range; existing default is `10.43.0.0/16`. Keep the installed value. |
| `CLUSTER_DNS` | kube-dns's **Service IP**, existing default `10.43.0.10`. This is for pods/k3s, not the DNS address for LAN clients. It must belong to `SERVICE_CIDR`. |
| `INTERNAL_DOMAIN` | `internal` preserves current names. A second cluster can use `production.internal`, producing `*.hosts.production.internal`, `*.admin.production.internal`, `*.test.production.internal`, etc. |
| `IDENTITY_HOST` | `keycloak.admin.INTERNAL_DOMAIN` for private access. Existing cluster: `keycloak.admin.internal`. The public-exposure runbook covers changing the canonical issuer later. |
| `PUBLIC_EDGE_IP` | Leave the shared default `NOT_CONFIGURED` until deliberately enabling the separate public gateway. |
| `PG_IMAGE` | Shared PostgreSQL image pin; normally leave the default. |
| `FGA_STORE_ID`, `FGA_MODEL_ID` | Start with the shared `NOT_CONFIGURED` defaults. After initializing OpenFGA **on this cluster**, put its returned IDs in this profile. Do not reuse another cluster's IDs. |

Your tracked `API_HOST` is `192.168.2.153`, while the old gateway/DNS/pool values are still `192.168.50.*` examples. Determine your actual LAN subnet with `ip -4 addr` and `ip -4 route`; an API IP alone does not reveal its subnet mask. If your LAN is `192.168.2.0/24`, an illustrative configuration is:

```yaml
  API_HOST: 192.168.2.153
  LB_START: 192.168.2.240
  LB_STOP: 192.168.2.249
  EDGE_IP: 192.168.2.240
  DNS_IP: 192.168.2.242
  DNS_CLIENT_CIDR: 192.168.2.0/24
  DNS_UPSTREAMS: '1.1.1.1 9.9.9.9'
```

Use those addresses only after checking that they are free and excluded from DHCP. You do **not** need a DHCP reservation per virtual IP or per worker: exclude one small pool range once. Reserve stable addresses for the control-plane machines/API endpoint. Workers can use ordinary DHCP.

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

Use the exported env file on that cluster's nodes. It contains `CLUSTER_NAME`, API endpoint, Pod/Service networks, kube-dns IP and the private suffix. Editing the tracked profile and re-exporting avoids maintaining these values twice. Legacy `configure-cluster.sh local/cluster.env` remains available to import an existing env file into the selected profile; missing `CLUSTER_NAME` means `laptops` for compatibility. It now synchronizes Service CIDR, kube-dns IP and the internal suffix too.

Follow the normal [bootstrap runbook](bootstrap.md) with your new node names and files. For example:

```sh
# On the new controller: choose its actual stable LAN IP.
sudo bash scripts/install-k3s.sh --role hybrid --name control-a --ip 192.168.2.154 \
  --config local/production/cluster.env --init

# On any freshly prepared DHCP worker, with the new cluster's token file:
sudo bash scripts/install-k3s.sh --role worker --name inference-east --ip auto \
  --config local/production/cluster.env --server https://192.168.2.154:6443 \
  --token-file /root/k3s-join-token
```

Use `--role controller` for a dedicated server or `--role hybrid` for workload capacity; additional servers use `--server` and the server token, never another `--init`. `--print-config` prints the generated configuration without installing anything. Node names do not imply a GPU vendor.

Back on the workstation, copy the new cluster's admin kubeconfig into `local/production/kubeconfig` and set its API server address correctly:

```sh
export KUBECONFIG="$PWD/local/production/kubeconfig"
bash scripts/bootstrap-cilium.sh local/production/cluster.env
age-keygen -o local/production/age.agekey
bash scripts/generate-secrets.sh "$(age-keygen -y local/production/age.agekey)" production
# Commit/push the new profile and any intentional shared changes.
bash scripts/bootstrap-flux.sh local/production/age.agekey local/production/cluster.env
```

Generate the age key **once** and keep a secure recovery copy. Complete the CA trust/OpenFGA steps for this cluster; `bootstrap-openfga.sh KEYFILE production` records state under `local/production`. Both Cilium and Flux bootstrap check the selected API endpoint against the current kubeconfig, and refuse a different live cluster name. Flux's GitHub owner/repository is read from `origin`; each cluster gets its own read-only deploy key.

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

Use disjoint Cilium pools and distinct DNS/gateway IPs. For example, exclude `.240`–`.254` from DHCP once, then allocate `.240`–`.249` to `laptops` and `.250`–`.254` to `production`. Use different Pod/Service CIDRs if the clusters may communicate through routing, VPN or multi-cluster networking later. The new-profile template starts with `10.52.0.0/16`, `10.53.0.0/16` and `10.53.0.10` so it differs from the existing cluster.

The same hostname cannot select two different clusters in one DNS view. Keep `internal` on `laptops` and choose `production.internal` for the second cluster, or use isolated LAN/VPN resolver views. To have clients use the laptops DNS IP for both, add a conditional forwarding block to **`clusters/laptops/dns-forwarding.yaml`**:

```yaml
data:
  production.server: |
    production.internal:1053 {
        errors
        cache 30
        forward . 192.168.2.252
    }
```

Replace `.252` with the production cluster's reserved `DNS_IP` and permit the first cluster's node addresses through its `DNS_CLIENT_CIDR`. The more specific forwarded zone takes precedence over `*.internal`; new production application/node names then work without adding individual records. `kube-system/lan-dns` reloads this ConfigMap through CoreDNS's supported import. Do not configure reciprocal forwarding of the same zone. Both resolvers can keep independent upstreams for public DNS.

Do not list two cluster resolvers as client-side primary/secondary unless they serve the same DNS view. Import the public root certificate from each cluster on clients that access both. DNS forwarding creates no public route, Internet port-forward, identity permission or application deployment.

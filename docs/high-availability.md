# Node roles and high availability

## Roles

| Role | k3s mode | Workloads / Longhorn disk | Scheduling |
| --- | --- | --- | --- |
| `controller` | server with embedded etcd | No | Dedicated control-plane NoSchedule taint |
| `hybrid` | server with embedded etcd | Yes | Ordinary workloads allowed |
| `worker` | agent | Yes | Ordinary workloads allowed |

A dedicated controller is not an agentless k3s server: Cilium still needs a node, and control-plane networking should work without a second design. Network agents and the infrastructure monitoring node exporter tolerate its taint. Prometheus/Grafana and ordinary workloads remain on workload-capable nodes. Longhorn managers and system-managed storage components select workload-capable nodes. Taints do not stop privileged administrators from explicitly overriding scheduling, and changing labels does not evict existing pods.

## Add controllers

The initial `--cluster-init` chooses embedded etcd on day one. One controller works. Three controllers tolerate one controller failure; **two do not tolerate either member failing**. Add the second and third in a planned window and do not leave the cluster at two members. Kubernetes control-plane HA is separate from application/storage HA.

1. Save an etcd snapshot and copy it off the cluster together with the k3s server token. Verify reliable SSDs and stable wired connectivity on all proposed servers.
2. Give the API a stable endpoint through an existing external TCP load balancer forwarding to healthy servers on TCP 6443. Keep its address outside `LB_CIDR`; the Cilium BGP service routes do not provide an API endpoint. Choose a load-balancer setup that does not itself rely on ARP VIP announcements if that is a requirement for the whole LAN. Keep `API_HOST` pointing to k8s1 until the new endpoint is verified.
3. Add the endpoint IP/DNS name to `tls-san` in `/etc/rancher/k3s/config.yaml` on the existing server, retaining its old SAN. Restart k3s in the maintenance window. Verify `kubectl` against the new endpoint with certificate validation enabled. For a DNS name, add both the name and IP when you need both access forms.
4. Change `API_HOST` in workstation/host `local/cluster.env` and the admin kubeconfig. Run `bash scripts/configure-cluster.sh local/cluster.env` on the workstation to update the GitOps settings, then commit and push `clusters/laptops/settings.yaml`. Let Cilium reconcile its direct API endpoint and verify it before joining further servers. Keep the old endpoint reachable until the Cilium rollout finishes; do not use the bootstrap Helm script once Flux owns the release.
5. On each **fresh** added server, reserve a stable LAN IP, run host preparation and join with the **server token**, using `--role controller` or `--role hybrid` and `--server https://API_ENDPOINT:6443`. Do not pass `--init` again. Apply the same k3s version, disabled components, CIDRs, DNS, secret encryption and egress-selector settings. Add the healthy server to the external API load balancer.
6. Confirm all three server nodes and etcd members are healthy. Complete the BGP peer setup below, then test one server down at a time; restore quorum before the next test. Existing agents learn server endpoints after registration, but newly joining agents and off-cluster clients still need a reachable initial endpoint.

Private DNS/gateway reachability uses BGP from controller peers. After adding stable
controllers, regenerate the [EdgeRouter configuration](bgp.md#generate-the-router-setup)
with `python3 scripts/configure-bgp.py laptops --discover`, review and apply their
new neighbor entries, and verify both service routes before relying on failover.
Workers need no BGP neighbors. Retired controller neighbors must be removed explicitly.

## Optional ARP API VIP

`infrastructure/api-vip` and `examples/api-vip-reconciliation.yaml` retain an
explicitly optional kube-vip API HA example. It is **not part of the BGP-only
base** and still announces the API VIP using ARP. Enabling it is a deliberate
exception; leave it unattached when virtual-IP L2 announcements must stay disabled.
Cilium's service and pod announcement settings remain disabled independently.

If choosing this exception, set both `API_VIP` and `API_VIP_INTERFACE` in the
profile. Reserve a free address inside `LAN_CIDR`, separate from the router,
physical nodes and all service VIPs. The interface must exist on every
participating controller; differing NIC names need a reviewed per-node variant.
Copy the example Flux Kustomization into `clusters/NAME` and reference that file
in its root Kustomization. Keep `API_HOST` on the working controller until the
VIP is verified, then use the SAN/API endpoint migration steps above. kube-vip
uses host networking and each controller's local API for leader election.

The DaemonSet has NET_ADMIN/NET_RAW on control-plane hosts and is trusted
infrastructure. Test ARP takeover on the actual LAN during an approved HA window;
a manifest render cannot establish switch behavior. This API mechanism provides
no fallback for the BGP-routed DNS/gateway Services.

## Reusing k8s2 and k8s3 as hybrids

Use [the node role-change runbook](node-role-changes.md). `remove-node.sh` evacuates an existing worker, removes its Kubernetes/Longhorn node metadata and uninstalls k3s; after a reboot, `install-k3s.sh --role hybrid --server ...` joins it back as a server. Do not pass `--init`. Convert k8s2 and then k8s3, verifying each migration and keeping the two-server interval short. The GPU remains usable on a hybrid after its GPU label is restored.

`set-server-role.sh` handles hybrid ↔ dedicated controller while preserving the running server and etcd member. Becoming dedicated includes workload drain, storage eviction, persistent/live role settings and the dedicated taint. It can be used on the sole server as long as another node has workload capacity. Server ↔ worker changes use removal/rejoin and require a surviving API/etcd server.

## Make services highly available separately

Edit the existing manifests in one reviewed Git change, after enough workload nodes exist:

- Increase each CNPG Cluster to `instances: 3`. Its required hostname anti-affinity puts instances on distinct workload nodes. If there are three **dedicated** controllers and only two workers, three instances cannot schedule. PostgreSQL replication defaults are not a promise of zero data loss; configure synchronous replication according to your availability/RPO requirements.
- Scale Keycloak to two or more replicas using its supported distributed cache/database discovery configuration; review the pinned Keycloak production guidance, change the Deployment strategy deliberately, and add anti-affinity/PDBs. This repository's one-instance baseline does not claim Keycloak HA from a replica count alone.
- Scale Authorino, OpenFGA, Envoy's data-plane Deployment, Cilium operator, CNPG operator, cert-manager and Kyverno admission replicas as appropriate, with pod spreading/PDBs. OpenFGA migrations run in a supported initContainer in the one-instance baseline. For multiple OpenFGA replicas, follow its migration procedure before a rollout; do not start competing schema migrations blindly.
- Increase Longhorn CSI controller replicas and UI replicas if needed. Keep its per-volume storage class choices intentional. `longhorn-3` needs three distinct storage nodes with free space.

DNS/resolver availability, the LAN, power, laptop thermal behavior, the gateway, identity databases, the application database and the data volume are all part of effective service availability. Three etcd members alone do not make these redundant.

# Node roles and high availability

## Roles

| Role | k3s mode | Workloads / Longhorn disk | Scheduling |
| --- | --- | --- | --- |
| `controller` | server with embedded etcd | No | Dedicated control-plane NoSchedule taint |
| `hybrid` | server with embedded etcd | Yes | Ordinary workloads allowed |
| `worker` | agent | Yes | Ordinary workloads allowed |

A dedicated controller is not an agentless k3s server: Cilium still needs a node, and control-plane networking should work without a second design. Network agents may tolerate its taint. Longhorn managers and system-managed storage components select workload-capable nodes. Taints do not stop privileged administrators from explicitly overriding scheduling, and changing labels does not evict existing pods.

## Add controllers

The initial `--cluster-init` chooses embedded etcd on day one. One controller works. Three controllers tolerate one controller failure; **two do not tolerate either member failing**. Add the second and third in a planned window and do not leave the cluster at two members. Kubernetes control-plane HA is separate from application/storage HA.

1. Save an etcd snapshot and copy it off the cluster together with the k3s server token. Verify reliable SSDs and stable wired connectivity on all proposed servers.
2. Give the API a stable endpoint. Use an existing external TCP load balancer, or the optional upstream kube-vip configuration under `infrastructure/api-vip`. kube-vip is for the API only; Cilium continues to manage application load-balancer IPs. The API VIP must be outside Cilium's pool.
3. For kube-vip, set `API_VIP` and `API_VIP_INTERFACE` in the cluster settings. The interface name must exist on every participating controller; use per-node variants if NIC names differ. Add `examples/api-vip-reconciliation.yaml` to the cluster's reconciliation resources. Keep `API_HOST` pointing to k8s1 until the VIP is working. kube-vip uses host networking and the local API endpoint, so it does not need the Cilium Service VIP to elect a leader.
4. Add the VIP/DNS name to `tls-san` in `/etc/rancher/k3s/config.yaml` on the existing server, retaining its old SAN. Restart k3s in the maintenance window. Verify `kubectl` against the VIP with certificate validation enabled. For a DNS name, add both the name and VIP when you need both access forms.
5. Change `API_HOST` in `clusters/laptops/settings.yaml`, workstation/host `local/cluster.env`, and the admin kubeconfig. Commit and let Cilium reconcile its direct API endpoint. Verify Cilium before joining further servers.
6. On each **fresh** added server, run host preparation and join with the **server token**, using `--role controller` or `--role hybrid` and `--server https://API_ENDPOINT:6443`. Do not pass `--init` again. Apply the same k3s version, disabled components, CIDRs, DNS, secret encryption and egress-selector settings.
7. Confirm all three server nodes and etcd members are healthy. Test one server down at a time; restore quorum before the next test. Existing agents learn server endpoints after registration, but newly joining agents and off-cluster clients still need a reachable initial endpoint.

The kube-vip DaemonSet has NET_ADMIN/NET_RAW on control-plane hosts and is therefore an explicitly trusted infrastructure component. It is optional, pinned upstream software. Test ARP failover on your actual switch; a manifest render cannot prove that your LAN permits VIP takeover.

## Reusing k8s2 and k8s3 as hybrids

The three laptops can all be servers eventually, keeping the GPU usable on k8s2. Adding fresh controllers is simpler than converting an active worker. For an existing worker, preserve `/var/lib/longhorn`, its node identity and all needed data, drain safely, stop/disable its old `k3s-agent` service, back up the configuration, and reinstall using k3s's supported server installation with the same node name and the server join token. Do not run the fresh-node script over the old configuration and do not run an uninstallation that deletes workload data merely to bypass its checks.

Read the upstream k3s installation/upgrade guidance for the installed version before conversion. A single-copy Longhorn volume on that node cannot survive loss of its disk. Evacuate it or take and verify an external backup first. Longhorn's volume/replica eviction and ordinary Kubernetes drain are different operations. Never drain two of three storage/controller nodes simultaneously.

Changing a hybrid to dedicated also requires moving its workloads, evicting storage replicas, disabling Longhorn disk scheduling, updating labels and adding the dedicated taint. A taint alone leaves already-running workloads and stored replicas behind. Do not mark a server with live workloads “pure” without completing those steps.

## Make services highly available separately

Edit the existing manifests in one reviewed Git change, after enough workload nodes exist:

- Increase each CNPG Cluster to `instances: 3`. Its required hostname anti-affinity puts instances on distinct workload nodes. If there are three **dedicated** controllers and only two workers, three instances cannot schedule. PostgreSQL replication defaults are not a promise of zero data loss; configure synchronous replication according to your availability/RPO requirements.
- Scale Keycloak to two or more replicas using its supported distributed cache/database discovery configuration; review the pinned Keycloak production guidance, change the Deployment strategy deliberately, and add anti-affinity/PDBs. This repository's one-instance baseline does not claim Keycloak HA from a replica count alone.
- Scale Authorino, OpenFGA, Envoy's data-plane Deployment, Cilium operator, CNPG operator, cert-manager and Kyverno admission replicas as appropriate, with pod spreading/PDBs. OpenFGA migrations run in a supported initContainer in the one-instance baseline. For multiple OpenFGA replicas, follow its migration procedure before a rollout; do not start competing schema migrations blindly.
- Increase Longhorn CSI controller replicas and UI replicas if needed. Keep its per-volume storage class choices intentional. `longhorn-3` needs three distinct storage nodes with free space.

DNS/resolver availability, the LAN, power, laptop thermal behavior, the gateway, identity databases, the application database and the data volume are all part of effective service availability. Three etcd members alone do not make these redundant.

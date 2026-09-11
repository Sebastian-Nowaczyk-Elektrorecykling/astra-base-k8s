# Changing a machine's role

The scripts run on your **administrator workstation**, use its current cluster-admin kubeconfig, and perform host operations through SSH. They support healthy Debian nodes installed with this repository's pinned k3s version and default paths. They install no controller or other cluster software.

| From | To | Procedure |
| --- | --- | --- |
| Worker | Hybrid | Remove, reboot, join with `--role hybrid` |
| Worker | Controller | Remove, reboot, join with `--role controller` |
| Hybrid | Worker | Remove, reboot, join with `--role worker` |
| Controller | Worker | Remove, reboot, join with `--role worker` |
| Hybrid | Controller | `set-server-role.sh --role controller`, preserving the existing server |
| Controller | Hybrid | `set-server-role.sh --role hybrid`, preserving the existing server |

`controller` means a k3s server with embedded etcd and a dedicated scheduling taint. `hybrid` is the same server with workload/storage capacity. These are the two equivalents of “master” here. `worker` is a k3s agent. The scripts never initialize a new cluster as part of migration.

## Before starting

Operate on **one node at a time**, finish its migration, and verify the cluster before proceeding. Back up databases/Longhorn volumes externally and verify recovery. Check that other eligible nodes have enough CPU, memory, GPU capacity and storage. The scripts can check health and blockers; they cannot prove your application can tolerate downtime or fit on the remaining hardware.

The workstation needs the existing `prepare-workstation.sh` tools. Export your admin kubeconfig and verify context:

```sh
export KUBECONFIG="$PWD/local/kubeconfig"
kubectl config current-context
kubectl get nodes -o wide
```

Use an SSH account that already has root access, or noninteractive `sudo -n` access. The examples use `root@k8s2.hosts.internal`; substitute your actual SSH account or configured SSH host alias. If your resolver is not configured, use the node's actual LAN address. Connect normally once to verify the SSH host key. The scripts use SSH keys/BatchMode and normal host-key checking; they do not collect passwords or configure SSH/sudo. Verify the Kubernetes Node name and the SSH target: the script compares the node's machineID with `/etc/machine-id` before host operations.

A server being **removed** must have another healthy server. Move your kubeconfig, `local/cluster.env` / tracked `API_HOST`, and the live Cilium API endpoint to a surviving server or tested API VIP first. Follow [API endpoint migration](high-availability.md#add-controllers). The removal checks reject the target's own address, loopback endpoints, unhealthy servers and a still-unrolled Cilium change. Agent join addresses in local configuration should also point at the surviving endpoint for subsequent reconnects/installations.

The last server cannot become a worker without adding a replacement first. It **can** switch between hybrid and controller without removing etcd, provided another node can host its workloads. With two etcd members, both must remain online until membership is reduced; the script requests retirement through k3s before stopping the selected server. Three → two loses failure tolerance. Restore three for HA, or deliberately finish a planned reduction to one; do not mistake two for HA.

## Worker ↔ server: remove and rejoin

First run the read-only checks on the workstation:

```sh
bash scripts/remove-node.sh --node k8s2 --ssh root@k8s2.hosts.internal
```

When ready for the maintenance operation:

```sh
bash scripts/remove-node.sh --node k8s2 --ssh root@k8s2.hosts.internal \
  --apply --delete-emptydir-data --timeout 1800
```

`--delete-emptydir-data` explicitly permits discarding pod `emptyDir` contents during drain. Omit it if those contents need review first. It does not delete PVCs. The script never forces pod eviction or disables a PodDisruptionBudget.

The script backs up the host's configuration and, for a server, takes an etcd snapshot and copies the server token into a root-only `/var/backups/elektro-k3s/NODE/OPERATION/` directory outside the k3s uninstall path. Copy important backups off that machine: a local snapshot does not survive losing the machine. Sensitive configuration and uninstall logs remain root-only and are not printed.

It then cordons the node, disables Longhorn scheduling and requests replica/backing-image eviction. After replicas have moved, it drains pods and waits for CSI attachments to disappear. It checks surviving healthy replica records and the volume's desired replica count before proceeding. It refuses local/hostPath PVs, whose data placement needs a separate review. For a server, it requests and waits for the pinned k3s controller's etcd-removal acknowledgement while the server is online. It then stops/disables k3s, deletes the Kubernetes Node, waits for its old node-password Secret to disappear, performs Cilium-specific cleanup, invokes the upstream uninstaller, and deletes the evacuated Longhorn Node metadata.

The OS, NVIDIA driver/toolkit and `/var/lib/longhorn` directory remain. Active replicas have already moved away; keeping the directory is not the safety mechanism for a one-copy volume. The upstream uninstaller removes the old k3s runtime/configuration/datastore. Do not restore its old etcd database or node password when rejoining.

After success, reboot the target to clear remaining kernel/BPF state:

```sh
# On the removed machine:
sudo reboot
```

The fresh-node installer checks a boot-ID marker and refuses a same-boot rejoin after removal. Reuse the checkout and `local/cluster.env` on that machine. Confirm the same k3s pin and cluster-critical settings as the existing servers. Securely copy the **surviving server's** join token into a root-readable file outside `/var/lib/rancher/k3s`, for example `/root/k3s-join-token`. A server token is required for a hybrid/controller; an agent-only token suffices for a worker.

Choose exactly one of these commands on the machine, using its actual IP and a surviving server/API VIP:

```sh
# Hybrid server, with workload capacity:
sudo bash scripts/install-k3s.sh --role hybrid --name k8s2 --ip 192.168.50.12 \
  --config local/cluster.env --server https://k8s1.hosts.internal:6443 \
  --token-file /root/k3s-join-token

# Dedicated controller:
sudo bash scripts/install-k3s.sh --role controller --name k8s2 --ip 192.168.50.12 \
  --config local/cluster.env --server https://k8s1.hosts.internal:6443 \
  --token-file /root/k3s-join-token

# Worker:
sudo bash scripts/install-k3s.sh --role worker --name k8s2 --ip 192.168.50.12 \
  --config local/cluster.env --server https://k8s1.hosts.internal:6443 \
  --token-file /root/k3s-join-token
```

Use `k8s1.hosts.internal` only if k8s1 survives and its API certificate contains that SAN. Otherwise use the already verified API address from your kubeconfig. Never use `--init` on a rejoining machine. Debian preparation, Cilium Helm bootstrap and Flux bootstrap do not need to be repeated. The existing Cilium/Flux controllers configure the returning node automatically.

Deleting a Node removes labels/taints that were only stored on that Kubernetes object. The installer recreates the chosen role labels. Restore intended GPU and application-specific labels/taints from your inventory, excluding old k3s control-plane/etcd annotations. For an NVIDIA workload node, reapply `elektro.local/gpu-vendor=nvidia` and run the existing GPU smoke test. The driver/toolkit remain installed and k3s rediscovers `nvidia-container-runtime` at startup.

## Hybrid ↔ dedicated controller: keep the server

For the current k8s1, this preserves its embedded-etcd member and avoids an API restart:

```sh
# First inspect the plan; add --apply when ready.
bash scripts/set-server-role.sh --node k8s1 --ssh root@k8s1.hosts.internal --role controller
bash scripts/set-server-role.sh --node k8s1 --ssh root@k8s1.hosts.internal \
  --role controller --apply --delete-emptydir-data

# To allow workloads/storage on the same server again:
bash scripts/set-server-role.sh --node k8s1 --ssh root@k8s1.hosts.internal \
  --role hybrid --apply
```

Becoming dedicated first evacuates storage and drains workloads, then updates the three role labels in `/etc/rancher/k3s/config.yaml`, the live Kubernetes labels and the dedicated taint. It waits for non-network DaemonSets to leave too. The base Longhorn and optional NVIDIA components select `elektro.local/workloads=true`; reconcile this repository's updated NVIDIA manifest before converting a GPU node. Other repositories' DaemonSets must also exclude dedicated controllers if they are not networking/control-plane components. The helper leaves Cilium, Cilium Envoy and optional kube-vip running.

Becoming hybrid enables workload/default-disk labels, removes only this setup's dedicated NoSchedule taint, clears the Longhorn node's eviction request and enables Longhorn node scheduling. Per-disk scheduling decisions and unrelated taints are preserved. Both paths uncordon only after completing their checks. Editing only a taint or a Node label would not perform this full transition. Role flags are also persisted because k3s registration flags do not update an existing Node's labels automatically.

These helpers require the generated default configuration. They refuse custom datastore/data-dir settings, split/agentless servers, configuration drop-ins and conflicting service overrides. Keep such custom installations on their own reviewed maintenance procedure.

## Storage and database blockers

A `longhorn-3` volume on exactly three storage nodes generally needs a **fourth eligible storage node** to evacuate one while preserving three distinct replicas. Add temporary capacity, or deliberately revise that volume's replica count in Longhorn after reviewing the reduced durability; changing a StorageClass does not change existing volumes. The scripts never lower replica counts, remove volume finalizers, delete PVs/PVCs, or erase Longhorn's data directory.

Single-instance CNPG databases normally block draining their primary through a PDB. For a maintenance window, either add a database instance on another workload node and let CNPG switch primary, or deliberately set the affected Cluster's `spec.enablePDB: false` in its owning Git configuration and accept database/login downtime. Wait for Flux/CNPG to apply that choice, then rerun/resume the script; restore PDB protection afterward. Do not delete the database/PVC or disable the global admission policy. Longhorn-backed PVCs can follow the pod after storage evacuation. CNPG also uses `emptyDir` for temporary files, which is why the explicit drain option may be required. See [CNPG maintenance guidance](https://cloudnative-pg.io/docs/1.30/kubernetes_upgrade/).

## Interrupted operations and verification

Removal records each completed phase in an ignored `local/node-maintenance/remove-*.json` file. A failure leaves the node cordoned and Longhorn scheduling/eviction settings in their maintenance state. Resolve the reported problem, then use the exact state path printed by the script:

```sh
bash scripts/remove-node.sh --node k8s2 --ssh root@k8s2.hosts.internal \
  --apply --delete-emptydir-data --resume local/node-maintenance/EXACT_STATE_FILE.json
```

Resume checks the cluster UID, original Node UID and host machineID. It refuses to act on a replacement Node with the same name. Do not restart a retired server with its old database to “undo” membership removal. After etcd retirement, complete removal and rejoin; if the upstream uninstall itself was interrupted, inspect its root-only log and the host before proceeding. No blanket rollback can safely recreate a retired etcd member.

If **no etcd removal request has been sent**, you can abandon a blocked removal: clear the Longhorn node's `evictionRequested`, restore its intended `allowScheduling`, verify volume health, and uncordon the node. Replicas already moved need not be moved back. Once `etcd.k3s.cattle.io/remove=true` has been requested, a timeout does not cancel that asynchronous operation. Inspect the node annotations and continue the removal; do not assume the saved `drained` phase means membership is unchanged. A failed server-role change can be rerun toward the same intended role; inspect the live labels/taint and host backup if changing your decision.

After each migration:

```sh
kubectl wait --for=condition=Ready node/k8s2 --timeout=5m
kubectl get nodes -L elektro.local/role,elektro.local/workloads
kubectl -n longhorn-system get nodes.longhorn.io,volumes.longhorn.io
kubectl get clusters.postgresql.cnpg.io -A
flux get kustomizations
```

Confirm the intended workloads, storage replicas and optional GPU actually function. For servers, confirm k3s reports healthy embedded-etcd membership before changing another node. These scripts are not disaster-recovery tooling for dead/partitioned nodes.

Upstream implementation references: [k3s uninstall](https://docs.k3s.io/installation/uninstall), [Cilium cleanup before uninstall](https://docs.k3s.io/networking/basic-network-options#custom-cni), [pinned k3s member-removal controller](https://github.com/k3s-io/k3s/blob/v1.36.4%2Bk3s1/pkg/etcd/member_controller.go), and [Longhorn node removal](https://longhorn.io/docs/1.12.1/nodes-and-volumes/nodes/graceful-node-removal/).

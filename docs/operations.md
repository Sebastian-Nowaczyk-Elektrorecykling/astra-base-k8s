# Storage and operations

## Volumes and databases

Longhorn uses the V1 data engine and `/var/lib/longhorn`. Check the underlying filesystem supports the required features (ext4/XFS), keep free space for rebuilds, and avoid filling the OS disk. No script formats or repartitions anything. V2's raw-device/hugepage requirements are not enabled.

The default one-replica class trades durability for simplicity/capacity. `longhorn-3` requests three distinct node/disk copies. If three eligible nodes with capacity are not available, a volume may be degraded/pending; do not mistake its existence for three healthy copies. Check the Longhorn volume's replica health before relying on it. StorageClasses use `Retain`: deleting a PVC leaves its PV/data for deliberate recovery or cleanup, which also means disk space is not automatically reclaimed.

CNPG's default is applied to the Cluster CR by Kyverno, not to every PVC carrying a guessed label. Explicit nonempty data/WAL classes are respected. Adding `walStorage` without a class also gets `longhorn-cnpg`. This does not move existing PVCs or mutate an immutable PVC class; for existing databases use a supported CNPG migration/recovery operation. Without Kyverno's webhook, matching new CNPG admission fails closed instead of silently receiving the ordinary default.

Longhorn and PostgreSQL replication solve different failures. Use CNPG replicas for database availability. Three CNPG instances each with three Longhorn replicas produce nine storage copies and unnecessary write amplification for this setup. One instance on a one-copy class is the configured starting point, including the identity and permission databases.

## Backups before important data

The base installs scheduled **local** etcd snapshots every six hours, retaining twelve. It cannot invent an off-cluster destination or backup credentials. Configure a real destination before putting irreplaceable data on these disks:

| State | Backup / restore |
| --- | --- |
| Kubernetes objects, secrets, etcd | k3s etcd snapshots copied off-cluster; preserve the matching server token for decryption |
| PostgreSQL data | CNPG Barman Cloud plugin, base backups and WAL to object storage; test point-in-time recovery |
| Ordinary Longhorn volumes | External Longhorn S3/NFS BackupTarget and recurring backup jobs |
| Bootstrap material | Offline age key, recovery kubeconfig, k3s token and private CA key protected as secrets |

`examples/backups/` contains opt-in manifests for the current Barman plugin and a Longhorn backup target. Set real bucket/endpoint names, encrypted credentials and retention, and add the paths to Flux only after review. Do not store the only backup on another volume in this cluster. Longhorn snapshots/replicas are not off-cluster backups, and database crash-consistent volume snapshots are not a replacement for PostgreSQL/WAL backups.

Perform an actual restore into a separate namespace/cluster and confirm application login and permissions, not just that a backup object exists. Choose and document an RPO/RTO. Back up both Keycloak and OpenFGA; restoring one without the other can restore an identity but lose its permission graph.

## Routine checks

```sh
flux get kustomizations
flux get helmreleases -A
kubectl get nodes -o wide
kubectl get clusters.postgresql.cnpg.io -A
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n edge get gateway,httproute,securitypolicy
kubectl -n authorization get authconfig
kubectl get certificates -A
kubectl top nodes
```

Hubble relay is enabled for troubleshooting, with no unauthenticated web UI. Use the upstream Cilium/Hubble CLI through privileged port-forwarding. k3s supplies metrics-server. Prometheus/Grafana/Loki and inference-serving stacks are deliberately not part of the base; add them when there is a concrete need and protect their endpoints like other apps.

## Upgrades

Pins were reviewed on 2026-09-09; they are not evergreen. Read release notes and compatibility matrices before changing them. CI renders the pinned charts and exercises admission in a disposable cluster; it cannot simulate every Longhorn upgrade or GPU driver/kernel pair.

1. Verify external backups and a restore before a stateful upgrade. Check free disk space and all Longhorn/CNPG replicas.
2. Upgrade k3s servers serially, preserving the entire on-host config. Use the supported pinned installer upgrade method; `scripts/install-k3s.sh` intentionally refuses existing nodes. Upgrade agents afterwards within Kubernetes version-skew rules. Never lose an etcd majority.
3. Upgrade Cilium according to its supported minor-version sequence; update both `bootstrap/versions.env` and the Cilium HelmRelease pin. The values file is shared. Confirm network health before further changes.
4. Upgrade operators/charts in dependency order. Flux uses `CreateReplace` for chart CRDs, but this does not make incompatible CRD changes safe. Longhorn requires its documented intermediate upgrade sequence; do not skip it.
5. For PostgreSQL, patch the operand image within its major version after reviewing extension/base OS compatibility. A PostgreSQL **major** upgrade is a CNPG operation, not an image-tag edit. For Keycloak/OpenFGA, read database migration/downgrade restrictions and keep a matching backup.

Do not enable unattended node reboots, broad automatic image upgrades or automatic schema migrations across arbitrarily many replicas in this small cluster.

## Failure recovery

If Flux is unhealthy, use the recovery kubeconfig and inspect its events/logs. Restore `sops-age` if encrypted resources cannot decrypt. Kustomizations that manage Cilium, StorageClasses and databases are not pruned; deleting a Git directory is not a storage deletion workflow.

If Keycloak or OpenFGA is down, the dashboard stays denied. Use admin port-forward/SSH recovery, repair the databases/Deployments, and verify access checks again. Do not remove the security policy to get the UI back. The admission guard intentionally rejects deletion of that policy; an actual retirement requires shutting down the gateway and a reviewed guard change.

For etcd loss, follow the pinned k3s snapshot-restore procedure with the original server token. Restore one server from backup, then rejoin the others using the documented reset sequence. Do not run `cluster-reset` as a routine fix or initialize a competing cluster with the same data.

Before any k3s uninstall/killall, follow k3s's **Cilium-specific network cleanup** instructions. Leaving Cilium interfaces/rules behind can break host networking. Do not delete `/var/lib/longhorn` unless permanently deleting the data is the explicit goal.

## Credential rotation

Use SOPS for encrypted secret changes. Restart consumers that read credentials only at process startup. Coordinate the gateway's client secret with the existing Keycloak client: changing the realm import file will not update the live client. Remove the bootstrap-admin env references after initial administration is established. Rotate the OpenFGA key and Authorino's copy together; the baseline uses one Secret with both consumers. Keep temporary overlap limited and follow OpenFGA's key rotation guidance. Existing Keycloak/PG passwords must be rotated through their supported APIs/operator, not by overwriting only one Secret.

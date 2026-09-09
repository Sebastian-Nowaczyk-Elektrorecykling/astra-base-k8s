# Off-cluster backups (opt-in)

Install the pinned Barman HelmRelease after CNPG and cert-manager. Install its ObjectStore CR only after the plugin CRD exists. Add `cnpg-plugin-patch.yaml` as a Kustomize patch, never as a separate incomplete Cluster manifest. Add the ScheduledBackup after the Cluster has reconciled its plugin. Replicate this configuration for `authorization/openfga-db` with a distinct bucket prefix. Supply encrypted S3 credentials in each database namespace.

The existing database ingress policies permit the CNPG operator; the Barman plugin needs outbound access to your object store (egress is allowed by the base). Use a trusted HTTPS endpoint and follow the plugin's CA configuration if it has a private root. Set retention and test base-backup/WAL restoration.

For Longhorn, supply the encrypted `longhorn-backup-credentials` Secret with its documented AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and optional AWS_ENDPOINTS fields. Reconcile the BackupTarget, then define Longhorn recurring **backup** jobs and volume selectors for the volumes you intend to protect. Merely defining a target does not create backups. Keep this target off-cluster, and test a volume restore. See upstream references in docs/upstream.md.

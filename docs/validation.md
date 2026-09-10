# Validation and acceptance

## Automated checks

`python3 tests/render.py` parses repository YAML with duplicate-key rejection and checks dependency cycles, referenced paths, release pins and key storage/authentication invariants. `bash -n` and ShellCheck check the workstation/host scripts.

The GitHub Actions workflow also pulls and lints the actual pinned Helm charts, runs Kustomize, and loads upstream CRDs into a disposable Kubernetes 1.36 kind cluster. It installs the real Kyverno webhook there, performs strict server-side dry runs, confirms CNPG's default class mutation and rejects alternate NodePort/native-route/security-policy paths. CI uses no deployment secrets and does not contact your laptops. Look at the workflow result for the exact commit, rather than assuming a checked-in workflow has passed.

Separate fresh Debian 12 and 13 amd64 containers run the actual `prepare-workstation.sh` installer. They check installed CLI versions, perform an age/SOPS encryption/decryption round trip, and build the Flux manifests twice: once with generated controllers and an empty sync placeholder, then with generated GitRepository/Kustomization objects. These regress the reported empty-bootstrap failure without using a GitHub token or contacting a Kubernetes cluster. The installer also supports the upstream arm64 binaries; these CI jobs exercise amd64.

The Debian jobs also exercise `configure-cluster.sh` with a nondefault API IP and a DNS name. They verify mismatch rejection, propagation into GitOps settings, preservation of unrelated configuration and repeatable execution. Chart validation checks the rendered API host/port in the Cilium agent, operator and API-dependent init containers.

These checks do not exercise physical Debian installation, Cilium's real LAN/ARP/WireGuard behavior, Longhorn iSCSI and disk recovery, browser sessions, Google credentials, GPU drivers, or a complete production cluster. Complete the following acceptance checks on your hardware before relying on the foundation.

## Access checks

```sh
bash scripts/verify-access.sh longhorn.apps.YOUR_DOMAIN local/platform-ca.crt
```

| Scenario | Required result |
| --- | --- |
| Anonymous browser | Redirect to Keycloak; no dashboard data |
| Spoofed user headers / invalid bearer token | No dashboard data |
| Logged-in user without FGA tuple | 403 |
| User with exact service-access tuple | Dashboard available |
| Wrong JWT issuer, audience, signature or expired token | Denied |
| Authorized request observed by backend | Authorization is `GatewayAuthenticated`, not a bearer token; X-Elektro-Subject is the verified subject |
| Remove the user's FGA tuple | New dashboard request denied |
| New application hostname without callback registration | Login cannot complete; no bypass |
| New hostname with callback but without a tuple | Denied |
| Direct pod/ClusterIP access, including Longhorn backend API, from ordinary application namespace | Denied by Cilium |
| New NodePort, extra LoadBalancer, externalIPs, raw Ingress or alternate route | Admission rejected |
| Route-level SecurityPolicy override or reusing identity listener for Longhorn | Admission rejected |

For outage testing, use a maintenance window. Record the current replicas, temporarily scale Authorino to zero, and make an **authenticated** request (an anonymous request may merely receive a login redirect). It must return 5xx/denial, never the dashboard. Restore the Deployment and wait for Ready. Repeat for OpenFGA. Flux may restore the replica count during the test; suspend only that Kustomization for the brief test if needed, then resume it. Do not disable auth or admission to perform the test.

Keycloak outage behavior differs: existing signed tokens may remain valid until their short expiry, while new login and refresh fail. If immediate session revocation is needed, use a supported token-introspection design and accept its availability/latency dependency; the baseline does not promise immediate revocation of every outstanding JWT.

Kubernetes port-forward, exec, host root and cluster-admin access are trusted bypasses for operations. Test direct-service denial from an ordinary unprivileged pod, not a privileged admin port-forward. Do not grant apps the ability to edit the protected infrastructure namespaces, network policies or admission policies.

## Storage, restart and HA checks

Create a temporary ordinary PVC without a class and verify `longhorn`; create CNPG with no storageClass and verify its CR and PVC use `longhorn-cnpg`; provide `longhorn-3` explicitly and verify that it stays explicit. Verify optional WAL defaulting too. Check **actual** Longhorn replica placement rather than just its requested count. Write/read data, reschedule workloads within the supported failure model, reboot one node, and restore from the configured external backup.

After extending to three servers, test the API VIP and one controller loss, keeping two healthy etcd members. Verify CNPG and volume failover independently of the API. A one-instance database or one-copy Longhorn disk cannot pass a test that requires an independent surviving data copy.

Run the GPU Job on each supported GPU node after kernel/driver/runtime changes. Do not infer a usable GPU from a node label alone.

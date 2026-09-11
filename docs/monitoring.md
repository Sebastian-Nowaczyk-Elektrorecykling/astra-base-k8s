# Metrics and Grafana

The shared cluster base installs the upstream `kube-prometheus-stack`: Prometheus
Operator, Prometheus, Alertmanager, Grafana, kube-state-metrics and node-exporter.
There is no additional metrics operator or custom service. Grafana is at
**https://grafana.admin.internal** on laptops; another profile uses
`https://grafana.admin.<INTERNAL_DOMAIN>`.

## Access boundary

This is a **cluster administration** metrics stack. Grant it only to people
trusted to read cluster-wide infrastructure and application metrics. Grafana OSS
folder/dashboard permissions do not isolate a shared data source: even a Viewer
can submit arbitrary queries to that source. Prometheus has no per-namespace
read authorization. Dashboard variables and namespace filters are not a security
boundary. See [Grafana data source permissions](https://grafana.com/docs/grafana/latest/administration/data-source-management/)
and [Prometheus security](https://prometheus.io/docs/operating/security/).

Every gateway request requires Keycloak authentication and an OpenFGA grant to
`service:grafana.admin.internal`. Authorino overwrites `X-Elektro-Subject` with
the verified Keycloak subject, and Grafana uses its supported
[auth proxy](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/auth-proxy/)
integration. Cilium permits Grafana ingress only from the private gateway's pods.
The header is not safe to trust on an unrestricted Service.

Anonymous access, basic/password login, self-registration and local initial admin
creation are disabled. The chart creates no Grafana admin password. Proxy users
receive the **Viewer** role in one infrastructure organization; this still allows
querying every series in the shared Prometheus. Grafana creates no separate login
cookie that could substitute for the gateway checks. Only the subject header is
trusted; client-supplied user/role headers do not assign Grafana roles. Provision
dashboards and data sources through Git. Do not grant ordinary application users
access to this instance as a way to give them their own dashboards.

Prometheus, Alertmanager and exporters have ClusterIP Services only. Cilium
restricts their ingress to the relevant monitoring components. Admission rejects
Grafana aliases such as `grafana.internal`, public aliases, and routes to other
monitoring backends. There is no public monitoring gateway or Internet DNS entry.
Node root, cluster administrators and Kubernetes port-forward permissions remain
trusted administration paths.

To offer `grafana.internal` to application users later, provision a separate
application-facing instance with genuinely isolated metrics backends/tenants and
appropriately scoped credentials. Grafana organizations can separate resources,
but attaching the cluster Prometheus to an application's organization would still
expose cluster data. Data-source query permissions alone do not filter the series
within a shared source. That tenant design belongs with the separate application
platform repository.

## Enable access on an existing cluster

Flux installs the stack automatically after storage and network policies are
ready. The Grafana route waits for both monitoring and the existing protected
gateway access policy. No node IP list or new LAN service IP is needed; the
existing wildcard DNS, certificate and `EDGE_IP` already cover the hostname.

1. At `https://keycloak.admin.internal`, select realm **elektro**, then client
   **elektro-edge**. Add `https://grafana.admin.internal/oauth2/callback` to **Valid
   redirect URIs**, preserving every existing URI. Save. Use your profile's
   suffix on another cluster. Fresh realm imports already include this URI;
   Keycloak deliberately skips reimporting an existing realm.
2. Initialize OpenFGA if you have not yet done bootstrap part 5. Follow
   [the grant procedure](identity-access.md#initialize-openfga), with your Keycloak
   user UUID and object `service:grafana.admin.internal`. For example, the request
   body in `local/grafana-grant.json` is:

   ```json
   {
     "writes": {
       "tuple_keys": [
         {"user": "principal:KEYCLOAK_USER_UUID", "relation": "access", "object": "service:grafana.admin.internal"}
       ]
     }
   }
   ```

   Send it to the existing store's `/write` endpoint using the protected header
   file and local port-forward described there. Do not create another store or
   replace the authorization model. An alternative is a grant to your existing
   `group:platform-admins#member`; group membership must already be deliberate.
3. Visit **https://grafana.admin.internal** with the cluster CA trusted on the
   workstation. You should be redirected to Keycloak and then see the Kubernetes
   dashboards. A login without a matching grant must be denied.

There is no automatic grant to all logged-in users, all Keycloak administrators,
or all company email addresses. Remove the OpenFGA tuple to revoke entry; the
existing gateway checks authorization on each request. Metrics collection runs
even before the first person is granted Grafana access.

## Collection and capacity

Kubernetes API discovery tracks nodes and workloads as they join, leave or change
IP. The stack collects API-server, kubelet/cAdvisor, node, Kubernetes object,
CoreDNS, Prometheus/operator and Alertmanager metrics. Additional PodMonitors
collect Longhorn manager metrics and the foundation's CNPG databases. Default
dashboards and alert rules come from the pinned upstream chart; Longhorn/CNPG
series can be queried in Explore without downloading unreviewed dashboards.

There are no hardcoded node endpoint addresses. kube-proxy monitoring is disabled
because Cilium replaces kube-proxy. Embedded etcd, scheduler and controller-manager
scrapes/associated rule groups are disabled because k3s binds these endpoints to
loopback. This avoids permanent false-down targets and does not open new host
management ports. Node-exporter reads host filesystems, CPU and memory using
read-only host mounts, but runs without `hostNetwork` to keep unauthenticated port
9100 off the LAN. Collectors that depend on the network namespace reflect the
exporter pod's network namespace; use cAdvisor for workload network metrics.

| Component | Instances | Longhorn volume | Retention |
| --- | ---: | ---: | --- |
| Prometheus | 1 | 20 GiB | 7 days or 15 GB of blocks, whichever expires first |
| Grafana | 1 | 2 GiB | Persistent user preferences and SQLite state |
| Alertmanager | 1 | 1 GiB | 120 hours for notification/silence state |
| Node exporter | One per Linux node | None | Stored by Prometheus |

Prometheus needs space beyond its block limit for the WAL/head and temporary
compaction files; the retention-size setting is not a filesystem quota. These
defaults suit a small starting cluster. Watch disk, active series, dropped
scrapes and memory as it grows. Per-scrape sample/label and per-monitor target
limits bound accidental cardinality; increase them deliberately if legitimate
targets exceed them. Resource requests/limits and storage live in
`infrastructure/monitoring/release.yaml`. A profile can customize the monitoring
Flux Kustomization's `spec.patches` to patch its HelmRelease without copying the
shared infrastructure directory.

Workload pods run on nodes labelled `elektro.local/workloads=true`; node-exporter
also observes pure controllers. The monitoring namespace is trusted privileged
infrastructure because the exporter needs host filesystem/process visibility.
Do not delegate namespace-admin there to application teams.

All three volumes use `longhorn`, hence **one storage replica** and retained PVs.
Metrics and Grafana availability can be lost with that disk/node. This is not an
HA monitoring stack; increasing controllers does not change its replica counts.
Keep dashboards/rules in Git and back up state you need. Grafana's SQLite setup
must not be scaled to multiple replicas sharing a filesystem; use Grafana's
supported external database arrangement before doing that.

Alert rules evaluate immediately, but **external notifications are not configured**.
Alertmanager's upstream null receiver sends nothing. Add a reviewed receiver and
route, with credentials in SOPS Secrets, when you choose your notification
destination. No Slack/email integration or external message is created by this
base. Read firing alerts through Grafana's Prometheus data source.

## Adding application metrics and dashboards

Discovery of ServiceMonitor, PodMonitor, PrometheusRule, Probe and ScrapeConfig
objects is restricted to `monitoring` and label `release: metrics`. Only trusted
platform GitOps should write there. A monitor in an application namespace is
not automatically accepted. To onboard an application, install a reviewed monitor
in `monitoring` with an explicit target namespace/selector and a Cilium rule
allowing the Prometheus pods to reach only the application's metrics port.
The existing application ingress policy otherwise denies those scrapes. Never
expose a metrics port through an HTTPRoute just to make scraping work.

Grafana's upstream dashboard sidecar reads ConfigMaps labelled
`grafana_dashboard: '1'` in `monitoring` only, with namespaced RBAC. Application
ConfigMaps and Secrets cannot inject dashboards or data sources. Store reviewed
dashboard JSON in those ConfigMaps; Grafana polls the mounted files. Data sources
are provisioned directly from Helm values and change through a Grafana rollout,
without a password-based provisioning job.

## Verification and troubleshooting

```sh
flux get kustomizations
flux get helmrelease metrics -n monitoring
kubectl -n monitoring get pods,pvc
kubectl -n monitoring get prometheus,alertmanager,servicemonitor,podmonitor
```

If login reports an invalid redirect URI, check the existing Keycloak client
callback list. An authorization denial after successful login means the exact
host's OpenFGA grant/store/model needs checking. Do not turn off authorization
to diagnose either. A data source connection error calls for checking Prometheus
readiness and Cilium flows, not publishing Prometheus directly.

An administrator can inspect discovery using:

```sh
kubectl -n monitoring port-forward service/metrics-prometheus 9090:9090
# Open http://127.0.0.1:9090/targets locally.
```

CI renders the exact chart, checks private discovery/auth settings, exercises
admission denials, and starts the real stack with temporary volumes in kind. It
checks real node/kubelet samples, provisioned dashboards, anonymous denials and
the proxy user's Viewer role. CI substitutes a localhost proxy allowlist only for
its port-forward probes. It does not run the full production Cilium/Keycloak/FGA
request chain. On the LAN, verify an ungranted user is denied, a granted user can
read dashboards, revocation denies access, and a pod outside the trusted gateway
cannot reach Grafana/Prometheus even with a forged subject header.

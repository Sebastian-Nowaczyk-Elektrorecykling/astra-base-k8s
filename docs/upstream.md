# Pins and upstream design references

Reviewed 2026-09-09. These are exact starting versions, not a claim of permanent compatibility. Follow the upstream support windows and update the pins deliberately.

| Component | Pin | Official source |
| --- | --- | --- |
| k3s | `v1.36.4+k3s1` | [release](https://github.com/k3s-io/k3s/releases/tag/v1.36.4%2Bk3s1) |
| Cilium | chart `1.20.1` | [release](https://github.com/cilium/cilium/releases/tag/v1.20.1) |
| Flux | `v2.9.5` | [release](https://github.com/fluxcd/flux2/releases/tag/v2.9.5) |
| Workstation kubectl | `v1.36.4` | [installation and checksum validation](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) |
| Workstation Helm | `v4.2.4` | [release](https://github.com/helm/helm/releases/tag/v4.2.4) |
| Workstation SOPS | `v3.13.3` | [release](https://github.com/getsops/sops/releases/tag/v3.13.3) |
| Longhorn | chart `1.12.1`, V1 data engine | [release](https://github.com/longhorn/longhorn/releases/tag/v1.12.1) |
| CloudNativePG | chart `0.29.0`, operator `1.30.0` | [chart](https://github.com/cloudnative-pg/charts/releases/tag/cloudnative-pg-v0.29.0), [support](https://cloudnative-pg.io/docs/1.30/supported_releases/) |
| PostgreSQL | `17.11-standard-trixie` | [official operand images](https://github.com/cloudnative-pg/postgres-containers) |
| cert-manager | chart `v1.21.1` | [release](https://github.com/cert-manager/cert-manager/releases/tag/v1.21.1) |
| Kyverno | chart `3.9.0`, app `1.19.0` | [chart metadata](https://github.com/kyverno/kyverno/blob/v1.19.0/charts/kyverno/Chart.yaml) |
| Envoy Gateway | chart `v1.9.1` (owns Gateway API CRDs) | [release](https://github.com/envoyproxy/gateway/releases/tag/v1.9.1) |
| Keycloak | image `26.7.3` | [release](https://github.com/keycloak/keycloak/releases/tag/26.7.3) |
| Authorino | image/CRDs `v0.26.3`, standalone | [release](https://github.com/Kuadrant/authorino/releases/tag/v0.26.3) |
| OpenFGA | chart `0.3.14`, image `v1.20.0` | [release](https://github.com/openfga/helm-charts/releases/tag/openfga-0.3.14) |
| Optional NVIDIA | device plugin chart `0.19.2`, toolkit `1.20.0-1` | [plugin](https://github.com/NVIDIA/k8s-device-plugin/releases/tag/v0.19.2), [toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) |
| Optional API VIP | kube-vip `v1.2.3` | [release](https://github.com/kube-vip/kube-vip/releases/tag/v1.2.3) |
| Optional PG backup | Barman chart `0.8.0` | [release](https://github.com/cloudnative-pg/charts/releases/tag/plugin-barman-cloud-v0.8.0) |

## Why these integrations

Workstation CLI pins were checked on 2026-09-10. The workstation installer validates published SHA-256 checksums before installing binaries. Debian supplies age and the other administration dependencies through its signed package repositories. The Flux file layout follows [upstream bootstrap customization](https://fluxcd.io/flux/installation/configuration/bootstrap-customization/): include both generated manifests and provide an initially empty sync file for the component-install phase.

- [k3s embedded-etcd HA](https://docs.k3s.io/datastore/ha-embedded) and [custom CNI/egress configuration](https://docs.k3s.io/networking/basic-network-options) are the basis for the server flags. Disable the bundled competing network/storage components on **every** server.
- [Cilium L2 announcements](https://docs.cilium.io/en/stable/network/l2-announcements/) and [LB IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/) replace a separate application load-balancer allocator. The service's external traffic policy is `Cluster`, compatible with L2 announcement behavior.
- [Envoy Gateway OIDC](https://gateway.envoyproxy.io/v1.9/tasks/security/oidc/), [external authorization](https://gateway.envoyproxy.io/v1.9/tasks/security/ext-auth/) and [policy precedence](https://gateway.envoyproxy.io/v1.9/concepts/gateway_api_extensions/security-policy/) motivate the shared listener policy, explicit filter order and prohibition on child policy overrides.
- [Authorino HTTP metadata](https://github.com/Kuadrant/authorino/blob/v0.26.3/docs/user-guides/external-metadata.md) is a supported way to call OpenFGA's JSON Check endpoint. Authorino is configured directly; the full Kuadrant/Authorino operator stack is not required. Its 0.26.3 timeout fix is relevant to fail-closed behavior.
- The pinned [Authorino Dockerfile](https://github.com/Kuadrant/authorino/blob/v0.26.3/Dockerfile) creates UID 1000 but declares `USER authorino`. The Deployment sets numeric `runAsUser: 1000` alongside `runAsNonRoot: true`, so kubelet can verify the user. Its args contain only server flags because the image entrypoint already includes `authorino server`.
- [OpenFGA authorization concepts](https://openfga.dev/docs/authorization-concepts), [modeling](https://openfga.dev/docs/modeling) and [production configuration](https://openfga.dev/docs/getting-started/setup-openfga/configure-openfga) explain the separate identity/permission stores. An FGA model does not itself authenticate tokens or implement a future application's business checks.
- [Keycloak container deployment](https://www.keycloak.org/server/containers), [realm import](https://www.keycloak.org/server/importExport), [reverse proxy](https://www.keycloak.org/server/reverseproxy) and [standard token exchange](https://www.keycloak.org/securing-apps/token-exchange) define the supported deployment and delegation boundaries.
- [Longhorn prerequisites](https://longhorn.io/docs/1.12.1/deploy/install/), [StorageClass parameters](https://longhorn.io/docs/1.12.1/references/storage-class-parameters/) and [backup targets](https://longhorn.io/docs/1.12.1/snapshots-and-backups/backup-and-restore/set-backup-target/) cover the host preparation and ordinary-directory storage model.
- [CNPG storage](https://cloudnative-pg.io/docs/1.30/storage/), [replication](https://cloudnative-pg.io/docs/1.30/replication/) and [Barman plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/) describe database-layer durability, independent of Longhorn volume replicas.
- [Kubernetes validating admission policies](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) provide in-process security guards; [Kyverno mutation](https://kyverno.io/docs/policy-types/cluster-policy/mutate/) supplies storage defaults. The baseline contains no OPA server, handwritten authorization microservice, Crossplane composition, or Kratix controller.

Admission policy expressions and shell administration scripts are configuration/automation around these upstream projects. No generated application binary is part of the platform.

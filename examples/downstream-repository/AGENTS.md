# Instructions for human and AI authors

This repository extends an existing Elektro base cluster, contract version 1.
Read `README.md` and the [base contract](https://github.com/Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s/blob/main/docs/platform-contract.md)
before adding services. Record the exact base revision validated by this
repository; a reference to `main` is documentation, not a compatibility pin.

- Reuse the running Flux installation and base operators. Never run a second
  bootstrap or claim resources already owned by the base or another release.
- The supplied nested Flux reconciliations are trusted cluster administration.
  Do not describe this setup as isolation for untrusted Git contributors.
- Keep independent profile overlays under `clusters/NAME`. Get suffix/settings
  from `flux-system/cluster-settings`, and declare substitution/decryption on each
  child stage that needs them. Do not hardcode laptops, node counts or LAN IPs.
- Use exact HTTPRoutes in `edge` attached to the base listener, application
  ClusterIP Services and narrowly named ReferenceGrants. No alternate ingress,
  NodePort, public exposure, native-auth exemption, route filters or security
  override without an explicit base design change.
- Preserve verified subject handling. Keycloak callbacks, OpenFGA service grants,
  and business authorization are separate responsibilities. Do not infer grants
  from login, email or a client-provided subject. Never distribute administrative
  OpenFGA keys or Keycloak credentials to application workloads.
- Review network allowances for every dependency, including same-namespace CNPG
  replication/operator access. Policies are additive. Internal DNS resolution
  does not install the private CA into application images.
- Use workload node labels, restricted Pod security, pinned images/charts and
  declared readiness. GPU drivers/device plugin are an opt-in base prerequisite.
- Keep secrets encrypted with SOPS. Do not copy private age keys, kubeconfigs,
  join tokens or base credentials into this repository.
- Define data retention, backup/restore and cleanup of callbacks/grants/routes
  before adding prune-managed resources. Retained volumes are not backups.
- Validate Kustomize output for every target profile, CRD schemas and admission
  against the supported base; perform actual login/denial/outage acceptance before
  publishing sensitive services. Never run host wipe/removal or real-cluster
  failure tests as an incidental part of a code review.

Use supported upstream software and APIs. Do not add custom foundation services,
authentication proxies, controllers or Crossplane/Kratix compositions to work
around a missing integration.

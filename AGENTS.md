# Guidance for maintainers and coding agents

Read `README.md`, `docs/platform-contract.md` and the runbook for the component
being changed. `docs/scripts.md` describes the administration scripts. The shared
interface for downstream repositories is contract version 1, exported as
`flux-system/cluster-settings.data.BASE_CONTRACT_VERSION`.

- This repository owns the base cluster. Application/internal-developer-platform
  deployments belong in separate repositories. Use `examples/downstream-repository`
  as the maintained starter; do not bootstrap a second set of Flux controllers.
- Preserve the user's chosen upstream projects. Do not introduce custom running
  services/controllers, Crossplane/Kratix compositions or handwritten auth proxies.
- Keep one GitOps owner per resource. Put cluster-specific settings/attachments in
  `clusters/NAME`; do not fork the shared infrastructure for new host names or IPs.
- Read current files before editing. Keep existing user changes and unrelated
  credentials. Never run host installation, removal, wiping, router changes or
  real-cluster failure tests as part of a code review.
- Preserve fail-closed entry, exact hostnames, private/public separation and the
  verified subject header. A chart needing ingress, NodePorts, host access or a
  native-auth exception needs an explicit base design change, not weaker guards.
- Do not copy base age/private keys, kubeconfigs, join tokens or OpenFGA/Keycloak
  administrative credentials into downstream workloads or Git. Use SOPS and
  supported upstream administration APIs; placeholders in opt-in examples must be
  identified as inputs, never presented as discovered production values.
- Preserve node join/removal/role-change and HA tooling. Update integration tests
  when a new system DaemonSet changes controller scheduling or maintenance behavior.
- Run the relevant checks in `.github/workflows/validate.yaml`; use
  `python3 tests/render.py`, `python3 tests/network-settings.py` and
  `python3 tests/contracts.py` for local static validation when dependencies exist.
  The Debian CI jobs test workstation scripts, and disposable Kubernetes CI tests
  schemas/admission/runtime behavior. Report physical-network/storage/GPU and full
  browser-login acceptance separately; do not claim they ran on users' hardware.
- Update the contract, examples, script reference and affected runbooks with
  behavior changes. Do not retain obsolete alternative setup paths or duplicate
  manifests as compatibility workarounds. Intentional optional examples and
  safety/maintenance code are not obsolete merely because they are not bootstrapped.

Keep upstream version pins deliberate. A passing render is not an upgrade plan
for existing disks, database formats, identity state or external router firmware.

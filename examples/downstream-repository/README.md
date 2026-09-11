# Services on an Elektro base cluster

Copy the **contents of this directory** to a new, independently versioned Git
repository. This is a starter for a trusted platform team, using Elektro base
contract **1**. It installs no Flux controllers or additional base operators.
Read the [base contract](https://github.com/Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s/blob/main/docs/platform-contract.md)
and record the base revision tested by your own repository before deployment.

The included `demo` is the upstream Kubernetes `agnhost netexec` diagnostic
server. Use it to verify routing, then replace it with your application. It has
diagnostic endpoints and is not a production application template. Keep its
route protected; do not place secrets or sensitive input in diagnostic requests.

## Prepare the new repository

1. Rename `clusters/example` to the base profile name, such as `clusters/laptops`.
   For another independent cluster, copy that directory to `clusters/production`.
   Reuse `apps/` and `reconciliation/`; each Kubernetes API has its own objects.
2. Keep `applications` as the source/reconciliation prefix for the first attached
   repository. For another source in the **same cluster**, change the prefix in
   the base attachment and every child `sourceRef`, name and dependency together.
3. Commit and push the new repository. The two child stages deploy the workload
   first, then its route. Every stage that substitutes settings explicitly reads
   `flux-system/cluster-settings`. Workloads also use the existing `sops-age`
   decryption Secret. No application Secret is needed for the diagnostic server.

The base namespace, source, operators, gateway and settings must keep their
existing owners. Do not copy the base `clusters/NAME` directory or run
`flux bootstrap` against the new repository.

## Attach it from the base repository

Run these steps from the **base checkout** on the administrator workstation,
with that cluster's kubeconfig selected. Finish base bootstrap, including TLS
trust and OpenFGA initialization, first.

For a private GitHub repository, create a **separate read-only deploy key**:

```sh
mkdir -p local/laptops
umask 077
ssh-keygen -t ed25519 -N '' -C 'elektro-laptops-applications' \
  -f local/laptops/applications-deploy-key
```

Add only `applications-deploy-key.pub` to the new repository's GitHub deploy
keys, leaving write access disabled. Never reuse the base repository's deploy
key. Export its Secret using Flux's supported CLI, review the GitHub host key
against GitHub's published fingerprints, then encrypt it with this cluster's
public age recipient:

```sh
flux create secret git applications-git --namespace=flux-system \
  --url=ssh://git@github.com/YOUR_ORG/YOUR_APPLICATION_REPO \
  --private-key-file=local/laptops/applications-deploy-key --export \
  > local/laptops/applications-git.yaml
sops --encrypt --age age1YOUR_CLUSTER_PUBLIC_RECIPIENT \
  --encrypted-regex '^(data|stringData)$' local/laptops/applications-git.yaml \
  > clusters/laptops/secrets/applications-git.sops.yaml
```

Check that encryption succeeded before adding the encrypted file to
`clusters/laptops/secrets/kustomization.yaml`. Remove the local plaintext Secret
afterward. Preserve `bootstrap.sops.yaml` and the other existing entries. The
deploy key remains a sensitive local recovery credential. Upstream references:
[Flux Git Secret](https://fluxcd.io/flux/cmd/flux_create_secret_git/),
[GitHub SSH fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).

Copy `examples/downstream-source.yaml` from the base to
`clusters/laptops/applications.yaml`. Edit its Git URL and literal
`spec.path: ./clusters/laptops`, then add `applications.yaml` to the base
profile's root `kustomization.yaml` resources. Do **not** put `${CLUSTER_NAME}` in
this attachment's path: the base root does not perform that substitution.
Commit and push the base changes. For a public source, HTTPS with no `secretRef`
is an alternative; do not publish secrets merely to avoid a deploy key.

```sh
flux reconcile kustomization flux-system --with-source
flux get sources git
flux get kustomizations
kubectl -n app-demo get deployment,service
kubectl -n edge get httproute demo -o yaml
```

`applications` creates the child reconciliation objects. The workloads stage
waits for readiness; the routes stage waits for current `Accepted` and
`ResolvedRefs` conditions from Envoy Gateway. A green route still requires the
identity setup below. Use [the base troubleshooting/acceptance guide](https://github.com/Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s/blob/main/docs/validation.md)
when a dependency is not Ready.

## Enable access to demo

For laptops the URL is `https://demo.internal`; a profile using
`production.internal` produces `https://demo.production.internal` without
editing the shared route. Add that exact host's `/oauth2/callback` HTTPS URI to
the existing Keycloak client `elektro-edge`, preserving its other callbacks.
Grant the intended principal/group access to `service:demo.internal` (or the
actual profile hostname) in the cluster's OpenFGA store/model. Follow the
[identity runbook](https://github.com/Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s/blob/main/docs/identity-access.md)
for supported administration APIs and tuple shapes. No grants are automatic.

Use client DNS pointing at the base resolver and trust that cluster's private
CA. Check anonymous denial/login, authenticated denial without a grant, and
successful access after a grant. Test forged identity headers and authorization
service failure as described by the base acceptance guide. The verified
`X-Elektro-Subject` is an opaque subject, not an email or a business permission.

## Extend and retire services

- Add each application's namespace/workload/ClusterIP Service to the workloads
  overlay, and its exact HTTPRoute plus named ReferenceGrant to routes. Keep
  routes in `edge`; do not add a blanket Kustomize namespace transformer.
- A database needs its own CNPG Cluster, credentials, backup/recovery plan and
  explicit Cilium ingress allowances for clients, replication and the operator.
  The base's CNPG/network examples describe these. Same-namespace traffic is
  subject to the base application ingress policy too.
- Pin Helm charts/images and wait for required CRDs before their resources.
  Do not install another ingress, CNI, storage driver or PostgreSQL operator.
- Encrypt application Secrets for this cluster's public age recipient. Keep the
  private key in `flux-system/sops-age` and approved recovery storage. Sharing the
  public recipient is enough for authors; they do not need the private key.
- Define database/PVC deletion behavior before using `prune: true`. The sample
  namespace has pruning disabled; this alone does not retain every child
  workload, PVC or database CR. Removing the root attachment can cascade through
  its children. Remove routes/callbacks/grants first, back up data, then retire
  workloads deliberately. Never test deletion against the base-owned resources.

Application code, project naming, callbacks, OpenFGA tuples, business-level
authorization and agent delegation belong to this repository's future design;
the base does not supply a project lifecycle controller or automatic provisioning.

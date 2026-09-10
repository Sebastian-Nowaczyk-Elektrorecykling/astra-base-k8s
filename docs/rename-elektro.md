# Resume the earlier bootstrap with Elektro

The setup name is now `elektro`: the Keycloak realm, gateway client/audience, identity header, OpenFGA store display name, admission-policy names and platform/node labels use this name. The GitHub repository is still `Sebastian-Nowaczyk-Elektrorecykling/astra-base-k8s`, so your existing clone, deploy key and repository access continue to work. PostgreSQL cluster names, Longhorn volumes and encrypted Secret names are unchanged.

## Resume after the reported Flux error

The earlier empty `clusters/laptops/flux-system/kustomization.yaml` hid the generated controllers from Flux. The fixed resource list includes the component manifests and the sync placeholder. Flux fills in the latter after installing its controllers.

On the administrator workstation:

```sh
git pull --ff-only
sudo bash scripts/prepare-workstation.sh
hash -r
export KUBECONFIG="$PWD/local/kubeconfig"
```

Your existing nodes may still have `astra.local` labels from the first installation. Update the live labels before starting the renamed platform, using the original three-node layout:

```sh
kubectl label node k8s1 elektro.local/role=hybrid elektro.local/workloads=true --overwrite
kubectl label node k8s2 elektro.local/role=worker elektro.local/workloads=true --overwrite
kubectl label node k8s3 elektro.local/role=worker elektro.local/workloads=true --overwrite
kubectl get nodes -L elektro.local/role,elektro.local/workloads
```

For other layouts, use the actual role. A dedicated controller gets `elektro.local/role=controller` and `elektro.local/workloads=false`, with the `elektro.local/dedicated=control-plane:NoSchedule` taint. Add the new taint before removing its old `astra.local/dedicated` equivalent. If the NVIDIA option was already configured, also copy that node's GPU label to `elektro.local/gpu-vendor=nvidia`.

On each previously installed host, back up and edit `/etc/rancher/k3s/config.yaml`: replace `astra.local/` with `elektro.local/` in the `node-label` and any `node-taint` entries. This keeps the configured labels correct after node registration or replacement. The live label commands above take effect immediately; do not rerun the fresh-node k3s installer. Old labels may coexist during the transition and can be removed after the new selectors are in use.

Reuse the age key and encrypted secrets from your first attempt:

```sh
# Set GITHUB_TOKEN securely in this shell, as during the first attempt.
bash scripts/bootstrap-flux.sh local/age.agekey
unset GITHUB_TOKEN
git pull --ff-only
flux get kustomizations
```

Do not rerun `age-keygen` over your existing key or regenerate bootstrap credentials. Complete the remaining steps in [the bootstrap runbook](bootstrap.md), including your real DNS/IP settings, CA trust and first OpenFGA grant.

## If identity services had already been used

The reported failure happens before Flux installs the platform, so this section normally does not apply to that attempt. If you independently got Keycloak running and created users, take a database backup and migrate the existing realm through Keycloak's supported administration before switching applications. A changed import JSON is not an in-place realm migration: startup import skips an existing realm and can create a separate `elektro` realm while leaving `astra` intact. Preserve existing user IDs, credentials and OpenFGA grants when choosing a migration procedure.

Update the realm name, gateway client ID and audience mapper together; existing tokens and browser sessions for the previous issuer/audience must be replaced by a new login. Update applications that read the verified header from `X-Astra-Subject` to `X-Elektro-Subject`. An existing OpenFGA store ID remains usable; its display name does not control authorization. If the private CA was already issued under the old display name, verify the reissued CA and client trust as part of that planned cutover.

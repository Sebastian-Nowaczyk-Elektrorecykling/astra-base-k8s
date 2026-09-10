# Correct Cilium's Kubernetes API address

`local/cluster.env` supplies the initial Helm install. After bootstrap, Flux reads `API_HOST` from `clusters/laptops/settings.yaml`, substitutes it into `infrastructure/cilium/release.yaml`, and reconciles the Helm release. Flux cannot read an ignored file on your workstation. Previously, a correct local address could therefore be replaced with the example address `192.168.50.11` from Git.

The bootstrap script now copies `API_HOST` and `POD_CIDR` into the tracked ConfigMap. Flux bootstrap checks that those values match the local file and that the cluster configuration has been pushed to `origin/main`. For an existing cluster, use the steps below. Keep the pod CIDR at its existing value; this procedure changes the API endpoint, not the cluster's network ranges.

## Commit the correct desired address

On the workstation, using your existing kubeconfig and local settings:

```sh
git pull --ff-only
export KUBECONFIG="$PWD/local/kubeconfig"
bash scripts/configure-cluster.sh local/cluster.env
git diff -- clusters/laptops/settings.yaml
git add clusters/laptops/settings.yaml
git commit -m 'Use the correct Kubernetes API endpoint for Cilium'
git push origin main
```

`API_HOST` must be a reachable node address or an already working API VIP/DNS name, without a URL scheme or port. The configured API port is 6443. The API certificate must cover that address. Changing Cilium does not change the k3s API listener or certificate; a new HA endpoint needs the [HA procedure](high-availability.md).

Compare the live Flux settings, desired Helm values and actual pod templates:

```sh
kubectl -n flux-system get configmap cluster-settings -o jsonpath='{.data.API_HOST}{"\n"}'
kubectl -n kube-system get helmrelease cilium -o jsonpath='{.spec.values.k8sServiceHost}{"\n"}'
kubectl -n kube-system get daemonset/cilium deployment/cilium-operator -o json |
  jq -r '.items[] as $w |
    ($w.spec.template.spec.containers + ($w.spec.template.spec.initContainers // []))[] as $c |
    $c.env[]? | select(.name == "KUBERNETES_SERVICE_HOST") |
    [$w.metadata.name, $c.name, (.value // "ConfigMap reference")] | @tsv'
```

In Headlamp, the same values are under **flux-system → ConfigMaps → cluster-settings**, **kube-system → HelmRelease cilium**, and the Cilium workload/pod YAML's `KUBERNETES_SERVICE_HOST` environment variable. Inspect current pod YAML as well as the workload template if a rollout is incomplete.

## If Flux is healthy

Ask it to fetch the committed settings and reconcile Cilium:

```sh
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization cilium --with-source --timeout=15m
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m
```

Changing `k8sServiceHost` changes the pod template and triggers a rollout. The pinned Cilium chart puts the address into the [agent and its init containers](https://github.com/cilium/cilium/blob/v1.20.1/install/kubernetes/cilium/templates/cilium-agent/daemonset.yaml) and the [operator](https://github.com/cilium/cilium/blob/v1.20.1/install/kubernetes/cilium/templates/cilium-operator/deployment.yaml).

If the Cilium HelmRelease does not exist yet, Flux has not taken over that release. Run `bash scripts/bootstrap-cilium.sh local/cluster.env`, then commit/push any settings change before continuing Flux bootstrap.

## If broken networking prevents Flux from recovering

Use the workstation's direct, certificate-verified API connection. These steps are for an existing Flux-managed Cilium release. First complete the Git correction above; otherwise reconciliation can restore the wrong address.

```sh
kubectl get --raw=/readyz
flux suspend kustomization flux-system
flux suspend kustomization cilium
flux suspend helmrelease cilium -n kube-system
kubectl apply -f clusters/laptops/settings.yaml

# Source only your own trusted configuration file.
source local/cluster.env
patch=$(jq -n --arg host "$API_HOST" '{spec: {values: {k8sServiceHost: $host}}}')
kubectl -n kube-system patch helmrelease cilium --type=merge --patch "$patch"
```

Temporarily correct the live workload templates, including the init containers, so Cilium can restore the network without waiting for the in-cluster Helm controller. This strategic merge preserves each container's other settings and environment variables:

```sh
for workload in daemonset/cilium deployment/cilium-operator; do
  kubectl -n kube-system get "$workload" -o json |
    jq --arg host "$API_HOST" '{spec: {template: {spec:
      (.spec.template.spec | {containers, initContainers} |
       with_entries(select(.value != null)) |
       map_values(map({name, env: [
         {name: "KUBERNETES_SERVICE_HOST", value: $host, valueFrom: null},
         {name: "KUBERNETES_SERVICE_PORT", value: "6443", valueFrom: null}
       ]})))
    }}}' > local/cilium-api-recovery.patch.json
  kubectl -n kube-system patch "$workload" --type=strategic \
    --patch-file=local/cilium-api-recovery.patch.json
done
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m
```

Suspending a HelmRelease stops subsequent reconciliations; an already running Helm operation can still finish. If it rewrites a template during recovery, let that operation finish and repeat the template correction while the release remains suspended. Do not restart all Cilium pods at once: the workload controllers perform the rollout.

Once Cilium is healthy, restore GitOps management and let Helm converge the complete chart configuration:

```sh
flux resume kustomization flux-system
flux reconcile kustomization flux-system --with-source
flux resume kustomization cilium
flux resume helmrelease cilium -n kube-system
flux reconcile helmrelease cilium -n kube-system --reset --timeout=15m
flux reconcile kustomization cilium --with-source --timeout=15m
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=cilium
```

Recheck the three address views above. They must agree with `local/cluster.env`, and the Cilium pods must become Ready. If the address agrees but connections still fail, check reachability to TCP 6443 from each node, DNS if you use a hostname, and the API certificate's SANs; do not disable TLS verification.

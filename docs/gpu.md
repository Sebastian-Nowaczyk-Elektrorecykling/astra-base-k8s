# GPU preparation

Prepare the GPU **before the first `install-k3s.sh` invocation on that machine**.
k3s discovers the installed NVIDIA runtime on its first startup, so initial GPU
enablement needs no post-join drain or k3s restart. Driver installation can still
require a host reboot; perform it while the machine is outside the cluster.

`k8s2` is an example hostname, not a fixed GPU inventory. Use a **worker or
hybrid** for GPU workloads; a dedicated controller excludes the device plugin
and application workloads. Ordinary nodes need no GPU driver or vendor software.

## Fresh NVIDIA node: prepare before joining

Run host commands below on the intended Debian GPU machine, from this checkout.
If it already runs k3s, use [the existing-node procedure](#existing-node-or-later-driver-upgrades)
instead of repeating the fresh installer.

1. Complete the normal [Debian node preparation](bootstrap.md#2-prepare-and-start-nodes),
   including its reboot. If you already completed it, continue with step 2:

   ```sh
   sudo bash scripts/prepare-debian.sh --disable-sleep
   sudo reboot
   ```

2. After reconnecting, identify the GPU and running kernel:

   ```sh
   lspci -nn
   uname -r
   ```

   Enable the appropriate official Debian `contrib`, `non-free` and
   `non-free-firmware` components in your existing APT sources, preserving their
   release/suite. Choose a packaged driver that supports the exact GPU and kernel.
   If Debian's standard `nvidia-driver` package supports your model, the usual
   installation is (Debian package references: [driver](https://packages.debian.org/trixie/nvidia-driver),
   [nvidia-smi](https://packages.debian.org/trixie/nvidia-smi)):

   ```sh
   sudo apt-get update
   sudo apt-get install "linux-headers-$(uname -r)" nvidia-driver nvidia-smi
   ```

   Otherwise follow the supported branch/package selection in the
   [NVIDIA Debian driver guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/debian.html).
   Do not mix Debian and NVIDIA driver repositories without following their
   documented installation choice. Older GPUs and very new GPUs can need
   different branches; open kernel modules are not suitable for every generation.
   Secure Boot may require signing/enrolling the module's MOK during reboot.
   Complete the package instructions, then:

   ```sh
   sudo reboot
   ```

3. After reconnecting, require a successful host driver check before proceeding:

   ```sh
   nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
   ```

   Resolve missing devices, failed kernel-module loading or Secure Boot errors
   here, while there are no cluster workloads to evacuate. Check cooling and
   available VRAM too. A full CUDA development toolkit is not a prerequisite for
   this base's container-runtime preparation.

4. Install the pinned NVIDIA Container Toolkit **before installing k3s**:

   ```sh
   sudo bash scripts/prepare-nvidia.sh
   command -v nvidia-container-runtime
   nvidia-container-runtime --version
   ```

   The script installs the toolkit, not the kernel driver, k3s or a device plugin.
   It requires working `nvidia-smi` and stops on installation failure. The runtime
   executable must be in the k3s service's standard PATH, normally `/usr/bin`.
   Do not install a second containerd/Docker service or run `nvidia-ctk runtime configure`
   against `/etc/containerd/config.toml`: k3s manages its own containerd configuration.

5. Copy the selected profile's exported `local/cluster.env` and a suitable join
   token through the [bootstrap procedure](bootstrap.md#2-prepare-and-start-nodes).
   Keep the token root-readable and out of Git, command arguments and logs.
   Then join the prepared worker; replace the example name/API address:

   ```sh
   sudo bash scripts/install-k3s.sh --role worker --name k8s2 --ip auto \
     --config local/cluster.env --server https://192.168.2.153:6443 \
     --token-file /root/k3s-join-token
   ```

   For a hybrid joining an existing cluster, use `--role hybrid`, its stable LAN
   `--ip`, and a server-capable join token with the same `--server` endpoint.
   Use `--init` only if this is the **first server of a new cluster**; follow
   [bootstrap](bootstrap.md) rather than initializing a second cluster.
   Cilium/Flux bootstrap is performed once per cluster, not again for each GPU node.

6. Inspect the generated runtime configuration on this newly joined GPU host:

   ```sh
   sudo grep -n nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
   ```

   Expect an NVIDIA runtime entry pointing to the installed executable. A
   cluster-wide `RuntimeClass` alone does not prove detection on this node.
   Continue with the plugin and checks below. Initial installation starts the
   correct runtime; labelling the node and deploying the plugin do not require
   another service restart or a drain.

## Enable the device plugin and verify the joined node

From the **administrator workstation**, select the intended cluster's kubeconfig.
For a new cluster, first finish Cilium and the Flux foundation/controllers stages.
Wait for the joined node to become Ready, then opt that node into NVIDIA scheduling:

```sh
kubectl wait --for=condition=Ready node/k8s2 --timeout=5m
kubectl label node k8s2 elektro.local/gpu-vendor=nvidia
kubectl get runtimeclass nvidia
```

Record this label in the node's administrative inventory. It is applied to the
registered Node and does not require a k3s restart; removal/rejoin creates a new
Node and requires restoring it. The installer already supplies the worker/hybrid
`elektro.local/workloads=true` label.

Once per cluster profile, copy `examples/nvidia-reconciliation.yaml` to
`clusters/NAME/nvidia.yaml` and add `- nvidia.yaml` to that profile's existing
`kustomization.yaml` **resources**. Commit/push this base change, then:

```sh
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization gpu-nvidia
flux get helmrelease nvidia-device-plugin -n gpu-system
kubectl -n gpu-system get pods -o wide
kubectl describe node k8s2
```

If the stage is already enabled, just label each additional prepared GPU node.
The device-plugin HelmRelease selects the workload and GPU-vendor labels; it has
no NFD/GPU-feature-discovery bootstrap dependency. Expect a healthy plugin pod on
the intended node and a nonzero `nvidia.com/gpu` **Allocatable** value.

For a one-GPU-node cluster, run the supplied diagnostic Job:

```sh
kubectl apply -f examples/gpu-smoke.yaml
kubectl -n gpu-system wait --for=condition=Complete job/gpu-smoke --timeout=5m
kubectl -n gpu-system logs job/gpu-smoke
```

With multiple GPU nodes, copy this example into an ignored local file and add
`kubernetes.io/hostname: ACTUAL_NODE_NAME` to its `spec.template.spec.nodeSelector`
before applying it, so the test covers the machine just prepared. The existing
Job must finish and be deleted (or expire through its TTL) before reusing its name
with a changed node selector. Check the CUDA image's driver requirements for
your hardware. A successful `nvidia-smi` Job verifies GPU/container access, not a
particular inference framework or model; test that application's image separately.

## Existing node or later driver upgrades

Installing drivers/toolkit after joining, or upgrading a loaded driver/kernel,
is a maintenance operation. Plan storage/database availability and evacuate
workloads before changing the driver or restarting/rebooting a live node. Review
[Longhorn/CNPG maintenance blockers](node-role-changes.md#storage-and-database-blockers),
PDBs and DaemonSets; a plain drain does not evict every storage DaemonSet.
Keep surviving etcd quorum for a hybrid; restarting the only server interrupts
the control plane. The removal/rejoin scripts are not needed just to add a runtime.

After the required maintenance preparation, install the driver/toolkit, reboot
if needed, or restart `k3s-agent` on a worker / `k3s` on a hybrid so runtime
discovery runs again. Verify the host driver, generated containerd runtime entry,
node health, plugin and GPU capacity before uncordoning. Then run the smoke Job.
If the driver and runtime were already installed and detected before joining,
adding only the GPU label/plugin follows the section above and needs no restart.

Do not edit the generated containerd file or launch a second device plugin/GPU
Operator over the same devices. Diagnose missing runtime detection through the
service PATH and its journal; diagnose zero allocatable GPUs through plugin logs,
the host driver and actual device availability.

## Resource sharing and other vendors

The default gives each pod a whole GPU through an explicit `nvidia.com/gpu: 1`
limit and `runtimeClassName: nvidia`. GPU resources cannot be overcommitted like
ordinary CPU requests. MIG requires a supported GPU; consumer laptop GPUs usually
do not support it. Time slicing has isolation/VRAM implications and is not enabled.
No model-serving application, scheduler extension, distributed training stack or
inference operator is installed.

If ordinary workloads should stay off the GPU node, add an explicit
`nvidia.com/gpu=present:NoSchedule` taint and matching tolerations for the GPU
plugin/jobs **and all required storage/system workloads**. The baseline does not
add that taint because Longhorn and base services may need the node's resources.
Measure latency and memory pressure when combining inference, etcd and storage.

For AMD or Intel, leave the NVIDIA option disabled. Install and verify the
vendor-supported host driver/firmware before joining, then deploy that vendor's
supported Kubernetes device plugin/operator for the actual GPU and Debian kernel.
Resource keys/runtime support differ; this repository does not claim untested
cross-vendor inference compatibility.

Official references: [NVIDIA toolkit installation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),
[NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin),
[k3s alternative runtime support](https://docs.k3s.io/advanced#alternative-container-runtime-support).

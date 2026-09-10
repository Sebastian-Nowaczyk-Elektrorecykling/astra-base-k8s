# GPU preparation

`k8s2` is only an example hostname. Ordinary nodes get no GPU driver, taint or vendor workload. Check `lspci -nn`, the exact GPU model, supported driver branch, Secure Boot status, cooling and available VRAM before choosing a runtime.

For NVIDIA on Debian:

1. Enable the appropriate official Debian `contrib`, `non-free` and `non-free-firmware` components, and install the supported packaged driver and headers for your kernel. Check Debian/NVIDIA documentation for your device. A blanket driver branch is unsafe for older laptop GPUs; Secure Boot may require MOK enrollment. Reboot and make `nvidia-smi` work on the **host** first.
2. Run `sudo bash scripts/prepare-nvidia.sh`. It installs the pinned upstream NVIDIA Container Toolkit. If k3s already runs there, drain the node safely, restart `k3s-agent` (or `k3s` on a hybrid), verify detection and uncordon. k3s discovers `nvidia-container-runtime` from its service PATH on startup and provides RuntimeClass `nvidia`.
3. Label the actual GPU node: `kubectl label node k8s2 elektro.local/gpu-vendor=nvidia`. Record the label in your node inventory. Add the resource from `examples/nvidia-reconciliation.yaml` to the cluster configuration. The device-plugin HelmRelease selects only that label, and has no implicit NFD/GPU-node-label bootstrap dependency.
4. Verify `kubectl get runtimeclass nvidia` and `kubectl describe node k8s2` show `nvidia.com/gpu`. Apply `examples/gpu-smoke.yaml` and inspect its logs. A successful host `nvidia-smi` alone is insufficient.

Do not run `nvidia-ctk` against `/etc/containerd/config.toml` for this k3s setup: it is a different configuration path. k3s manages the containerd template/runtime entries. Check `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` after restart if detection fails. Do not launch a second device plugin or GPU Operator over the same devices.

The default gives each pod a whole GPU through an explicit `nvidia.com/gpu: 1` limit. GPU resources cannot be overcommitted like ordinary CPU requests. MIG requires a supported GPU; consumer laptop GPUs usually do not support it. Time slicing has isolation/VRAM implications and is not enabled. No model-serving application, scheduler extension, distributed training stack or inference operator is installed.

If ordinary workloads should stay off the GPU node, add an explicit `nvidia.com/gpu=present:NoSchedule` taint and matching tolerations for the GPU plugin/jobs **and all required storage/system workloads**. The baseline does not add that taint because Longhorn and base services may need k8s2's resources. Do not combine GPU inference and etcd/storage contention without measuring latency and memory pressure.

For AMD or Intel, leave the NVIDIA option disabled and use the vendor's supported Kubernetes device plugin/operator for the actual GPU generation and Debian kernel/driver combination. Resource keys/runtime support differ. The common cluster networking, storage and node-role preparation remain applicable. This repository does not claim untested cross-vendor inference compatibility.

Official references: [NVIDIA toolkit installation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html), [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin), [k3s alternative runtime support](https://docs.k3s.io/advanced#alternative-container-runtime-support).

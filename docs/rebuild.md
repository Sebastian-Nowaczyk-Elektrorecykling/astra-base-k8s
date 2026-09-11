# Rebuild the laptops cluster from scratch

This is a **new, empty cluster** using the existing `laptops` GitOps profile.
Wiping all laptop disks destroys etcd, Longhorn replicas and the Keycloak/OpenFGA
databases. Export anything you want to retain to storage outside these machines
first. For recovering data instead, use [backup/recovery](operations.md).

Do not run `remove-node.sh` on every laptop to perform this reset: it deliberately
protects the last server and storage replicas. That script and `set-server-role.sh`
remain the tools for [individual node/role maintenance](node-role-changes.md).

## 1. Retire the old instance

1. Give the workstation and laptops working DNS independent of the cluster.
   Temporarily change DHCP DNS if it points only at the cluster you are wiping.
2. Save any required data/credentials offline, then power off **all** old cluster
   nodes. Do not let the old and new installations advertise the same service IPs
   simultaneously. If you enabled BGP or public port forwarding separately,
   disable those old cluster entries until the replacement passes acceptance.
3. Reinstall Debian 12/13 on each laptop, wiping/reformatting the old OS/data
   filesystems, including `/var/lib/rancher/k3s`, `/etc/rancher/k3s` and
   `/var/lib/longhorn`. Keeping an old `/var` filesystem is not a clean reinstall.
   Retain the intended host names if useful; they do not retain Kubernetes identity.

No router reset is needed. Preserve the controller's DHCP reservation and the
excluded service pool, after checking they match the real LAN.

## 2. Prepare the workstation checkout and profile

Pull the current `main` and install/update its workstation tools. Use the normal
working checkout; do not delete other cluster profiles or their `local/NAME` files.

```sh
git pull --ff-only
sudo bash scripts/prepare-workstation.sh
hash -r
```

Archive the old laptops files **after the old nodes are off**. This moves local
credentials out of active paths and saves the old encrypted bundle; it does not
contact Kubernetes or wipe a machine. The archive is ignored by Git and must be
protected as credentials. Copy it to secure offline storage if needed for recovery.

```sh
umask 077
mkdir -p local
rebuild_archive=$(mktemp -d "$PWD/local/retired-laptops.XXXXXX")
for name in laptops cluster.env kubeconfig age.agekey openfga.key openfga-state.json platform-ca.crt; do
  if [ -e "local/$name" ]; then
    mv -- "local/$name" "$rebuild_archive/$name"
  fi
done
if [ -f clusters/laptops/secrets/bootstrap.sops.yaml ]; then
  mv clusters/laptops/secrets/bootstrap.sops.yaml "$rebuild_archive/bootstrap.sops.yaml"
fi
unset KUBECONFIG SOPS_AGE_KEY SOPS_AGE_KEY_FILE
```

Remove the old cluster connection from Headlamp and stop old port-forwards. Retire
any other old laptops token/header/grant files you created under `local/`; never
reuse an old user UUID or OpenFGA store/model ID for the new databases. If you used
different credential paths, archive those too.

In `clusters/laptops/settings.yaml`:

- Keep the chosen network and `.internal` names. Defaults are API
  `192.168.2.153`, pool `.240`–`.249`, gateway `.240`, DNS `.242` on
  `192.168.2.0/24`. Adapt them if your actual LAN/mask differs. Exclude the pool
  from DHCP; workers need no reservations. See [the settings reference](clusters.md).
- Remove any profile overrides for `FGA_STORE_ID` and `FGA_MODEL_ID`, so both
  inherit `NOT_CONFIGURED` from the base. The empty OpenFGA database will generate
  new IDs even if a credential happened to be reused.
- For the first clean test, leave BGP disabled and optional public/API-VIP stages
  out of the profile. Use the initial controller IP as `API_HOST`. Do not erase
  shared infrastructure or generated `gotk-components.yaml`/`gotk-sync.yaml`.

The encrypted secret file is regenerated in bootstrap part 4 below. Until then,
the old secrets kustomization temporarily references the removed file; **do not
commit/push this intermediate state**. The generator recreates the file and its
resource list together. Existing encrypted credentials are not automatically
deleted from Git history or from any other cluster.

## 3. Run the fresh bootstrap

Follow [bootstrap parts 1–5](bootstrap.md), starting by exporting the edited
profile. The runbook's default local paths are now free for new credentials.

```sh
mkdir -p local
bash scripts/configure-cluster.sh --export laptops > local/cluster.env
```

Copy that file to each prepared node. Initialize exactly one new hybrid:

```sh
# On freshly prepared k8s1, after the preparation reboot:
sudo bash scripts/install-k3s.sh --role hybrid --name k8s1 --ip 192.168.2.153 \
  --config local/cluster.env --init
```

Copy the **new** k3s server token securely to the other machines. Join any number
of workers using `--role worker --ip auto --server https://192.168.2.153:6443
--token-file /root/k3s-join-token`; use each machine's unique name. Additional
controllers/hybrids join with that server token and `--server`, never `--init`.
The [HA guide](high-availability.md) covers the eventual stable API VIP and quorum.

Continue the runbook with the **new** kubeconfig, Cilium, a new age key and newly
generated encrypted secrets. Commit/push the completed profile before Flux
bootstrap. Keep the age key offline. Flux bootstrap can reuse the repository and
its generated sync manifests; it creates the new cluster's credentials. If GitHub
reports that an old deploy key conflicts, remove **only the retired laptops key**
in the repository's Deploy keys settings, identified by its saved old public key,
and rerun bootstrap. Do not remove another cluster's deploy key.

Import the **new public** cluster CA into the workstation/browser and remove the
retired CA after checking its fingerprint. Reusing the internal hostnames does
not preserve trust. Clear old Keycloak/gateway browser sessions for those names.
Create new Keycloak users, initialize OpenFGA once, commit its new store/model IDs,
and grant the new user UUID access to Longhorn and Grafana. Logins alone grant no
dashboard access. Re-add the new kubeconfig to Headlamp.

## 4. Accept the new installation

```sh
kubectl get nodes -o wide
flux get kustomizations
flux get helmreleases -A
kubectl get clusters.postgresql.cnpg.io -A
kubectl -n kube-system get service lan-dns -o wide
dig @192.168.2.242 k8s2.hosts.internal +short
dig @192.168.2.242 grafana.admin.internal +short
```

Verify the node answer is its current LAN IP and Grafana resolves to `.240`.
Complete [DNS checks](dns.md), [access checks](validation.md) and a disposable
PVC/database test before keeping data. Point clients/DHCP back at `.242` only
after the resolver works. Restore GPU preparation on the intended GPU node.
Enable [BGP](bgp.md) later if needed; it is not a prerequisite for this rebuild.

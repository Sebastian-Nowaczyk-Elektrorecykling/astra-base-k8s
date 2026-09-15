# Administration script reference

Run workstation commands as your regular administrator user with the intended
kubeconfig. Run host commands on the named physical node as root. All env files
are trusted shell input; never source files supplied by an untrusted application.
Paths below are relative to this repository's root. The [bootstrap runbook](bootstrap.md)
provides the ordered installation, and [node maintenance](node-role-changes.md)
provides the data-safety procedure. Internal `scripts/lib/` files are not entrypoints.
`scripts/validate-cluster.py` is the internal validator called by the configuration
commands; it reads merged settings as JSON on stdin and contacts no cluster.

| Script | Where / inputs | Effects and limits |
| --- | --- | --- |
| `prepare-workstation.sh` | Debian workstation, root; no arguments | Installs pinned administrator CLIs and dependencies; no cluster/host installation |
| `prepare-debian.sh` | Each Debian node, root; optional `--disable-sleep` | Installs host prerequisites, configures kernel/sysctl/mount propagation, disables swap; reboot afterward; no partitioning or GPU driver installation |
| `install-k3s.sh` | Prepared node, root; role/name/config and exactly one of `--init` or `--server` plus token file | Fresh install/join; `--ip auto` defaults to startup address discovery; `--print-config` is read-only. Refuses existing installations. Download/service failures may leave an incomplete installation to inspect, not overwrite blindly |
| `prepare-nvidia.sh` | Intended NVIDIA worker/hybrid, root, working `nvidia-smi` | Installs pinned container toolkit; no kernel driver or cluster join. Prefer running before `install-k3s.sh` so the first startup detects it; existing nodes need maintenance before a runtime restart. See [GPU ordering](gpu.md#fresh-nvidia-node-prepare-before-joining) |
| `create-cluster.sh` | Workstation; `NAME [INTERNAL_DOMAIN]` | Creates a new local profile from the template; contacts no cluster, copies no credentials; refuses existing names |
| `configure-cluster.sh` | Workstation; `--export NAME`, trusted `FILE`, or `--check FILE` | Exports bootstrap, LAN, DNS, pool and BGP values; imports an intended env change or checks agreement without writing. Rejects retired enable/interface flags and invalid merged profiles; does not inspect DHCP leases or discover a free VIP |
| `configure-bgp.py` | Workstation; `NAME --node-ip IP [--node-ip IP ...]` or `NAME --discover`; optional `--dns-forwarding`, `--router-id IP`, `--include-public` | Prints filtered EdgeOS commands after validation and optional checked controller discovery. Preserves the router ID unless explicitly supplied; public routing requires separate opt-in. DNS forwarding requires the router in the allowed DNS client range. Writes/deletes no router or cluster settings and never commits them. See [BGP setup](bgp.md#generate-the-router-setup) |
| `bootstrap-cilium.sh` | Workstation; trusted env `FILE`, selected admin kubeconfig | First Cilium Helm install with the profile's API and shared BGP-on/L2-off values; checks cluster target and refuses a Flux-managed release |
| `generate-secrets.sh` | Workstation; `AGE_PUBLIC_RECIPIENT [NAME]` | Initializes missing `secrets/` and its Kustomization in an existing profile; generates random identity/FGA bootstrap credentials and publishes complete SOPS ciphertext; preserves existing Kustomize options/resources and refuses existing credentials; failed encryption leaves no target file |
| `bootstrap-flux.sh` | Workstation; age key file, optional env file, temporary `GITHUB_TOKEN` | Bootstraps this base repository, creates `sops-age` and a read-only Git deploy key; lets Flux generate an absent/empty `flux-system/`, validates existing customizations, and verifies settings/current API and pushed configuration. Pull afterward to obtain generated files. Not for attaching a second service repository |
| `bootstrap-openfga.sh` | Workstation; FGA key file, optional `NAME`; selected cluster forwarded to localhost:8080 | Creates the base gateway store/model once and records IDs under `local/NAME`; creates no access grants. NAME chooses the state path, not the port-forward target; verify that connection separately |
| `verify-access.sh` | Workstation; hostname and trusted public CA file | Checks anonymous/invalid-token/spoofed-header denial or login statuses. Does not prove successful login, backend identity, business authorization or outage behavior |
| `remove-node.sh` | Workstation; `--node NAME --ssh USER@HOST`, optional `--apply` | Default read-only checks; apply evacuates Longhorn/drains/retires membership/uninstalls. Protects last server/workload capacity. State supports `--resume`; reboot before rejoin |
| `set-server-role.sh` | Workstation; node/SSH, `--role controller\|hybrid`, optional `--apply` | Default read-only checks; changes an existing server's scheduling role without replacing etcd. Worker/server conversion uses removal/rejoin. Networking and node-exporter may remain on a controller |

`remove-node.sh` and `set-server-role.sh` also support `--timeout SECONDS` and
explicit `--delete-emptydir-data`. They preserve PDBs and do not use forced pod
eviction. They operate on healthy nodes at the repository's pinned k3s version
and its standard paths/config format; outages, custom datastores, override files
and non-Longhorn local volumes need a separate recovery review. Keep one
maintenance operation active at a time and retain its logs/state.
These helpers do not inspect BGP sessions or edit router neighbors. Verify
surviving controller paths before removal, and update neighbors after adding,
retiring or changing a controller's address as described in the BGP runbook.

For a running cluster, API/VIP changes use the [HA runbook](high-availability.md),
role changes use [node maintenance](node-role-changes.md), and whole-cluster wipes
use [rebuild](rebuild.md). Do not confuse these with rerunning the fresh installer.

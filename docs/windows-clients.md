# Windows access with an ordinary browser

Use normal Windows DNS and the public certificate of the cluster's private CA. No Kubernetes
client, browser extension, hosts-file inventory, BGP client or application agent
is required. Examples use the laptops profile: router `192.168.2.1`, DNS
`192.168.2.242`, gateway `192.168.2.240`, suffix `internal`. Substitute your actual
profile values; Windows addresses remain DHCP-managed.

| Network mode | Windows routing setup | DNS and TLS setup |
| --- | --- | --- |
| Default L2, same LAN | Existing DHCP address/mask/gateway | Choose one DNS option below; trust the cluster root once |
| L2 plus BGP, same LAN | Identical; on-link VIPs still use ARP | Identical |
| Allowed VLAN/VPN, either mode | Existing gateway/VPN must route to the node LAN; router/firewall must permit access | Prefer conditional DNS through that network's resolver; trust the same root |

Do not add persistent `/32` routes to individual laptops. They bypass normal
failover and become stale. BGP peers are the router and controllers; Windows
does not participate. [The L2/BGP guide](bgp.md#l2-and-bgp-together-on-this-lan)
explains the two paths and their failure behavior. Overlapping home/VPN subnets,
guest-Wi-Fi isolation or a VPN that denies LAN access require a network fix;
DNS and certificates cannot supply missing reachability.

## Option A: keep DHCP and use router DNS

Recommended for the company LAN. Add [EdgeRouter conditional forwarding](dns.md#edgerouter-conditional-forwarding)
and let DHCP continue supplying the router's LAN address as DNS. If that is
already the DHCP setting, Windows needs no DNS change. Otherwise reconnect or
renew the lease after the administrator changes the scope. On a domain-managed
Windows network, keep its AD DNS servers and put the conditional forwarder there
instead; replacing AD DNS can break domain services.

Inspect the active adapters without changing them:

```powershell
Get-NetIPConfiguration
Get-DnsClientServerAddress
```

All advertised/configured resolvers must know the internal zone, including any
IPv6 DNS servers. A public secondary resolver is not a per-domain fallback.
Retain IPv6 networking; configure its resolver path consistently. With conditional
forwarding, a cluster outage affects internal queries while the router continues
resolving public names independently.

## Option B: one workstation with a suffix rule

Useful for a pilot workstation when you cannot change the router. An NRPT rule
sends only `.internal` lookups through `DNS_IP`, leaving adapter DNS, DHCP and
ordinary Internet resolution unchanged. It is a machine-level DNS policy; adding
or removing it requires **PowerShell as administrator**. On a managed/VPN machine,
inspect effective policy first and have its administrator resolve overlapping
rules; Group Policy or VPN rules may take precedence over local configuration.

```powershell
Get-DnsClientNrptPolicy -Effective
Get-DnsClientNrptRule | Format-List Name, Namespace, NameServers, Comment

# Run once, only after checking there is no conflicting rule for this suffix.
Add-DnsClientNrptRule -Namespace '.internal' -NameServers '192.168.2.242' -Comment 'Elektro laptops internal DNS'
Clear-DnsClientCache
Get-DnsClientNrptPolicy -Effective
```

The leading dot means a suffix; do not use `*.internal` or `.` (all DNS). Use the
profile's `.production.internal` for a second cluster. A more-specific suffix can
select its resolver, provided that address is reachable from this workstation.
Do not point two independent clusters at the same suffix. See Microsoft's
[NRPT command](https://learn.microsoft.com/en-us/powershell/module/dnsclient/add-dnsclientnrptrule)
and [policy behavior](https://learn.microsoft.com/en-us/windows-server/networking/dns/name-resolution-policy-table).

Remove just the added rule when retiring this setup or moving to router DNS:

```powershell
Get-DnsClientNrptRule | Where-Object Comment -EQ 'Elektro laptops internal DNS' |
    Format-List Name, Namespace, NameServers, Comment
# Copy the exact Name (GUID) of the reviewed Elektro rule above.
Remove-DnsClientNrptRule -Name '{RULE-GUID}' -Force
Clear-DnsClientCache
```

Do not delete all NRPT rules. This rule remains active when the workstation leaves
the LAN; `.internal` needs a suitable VPN or will fail there, while unrelated
names still use normal DNS. Windows name-resolution policy does not force an
application with its own resolver to obey it; see browser diagnostics below.

## Option C: use CoreDNS for the adapter

This is the simple direct-DNS alternative already supported by the base. In
Windows network settings, select the actual Ethernet/Wi-Fi adapter and set its
DNS server to `DNS_IP`, keeping IP assignment and the default gateway on DHCP.
Record the previous DNS settings first. All lookups now depend on the cluster;
public queries use `DNS_UPSTREAMS`. Do not add a public secondary DNS server, and
check other active adapters/IPv6 DNS for inconsistent resolvers. Restore the
previous settings (normally DNS Automatic/DHCP) to undo. Options A or B avoid
making public browsing depend on the laptops cluster.

## Trust the public root certificate once

The cluster administrator exports the root through the authenticated Kubernetes
API using [the TLS runbook](tls.md#export-and-identify-the-public-root). Obtain
`platform-ca.cer` and its SHA-256 fingerprint through a trusted channel. This is
the public certificate, never a `.key`, PFX, kubeconfig or Kubernetes Secret YAML.
Each independent cluster has its own root even if the display name is the same.

For the least machine-wide impact, open ordinary **Windows PowerShell as the
intended browser user**, without elevation. Verify the SHA-256 file hash matches
the administrator's fingerprint (the exported `.cer` is DER, so these hashes
match), then import it:

```powershell
$CaFile = Join-Path $env:USERPROFILE 'Downloads\platform-ca.cer'
Get-FileHash -Algorithm SHA256 -LiteralPath $CaFile
# Compare the hash through the trusted channel before running the next line.
$ImportedCa = Import-Certificate -FilePath $CaFile -CertStoreLocation 'Cert:\CurrentUser\Root'
$ImportedCa | Format-List Subject, Issuer, NotAfter, Thumbprint
```

This trusts the CA for this Windows account. Windows may display a root-install
confirmation, and organizational policy can restrict user-added roots. For all
users, an administrator can instead use `Cert:\LocalMachine\Root`; for a fleet,
distribute the public root through the organization's existing Group Policy/MDM.
[Microsoft documents both certificate stores](https://learn.microsoft.com/en-us/powershell/module/pki/import-certificate).

Current Edge and Chrome honor locally installed Windows roots, including user
roots. Firefox 120 and later enables OS-root trust by default. Restart the browser
after import. No per-site certificate exceptions or disabled TLS checks are
needed with these defaults. See [Edge certificate verification](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-security-cert-verification),
[Chromium's Windows trust-store integration](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/cert/internal/trust_store_win.cc)
and [Firefox OS-root trust](https://support.mozilla.org/en-US/kb/automatically-trust-third-party-certificates).

A root-store entry trusts this CA beyond `.internal`; the default CA has no DNS
name constraint. A user store limits the affected Windows account, not the names
the CA can certify. Only install the verified cluster root. Its private key stays
with infrastructure administrators; see [root lifecycle and recovery](tls.md#renewal-recovery-and-root-rotation).

To remove a retired root, use its exact saved **Thumbprint** (the Windows store
identifier, distinct from the SHA-256 fingerprint), inspect it, then remove it:

```powershell
Get-Item 'Cert:\CurrentUser\Root\EXACT_RETIRED_THUMBPRINT' | Format-List Subject, NotAfter, Thumbprint
Remove-Item 'Cert:\CurrentUser\Root\EXACT_RETIRED_THUMBPRINT'
```

Use the original store and its required privileges. Never delete by common name:
another live cluster can have that same certificate name.

## Verify and troubleshoot

Run these in ordinary PowerShell after DNS/trust configuration:

```powershell
# Direct service tests: bypass normal resolver selection, useful for diagnosis.
Resolve-DnsName grafana.admin.internal -Server 192.168.2.242 -Type A -DnsOnly
Resolve-DnsName grafana.admin.internal -Server 192.168.2.242 -Type A -DnsOnly -TcpOnly
# Effective Windows resolver: omit -Server to exercise DHCP/NRPT configuration.
Resolve-DnsName grafana.admin.internal -Type A -DnsOnly
[System.Net.Dns]::GetHostAddresses('keycloak.admin.internal')
Resolve-DnsName k8s1.hosts.internal -Type A -DnsOnly
Resolve-DnsName example.org -Type A -DnsOnly
Test-NetConnection grafana.admin.internal -Port 443
```

Application names should return `EDGE_IP`; a registered node name returns that
node's current LAN IP. `nslookup` and an explicit `-Server` are direct resolver
tests, not proof that ordinary applications used an NRPT rule. A ping failure is
not decisive for a Service VIP: test TCP 443 and both DNS transports instead.

Open **`https://keycloak.admin.internal/admin`**, then
**`https://grafana.admin.internal`**. Include `https://`: the base has no port 80
redirect. Open the browser certificate viewer and check the hostname/chain and
expiry. Keycloak login plus the exact OpenFGA grant is required for Grafana;
a permission denial after valid TLS is separate from a network failure.

| Symptom | Check |
| --- | --- |
| Direct DNS succeeds, normal lookup fails | Effective NRPT, DHCP resolvers on every adapter, IPv6 DNS, VPN/AD policy; clear Windows DNS cache |
| Windows lookup succeeds, browser lookup fails | Browser Secure DNS/DoH, remote-DNS proxy or VPN; restart browser to clear its cached result |
| Untrusted certificate | Correct root fingerprint and Windows account/store, complete served chain, browser OS-root policy |
| Wrong-name or expired certificate | Use the hostname rather than the VIP; check Windows time and cert-manager Certificate status |
| `foo.internal` fails TLS while admin/test names work | Add its exact SAN to the base certificate; `*.internal` is rejected by common clients ([procedure](tls.md#exact-names-for-applications-directly-under-internal)) |
| Same-LAN access works, router/routed access fails with BGP | Selected `/32` next hop, negotiated hold time, stale routes and router firewall |
| Router DNS fails but direct DNS works | Conditional rule, DNS rebind checks, router source address and its BGP route |

An unmodified browser using system/default local-compatible DNS works with this
setup. A browser explicitly locked to a public DoH resolver cannot be made to
resolve private names merely by changing Windows/router DNS. Edge's strict
`secure` mode has no ordinary-DNS fallback; Firefox's default rollout uses
fallback, but custom protection settings differ. Use a supported internal-zone
exception/system-resolver policy through existing endpoint management if needed;
do not weaken TLS or install a browser extension. Likewise, a remote-DNS proxy
must resolve and reach the private zone. [Edge DoH modes](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/dnsoverhttpsmode)
and [Firefox DoH behavior](https://support.mozilla.org/en-US/kb/firefox-dns-over-https)
describe these limits. This base exposes plain LAN DNS on TCP/UDP 53, not a DoH
endpoint; do not configure `https://dns.admin.internal/dns-query` in a browser.

For a pilot, verify both the default installed browser and any company-managed
browser/VPN combination. For BGP acceptance, also test the router or an allowed
routed client: a browser on the VIP's subnet usually exercises L2 alone. No
Windows or physical EdgeRouter execution is performed by repository CI.

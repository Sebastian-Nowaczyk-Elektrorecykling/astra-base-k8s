# Private TLS for internal names

Keep the private CA for `.internal`. Publicly trusted CAs cannot issue for
internal server names; installing the cluster's **public root certificate** in
Windows is the required trust step for these names. BGP and DNS do not change
certificate trust. See the [CA/Browser Forum's internal-name guidance](https://cabforum.org/uploads/Guidance-Deprecated-Internal-Names.pdf)
and [Windows setup](windows-clients.md#trust-the-public-root-certificate-once).

## What the base issues

| Resource | Purpose | Lifetime / key behavior |
| --- | --- | --- |
| `cert-manager/platform-root-ca` Certificate and Secret | Self-signed ECDSA P-256 root, through `bootstrap-selfsigned` | 87600 hours (3650 days), renewal scheduled 8760 hours before expiry; preserve its key |
| `platform-ca` ClusterIssuer | Signs using that root Secret | Issuer reads the CA key; it does not distribute trust |
| `edge/edge-tls` Certificate and Secret | Private gateway server certificate | 2160 hours (90 days), renew 720 hours before expiry; rotate the leaf key |

The edge certificate requests `*.internal`, `*.admin.internal`,
`*.test.internal` and `*.staging.internal`, or those four patterns beneath the
profile's `INTERNAL_DOMAIN`. A single-label wildcard already covers each new
random test deployment; no certificate request per test deployment is needed.
There is an additional constraint: **`*.internal` is a wildcard directly beneath
a top-level suffix and is rejected for `foo.internal` by common TLS clients**.
This was reproduced with OpenSSL; Chromium's [hostname verifier](https://chromium.googlesource.com/chromium/src/+/90ab54e99e9e6bd8958dc1c14b690881fad02996/net/cert/x509_certificate.cc)
also excludes wildcards at unknown top-level domains. Trusting the private CA
does not relax hostname matching. Use the exact-name procedure below for ordinary
`foo.internal` applications. The admin/test/staging wildcards are sufficiently
deep, as is `*.production.internal` for a profile with that suffix.

`*.internal` also would not cover `foo.test.internal`, which is why the grouped
SANs exist. Multi-label test names, raw VIP URLs and the suffix apex are not
covered. Exact routing, callbacks and OpenFGA grants remain necessary.

`NODE.hosts.internal` resolves a machine address and is not a gateway TLS endpoint.
k3s has a separate API CA and server certificate, supplied in the administrator's
kubeconfig. Importing the gateway root does not authenticate Kubernetes API access,
and Headlamp should keep using that kubeconfig's CA. No wildcard machine-web
certificate is installed on nodes.

The gateway serves the certificate through its Secret reference and follows
Secret updates. Clients trust the root, so ordinary leaf renewal requires no
Windows changes. Verify the served certificate after renewal; a Ready Certificate
alone does not prove the gateway has delivered it to clients. cert-manager
documents [Certificate renewal and key rotation](https://cert-manager.io/docs/usage/certificate/#issuance-behavior-rotation-of-the-private-key).

## Exact names for applications directly under .internal

Preserve names such as `foo.internal` by adding exact SANs to the base-owned
`edge-tls` Certificate. This uses normal Flux patches and cert-manager issuance;
no extra controller, application code or per-site browser exception is involved.
The list is managed once per base profile and can contain names from multiple
downstream repositories.

Copy [private-app-certificate-names.yaml](../examples/private-app-certificate-names.yaml)
to `clusters/laptops/certificate-names.yaml`. Retain the `demo` entry when using
the downstream starter, replace it otherwise, and add one JSON-patch `add`
operation per ordinary application hostname. Add this file to the **patches**
list in the profile's existing `kustomization.yaml`, preserving other patches:

```yaml
patches:
  - path: settings.yaml
  - path: certificate-names.yaml
  # Preserve the profile's existing inline patches here too.
```

This patches the base Flux `certificates` Kustomization, whose nested patch extends
`Certificate/edge-tls.spec.dnsNames` before Flux substitutes `${INTERNAL_DOMAIN}`.
Keep all existing exact SAN entries. Do not replace the four shared wildcard
entries, copy the private key or let another reconciliation own `edge-tls`.
If `certificates.spec.patches` is already customized, merge the new operations
into that list rather than replacing it.

Commit/push, reconcile `flux-system` and then `certificates`, and wait for issuance.
Verify the **served** certificate contains the new exact name before advertising
the application's URL. Extend its exact HTTPRoute, Keycloak callback and FGA grant
as usual. On retirement, remove the route/callback/grants first, then its exact
SAN. Every SAN edit can renew the shared leaf key; clients still trust the same CA.

For `foo-RANDOM.test.internal` and the admin/staging groups, no per-deployment
TLS edit is required. For a deeper profile suffix such as `production.internal`,
`foo.production.internal` is covered by that profile's ordinary wildcard.
If future automation provisions direct `foo.internal` names, its reviewed Git
workflow must update this base SAN list as well as its downstream route and
identity entries. A ready HTTPRoute alone cannot prove client hostname validation.

## Export and identify the public root

On the trusted administrator workstation, with the correct cluster's kubeconfig:

```sh
kubectl -n cert-manager wait --for=condition=Ready certificate/platform-root-ca --timeout=5m
kubectl -n edge wait --for=condition=Ready certificate/edge-tls --timeout=5m
mkdir -p local
kubectl -n cert-manager get secret platform-root-ca -o jsonpath='{.data.ca\.crt}' \
  | base64 --decode > local/platform-ca.crt
openssl x509 -in local/platform-ca.crt -noout -subject -issuer -dates -fingerprint -sha256
openssl x509 -in local/platform-ca.crt -outform DER -out local/platform-ca.cer
sha256sum local/platform-ca.cer
```

The PEM `.crt` is useful with curl/OpenSSL; the DER `.cer` is convenient for
Windows. Their encoded file hashes differ. The DER file's SHA-256 hash equals
the displayed certificate fingerprint after removing colons and normalizing
letter case. Windows `Get-FileHash` on that same `.cer` therefore provides a
direct comparison. The Windows certificate-store Thumbprint is a different
identifier; use it only when selecting the exact imported entry for inspection
or removal.

Transfer only the public certificate using an authenticated channel and verify
the fingerprint independently of an untrusted download. A fresh browser cannot
securely bootstrap CA trust from a site whose certificate it does not yet trust.
Never send `tls.key`, Secret YAML, private age keys or kubeconfigs to application
users. The public certificate itself can be distributed freely once its
authenticity is established.

On the Debian workstation, a direct TLS verification that also checks SNI and
hostname is:

```sh
openssl s_client -connect 192.168.2.240:443 -servername grafana.admin.internal \
  -CAfile local/platform-ca.crt -verify_hostname grafana.admin.internal \
  -verify_return_error </dev/null
```

Substitute the actual `EDGE_IP` and profile hostname. This bypasses DNS for
diagnosis while retaining certificate validation. Then test normal DNS and the
[full access flow](validation.md#access-checks). No `-k` or browser warning bypass
is needed.

## Renewal, recovery and root rotation

The root explicitly uses `rotationPolicy: Never`; the leaf uses `Always`.
cert-manager 1.18 and later defaults to rotating keys on reissuance. An unnoticed
new root key would not match existing client trust, so this base makes their
different lifecycles explicit. Applying this setting to an existing intact root
Secret is intended to preserve that key for future renewal; do not delete the
Secret or force a root renewal merely to apply it.

This is not permanent trust: renewing the root Certificate in Kubernetes does
not update the certificate previously imported into Windows. The installed root
still expires on its original date. Monitor both cluster certificate expiry and
the oldest root distributed to clients; plan the replacement before the root's
one-year renewal window, not after browsers report errors.

The private root key lives online in the cluster. Cluster/Secret administrators
can issue certificates with it, and the default root is not constrained to
`.internal` names. The CA issuer supplies no operated CRL/OCSP service here.
For a pilot this keeps the installed base small. A company PKI requiring offline
roots, revocation or centrally governed issuance should use an existing supported
issuer/PKI integration before broad trust distribution; adding trust-manager
alone would not install roots on Windows. No additional PKI software is installed
by this change.

For recovery, include the CA Secret in encrypted, off-cluster administrative
backups together with the Kubernetes state and required decryption material.
Application authors must not receive the signing key. An etcd snapshot includes
Secrets; protect it accordingly. If intentionally restoring the same trust
identity, restore the original CA Secret before cert-manager generates a new
one, and check its fingerprint against the saved public root. A clean wipe with
no restoration creates a new CA and requires the Windows trust step again,
regardless of whether IPs/names are reused. See [rebuild](rebuild.md).

For a planned replacement, make a reviewed base change with a separately named
root/issuer, distribute the new public root alongside the old one, then switch
the edge Certificate's issuer and verify newly issued/served leaves. Keep the
old trust until clients and dependent certificates have moved, then remove the
retired root by fingerprint/thumbprint. Merely replacing the CA Secret does not
force existing leaf certificates to renew. During a compromise, remove the
compromised trust promptly and use an incident-specific recovery plan; keeping
it trusted for a leisurely overlap is inappropriate. The upstream
[CA issuer limitations](https://cert-manager.io/docs/configuration/ca/#important-information)
explain why CA rotation and trust distribution are separate responsibilities.

Inspect current lifetimes and scheduled renewal:

```sh
kubectl -n cert-manager get certificate platform-root-ca \
  -o custom-columns=NAME:.metadata.name,EXPIRES:.status.notAfter,RENEW:.status.renewalTime
kubectl -n edge get certificate edge-tls \
  -o custom-columns=NAME:.metadata.name,EXPIRES:.status.notAfter,RENEW:.status.renewalTime
```

These are explicit operational checks, not an out-of-band expiry notification
service. Keep workstation and node clocks synchronized.

## Public certificates without public application exposure

If importing a private root becomes unacceptable for a future group of clients,
an alternative is an owned registered DNS suffix with ACME DNS-01 validation.
DNS-01 can issue certificates for a web service that remains private; it needs
public validation TXT records and DNS-provider authorization, not public inbound
HTTP/HTTPS. Public certificate names are normally visible in Certificate
Transparency logs; a wildcard can avoid listing each random deployment name.
See [Let's Encrypt DNS-01](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge).

That alternative requires deliberate naming/certificate/route/identity changes;
it does not make `.internal` publicly certifiable and is not enabled here.
The current base continues using private names and its private gateway.
For actual Internet applications such as `fuzzy.elektrorecykling.pl`, use the
separate [public gateway and certificate procedure](../examples/public-exposure/README.md).
Issuing a certificate, enabling BGP or trusting a CA never substitutes for that
explicit exposure decision.

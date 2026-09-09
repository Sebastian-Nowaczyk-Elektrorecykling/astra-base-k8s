# Public certificates (optional)

The base uses a private CA. This sample selects Cloudflare DNS-01 only as one supported provider; replace the solver with cert-manager's RFC2136 or your provider if appropriate. Do not install another certificate manager.

Create a minimally scoped DNS API token for your zone, store it as the SOPS-encrypted `cert-manager/cloudflare-dns` Secret (`api-token` key), edit the email, and reconcile the issuer. Test against Let's Encrypt staging first. Once the issuer is Ready, change `infrastructure/certificates/resources.yaml` so `edge-tls` uses `letsencrypt-dns` instead of `platform-ca`. Preserve the single owner of `edge-tls`. DNS-01 supports the wildcard without exposing HTTP or adding an authentication bypass for ACME.

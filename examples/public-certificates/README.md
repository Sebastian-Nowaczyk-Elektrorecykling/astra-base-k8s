# Public certificates (optional)

The internal gateway keeps its private CA: publicly trusted issuers do not issue certificates for these `.internal` names. This sample selects Cloudflare DNS-01 as one supported provider; use cert-manager's RFC2136 or your existing provider if appropriate. It uses the already installed cert-manager.

Create a minimally scoped DNS API token for the public zone and store it as the SOPS-encrypted `cert-manager/cloudflare-dns` Secret (`api-token` key). Set a real ACME contact email in `issuer.yaml`, then reconcile the issuer from your chosen Flux repository. Test against Let's Encrypt staging first. DNS-01 avoids a public HTTP challenge listener or authentication bypass.

Once the production issuer is Ready, the separate [public exposure example](../public-exposure/README.md) requests `public-edge-tls` for the exact external application and login names. Keep `edge-tls` owned by `infrastructure/certificates` and signed by `platform-ca`. Adding a public hostname requires updating its Certificate SANs as well as its route; never use the private wildcard certificate for a public name.

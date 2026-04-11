# Cloudflare DNS Setup for aegisremit.ng

## 1. Add site to Cloudflare

1. Go to [dash.cloudflare.com](https://dash.cloudflare.com)
2. Click "Add a site" → enter `aegisremit.ng`
3. Select **Free plan**
4. Cloudflare gives you two nameservers (e.g. `anna.ns.cloudflare.com`, `bob.ns.cloudflare.com`)

## 2. Update nameservers at Whogohost

1. Log in to [app.go54.com](https://app.go54.com)
2. Go to Domain → My Domains → aegisremit.ng → Manage Domain
3. Select "Custom Nameservers"
4. Enter the two Cloudflare nameservers
5. Click "Update Nameservers"
6. Wait 15–60 minutes for propagation

## 3. DNS records

Once your Contabo VPS is provisioned, add these A records in Cloudflare.
Replace `YOUR_VPS_IP` with the IP from your Contabo welcome email.

| Type  | Name       | Content       | Proxy  | TTL  |
|-------|------------|---------------|--------|------|
| A     | `@`        | YOUR_VPS_IP   | Off    | Auto |
| A     | `api`      | YOUR_VPS_IP   | On     | Auto |
| A     | `app`      | YOUR_VPS_IP   | On     | Auto |
| A     | `traefik`  | YOUR_VPS_IP   | Off    | Auto |
| A     | `rabbitmq` | YOUR_VPS_IP   | Off    | Auto |
| A     | `signoz`   | YOUR_VPS_IP   | Off    | Auto |
| CNAME | `www`      | aegisremit.ng | On     | Auto |

### Why proxy some and not others:

- **`api` and `app`** — Proxied (orange cloud) for DDoS protection + CDN
- **`traefik`, `rabbitmq`, `signoz`** — DNS-only (gray cloud) because these
  are admin dashboards behind BasicAuth, and Cloudflare proxy can interfere
  with WebSocket connections (RabbitMQ management) and long-lived streams

## 4. Cloudflare API token for SSL

Traefik uses Cloudflare DNS challenge to get wildcard SSL certs.

1. Go to [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Click "Create Token"
3. Use the "Edit zone DNS" template
4. Permissions: **Zone → DNS → Edit**
5. Zone Resources: **Include → Specific zone → aegisremit.ng**
6. Create token → copy the value
7. Add to your VPS `.env` file as `CF_DNS_API_TOKEN=<token>`

## 5. Cloudflare SSL/TLS settings

In Cloudflare dashboard → SSL/TLS:

- **Encryption mode**: Full (strict)
  - This means Cloudflare ↔ Traefik uses real Let's Encrypt certs (not self-signed)
- **Edge Certificates → Always Use HTTPS**: On
- **Edge Certificates → Minimum TLS Version**: 1.2

## 6. Cloudflare security settings

In Cloudflare dashboard → Security:

- **Bot Fight Mode**: On
- **Browser Integrity Check**: On
- **Security Level**: Medium

## 7. Verify

After DNS propagates and Traefik starts:

```bash
# Check DNS resolution
dig api.aegisremit.ng +short

# Check SSL cert
curl -vI https://api.aegisremit.ng 2>&1 | grep -i "subject\|issuer"

# Check API health
curl https://api.aegisremit.ng/health
```

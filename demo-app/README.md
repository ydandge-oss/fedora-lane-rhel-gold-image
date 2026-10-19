# Fedora Lane — dummy boutique app (PoC)

Static demo storefront that runs on gold VMs via the existing **Podman httpd** container on port **35443**.

This shows how customers **host an application on gold VMs** without rebuilding the AMI/VHD for every app change.

## What it is

| Path | Purpose |
|---|---|
| `html/index.html` | Boutique landing + catalog UI |
| `html/api/catalog.json` | Dummy product API |
| `html/health.json` | Health check for demos / LB probes |
| `deploy-to-vm.sh` | Push app files onto a running gold VM |

## Deploy to an existing gold VM

```bash
# AWS or Azure PoC VM (SSH 2222, fladmin1)
cd solution/demo-app
PUBLIC_IP=<poc-public-ip> ./deploy-to-vm.sh
# or
./deploy-to-vm.sh <poc-public-ip>
```

Then open:

- `http://<ip>:35443/` — storefront  
- `http://<ip>:35443/health.json` — health  
- `http://<ip>:35443/api/catalog.json` — catalog  

## How this maps to “hosting apps”

1. Gold image = OS + security + container runtime (stable).  
2. App files land on the httpd volume (`/opt/fl/httpd-gold/html`).  
3. Update the app → re-run `deploy-to-vm.sh` (or CI/CD) — **no new gold image**.  
4. Change OS/hardening → edit blueprint → **new** gold image → replace VMs.

## Firstboot default

`solution/image-builder/files/fl-gold-firstboot.sh` installs this same demo app on first boot so a fresh gold VM already serves the boutique page.

# Solution overview — Fedora Lane RHEL gold image

## Problem

Fedora Lane runs ~1,600 servers with mixed Linux distributions. Ad-hoc change is hard to audit. Ops need a clear container path for web services.

## Solution

One **local RHEL Image Builder** blueprint in Git → compose **AMI** (AWS) and **VHD** (Azure) → launch identical web VMs.

**What is the blueprint?** See [blueprint-explained.md](./blueprint-explained.md).  
**TOML files:** [fedora-lane-gold.blueprint.toml](./fedora-lane-gold.blueprint.toml) · [fedora-lane-gold.toml](./fedora-lane-gold.toml)

```text
TOML blueprint (Git)
    → Local Image Builder (RHEL 10 host)
    → Gold disk (.raw / .vhd)
    → AWS AMI / Azure managed image
    → Web nodes (SSH 2222, httpd 35443)
```

## Expansion Pack controls (on every gold VM)

| Control | How |
|---|---|
| Separate mounts &lt; 5 GiB | Blueprint `[[customizations.filesystem]]` for `/var/log`, `/home`, `/tmp`, `/var/tmp` |
| `/tmp` noexec | Firstboot remount |
| SELinux enforcing | Firstboot + config |
| SSH 2222, key-only, no root | `sshd_config.d` + firewall |
| fladmins | Group + users in blueprint |
| httpd container :35443 | Firstboot Podman |
| Firewall | Only 2222 + 35443 |

## Why local Image Builder

Expansion Pack requires a **manual** gold image — not hosted console.redhat.com. Local `image-builder` CLI on a subscribed RHEL host matches that.

## Day-2

- **App change:** deploy to httpd volume (`demo-app/`) — no new AMI.  
- **OS / hardening change:** edit TOML → new gold image → replace VMs in waves.  
- Persistent app data stays off the web VM (DB / object storage).

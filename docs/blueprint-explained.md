# What is the Image Builder blueprint?

The **blueprint** is a TOML recipe file that tells **local RHEL Image Builder** how to build Fedora Lane’s gold image.  
It is the **source of truth** in Git — not a running VM you hand-edit.

## Files in this repo

| File | Role |
|---|---|
| [`fedora-lane-gold.blueprint.toml`](./fedora-lane-gold.blueprint.toml) *(link → image-builder)* | Editable recipe (partitions, users, firewall, packages) |
| [`fedora-lane-gold.toml`](./fedora-lane-gold.toml) *(link → image-builder)* | Compose-ready copy (blueprint + embedded firstboot script) |
| [`../image-builder/files/fl-gold-firstboot.sh`](../image-builder/files/fl-gold-firstboot.sh) | First-boot script baked into the image |

Canonical location: [`../image-builder/`](../image-builder/). The files under `docs/` are the same content (symlinks) so reviewers can open them from the docs tree on GitHub.

---

## In plain language

Think of the blueprint as a **shopping list + security checklist** for a new RHEL disk:

1. **Which OS** — `distro = "rhel-10.1"` (must be a versioned id, not bare `rhel-10`)  
2. **Which packages** — e.g. `podman`, `firewalld`, `sudo`  
3. **Disk layout** — separate mounts for `/var/log`, `/home`, `/tmp`, `/var/tmp` (each under 5 GiB)  
4. **Who can log in** — group `fladmins`, users `fladmin1` / `fladmin2`, SSH public keys  
5. **Network hardening** — firewall ports **2222** and **35443** only  
6. **SSH policy** — port 2222, no root, no password SSH  
7. **Firstboot** — script that sets SELinux ports, `/tmp` noexec, starts **httpd in Podman** on 35443  

Image Builder reads this file and builds a **disk image** (`.raw` / AMI / VHD). Every VM launched from that image gets the same baseline.

---

## What each major section means

### Identity

```toml
name = "fedora-lane-gold"
distro = "rhel-10.1"
```

Name of the blueprint and the exact RHEL 10 minor Image Builder should use.

### Separate filesystems (Expansion Pack)

```toml
[[customizations.filesystem]]
mountpoint = "/var/log"
minsize = "4 GiB"
# also /home, /tmp, /var/tmp — each under 5 GiB
```

So logs and temp data cannot fill the root disk.

### Admins

```toml
[[customizations.group]]
name = "fladmins"

[[customizations.user]]
name = "fladmin1"
groups = ["fladmins", "wheel"]
key = "ssh-rsa AAAA..."
```

Named admins with keys — not anonymous root logins.

### Firewall + SSH

```toml
[customizations.firewall]
ports = ["2222:tcp", "35443:tcp"]
```

Plus an `sshd_config.d` drop-in: Port 2222, `PermitRootLogin no`, `PasswordAuthentication no`.

### Firstboot service

The blueprint installs `fl-gold-firstboot.service`, which runs `fl-gold-firstboot.sh` once after first boot to finish SELinux port labels, `/tmp` noexec, and the httpd container.

---

## How we use it

```bash
cd image-builder
# 1) Edit the blueprint (keys, sizes, packages)
vi fedora-lane-gold.blueprint.toml

# 2) Merge firstboot → compose-ready TOML
./generate-blueprint.sh

# 3) Build
sudo ./compose.sh ami    # AWS
sudo ./compose.sh vhd    # Azure
```

You do **not** change production by SSHing into an old gold VM and “saving” it.  
You change the **blueprint in Git**, compose a **new** gold image, then launch / replace VMs.

---

## Related

- Build steps: [../image-builder/README.md](../image-builder/README.md)  
- Architecture: [solution-overview.md](./solution-overview.md)  
- Spoken script (blueprint talking points): [15-minute-script.md](./15-minute-script.md)

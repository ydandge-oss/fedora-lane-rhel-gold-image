# Local RHEL Image Builder (RHEL 10 CLI)

Fedora Lane’s gold image is built with **local** RHEL Image Builder — package `image-builder`, command `image-builder`.

Do **not** use hosted Image Builder on console.redhat.com for this standard.

Official links: [docs/redhat-documentation.md](../docs/redhat-documentation.md)

## Blueprint

| File | Use |
|---|---|
| `fedora-lane-gold.blueprint.toml` | Edit this (keys, sizes, packages) |
| `generate-blueprint.sh` | Merges firstboot → `fedora-lane-gold.toml` |
| `fedora-lane-gold.toml` | Compose-ready (do not hand-edit firstboot block) |
| `files/fl-gold-firstboot.sh` | SELinux ports, `/tmp` noexec, httpd container |

## Install (RHEL 10 builder)

```bash
sudo rhc connect          # RHSM required for Image Builder
sudo ./install-image-builder.sh
# or: sudo dnf install -y image-builder
sudo image-builder list | grep rhel-10 | grep x86_64 | grep ami
```

Expect versioned distros such as `rhel-10.0` / `rhel-10.1` — **not** bare `rhel-10`.

## Build

```bash
./generate-blueprint.sh
sudo ./compose.sh ami          # AWS
sudo ./compose.sh vhd          # Azure
```

Build + AWS upload:

```bash
sudo image-builder build ami \
  --blueprint ./fedora-lane-gold.toml \
  --distro rhel-10.1 \
  --aws-region us-east-2 \
  --aws-bucket YOUR_BUCKET \
  --aws-ami-name fedora-lane-rhel10-gold
```

More examples: [13-image-builder-aws-examples.md](./13-image-builder-aws-examples.md)  
S3 / credentials: [12-aws-access-s3-upload.md](./12-aws-access-s3-upload.md)  
Full rebuild notes: [08-rhel10-rebuild.md](./08-rhel10-rebuild.md)

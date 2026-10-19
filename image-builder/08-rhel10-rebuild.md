# Rebuild gold image on RHEL 10

## Once on the builder

```bash
sudo rhc connect
sudo dnf install -y image-builder
cd /path/to/this-repo/image-builder
./generate-blueprint.sh
```

Confirm distro id:

```bash
sudo image-builder list | grep -E '^rhel-10\.[0-9]+ type:ami'
```

Set the same id in `fedora-lane-gold.blueprint.toml` (`distro = "rhel-10.x"`), then regenerate.

## Compose AMI

```bash
sudo ./compose.sh ami
# or with upload flags via compose.sh env AWS_BUCKET / AWS_REGION / AWS_AMI_NAME
```

## Compose VHD (Azure)

```bash
sudo ./compose.sh vhd
```

## After compose

- **AWS:** AMI appears in EC2 → AMIs (or re-run upload). Then [docs/aws-cli-and-console.md](../docs/aws-cli-and-console.md).  
- **Azure:** upload `.vhd` → managed image. Use `../azure/` scripts.  

Time: often **1–2 hours** for a first compose.

# Fedora Lane — RHEL 10 Gold Image

**Audience:** Fedora Lane infrastructure, security, and Linux operations (e-commerce web fleet).  
**Goal:** A secure, standardized **Red Hat Enterprise Linux 10** gold image for web servers on **AWS** and **Azure**.

---

## What we built

A **repeatable RHEL 10 gold image** defined in Image Builder TOML, published as an **AWS AMI** and **Azure VHD**, and proven on live VMs with hardened SSH, SELinux, separate filesystems, and **httpd in a Podman container**.

---

## Challenges → this solution

| Challenge | What the gold image does |
|-----------|---------------------------|
| **Inconsistent servers** (mixed OS, drift) | One RHEL 10 AMI/VHD — identical layout every launch |
| **Untraceable admin changes** | Named `fladmins`, no root/password SSH, passworded sudo |
| **Container skills gap** | **httpd** in Podman on port **35443** |

Full narrative: [docs/solution-overview.md](docs/solution-overview.md)  
Official Red Hat docs: [docs/redhat-documentation.md](docs/redhat-documentation.md)

---

## Repository layout

```text
README.md                          ← you are here
image-builder/
  fedora-lane-gold.toml            ← compose-ready blueprint
  fedora-lane-gold.blueprint.toml  ← edit this + run generate-blueprint.sh
  files/fl-gold-firstboot.sh       ← SELinux ports, /tmp noexec, httpd
  compose.sh / install-image-builder.sh
  README.md · 08-rhel10-rebuild.md · 12-… · 13-…
docs/
  solution-overview.md
  08-verify-customizations.md
  aws-cli-and-console.md           ← AWS without project scripts
  azure-cli-and-console.md         ← Azure without project scripts
  15-minute-script.md              ← presentation teleprompter
aws/                               ← RHDP AWS Blank OPEN automation
azure/                             ← RHDP Azure Blank OPEN automation
demo-app/                          ← dummy boutique site (deploy without new AMI)
verify/verify.sh
scripts/                           ← notes / optional helpers
```

---

## Requirements checklist

- [x] Local Image Builder (not hosted console.redhat.com)
- [x] Base: **RHEL 10** (`distro = "rhel-10.x"` — confirm with `image-builder list`)
- [x] Deployable on **AWS** (AMI) and **Azure** (VHD)
- [x] httpd container on port **35443**
- [x] Separate mounts `<5 GiB`: `/var/log`, `/home`, `/tmp`, `/var/tmp`
- [x] SELinux **enforcing**; `/tmp` **noexec**
- [x] SSH **2222**; no root SSH; no password SSH
- [x] `fladmins` + `fladmin1` / `fladmin2`
- [x] Firewall: only 2222 + 35443
- [x] Survives reboot
- [ ] Stretch: OpenSCAP CIS (not done yet)

SSH public keys for `fladmin1` / `fladmin2` are in the blueprint — replace with yours before compose.

---

## How to build and run

### Prerequisites

1. A **RHEL 10** host with local Image Builder (`image-builder` CLI), **or** use `aws/` / `azure/` scripts to launch a builder.  
2. Cloud credentials (AWS and/or Azure) — **never commit** them.  
3. Builder subscribed to Red Hat (`sudo rhc connect`) so Image Builder can depsolve.  
4. SSH key (lab default path: `~/.ssh/fl-gold-poc.pem`).

### Build (high level) — on the RHEL 10 builder

```bash
sudo dnf install -y image-builder
# Must show e.g. rhel-10.0 type:ami — NOT bare "rhel-10"
sudo image-builder list | grep rhel-10 | grep ami

cd image-builder
./generate-blueprint.sh          # if you edited the .blueprint.toml
sudo ./compose.sh ami
```

Or raw CLI:

```bash
sudo image-builder build ami \
  --blueprint ./fedora-lane-gold.toml \
  --distro rhel-10.1
```

### Build + upload to AWS

```bash
sudo image-builder build ami \
  --blueprint ./fedora-lane-gold.toml \
  --distro rhel-10.1 \
  --aws-region us-east-2 \
  --aws-bucket fl-gold-<ACCOUNT>-us-east-2 \
  --aws-ami-name fedora-lane-rhel10-gold
```

Needs IAM role **`vmimport`** (see `aws/setup-vmimport-role.sh`).

**Easiest (Mac → scripts):**

```bash
cd aws
cp -n env.example env.local    # fill AWS keys — never commit
./setup-vmimport-role.sh
./compose-on-builder.sh
# on builder: sudo rhc connect
# ./continue-compose-on-builder.sh <BUILDER_IP>
./launch-gold-ami.sh
./verify-remote.sh
```

### Upload an existing `.raw`

```bash
sudo image-builder upload ./your-image.raw \
  --to=aws \
  --aws-region us-east-2 \
  --aws-bucket fl-gold-<ACCOUNT>-us-east-2 \
  --aws-ami-name fedora-lane-rhel10-gold
```

Or: `./aws/reupload-ami-from-builder.sh <BUILDER_IP>`

Details: [image-builder/13-image-builder-aws-examples.md](image-builder/13-image-builder-aws-examples.md) · [12-aws-access-s3-upload.md](image-builder/12-aws-access-s3-upload.md)

### Launch a VM from the gold AMI (AWS)

Gold VMs use **SSH port 2222** and **httpd port 35443** (not port 22).  
PoC region: **us-east-2**.  
AMI name: `fedora-lane-rhel10-gold` (also try `fl-rhel-gold` if that is what you registered).

#### Option A — AWS CLI (one step at a time)

```bash
export AWS_REGION=us-east-2
export AWS_DEFAULT_REGION=us-east-2
```

**1. Find the gold AMI**

```bash
aws ec2 describe-images --owners self \
  --filters Name=name,Values=fedora-lane-rhel10-gold Name=state,Values=available \
  --output table
```

```bash
AMI_ID=ami-xxxxxxxx
echo $AMI_ID
```

**2. Default VPC + subnet**

```bash
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --output table
VPC_ID=vpc-xxxxxxxx

aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --output table
SUBNET_ID=subnet-xxxxxxxx
```

**3. Security group (ports 2222 + 35443)**

```bash
aws ec2 create-security-group \
  --group-name fl-gold-sg \
  --description "Fedora Lane gold SSH 2222 + httpd 35443" \
  --vpc-id $VPC_ID \
  --output table
SG_ID=sg-xxxxxxxx

MYIP=x.x.x.x/32
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 2222 --cidr $MYIP
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 35443 --cidr $MYIP
```

(Ignore errors if the group or rules already exist.)

**4. Launch the instance**

```bash
KEY_NAME=fl-gold-poc

aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --associate-public-ip-address \
  --output table

INSTANCE_ID=i-xxxxxxxx
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
```

**5. Get public IP**

```bash
aws ec2 describe-instances --instance-ids $INSTANCE_ID --output table
PUBLIC_IP=x.x.x.x
```

**6. Connect and prove (wait ~4–5 minutes for firstboot / Podman)**

```bash
ssh -i ~/.ssh/fl-gold-poc.pem -p 2222 fladmin1@$PUBLIC_IP
curl -s http://$PUBLIC_IP:35443/
```

On the VM:

```bash
getenforce
findmnt /var/log /home /tmp /var/tmp
ss -tln | grep -E '2222|35443'
curl -s http://127.0.0.1:35443/ | head
exit
```

Full checklist: [docs/08-verify-customizations.md](docs/08-verify-customizations.md)

**Optional — User data at launch** (so httpd starts reliably, especially for Console launches):

```yaml
#cloud-config
runcmd:
  - [rm, -f, /var/lib/fl-gold-firstboot-done]
  - [/bin/bash, /etc/fl-gold/bin/fl-gold-firstboot.sh]
```

#### Option B — AWS Console

1. Open AWS Console → region **US East (Ohio) / us-east-2**.  
2. **EC2 → AMIs → Owned by me** → select **fedora-lane-rhel10-gold** (or `fl-rhel-gold`) → **Launch instance from AMI**.  
3. Instance type: **t3.medium**.  
4. Key pair: any existing key (login still uses the key baked into the AMI for `fladmin1`, e.g. `~/.ssh/fl-gold-poc.pem`).  
5. Network: enable **Auto-assign public IP**.  
6. Security group: allow **TCP 2222** and **TCP 35443** from **My IP** (not port 22).  
7. Storage: at least **40 GiB**.  
8. **Advanced details → User data** — paste the YAML above (leave “already base64 encoded” unchecked).  
9. **Launch** → wait **4–5 minutes**.  
10. Connect:

```bash
ssh -i ~/.ssh/fl-gold-poc.pem -p 2222 fladmin1@<Public-IP>
curl -s http://<Public-IP>:35443/
```

#### Option C — project script

```bash
cd aws
./launch-gold-ami.sh
./verify-remote.sh
```

More detail: [docs/aws-cli-and-console.md](docs/aws-cli-and-console.md)

### Azure (same TOML → VHD)

```bash
cd azure
cp -n env.example env.local
./compose-vhd-on-azure-builder.sh
# on builder: sudo rhc connect , then --continue
./create-image.sh && ./launch-vm.sh && ./verify-remote.sh
```

Console / plain CLI: [docs/azure-cli-and-console.md](docs/azure-cli-and-console.md)

### Dummy app (no new gold image)

```bash
cd demo-app
./deploy-to-vm.sh <PUBLIC_IP>
# http://<ip>:35443/
```

---

## Day-2 operations (end-user view)

1. New web server = launch from the **gold AMI / Azure image**.  
2. Admins: SSH keys on **2222** as `fladmin1` / `fladmin2`.  
3. Site on **35443**; httpd is a container.  
4. Baseline already on: SELinux, firewall, partitions, fladmins.  
5. App updates → `demo-app/deploy-to-vm.sh`. OS changes → new gold image → replace VMs.

---

## Recommended next step

1. Pilot this gold image on **non-prod** web nodes.  
2. Launch Template / ASG (AWS) or Scale Sets (Azure).  
3. Stretch: OpenSCAP CIS on the same factory.  

---

## Repository hygiene

Do **not** commit Access Keys, Secret Keys, `.pem` keys, `env.local`, or raw disk images (`.raw` / `.vhd`).

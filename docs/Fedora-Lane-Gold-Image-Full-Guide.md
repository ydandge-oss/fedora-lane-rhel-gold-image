# Fedora Lane — RHEL 10 Gold Image  
## End-to-end technical guide (Google Doc ready)

**Paste into Google Docs:** File → New → Document → paste this file (or Upload the `.md`).  
**Title suggestion:** `Fedora Lane — Expansion Pack Gold Image — Full Technical Guide`  
**GitHub source of truth:** https://github.com/ydandge-oss/fedora-lane-rhel-gold-image  
**Audience:** Infrastructure, Linux ops, Security, App Dev, CIO stakeholders  
**Scope:** Challenges → expectations → blueprint TOML → AMI/VHD build & upload → launch VMs → OpenSCAP next → wave migration & conclusion  

---

# 1. Challenges we addressed

Fedora Lane operates a large e-commerce estate (boutiques + global web). Approximate scale:

| Location | Approx. count |
|---|---:|
| On-premise VMs | ~900 |
| AWS + Azure instances | ~600 |
| Boutique servers | ~100 |
| **Total** | **~1,600** |

**OS mix today:** Rocky Linux, Ubuntu, CentOS Stream, Amazon Linux — no single web standard.

### Challenge A — Inconsistent estate

Every server looks slightly different. Mass patching fails. New capacity is a “snowflake” install. Drift grows over time.

### Challenge B — Risky / untraceable change

Ad-hoc SSH changes, unclear ownership, long outages when something breaks. Hard to return to a known-good baseline.

### Challenge C — Container skills gap

Teams need a clear, repeatable way to run services (like the web tier) in containers on RHEL — not one-off Docker experiments.

**Wanted outcome:** one secure **RHEL 10** baseline for **AWS and Azure** web nodes, rebuildable from Git, Expansion Pack hardened.

---

# 2. What was expected from the gold image

Expansion Pack / customer requirements for the gold image:

| Requirement | Expected |
|---|---|
| Factory | **Local** RHEL Image Builder (not hosted console.redhat.com) |
| Base OS | RHEL 10 (`distro = rhel-10.x`, not bare `rhel-10`) |
| Clouds | Deployable as **AWS AMI** and **Azure VHD** |
| Web service | **httpd in a container** on port **35443** |
| Filesystems | Separate mounts for `/var/log`, `/home`, `/tmp`, `/var/tmp` — each **&lt; 5 GiB** |
| `/tmp` | **noexec** |
| SELinux | **Enforcing** |
| SSH | Port **2222**, key-only, **no root**, no password SSH |
| Admins | Group `fladmins`, users `fladmin1` / `fladmin2`, passworded sudo |
| Firewall | Only SSH + httpd ports |
| Persistence | Survives **reboot**; services enabled at boot |

Stretch (not completed in this PoC): OpenSCAP CIS hardening with `scap-security-guide`.

---

# 3. Solution we implemented

### One sentence

> A **versioned Image Builder blueprint (TOML) in Git** → local compose → **gold AMI (AWS)** and **gold VHD (Azure)** → launch identical web VMs → prove Expansion Pack controls.

### Architecture

```text
Challenges / Expansion Pack requirements
                 │
                 ▼
     Blueprint TOML in Git  (source of truth)
                 │
                 ▼
     Local RHEL Image Builder (subscribed builder)
                 │
         ┌───────┴───────┐
         ▼               ▼
   AWS gold AMI     Azure gold VHD → managed image
         │               │
         └───────┬───────┘
                 ▼
        Gold web VMs (identical)
        SSH :2222 · httpd :35443
```

### What “source of truth” means

We do **not** hand-build one VM and clone it as the standard.  
We change the **TOML in Git**, compose a **new** gold image, then launch / replace VMs.

**Repo layout (key paths):**

| Path | Purpose |
|---|---|
| `docs/fedora-lane-gold.blueprint.toml` | Editable blueprint |
| `docs/fedora-lane-gold.toml` | Compose-ready TOML (used to build AMI/VHD) |
| `image-builder/files/fl-gold-firstboot.sh` | Firstboot: SELinux ports, noexec, httpd |
| `aws/` · `azure/` | Automation helpers |
| `docs/08-verify-customizations.md` | Prove the VM |

---

# 4. The blueprint (TOML) — what we wrote and why

**Files:**  
https://github.com/ydandge-oss/fedora-lane-rhel-gold-image/blob/main/docs/fedora-lane-gold.blueprint.toml  
https://github.com/ydandge-oss/fedora-lane-rhel-gold-image/blob/main/docs/fedora-lane-gold.toml  

**Plain language:** the blueprint is a **recipe**. Image Builder reads it and builds a disk. It is not a running server you edit by hand.

### 4.1 Identity

```toml
name = "fedora-lane-gold"
distro = "rhel-10.1"
hostname = "fl-rhel-gold"
partitioning_mode = "lvm"
```

- Exact Image Builder distro id (versioned).  
- LVM partitioning for separate filesystems.

### 4.2 Packages installed into the gold image

| Package | Why |
|---|---|
| `podman` | Run httpd as a container |
| `container-tools` | Container tooling on RHEL |
| `firewalld` | Host firewall |
| `policycoreutils-python-utils` | SELinux (`semanage`) |
| `setools-console` | SELinux troubleshooting |
| `sudo` | Admin elevation (passworded) |
| `chrony` | Time sync |
| `curl`, `jq`, `vim-enhanced` | Ops convenience |

### 4.3 Separate filesystems (&lt; 5 GiB each)

| Mount | Size in blueprint |
|---|---|
| `/` | 12 GiB |
| `/var/log` | 4 GiB |
| `/home` | 4 GiB |
| `/tmp` | 2 GiB |
| `/var/tmp` | 2 GiB |

Purpose: logs/temp cannot fill root; matches Expansion Pack.

### 4.4 Users and groups

- Group: `fladmins`  
- Users: `fladmin1`, `fladmin2` (wheel + fladmins)  
- SSH **public keys** embedded in the TOML  
- Sudo: always requires a password (no NOPASSWD for production policy)

### 4.5 Firewall and SSH

- Firewall open: **2222/tcp**, **35443/tcp**  
- Default SSH service disabled in firewall (we use custom port)  
- `sshd_config.d`: Port 2222, `PermitRootLogin no`, `PasswordAuthentication no`, `AllowGroups fladmins`

### 4.6 Services and firstboot

Enabled at boot: `sshd`, `firewalld`, `chronyd`, `fl-gold-firstboot.service`.

Firstboot script (baked in) finishes what the blueprint cannot fully express:

- SELinux enforcing + port labels for 2222 / 35443  
- `/tmp` **noexec** (and `/var/tmp` where applicable)  
- Start **httpd container** on **35443** (Podman)  
- Fedora Lane demo index / boutique content  

### 4.7 How we create / refresh the compose-ready TOML

```bash
cd image-builder
# edit fedora-lane-gold.blueprint.toml
./generate-blueprint.sh
# writes fedora-lane-gold.toml  (also copy into docs/ before commit)
```

---

# 5. Build the gold disk (Image Builder on RHEL 10)

### Prerequisites

1. RHEL 10 builder host with `image-builder`  
2. `sudo rhc connect` (RHSM — required for Image Builder)  
3. AWS and/or Azure credentials (never commit)  
4. IAM role **`vmimport`** for AWS AMI registration  

### High-level compose

```bash
sudo dnf install -y image-builder
sudo image-builder list | grep rhel-10 | grep ami
# must show rhel-10.x — not bare rhel-10

cd image-builder
./generate-blueprint.sh
sudo ./compose.sh ami    # AWS disk / AMI path
sudo ./compose.sh vhd    # Azure VHD path
```

**Time:** first compose often 1–2 hours.

---

# 6. Gold AMI on AWS — create, upload, register (CLI)

### What happens

```text
Blueprint TOML
  → image-builder build ami
  → .raw disk on builder
  → upload to S3
  → vmimport creates EBS snapshot
  → register AMI (e.g. fedora-lane-rhel10-gold)
```

We do **not** manually snapshot a hand-built PoC as the gold standard.

### 6.1 One-shot: build + upload + register

```bash
sudo image-builder build ami \
  --blueprint ./fedora-lane-gold.toml \
  --distro rhel-10.1 \
  --aws-region us-east-2 \
  --aws-bucket fl-gold-<ACCOUNT>-us-east-2 \
  --aws-ami-name fedora-lane-rhel10-gold
```

### 6.2 Upload an existing `.raw`

```bash
sudo image-builder upload ./your-image.raw \
  --to=aws \
  --aws-region us-east-2 \
  --aws-bucket fl-gold-<ACCOUNT>-us-east-2 \
  --aws-ami-name fedora-lane-rhel10-gold
```

### 6.3 Confirm AMI

```bash
export AWS_REGION=us-east-2
aws ec2 describe-images --owners self \
  --filters Name=name,Values=fedora-lane-rhel10-gold Name=state,Values=available \
  --output table
```

Expect **State = available** and an ImageId like `ami-xxxxxxxx`.

### 6.4 Helper scripts (optional)

```bash
cd aws
cp -n env.example env.local   # never commit
./setup-vmimport-role.sh
./compose-on-builder.sh
# on builder: sudo rhc connect
./launch-gold-ami.sh && ./verify-remote.sh
```

---

# 7. Launch VMs from the gold AMI (AWS CLI + Console)

Gold VMs use **SSH 2222** and **httpd 35443** (not port 22). Region: **us-east-2**.

## 7.1 AWS CLI — step by step

```bash
export AWS_REGION=us-east-2
export AWS_DEFAULT_REGION=us-east-2
```

**Find AMI**

```bash
aws ec2 describe-images --owners self \
  --filters Name=name,Values=fedora-lane-rhel10-gold Name=state,Values=available \
  --output table
AMI_ID=ami-xxxxxxxx
```

**VPC + subnet**

```bash
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --output table
VPC_ID=vpc-xxxxxxxx
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --output table
SUBNET_ID=subnet-xxxxxxxx
```

**Security group**

```bash
aws ec2 create-security-group \
  --group-name fl-gold-sg \
  --description "SSH 2222 + httpd 35443" \
  --vpc-id $VPC_ID --output table
SG_ID=sg-xxxxxxxx
MYIP=x.x.x.x/32
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 2222 --cidr $MYIP
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 35443 --cidr $MYIP
```

**Launch**

```bash
aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --key-name fl-gold-poc \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET_ID \
  --associate-public-ip-address \
  --output table
INSTANCE_ID=i-xxxxxxxx
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
aws ec2 describe-instances --instance-ids $INSTANCE_ID --output table
PUBLIC_IP=x.x.x.x
```

**Optional User data** (ensures firstboot / httpd starts):

```yaml
#cloud-config
runcmd:
  - [rm, -f, /var/lib/fl-gold-firstboot-done]
  - [/bin/bash, /etc/fl-gold/bin/fl-gold-firstboot.sh]
```

**Connect (wait ~4–5 minutes)**

```bash
ssh -i ~/.ssh/fl-gold-poc.pem -p 2222 fladmin1@$PUBLIC_IP
curl -s http://$PUBLIC_IP:35443/
```

## 7.2 AWS Console

1. Region **us-east-2**  
2. EC2 → AMIs → Owned by me → gold AMI → **Launch instance from AMI**  
3. Type **t3.medium** · public IP · SG **2222** + **35443** from My IP  
4. Advanced → User data (YAML above)  
5. Launch → wait → SSH `fladmin1` port 2222  

## 7.3 Prove Expansion Pack

```bash
getenforce
findmnt /var/log /home /tmp /var/tmp
findmnt -no OPTIONS /tmp | grep noexec
ss -tln | grep -E '2222|35443'
curl -s http://127.0.0.1:35443/ | head
```

Full list: `docs/08-verify-customizations.md`

---

# 8. Gold VHD on Azure — create, upload, image (CLI)

### What happens

```text
Same TOML blueprint
  → image-builder build vhd
  → .vhd on builder
  → upload to Azure storage (page blob)
  → create managed image
  → launch VM from that image
```

### 8.1 Compose VHD (on builder / via scripts)

```bash
cd azure
cp -n env.example env.local
./compose-vhd-on-azure-builder.sh
# ssh to builder → sudo rhc connect
# ./compose-vhd-on-azure-builder.sh --continue <BUILDER_IP>
./upload-vhd-from-azure-builder.sh <BUILDER_IP>   # if needed
./create-image.sh
```

Manual Image Builder (on subscribed RHEL 10):

```bash
sudo image-builder build vhd \
  --blueprint ./fedora-lane-gold.toml \
  --distro rhel-10.1
```

### 8.2 Create managed image (concept)

After the VHD is a page blob in a storage account:

```bash
az login
az account set --subscription <SUBSCRIPTION_ID>
# create-image from the uploaded VHD URI (see azure/create-image.sh)
az image show -g fl-gold-rg -n fl-rhel-gold -o table
```

---

# 9. Launch VMs from the gold Azure image (Azure CLI + Console)

## 9.1 Azure CLI

```bash
az login
RG=fl-gold-rg
IMAGE=fl-rhel-gold
MYIP=$(curl -4 -fsS ifconfig.me)

az vm create \
  -g $RG \
  -n fl-rhel-gold-poc \
  --image $(az image show -g $RG -n $IMAGE --query id -o tsv) \
  --admin-username azureuser \
  --ssh-key-values ~/.ssh/fl-gold-poc.pem.pub \
  --public-ip-sku Standard \
  --size Standard_D2s_v3 \
  -o table
```

**NSG rules**

```bash
# Replace <NSG> with your NSG name: az network nsg list -g $RG -o table
az network nsg rule create -g $RG --nsg-name <NSG> -n AllowSSH2222 \
  --priority 1000 --access Allow --protocol Tcp \
  --destination-port-ranges 2222 --source-address-prefixes $MYIP/32

az network nsg rule create -g $RG --nsg-name <NSG> -n AllowHttpd35443 \
  --priority 1010 --access Allow --protocol Tcp \
  --destination-port-ranges 35443 --source-address-prefixes $MYIP/32
```

```bash
IP=$(az vm list-ip-addresses -g $RG -n fl-rhel-gold-poc \
  --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
ssh -i ~/.ssh/fl-gold-poc.pem -p 2222 fladmin1@$IP
curl -s http://$IP:35443/
```

## 9.2 Azure Console

1. Portal → Images / My images → gold managed image  
2. Create VM · NSG allow **2222** + **35443**  
3. SSH `fladmin1` port **2222**  
4. Same verify checks as AWS  

---

# 10. Day-2 operations (after gold exists)

| Change type | What to do |
|---|---|
| New web capacity | Launch from gold AMI / Azure image (Launch Template / Scale Set) |
| App content update | Deploy to httpd volume (`demo-app/deploy-to-vm.sh`) — **no new AMI** |
| OS / hardening change | Edit blueprint → compose **new** gold → replace VMs |
| Persistent business data | Keep in DB / object storage — **not** only on the web VM local disk |

---

# 11. Recommendation — OpenSCAP (stretch / next phase)

**Status today:** not yet applied to the gold image (stretch goal).

**Recommendation for next phase:**

1. On a gold VM or during image factory, install:

```bash
sudo dnf install -y openscap-scanner scap-security-guide
```

2. List profiles for RHEL 10 content, then evaluate **CIS** (or org-approved profile):

```bash
oscap info /usr/share/xml/scap/ssg/content/ssg-rhel10-ds.xml | less
sudo oscap xccdf eval --profile <CIS_PROFILE_ID> \
  --results /tmp/fl-cis-results.xml \
  --report /tmp/fl-cis-report.html \
  /usr/share/xml/scap/ssg/content/ssg-rhel10-ds.xml
```

3. Remediate carefully (or use Image Builder / oscap remediation path per Red Hat docs).  
4. Re-compose the gold AMI/VHD so CIS controls are **baked in**, not applied ad-hoc.  
5. Keep the HTML report for audit (no secrets).

Official: Red Hat docs on OpenSCAP compliance scanning and remediation (linked in `docs/redhat-documentation.md`).

---

# 12. Migrating the old estate → gold image (waves)

We do **not** run Image Builder 1,600 times. We do **not** “reimage root in place” as the primary cloud model.

### Model

1. **Freeze** a versioned gold AMI / Azure image.  
2. **Launch** new web nodes from that image.  
3. **Cut traffic** over (load balancer / DNS).  
4. **Retire** old VMs.  
5. For Day-2 OS changes: new gold version → new waves.

### Suggested waves

| Wave | Scope | Goal |
|---|---|---|
| 0 | Non-prod / staging | Prove AMI/VHD, verify checklist, ops training |
| 1 | Canary (few prod web nodes) | Validate traffic + monitoring |
| 2 | First prod batch (~10–20%) | Build confidence |
| 3–N | Remaining batches | Complete web tier |
| Last | Long-tail / boutique exceptions | Special cases or keep alternate factories |

### Data safety

App/customer data is **not** lost if it lives in databases, object storage, or shared filesystems.  
Web VMs are treated as **stateless** — replaceable compute.

### How many servers benefit

| Tier | Approach |
|---|---|
| Cloud web (~AWS/Azure portion of ~600) | Primary candidates for gold AMI/VHD ASAP |
| On-prem / boutique (~1,000) | Same blueprint later via Kickstart / Image Mode / local IB, or keep alternate path |
| Full estate (~1,600) | Standardize over time; web tier first delivers most consistency win |

**Operational savings (qualitative):**

- One recipe instead of 1,600 unique builds  
- Faster recovery: relaunch from gold  
- Faster onboarding: same SSH/sudo/firewall every time  
- Clear container path for web ops  
- Dual-cloud parity from one TOML  

---

# 13. Conclusion

### What we proved

- Local Image Builder gold image from a **Git TOML blueprint**  
- **AWS AMI** and **Azure VHD** paths  
- Expansion Pack controls on live VMs (SSH 2222, httpd 35443, SELinux, mounts, reboot)  
- Launch via **CLI and Console** without mystery  

### How easy is this day-to-day?

| Task | Difficulty after factory exists |
|---|---|
| Launch a new web VM | Easy — Console/CLI from gold image |
| Deploy app content | Easy — volume / CI deploy |
| Change OS baseline | Medium — edit TOML, recompose once, roll waves |
| OpenSCAP CIS | Next phase — add to same factory |

### Ask / recommended next step

1. **Approve non-prod pilot** using this gold AMI / Azure image.  
2. Adopt Launch Template / Scale Sets for new capacity.  
3. Plan **wave replace** for prod web pools.  
4. Schedule **OpenSCAP CIS** stretch on the same blueprint factory.  

### Links

| Resource | URL |
|---|---|
| GitHub repo | https://github.com/ydandge-oss/fedora-lane-rhel-gold-image |
| Compose-ready TOML | https://github.com/ydandge-oss/fedora-lane-rhel-gold-image/blob/main/docs/fedora-lane-gold.toml |
| Blueprint explained | https://github.com/ydandge-oss/fedora-lane-rhel-gold-image/blob/main/docs/blueprint-explained.md |
| Verify checklist | https://github.com/ydandge-oss/fedora-lane-rhel-gold-image/blob/main/docs/08-verify-customizations.md |
| 15-min talk script | https://github.com/ydandge-oss/fedora-lane-rhel-gold-image/blob/main/docs/15-minute-script.md |

---

## How to turn this into a Google Doc

1. Open https://docs.google.com → **Blank document**.  
2. Title: `Fedora Lane — RHEL 10 Gold Image — Full Technical Guide`.  
3. Paste this markdown (or File → Open → Upload `Fedora-Lane-Gold-Image-Full-Guide.md`).  
4. Apply **Heading 1** to `#` titles and **Heading 2** to `##` sections.  
5. Share with Red Hat / Fedora Lane stakeholders (Viewer or Commenter).  
6. Put the GitHub repo URL in the Doc description or on page 1.  

**Never paste** Access Keys, Secret Keys, or private `.pem` contents into the Doc.

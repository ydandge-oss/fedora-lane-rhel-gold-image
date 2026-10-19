#!/usr/bin/env bash
# Pure Azure path: RHEL builder VM in Azure Blank OPEN → Image Builder VHD → page blob.
# No gold AMI. No AWS required.
#
# Usage:
#   ./compose-vhd-on-azure-builder.sh
#   ./compose-vhd-on-azure-builder.sh --continue <BUILDER_PUBLIC_IP>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
az_login
ensure_rg
detect_ssh_cidr
ensure_ssh_pubkey

BUILDER_NAME="${VM_NAME%-poc}-vhd-builder"
BUILDER_NSG="${BUILDER_NAME}-nsg"
BUILDER_SIZE="${BUILDER_SIZE:-Standard_D4s_v3}"
# Image Builder store + VHD export often needs >128G (VHD alone ~20–30G)
BUILDER_DISK_GB="${BUILDER_DISK_GB:-256}"
BUILDER_ADMIN="${BUILDER_ADMIN:-azureuser}"
CONTINUE=0
IP=""

if [[ "${1:-}" == "--continue" ]]; then
  CONTINUE=1
  IP="${2:?Usage: $0 --continue <BUILDER_PUBLIC_IP>}"
fi

ensure_builder_nsg() {
  if ! az network nsg show -g "$AZURE_RESOURCE_GROUP" -n "$BUILDER_NSG" >/dev/null 2>&1; then
    az network nsg create -g "$AZURE_RESOURCE_GROUP" -n "$BUILDER_NSG" -l "$AZURE_LOCATION" >/dev/null
  fi
  az network nsg rule create -g "$AZURE_RESOURCE_GROUP" --nsg-name "$BUILDER_NSG" \
    -n AllowSSH22 --priority 1000 --access Allow --protocol Tcp \
    --destination-port-ranges 22 --source-address-prefixes "$SSH_CIDR" >/dev/null 2>&1 || true
}

resolve_rhel_image() {
  # Prefer RHEL 10 / 9 Gen1-friendly URN from marketplace
  if [[ -n "${AZURE_BUILDER_IMAGE:-}" ]]; then
    echo "$AZURE_BUILDER_IMAGE"
    return
  fi
  local urn
  urn=$(az vm image list --publisher RedHat --offer RHEL --all \
    --query "[?contains(sku, '10') || contains(sku, '9')].urn" -o tsv 2>/dev/null \
    | grep -E 'RHEL:.*:(10|9)' | tail -1 || true)
  if [[ -z "$urn" ]]; then
    urn="RedHat:RHEL:9_4:latest"
  fi
  echo "$urn"
}

if [[ "$CONTINUE" -eq 0 ]]; then
  ensure_builder_nsg
  IMAGE_URN=$(resolve_rhel_image)
  echo "[azure-builder] Creating $BUILDER_NAME ($BUILDER_SIZE, ${BUILDER_DISK_GB}G) image=$IMAGE_URN"

  if az vm show -g "$AZURE_RESOURCE_GROUP" -n "$BUILDER_NAME" >/dev/null 2>&1; then
    echo "[azure-builder] VM exists — reusing"
  else
    az vm create \
      -g "$AZURE_RESOURCE_GROUP" \
      -n "$BUILDER_NAME" \
      --image "$IMAGE_URN" \
      --size "$BUILDER_SIZE" \
      --admin-username "$BUILDER_ADMIN" \
      --ssh-key-values "$SSH_PUBLIC_KEY" \
      --nsg "$BUILDER_NSG" \
      --public-ip-sku Standard \
      --os-disk-size-gb "$BUILDER_DISK_GB" \
      --storage-sku Premium_LRS >/dev/null
  fi

  IP=$(az vm show -d -g "$AZURE_RESOURCE_GROUP" -n "$BUILDER_NAME" --query publicIps -o tsv)
  [[ -n "$IP" && "$IP" != "None" ]] || die "Builder has no public IP"
  echo "[azure-builder] $BUILDER_NAME @ $IP"
  wait_ssh "$IP" 22 "$BUILDER_ADMIN"
else
  BUILDER_ADMIN="${BUILDER_ADMIN:-azureuser}"
  wait_ssh "$IP" 22 "$BUILDER_ADMIN"
fi

# RHSM gate
if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${BUILDER_ADMIN}@${IP}" \
  "sudo subscription-manager status 2>/dev/null | grep -qiE 'Overall Status: (Current|Registered)'"; then
  echo
  echo "ERROR: Builder is not RHSM-subscribed."
  echo "  ssh -i $SSH_PRIVATE_KEY ${BUILDER_ADMIN}@${IP}"
  echo "  sudo rhc connect"
  echo "  exit"
  echo "Then: ./compose-vhd-on-azure-builder.sh --continue ${IP}"
  exit 2
fi
echo "[azure-builder] RHSM OK"

# RHEL cloud images often ship tiny LVM /home (1G) while VG has tens of GB free.
# Grow /var (and a bit of /home), put Image Builder workdir on /var.
echo "[azure-builder] Expanding LVM so VHD export has space..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${BUILDER_ADMIN}@${IP}" \
  "sudo bash -s" <<'GROW'
set -euo pipefail
dnf install -y cloud-utils-growpart 2>/dev/null || dnf install -y growpart 2>/dev/null || true
growpart /dev/sda 4 2>/dev/null || growpart /dev/nvme0n1 4 2>/dev/null || true
pvresize /dev/sda4 2>/dev/null || pvresize /dev/nvme0n1p4 2>/dev/null || true
rm -rf /home/*/fl-image-builder/rhel-*-vhd-* 2>/dev/null || true
if vgs rootvg >/dev/null 2>&1; then
  lvextend -l +90%FREE /dev/rootvg/varlv 2>/dev/null || true
  FT=$(findmnt -n -o FSTYPE /var || true)
  if [[ "$FT" == xfs ]]; then xfs_growfs /var || true
  elif [[ -n "$FT" ]]; then resize2fs /dev/rootvg/varlv || true
  fi
  lvextend -L +2G /dev/rootvg/homelv 2>/dev/null || true
  FT=$(findmnt -n -o FSTYPE /home || true)
  if [[ "$FT" == xfs ]]; then xfs_growfs /home || true
  elif [[ -n "$FT" ]]; then resize2fs /dev/rootvg/homelv || true
  fi
fi
mkdir -p /var/fl-image-builder
chmod 755 /var/fl-image-builder
# Prefer workdir on /var (large); keep convenient path under home via symlink
if [[ -d /home/azureuser ]]; then
  if [[ -d /home/azureuser/fl-image-builder && ! -L /home/azureuser/fl-image-builder ]]; then
    rsync -a /home/azureuser/fl-image-builder/ /var/fl-image-builder/ 2>/dev/null || true
    rm -rf /home/azureuser/fl-image-builder
  fi
  ln -sfn /var/fl-image-builder /home/azureuser/fl-image-builder
  chown -h azureuser:azureuser /home/azureuser/fl-image-builder || true
fi
df -h /var /home
GROW

REMOTE=/home/${BUILDER_ADMIN}/fl-image-builder
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${BUILDER_ADMIN}@${IP}" "mkdir -p $REMOTE"
rsync -az -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_PRIVATE_KEY" \
  --exclude 'rhel-*-ami-*/' \
  --exclude 'rhel-*-vhd-*/' \
  --exclude '*.raw' \
  --exclude '*.vhd' \
  "$repo_root/image-builder/" "${BUILDER_ADMIN}@${IP}:$REMOTE/"

PUB=$(ssh-keygen -y -f "$SSH_PRIVATE_KEY")
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${BUILDER_ADMIN}@${IP}" \
  "python3 - <<'PY'
from pathlib import Path
import re
pub = '''$PUB'''.strip()
for name in ['fedora-lane-gold.toml','fl-rhel-gold.blueprint.toml']:
    p = Path('$REMOTE')/name
    if not p.exists(): continue
    t = p.read_text()
    t2, n = re.subn(r'key = \"ssh-[^\"]+\"', f'key = \"{pub}\"', t)
    p.write_text(t2)
    print(name, 'keys', n)
PY"

# Ensure storage for final VHD
if [[ -z "${STORAGE_ACCOUNT:-}" ]]; then
  SUFFIX=$(echo "$AZURE_SUBSCRIPTION_ID" | tr -d '-' | cut -c1-8 | tr '[:upper:]' '[:lower:]')
  STORAGE_ACCOUNT="flgold${SUFFIX}"
fi
if ! az storage account show -g "$AZURE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
  az storage account create -g "$AZURE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" \
    -l "$AZURE_LOCATION" --sku Standard_LRS --kind StorageV2 >/dev/null
fi
CONN=$(az storage account show-connection-string \
  -g "$AZURE_RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query connectionString -o tsv)
az storage container create --name "$STORAGE_CONTAINER" --connection-string "$CONN" >/dev/null 2>&1 || true
SAS=$(az storage container generate-sas \
  --account-name "$STORAGE_ACCOUNT" \
  --name "$STORAGE_CONTAINER" \
  --permissions racwdl \
  --expiry "$(date -u -v+2d +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d '+2 days' +%Y-%m-%dT%H:%MZ)" \
  --connection-string "$CONN" -o tsv)
BLOB_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${STORAGE_CONTAINER}"

echo "[azure-builder] Composing VHD on ${IP} (long)..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${BUILDER_ADMIN}@${IP}" \
  "sudo bash -s" <<EOS
set -euo pipefail
cd '$REMOTE'
chmod +x scripts/*.sh files/*.sh 2>/dev/null || true
./scripts/install-image-builder.sh
./scripts/generate-blueprint.sh || true
echo "=== COMPOSE VHD (Azure gold) ==="
./scripts/compose.sh vhd
# -L follows symlink workdir (/home/.../fl-image-builder → /var/fl-image-builder)
BEST=\$(find -L /var/fl-image-builder /home /var/tmp /tmp /root '$REMOTE' -type f -name '*.vhd' 2>/dev/null | xargs -r ls -1S 2>/dev/null | head -1 || true)
[[ -n "\$BEST" ]] || { echo "ERROR: no .vhd produced"; find -L /var/fl-image-builder -name '*.vhd' 2>/dev/null || true; exit 1; }
bn=\$(basename "\$BEST")
echo "PRIMARY=\$BEST"
# Install azcopy for direct upload inside Azure (no Mac middleman)
AZCOPY=/usr/local/bin/azcopy
if [[ ! -x "\$AZCOPY" ]]; then
  dnf install -y tar gzip curl >/dev/null 2>&1 || true
  cd /tmp
  rm -rf azcopy_linux_amd64_* azcopy.tgz
  curl -fL --retry 3 -o azcopy.tgz 'https://aka.ms/downloadazcopy-v10-linux'
  tar -xzf azcopy.tgz
  BIN=\$(find /tmp -type f -path '*/azcopy_linux_amd64_*/azcopy' | head -1)
  [[ -n "\$BIN" ]] || { echo "azcopy extract failed"; exit 1; }
  install -m 755 "\$BIN" "\$AZCOPY"
fi
DEST='${BLOB_BASE}/'"\$bn"'?${SAS}'
echo "Uploading \$BEST -> Azure page blob (azcopy)..."
"\$AZCOPY" copy "\$BEST" "\$DEST" --blob-type PageBlob
echo "\$bn" > /tmp/fl-vhd-primary.txt
EOS

BN=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${BUILDER_ADMIN}@${IP}" \
  "sudo cat /tmp/fl-vhd-primary.txt" | tr -d '\r')
VHD_URI="${BLOB_BASE}/${BN}"

python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/vhd-upload.json""").write_text(json.dumps({
  "vhd_uri": "$VHD_URI",
  "blob": "$BN",
  "storage_account": "$STORAGE_ACCOUNT",
  "container": "$STORAGE_CONTAINER",
  "resource_group": "$AZURE_RESOURCE_GROUP",
  "builder_ip": "$IP",
  "builder_name": "$BUILDER_NAME",
  "path": "pure-azure-image-builder",
}, indent=2) + "\n")
Path(r"""$out_dir/azure-builder-outputs.json""").write_text(json.dumps({
  "public_ip": "$IP",
  "vm_name": "$BUILDER_NAME",
  "admin": "$BUILDER_ADMIN",
}, indent=2) + "\n")
print("Wrote vhd-upload.json")
PY

if grep -q '^STORAGE_ACCOUNT=' "$env_file" 2>/dev/null; then
  sed -i.bak "s/^STORAGE_ACCOUNT=.*/STORAGE_ACCOUNT=${STORAGE_ACCOUNT}/" "$env_file"
else
  echo "STORAGE_ACCOUNT=${STORAGE_ACCOUNT}" >>"$env_file"
fi

echo
echo "============================================================"
echo " Pure Azure gold VHD ready (no AMI)"
echo "   $VHD_URI"
echo " Next:"
echo "   ./create-image.sh"
echo "   ./launch-vm.sh"
echo "   ./verify-remote.sh"
echo "============================================================"

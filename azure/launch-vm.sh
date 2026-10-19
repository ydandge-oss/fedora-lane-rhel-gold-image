#!/usr/bin/env bash
# Launch a PoC VM from the gold Azure managed image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
az_login
ensure_rg
detect_ssh_cidr
ensure_ssh_pubkey

IMAGE_JSON="$out_dir/gold-image.json"
[[ -f "$IMAGE_JSON" ]] || die "Missing $IMAGE_JSON — run ./create-image.sh first"
IMAGE_ID=$(python3 -c "import json;print(json.load(open(r'''$IMAGE_JSON'''))['image_id'])")

FIRSTBOOT_SRC="$repo_root/image-builder/files/fl-gold-firstboot.sh"
[[ -f "$FIRSTBOOT_SRC" ]] || die "Missing $FIRSTBOOT_SRC"

# Reject shell-metachar passwords (same rule as AWS launch-gold-ami)
case "$GOLD_ADMIN_PASSWORD" in
  *[!A-Za-z0-9]*) die "GOLD_ADMIN_PASSWORD must be letters/numbers only" ;;
esac

CUSTOM_DATA="$out_dir/azure-custom-data.yaml"
GOLD_ADMIN_PASSWORD="$GOLD_ADMIN_PASSWORD" \
FIRSTBOOT_SRC="$FIRSTBOOT_SRC" \
CUSTOM_DATA="$CUSTOM_DATA" \
python3 - <<'PY'
from pathlib import Path
import os
pw = os.environ["GOLD_ADMIN_PASSWORD"]
# Azure CLI custom-data path is latin-1 in some versions — keep ASCII only
script = Path(os.environ["FIRSTBOOT_SRC"]).read_text(encoding="utf-8")
script = script.replace("\u2014", "-").replace("\u2013", "-").replace("\u00b7", "|")
script = script.encode("ascii", "replace").decode("ascii")
lines = "\n".join("    " + (line if line.strip() else "") for line in script.splitlines())
if not lines.endswith("\n"):
    lines += "\n"
ud = f"""#cloud-config
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    fladmin1:{pw}
    fladmin2:{pw}
write_files:
  - path: /etc/fl-gold/bin/fl-gold-firstboot.sh
    permissions: "0755"
    owner: root:root
    content: |
{lines}
  - path: /etc/sudoers.d/99-fl-poc-nopasswd
    permissions: "0440"
    owner: root:root
    content: |
      fladmin1 ALL=(ALL) NOPASSWD:ALL
runcmd:
  - [passwd, -u, fladmin1]
  - [passwd, -u, fladmin2]
  - [rm, -f, /var/lib/fl-gold-firstboot-done]
  - [/bin/bash, /etc/fl-gold/bin/fl-gold-firstboot.sh]
"""
Path(os.environ["CUSTOM_DATA"]).write_text(ud)
print(f"Wrote {os.environ['CUSTOM_DATA']}")
PY

NSG_NAME="${VM_NAME}-nsg"
echo "[azure] Ensuring NSG $NSG_NAME (2222 + 35443 from $SSH_CIDR)"
if ! az network nsg show -g "$AZURE_RESOURCE_GROUP" -n "$NSG_NAME" >/dev/null 2>&1; then
  az network nsg create -g "$AZURE_RESOURCE_GROUP" -n "$NSG_NAME" -l "$AZURE_LOCATION" >/dev/null
fi
az network nsg rule create -g "$AZURE_RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  -n AllowSSH2222 --priority 1000 --access Allow --protocol Tcp \
  --destination-port-ranges 2222 --source-address-prefixes "$SSH_CIDR" >/dev/null 2>&1 || true
az network nsg rule create -g "$AZURE_RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  -n AllowHttpd35443 --priority 1010 --access Allow --protocol Tcp \
  --destination-port-ranges 35443 --source-address-prefixes "$SSH_CIDR" >/dev/null 2>&1 || true

if az vm show -g "$AZURE_RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  echo "[azure] VM $VM_NAME exists — deleting first"
  az vm delete -g "$AZURE_RESOURCE_GROUP" -n "$VM_NAME" --yes --force-deletion true >/dev/null
fi

echo "[azure] Creating VM $VM_NAME from gold image ($VM_SIZE)"
az vm create \
  -g "$AZURE_RESOURCE_GROUP" \
  -n "$VM_NAME" \
  --image "$IMAGE_ID" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_PUBLIC_KEY" \
  --nsg "$NSG_NAME" \
  --public-ip-sku Standard \
  --custom-data "$CUSTOM_DATA" \
  --os-disk-size-gb 40 \
  --storage-sku Premium_LRS >/dev/null

PUBLIC_IP=$(az vm show -d -g "$AZURE_RESOURCE_GROUP" -n "$VM_NAME" --query publicIps -o tsv)
VM_ID=$(az vm show -g "$AZURE_RESOURCE_GROUP" -n "$VM_NAME" --query id -o tsv)

python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/azure-outputs.json""").write_text(json.dumps({
  "vm_id": "$VM_ID",
  "vm_name": "$VM_NAME",
  "public_ip": "$PUBLIC_IP",
  "ssh_user": "$ADMIN_USER",
  "ssh_key": "$SSH_PRIVATE_KEY",
  "image_id": "$IMAGE_ID",
  "ssh_gold": f"ssh -i $SSH_PRIVATE_KEY -p 2222 $ADMIN_USER@$PUBLIC_IP",
  "httpd": f"http://$PUBLIC_IP:35443/",
  "path": "image-builder-gold-vhd",
  "sudo_password_hint": "GOLD_ADMIN_PASSWORD from env.local (default FlGoldDemo2026)",
}, indent=2) + "\n")
print("Wrote azure-outputs.json")
PY

echo
echo "============================================================"
echo " PoC VM from gold VHD launched"
echo "   Image: $IMAGE_ID"
echo "   VM:    $VM_NAME"
echo "   IP:    $PUBLIC_IP"
echo " Wait ~4–5 min for cloud-init + podman, then:"
echo "   curl -s http://$PUBLIC_IP:35443/"
echo "   ./verify-remote.sh"
echo "   ssh -i $SSH_PRIVATE_KEY -p 2222 ${ADMIN_USER}@$PUBLIC_IP"
echo "============================================================"

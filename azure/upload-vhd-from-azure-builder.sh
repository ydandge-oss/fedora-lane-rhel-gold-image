#!/usr/bin/env bash
# Upload an already-composed .vhd from the Azure builder to page blob storage.
# Use when compose succeeded but the finder/upload step failed.
#
# Usage:
#   ./upload-vhd-from-azure-builder.sh <BUILDER_IP> [remote-vhd-path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
az_login
ensure_rg

IP="${1:?Usage: $0 <BUILDER_IP> [remote-vhd-path]}"
REMOTE_VHD="${2:-/var/fl-image-builder/rhel-9.8-vhd-x86_64/rhel-9.8-vhd-x86_64.vhd}"
BUILDER_ADMIN="${BUILDER_ADMIN:-azureuser}"
BUILDER_NAME="${VM_NAME%-poc}-vhd-builder"

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

EXPIRY=$(date -u -v+2d +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d '+2 days' +%Y-%m-%dT%H:%MZ)
SAS=$(az storage container generate-sas \
  --account-name "$STORAGE_ACCOUNT" \
  --name "$STORAGE_CONTAINER" \
  --permissions racwdl \
  --expiry "$EXPIRY" \
  --connection-string "$CONN" -o tsv)
BLOB_BASE="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${STORAGE_CONTAINER}"
BN=$(basename "$REMOTE_VHD")
DEST="${BLOB_BASE}/${BN}?${SAS}"

echo "[upload] ${REMOTE_VHD} @ ${IP} → ${BLOB_BASE}/${BN}"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${BUILDER_ADMIN}@${IP}" \
  "sudo bash -s" <<EOS
set -euo pipefail
[[ -f '${REMOTE_VHD}' ]] || {
  echo "Missing ${REMOTE_VHD}; searching..."
  find -L /var/fl-image-builder /home /var/tmp -type f -name '*.vhd' 2>/dev/null
  exit 1
}
ls -lh '${REMOTE_VHD}'
AZCOPY=/usr/local/bin/azcopy
if [[ ! -x "\$AZCOPY" ]]; then
  dnf install -y tar gzip curl >/dev/null 2>&1 || true
  cd /tmp
  rm -rf azcopy_linux_amd64_* azcopy.tgz
  curl -fL --retry 3 -o azcopy.tgz 'https://aka.ms/downloadazcopy-v10-linux'
  tar -xzf azcopy.tgz
  BIN=\$(find /tmp -type f -path '*/azcopy_linux_amd64_*/azcopy' | head -1)
  [[ -n "\$BIN" ]] || { echo "azcopy extract failed"; ls -la /tmp; exit 1; }
  install -m 755 "\$BIN" "\$AZCOPY"
fi
"\$AZCOPY" --version
"\$AZCOPY" copy '${REMOTE_VHD}' '${DEST}' --blob-type PageBlob
echo '${BN}' > /tmp/fl-vhd-primary.txt
EOS

VHD_URI="${BLOB_BASE}/${BN}"
mkdir -p "$out_dir"
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
print("Wrote vhd-upload.json")
PY

if grep -q '^STORAGE_ACCOUNT=' "$env_file" 2>/dev/null; then
  sed -i.bak "s/^STORAGE_ACCOUNT=.*/STORAGE_ACCOUNT=${STORAGE_ACCOUNT}/" "$env_file"
else
  echo "STORAGE_ACCOUNT=${STORAGE_ACCOUNT}" >>"$env_file"
fi

echo
echo "OK: $VHD_URI"
echo "Next: ./create-image.sh && ./launch-vm.sh && ./verify-remote.sh"

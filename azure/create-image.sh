#!/usr/bin/env bash
# Create a managed disk + image from the uploaded gold VHD page blob.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
az_login
ensure_rg

UPLOAD_JSON="$out_dir/vhd-upload.json"
[[ -f "$UPLOAD_JSON" ]] || die "Missing $UPLOAD_JSON — run ./upload-vhd.sh first"

VHD_URI=$(python3 -c "import json;print(json.load(open(r'''$UPLOAD_JSON'''))['vhd_uri'])")
DISK_NAME="${IMAGE_NAME}-osdisk"

echo "[azure] Creating managed disk from VHD: $VHD_URI"
# Hyper-V Gen1 VHD from Image Builder azure type
if az disk show -g "$AZURE_RESOURCE_GROUP" -n "$DISK_NAME" >/dev/null 2>&1; then
  echo "[azure] Disk $DISK_NAME already exists — deleting to recreate"
  az disk delete -g "$AZURE_RESOURCE_GROUP" -n "$DISK_NAME" --yes >/dev/null
fi

az disk create \
  -g "$AZURE_RESOURCE_GROUP" \
  -n "$DISK_NAME" \
  --source "$VHD_URI" \
  --os-type Linux \
  --hyper-v-generation V1 \
  --sku Standard_LRS >/dev/null

DISK_ID=$(az disk show -g "$AZURE_RESOURCE_GROUP" -n "$DISK_NAME" --query id -o tsv)

if az image show -g "$AZURE_RESOURCE_GROUP" -n "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "[azure] Image $IMAGE_NAME exists — deleting to recreate"
  az image delete -g "$AZURE_RESOURCE_GROUP" -n "$IMAGE_NAME" >/dev/null
fi

echo "[azure] Creating image $IMAGE_NAME"
az image create \
  -g "$AZURE_RESOURCE_GROUP" \
  -n "$IMAGE_NAME" \
  --source "$DISK_ID" \
  --os-type Linux \
  --hyper-v-generation V1 >/dev/null

IMAGE_ID=$(az image show -g "$AZURE_RESOURCE_GROUP" -n "$IMAGE_NAME" --query id -o tsv)

python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/gold-image.json""").write_text(json.dumps({
  "image_id": "$IMAGE_ID",
  "image_name": "$IMAGE_NAME",
  "disk_name": "$DISK_NAME",
  "disk_id": "$DISK_ID",
  "vhd_uri": "$VHD_URI",
  "resource_group": "$AZURE_RESOURCE_GROUP",
}, indent=2) + "\n")
print("Wrote gold-image.json")
PY

echo
echo "Gold Azure image: $IMAGE_ID"
echo "Next: ./launch-vm.sh"

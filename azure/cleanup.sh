#!/usr/bin/env bash
# Delete PoC VM (and optionally the whole resource group).
#
# Usage:
#   ./cleanup.sh              # delete VM + NIC/IP/NSG leftovers carefully
#   ./cleanup.sh --group      # delete entire AZURE_RESOURCE_GROUP (destructive)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
az_login

if [[ "${1:-}" == "--group" ]]; then
  echo "[azure] Deleting resource group $AZURE_RESOURCE_GROUP"
  az group delete -n "$AZURE_RESOURCE_GROUP" --yes --no-wait
  echo "Delete started (async). Also delete the RHDP Azure Blank OPEN when finished."
  exit 0
fi

if az vm show -g "$AZURE_RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  echo "[azure] Deleting VM $VM_NAME"
  az vm delete -g "$AZURE_RESOURCE_GROUP" -n "$VM_NAME" --yes --force-deletion true
else
  echo "[azure] VM $VM_NAME not found"
fi

echo "VM removed. Image/disk/storage kept for reuse."
echo "Full wipe: ./cleanup.sh --group"
echo "Then delete the RHDP Azure Blank OPEN environment."

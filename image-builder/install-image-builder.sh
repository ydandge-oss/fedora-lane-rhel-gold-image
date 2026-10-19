#!/usr/bin/env bash
# Install local RHEL Image Builder on a subscribed RHEL 10 builder VM.
# Not the hosted console.redhat.com Image Builder service.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

echo "=== Installing RHEL image-builder CLI (Technology Preview on RHEL 10) ==="
dnf install -y image-builder osbuild osbuild-depsolve-dnf

echo "=== Verify ==="
image-builder list
echo
echo "Optional Cockpit UI: dnf install -y cockpit-image-builder && systemctl enable --now cockpit.socket"
echo "Done. Next: cd solution/image-builder && ./scripts/generate-blueprint.sh"

#!/usr/bin/env bash
# Deploy / refresh the Fedora Lane dummy boutique app onto a gold VM.
# Does NOT rebuild the gold AMI/VHD — only updates files on the httpd volume.
#
# Usage:
#   PUBLIC_IP=x.x.x.x ./deploy-to-vm.sh
#   ./deploy-to-vm.sh x.x.x.x
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HTML_DIR="$ROOT/html"
PUBLIC_IP="${1:-${PUBLIC_IP:-}}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-fladmin1}"
SSH_KEY="${SSH_PRIVATE_KEY:-${SSH_KEY:-$HOME/.ssh/fl-gold-poc.pem}}"
APP_DIR_ROOT="/opt/fl/httpd-gold/html"
APP_DIR_USER="\$HOME/fl-httpd/html"

if [[ -z "$PUBLIC_IP" ]]; then
  echo "Usage: PUBLIC_IP=<ip> $0   OR   $0 <ip>"
  exit 1
fi
if [[ ! -d "$HTML_DIR" ]]; then
  echo "Missing $HTML_DIR"
  exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
  echo "Missing SSH key: $SSH_KEY"
  exit 1
fi

SSH=(ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
SCP=(scp -i "$SSH_KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new)

echo "[demo-app] Uploading to $SSH_USER@$PUBLIC_IP ..."
"${SSH[@]}" "$SSH_USER@$PUBLIC_IP" 'mkdir -p /tmp/fl-demo-app/api'
"${SCP[@]}" -r "$HTML_DIR"/. "$SSH_USER@$PUBLIC_IP:/tmp/fl-demo-app/"

echo "[demo-app] Installing onto httpd document root ..."
"${SSH[@]}" "$SSH_USER@$PUBLIC_IP" bash -s <<'REMOTE'
set -euo pipefail
SRC=/tmp/fl-demo-app

install_tree() {
  local dest="$1"
  mkdir -p "$dest/api"
  cp -a "$SRC"/. "$dest"/
  chmod -R a+rX "$dest" 2>/dev/null || true
  echo "installed -> $dest"
}

if sudo -n true 2>/dev/null; then
  sudo -n mkdir -p /opt/fl/httpd-gold/html/api
  sudo -n cp -a "$SRC"/. /opt/fl/httpd-gold/html/
  sudo -n chmod -R a+rX /opt/fl/httpd-gold/html
  echo "installed -> /opt/fl/httpd-gold/html (root volume)"
elif [[ -d "$HOME/fl-httpd/html" ]] || command -v podman >/dev/null 2>&1; then
  mkdir -p "$HOME/fl-httpd/html/api"
  cp -a "$SRC"/. "$HOME/fl-httpd/html/"
  echo "installed -> $HOME/fl-httpd/html (user volume)"
  # Ensure rootless container is serving that path
  if ! ss -ltn 2>/dev/null | grep -q ':35443'; then
    podman rm -f fl-httpd 2>/dev/null || true
    podman pull registry.access.redhat.com/ubi9/httpd-24 >/dev/null 2>&1 || true
    podman run -d --name fl-httpd --restart=always \
      -p 35443:8080 \
      -v "$HOME/fl-httpd/html:/var/www/html:Z" \
      registry.access.redhat.com/ubi9/httpd-24
  fi
else
  echo "ERROR: cannot write app files (need sudo to /opt/fl or user fl-httpd path)"
  exit 1
fi

echo "--- smoke ---"
curl -sf --max-time 5 http://127.0.0.1:35443/ | head -5 || true
curl -sf --max-time 5 http://127.0.0.1:35443/health.json || true
REMOTE

echo
echo "[demo-app] Done. Open:"
echo "  http://${PUBLIC_IP}:35443/"
echo "  http://${PUBLIC_IP}:35443/health.json"
echo "  http://${PUBLIC_IP}:35443/api/catalog.json"

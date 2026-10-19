#!/usr/bin/env bash
# Verify Expansion Pack checks on the Azure gold VHD PoC VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env

OUT_JSON="$out_dir/azure-outputs.json"
[[ -f "$OUT_JSON" ]] || die "Missing $OUT_JSON — run ./launch-vm.sh first"

PUBLIC_IP=$(python3 -c "import json;print(json.load(open(r'''$OUT_JSON'''))['public_ip'])")
SSH_PRIVATE_KEY=$(python3 -c "import json;print(json.load(open(r'''$OUT_JSON'''))['ssh_key'])")
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY/#\~/$HOME}"
ADMIN_USER=$(python3 -c "import json;print(json.load(open(r'''$OUT_JSON''')).get('ssh_user','fladmin1'))")

echo "[verify] Target $PUBLIC_IP"
echo "[verify] Waiting for SSH ${ADMIN_USER}@${PUBLIC_IP}:2222..."
wait_ssh "$PUBLIC_IP" 2222 "$ADMIN_USER"

SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_PRIVATE_KEY" -p 2222)
SCP=(scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_PRIVATE_KEY" -P 2222)

echo "[verify] Non-root checks..."
"${SSH[@]}" "${ADMIN_USER}@${PUBLIC_IP}" 'bash -s' <<'EOS'
set +e
echo "--- getenforce ---"; getenforce
echo "--- listeners ---"; ss -tlnp | grep -E ':2222|:35443' || true
echo "--- mounts ---"
for m in /var/log /home /tmp /var/tmp; do findmnt "$m" || echo "MISSING $m"; done
echo "--- /tmp opts ---"; findmnt -n -o OPTIONS /tmp 2>/dev/null || true
echo "--- marker ---"; cat /etc/fl-gold/MARKER 2>/dev/null || echo "(no marker)"
EOS

echo "[verify] Copying scripts..."
"${SCP[@]}" \
  "$repo_root/solution/scripts/verify-gold-image.sh" \
  "$repo_root/image-builder/files/fl-gold-firstboot.sh" \
  "${ADMIN_USER}@${PUBLIC_IP}:/tmp/"

echo "[verify] Ensuring httpd on 35443 (skip if already listening)..."
"${SSH[@]}" "${ADMIN_USER}@${PUBLIC_IP}" 'bash -s' <<'EOS'
set -euo pipefail
if ss -ltn | grep -q ':35443'; then
  echo "[httpd] already listening on 35443 — leaving it alone"
  curl -sf --max-time 5 http://127.0.0.1:35443/ | head -8 || true
  exit 0
fi
mkdir -p "$HOME/fl-httpd/html"
cat >"$HOME/fl-httpd/html/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Fedora Lane Gold Image</title></head>
<body>
  <h1>Fedora Lane e-commerce web baseline</h1>
  <p>httpd is running from a container on the RHEL Image Builder gold image.</p>
  <p>Port 35443 | SSH 2222 | SELinux enforcing</p>
</body>
</html>
HTML

if sudo -n true 2>/dev/null; then
  echo "[httpd] sudo -n available - running system firstboot"
  sudo -n cp /tmp/fl-gold-firstboot.sh /etc/fl-gold/bin/fl-gold-firstboot.sh
  sudo -n chmod 755 /etc/fl-gold/bin/fl-gold-firstboot.sh
  sudo -n rm -f /var/lib/fl-gold-firstboot-done
  sudo -n /etc/fl-gold/bin/fl-gold-firstboot.sh || true
else
  echo "[httpd] starting rootless podman on 35443"
  podman rm -f fl-httpd 2>/dev/null || true
  if ! podman image exists registry.access.redhat.com/ubi9/httpd-24; then
    podman pull registry.access.redhat.com/ubi9/httpd-24
  fi
  podman run -d --name fl-httpd --restart=always \
    -p 35443:8080 \
    -v "$HOME/fl-httpd/html:/var/www/html:Z" \
    registry.access.redhat.com/ubi9/httpd-24
fi
sleep 5
ss -tlnp | grep 35443 || true
curl -sf --max-time 5 http://127.0.0.1:35443/ | head -8 || true
EOS

echo "[verify] Soft Expansion Pack checks..."
"${SSH[@]}" "${ADMIN_USER}@${PUBLIC_IP}" 'bash -s' <<'EOS'
set +e
pass=0; fail=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "PASS  $desc"; pass=$((pass + 1))
  else echo "FAIL  $desc"; fail=$((fail + 1)); fi
}
check "SELinux enforcing" bash -c '[[ "$(getenforce)" == "Enforcing" ]]'
check "/var/log separate" findmnt -n /var/log
check "/home separate" findmnt -n /home
check "/tmp separate" findmnt -n /tmp
check "/var/tmp separate" findmnt -n /var/tmp
check "/tmp noexec" bash -c 'findmnt -n -o OPTIONS /tmp | grep -q noexec'
check "sshd on 2222" bash -c 'ss -ltn | grep -q ":2222"'
check "httpd on 35443" bash -c 'ss -ltn | grep -q ":35443"'
check "httpd responds" bash -c 'curl -sf --max-time 5 http://127.0.0.1:35443/ | grep -qi "Fedora Lane"'
if curl -sf --max-time 5 http://127.0.0.1:35443/health.json 2>/dev/null | grep -qi "fedora-lane-demo-boutique"; then
  check "demo boutique app" true
else
  echo "INFO: demo boutique not deployed yet — run solution/demo-app/deploy-to-vm.sh"
fi
check "gold marker" test -f /etc/fl-gold/MARKER
check "fladmins group" getent group fladmins
check "fladmin1 user" id fladmin1
echo "Result: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
EOS

echo "[verify] Behavioral SSH policy from laptop..."
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 \
  -i "$SSH_PRIVATE_KEY" -p 2222 "root@${PUBLIC_IP}" 'true' 2>/dev/null; then
  echo "FAIL  root SSH disabled"; exit 1
else
  echo "PASS  root SSH disabled"
fi
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=0 -o ConnectTimeout=5 \
  -p 2222 "${ADMIN_USER}@${PUBLIC_IP}" 'true' 2>/dev/null; then
  echo "FAIL  password SSH disabled"; exit 1
else
  echo "PASS  password SSH disabled"
fi

echo "[verify] httpd from laptop..."
curl -sf --max-time 10 "http://${PUBLIC_IP}:35443/" | head -20 || {
  echo "WARN: httpd not reachable from laptop"; exit 1
}

echo
echo "PASS — Azure remote verification completed"
echo "Optional reboot: az vm restart -g $AZURE_RESOURCE_GROUP -n $VM_NAME"

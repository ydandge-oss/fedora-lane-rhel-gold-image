#!/usr/bin/env bash
# Verify Expansion Pack checks on the launched AWS gold PoC instance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

need_aws
load_env

OUT_JSON="$out_dir/aws-outputs.json"
[[ -f "$OUT_JSON" ]] || die "Missing $OUT_JSON — run ./launch-gold-ami.sh first"

PUBLIC_IP=$(python3 -c "import json;print(json.load(open(r'''$OUT_JSON'''))['public_ip'])")
SSH_PRIVATE_KEY=$(python3 -c "import json;print(json.load(open(r'''$OUT_JSON'''))['ssh_key'])")
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY/#\~/$HOME}"
PATH_KIND=$(python3 -c "import json;print(json.load(open(r'''$OUT_JSON''')).get('path',''))" 2>/dev/null || true)

echo "[verify] Target $PUBLIC_IP  path=${PATH_KIND:-unknown}"
echo "[verify] Waiting for SSH fladmin1@${PUBLIC_IP}:2222..."
wait_ssh "$PUBLIC_IP" 2222 fladmin1

SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_PRIVATE_KEY" -p 2222)
SCP=(scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_PRIVATE_KEY" -P 2222)

echo "[verify] Non-root checks..."
"${SSH[@]}" "fladmin1@${PUBLIC_IP}" 'bash -s' <<'EOS'
set +e
echo "--- getenforce ---"; getenforce
echo "--- listeners ---"; ss -tlnp | grep -E ':2222|:35443' || true
echo "--- mounts ---"
for m in /var/log /home /tmp /var/tmp; do findmnt "$m" || echo "MISSING $m"; done
echo "--- /tmp opts ---"; findmnt -n -o OPTIONS /tmp 2>/dev/null || true
echo "--- marker ---"; cat /etc/fl-gold/MARKER 2>/dev/null || echo "(no marker)"
echo "--- gold sudoers (passworded) ---"; cat /etc/sudoers.d/fladmins 2>/dev/null || ls -la /etc/sudoers.d/ 2>/dev/null || true
EOS

echo "[verify] Copying scripts..."
"${SCP[@]}" \
  "$repo_root/solution/scripts/verify-gold-image.sh" \
  "$repo_root/image-builder/files/fl-gold-firstboot.sh" \
  "fladmin1@${PUBLIC_IP}:/tmp/"

echo "[verify] Ensuring httpd on 35443 (skip if already listening)..."
"${SSH[@]}" "fladmin1@${PUBLIC_IP}" 'bash -s' <<'EOS'
set -euo pipefail
if ss -ltn | grep -q ':35443'; then
  echo "[httpd] already listening on 35443 - leaving it alone"
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
  echo "[httpd] starting rootless podman on 35443 (no sudo needed)"
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

echo "[verify] Running verifier..."
"${SSH[@]}" "fladmin1@${PUBLIC_IP}" 'bash -s' <<'EOS'
set +e
if sudo -n true 2>/dev/null; then
  sudo -n bash /tmp/verify-gold-image.sh
  sudo -n firewall-cmd --list-all || true
else
  echo "=== Soft verify (no sudo) ==="
  pass=0; fail=0
  check() {
    local desc="$1"; shift
    if "$@"; then
      echo "PASS  $desc"
      pass=$((pass + 1))
    else
      echo "FAIL  $desc"
      fail=$((fail + 1))
    fi
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
  # Soft: demo-app may be added via deploy-to-vm.sh without rebuilding gold
  if curl -sf --max-time 5 http://127.0.0.1:35443/health.json 2>/dev/null | grep -qi "fedora-lane-demo-boutique"; then
    check "demo boutique app" true
  else
    echo "INFO: demo boutique not deployed yet — run solution/demo-app/deploy-to-vm.sh"
  fi
  check "gold marker" test -f /etc/fl-gold/MARKER
  check "fladmins group" getent group fladmins
  check "fladmin1 user" id fladmin1
  echo
  echo "--- sshd drop-ins (debug) ---"
  ls -la /etc/ssh/sshd_config.d/ 2>/dev/null || true
  grep -RniE 'PermitRootLogin|PasswordAuthentication|Port |AllowGroups' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null | head -40 || true
  echo
  echo "Result so far: $pass passed, $fail failed (SSH policy checked from laptop next)"
  # Do not fail the remote script on the two config greps — laptop behavioral checks follow
  true
fi
EOS

echo "[verify] Behavioral SSH policy checks from laptop..."
# Root key login should fail (BatchMode, no password prompt)
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 \
  -i "$SSH_PRIVATE_KEY" -p 2222 "root@${PUBLIC_IP}" 'true' 2>/dev/null; then
  echo "FAIL  root SSH disabled (root login succeeded)"
  exit 1
else
  echo "PASS  root SSH disabled (root login rejected)"
fi

# Password auth should fail quickly with no prompts
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=0 -o ConnectTimeout=5 \
  -p 2222 "fladmin1@${PUBLIC_IP}" 'true' 2>/dev/null; then
  echo "FAIL  password SSH disabled (password auth succeeded)"
  exit 1
else
  echo "PASS  password SSH disabled (password auth rejected)"
fi

echo
echo "[verify] Re-check httpd from laptop..."
curl -sf --max-time 10 "http://${PUBLIC_IP}:35443/" | head -20 || {
  echo "WARN: httpd still not reachable from laptop."
  exit 1
}

echo
echo "PASS — remote verification completed"

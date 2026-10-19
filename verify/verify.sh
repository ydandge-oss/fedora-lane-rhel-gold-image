#!/usr/bin/env bash
# Verify Expansion Pack gold-image requirements on a deployed VM.
# Usage: sudo ./verify-gold-image.sh
set -euo pipefail

pass=0
fail=0
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

echo "=== Fedora Lane gold image verification ==="

check "SELinux enforcing" bash -c '[[ "$(getenforce)" == "Enforcing" ]]'
check "/var/log separate mount" findmnt -n /var/log
check "/home separate mount" findmnt -n /home
check "/tmp separate mount" findmnt -n /tmp
check "/var/tmp separate mount" findmnt -n /var/tmp
check "/tmp has noexec" bash -c 'findmnt -n -o OPTIONS /tmp | grep -q noexec'
check "sshd listens on 2222" bash -c 'ss -ltn | grep -q ":2222"'
check "Root login disabled in sshd" bash -c 'grep -REh "^\s*PermitRootLogin\s+(no|prohibit-password|without-password)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null | grep -q .'
check "PasswordAuthentication disabled" bash -c 'grep -REh "^\s*PasswordAuthentication\s+(no|false)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null | grep -q .'
check "fladmins group exists" getent group fladmins
check "fladmin1 exists" id fladmin1
check "sudoers requires password (no NOPASSWD for fladmins)" bash -c '! grep -R "NOPASSWD" /etc/sudoers.d/fladmins 2>/dev/null'
check "firewalld running" systemctl is-active --quiet firewalld
check "port 2222 open in firewall" bash -c 'firewall-cmd --list-ports 2>/dev/null | grep -q 2222 || firewall-cmd --list-all | grep -q 2222'
check "port 35443 open in firewall" bash -c 'firewall-cmd --list-ports 2>/dev/null | grep -q 35443 || firewall-cmd --list-all | grep -q 35443'
check "httpd responds on 35443" bash -c 'curl -sf --max-time 5 http://127.0.0.1:35443/ | grep -qi "Fedora Lane"'
check "gold marker present" test -f /etc/fl-gold/MARKER

echo
echo "Result: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

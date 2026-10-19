#!/usr/bin/env bash
# PoC: launch EC2 FROM the Image Builder gold AMI.
# Injects fixed firstboot script + fladmin password via cloud-init.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

need_aws
load_env
detect_ssh_cidr
ensure_keypair
resolve_vpc
ensure_sg

if [[ -z "${GOLD_AMI_ID:-}" && -f "$out_dir/gold-ami.json" ]]; then
  GOLD_AMI_ID=$(python3 -c "import json;print(json.load(open(r'''$out_dir/gold-ami.json'''))['ami_id'])")
fi
[[ -n "${GOLD_AMI_ID:-}" ]] || die "Set GOLD_AMI_ID in env.local (run compose-on-builder.sh first)"

: "${GOLD_ADMIN_PASSWORD:=FlGoldDemo2026}"

NAME_TAG="${NAME_TAG%-poc}-from-ami"
USER_DATA_FILE="$out_dir/gold-ami-user-data.yaml"
FIRSTBOOT_SRC="$repo_root/image-builder/files/fl-gold-firstboot.sh"
[[ -f "$FIRSTBOOT_SRC" ]] || die "Missing fixed firstboot: $FIRSTBOOT_SRC"
mkdir -p "$out_dir"

GOLD_ADMIN_PASSWORD="$GOLD_ADMIN_PASSWORD" \
FIRSTBOOT_SRC="$FIRSTBOOT_SRC" \
USER_DATA_FILE="$USER_DATA_FILE" \
python3 - <<'PY'
from pathlib import Path
import os
pw = os.environ["GOLD_ADMIN_PASSWORD"]
bad = set("!$`\\\"")
if any(c in pw for c in bad):
    raise SystemExit("GOLD_ADMIN_PASSWORD must be letters/numbers only (no ! $ ` \\ \")")
script = Path(os.environ["FIRSTBOOT_SRC"]).read_text()
lines = "\n".join("    " + (line if line.strip() else "") for line in script.splitlines())
if not lines.endswith("\n"):
    lines += "\n"
ud = f"""#cloud-config
# Set login passwords (gold AMI users are otherwise key-only / locked)
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
  # PoC-only: allow verify scripts to sudo without a TTY/password.
  # Gold AMI still ships passworded sudoers in /etc/sudoers.d/fladmins.
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
out = Path(os.environ["USER_DATA_FILE"])
out.write_text(ud)
print(f"Wrote {out} ({out.stat().st_size} bytes)")
PY

echo "[aws] Launching PoC from GOLD AMI $GOLD_AMI_ID ($INSTANCE_TYPE)"
echo "[aws] cloud-init will install FIXED firstboot + set fladmin password"

RUN_ARGS=(
  ec2 run-instances
  --image-id "$GOLD_AMI_ID"
  --instance-type "$INSTANCE_TYPE"
  --key-name "$KEY_NAME"
  --security-group-ids "$SG_ID"
  --user-data "file://${USER_DATA_FILE}"
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":40,"VolumeType":"gp3","DeleteOnTermination":true}}]'
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_TAG}},{Key=Project,Value=fedora-lane-gold},{Key=Role,Value=gold-from-ami}]"
  --count 1
  --query 'Instances[0].InstanceId'
  --output text
)
if [[ -n "$SUBNET_ID" ]]; then
  RUN_ARGS+=(--subnet-id "$SUBNET_ID" --associate-public-ip-address)
fi

INSTANCE_ID=$(aws "${RUN_ARGS[@]}")
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" || true

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/aws-outputs.json""").write_text(json.dumps({
  "instance_id": "$INSTANCE_ID",
  "public_ip": "$PUBLIC_IP",
  "ssh_user": "fladmin1",
  "ssh_key": "$SSH_PRIVATE_KEY",
  "gold_ami_id": "$GOLD_AMI_ID",
  "ssh_gold": f"ssh -i $SSH_PRIVATE_KEY -p 2222 fladmin1@$PUBLIC_IP",
  "httpd": f"http://$PUBLIC_IP:35443/",
  "path": "image-builder-gold-ami",
  "sudo_password_hint": "GOLD_ADMIN_PASSWORD from env.local (default FlGoldDemo2026)",
}, indent=2) + "\n")
print("Wrote aws-outputs.json")
PY

echo
echo "============================================================"
echo " PoC from gold AMI launched (fixed firstboot injected)"
echo "   AMI:      $GOLD_AMI_ID"
echo "   Instance: $INSTANCE_ID"
echo "   IP:       $PUBLIC_IP"
echo " Wait ~4–5 min for cloud-init + podman pull, then:"
echo "   curl -s http://$PUBLIC_IP:35443/"
echo "   ./verify-remote.sh"
echo "   ssh -t -i $SSH_PRIVATE_KEY -p 2222 fladmin1@$PUBLIC_IP"
echo "   sudo password: FlGoldDemo2026 (or GOLD_ADMIN_PASSWORD in env.local)"
echo "============================================================"

#!/usr/bin/env bash
# Continue Image Builder compose on an EXISTING builder EC2.
# Usage:
#   ./continue-compose-on-builder.sh 18.188.250.219
#
# No tilde paths — always uses /home/ec2-user/fl-image-builder on the builder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

IP="${1:-}"
[[ -n "$IP" ]] || die "Usage: $0 <builder-public-ip>"

need_aws
load_env

SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY/#\~/$HOME}"
KEY="$SSH_PRIVATE_KEY"
REMOTE="/home/ec2-user/fl-image-builder"
IB_SRC="$repo_root/solution/image-builder"
: "${AWS_AMI_NAME:=fedora-lane-rhel10-gold}"
: "${AWS_BUCKET:=fl-gold-$(aws sts get-caller-identity --query Account --output text)-${AWS_REGION}}"

echo "[continue] Builder IP=$IP"
echo "[continue] Remote dir=$REMOTE"
echo "[continue] Bucket=$AWS_BUCKET"

wait_ssh "$IP" 22 "$SSH_USER"

echo "[continue] Syncing image-builder assets..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$KEY" "${SSH_USER}@${IP}" \
  "sudo mkdir -p ${REMOTE} && sudo chown -R ${SSH_USER}:${SSH_USER} ${REMOTE}"
# Avoid --delete: prior compose artifacts are often root-owned and huge.
rsync -az \
  --exclude 'rhel-*-ami-*/' \
  --exclude 'rhel-*-vhd-*/' \
  --exclude '*.raw' \
  --exclude '*.vhd' \
  -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${KEY}" \
  "${IB_SRC}/" "${SSH_USER}@${IP}:${REMOTE}/"

PUB=$(ssh-keygen -y -f "$KEY")
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$KEY" "${SSH_USER}@${IP}" \
  "python3 -c \"
from pathlib import Path
import re
pub = '''${PUB}'''.strip()
for name in ['fedora-lane-gold.toml', 'fl-rhel-gold.blueprint.toml']:
    p = Path('${REMOTE}') / name
    if not p.exists():
        print('missing', p)
        continue
    t = p.read_text()
    t2, n = re.subn(r'key = \\\"ssh-[^\\\"]+\\\"', f'key = \\\"{pub}\\\"', t)
    p.write_text(t2)
    print(name, 'keys', n)
\""

echo "[continue] Writing AWS default profile on builder (image-builder needs it)..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$KEY" "${SSH_USER}@${IP}" \
  "sudo bash -lc '
    set -euo pipefail
    mkdir -p /root/.aws /home/ec2-user/.aws
    cat >/root/.aws/credentials <<EOF
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF
    cat >/root/.aws/config <<EOF
[default]
region=${AWS_REGION}
output=json
EOF
    cp /root/.aws/credentials /home/ec2-user/.aws/credentials
    cp /root/.aws/config /home/ec2-user/.aws/config
    chown -R ec2-user:ec2-user /home/ec2-user/.aws
    chmod 600 /root/.aws/credentials /home/ec2-user/.aws/credentials
  '"

echo "[continue] Installing Image Builder + composing AMI then VHD (long)..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$KEY" "${SSH_USER}@${IP}" \
  "sudo env \
    HOME=/root \
    AWS_SHARED_CREDENTIALS_FILE=/root/.aws/credentials \
    AWS_CONFIG_FILE=/root/.aws/config \
    AWS_DEFAULT_REGION=${AWS_REGION} \
    AWS_REGION=${AWS_REGION} \
    AWS_PROFILE=default \
    AWS_BUCKET=${AWS_BUCKET} \
    AWS_AMI_NAME=${AWS_AMI_NAME} \
    bash -s" <<'EOS'
set -euo pipefail
REMOTE=/home/ec2-user/fl-image-builder
cd "$REMOTE"
ls -la
export HOME=/root
export AWS_SHARED_CREDENTIALS_FILE=/root/.aws/credentials
export AWS_CONFIG_FILE=/root/.aws/config
export AWS_PROFILE=default
chmod +x scripts/*.sh files/*.sh 2>/dev/null || true
./scripts/install-image-builder.sh
./scripts/generate-blueprint.sh || true
if grep -q AAAREPLACE_WITH_REAL_PUBLIC_KEY fedora-lane-gold.toml 2>/dev/null; then
  echo "ERROR: placeholder key still in blueprint"
  exit 1
fi
echo "=== COMPOSE AMI ==="
./scripts/compose.sh ami
echo "=== COMPOSE VHD ==="
./scripts/compose.sh vhd || echo "WARN: vhd compose failed"
if ! command -v aws >/dev/null; then
  dnf install -y awscli || true
fi
find /home/ec2-user /var/tmp /tmp /root "$REMOTE" -type f \( -name '*.vhd' -o -name '*.raw' -o -name '*.ami' \) 2>/dev/null | head -40 | while read -r f; do
  echo "Uploading $f"
  aws s3 cp "$f" "s3://${AWS_BUCKET}/gold/$(basename "$f")" || true
done
aws s3 ls "s3://${AWS_BUCKET}/gold/" || true
echo "=== COMPOSE DONE ==="
EOS

echo
echo "[continue] Looking up AMI ${AWS_AMI_NAME}..."
sleep 10
GOLD_AMI=$(aws ec2 describe-images --owners self \
  --filters "Name=name,Values=${AWS_AMI_NAME}" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

mkdir -p "$out_dir"
python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/builder-outputs.json""").write_text(json.dumps({
  "public_ip": "$IP",
  "bucket": "$AWS_BUCKET",
  "ami_name": "$AWS_AMI_NAME",
  "gold_ami_id": None if "$GOLD_AMI" in ("", "None") else "$GOLD_AMI",
}, indent=2) + "\n")
PY

if [[ -z "$GOLD_AMI" || "$GOLD_AMI" == "None" ]]; then
  echo "WARN: No AMI named ${AWS_AMI_NAME} yet. Check builder logs."
  echo "  ssh -i $KEY ${SSH_USER}@${IP}"
  echo "  sudo journalctl -xe | tail -100"
  exit 1
fi

echo "[continue] GOLD AMI = $GOLD_AMI"
python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/gold-ami.json""").write_text(json.dumps({
  "ami_id": "$GOLD_AMI",
  "ami_name": "$AWS_AMI_NAME",
}, indent=2) + "\n")
PY
if grep -q '^GOLD_AMI_ID=' "$env_file" 2>/dev/null; then
  sed -i.bak "s/^GOLD_AMI_ID=.*/GOLD_AMI_ID=${GOLD_AMI}/" "$env_file"
else
  echo "GOLD_AMI_ID=${GOLD_AMI}" >>"$env_file"
fi

echo
echo "Next:"
echo "  ./launch-gold-ami.sh"
echo "  ./verify-remote.sh"

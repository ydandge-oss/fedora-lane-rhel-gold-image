#!/usr/bin/env bash
# Expansion Pack path — create a REAL gold AMI with local RHEL Image Builder on EC2.
#
# 1) Launch large RHEL builder in RHDP AWS
# 2) Install image-builder, compose ami, upload to S3 → register AMI
# 3) Write gold-ami-id to output/gold-ami.json
#
# Time: often 45–120+ minutes. Keep the Mac awake / terminal open.
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
resolve_rhel_ami

: "${AWS_AMI_NAME:=fedora-lane-rhel10-gold}"
: "${AWS_BUCKET:=}"

if [[ -z "$AWS_BUCKET" ]]; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  AWS_BUCKET="fl-gold-${ACCOUNT}-${AWS_REGION}"
fi

echo "[builder] Ensuring S3 bucket s3://${AWS_BUCKET} for AMI upload..."
if ! aws s3api head-bucket --bucket "$AWS_BUCKET" 2>/dev/null; then
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$AWS_BUCKET"
  else
    aws s3api create-bucket --bucket "$AWS_BUCKET" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
fi

BUILDER_NAME="${NAME_TAG}-builder"
echo "[builder] Launching $BUILDER_NAME ($BUILDER_INSTANCE_TYPE, ${BUILDER_VOLUME_GB}G)"

RUN_ARGS=(
  ec2 run-instances
  --image-id "$AMI_ID"
  --instance-type "$BUILDER_INSTANCE_TYPE"
  --key-name "$KEY_NAME"
  --security-group-ids "$SG_ID"
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${BUILDER_VOLUME_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${BUILDER_NAME}},{Key=Project,Value=fedora-lane-gold},{Key=Role,Value=image-builder}]"
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

[[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]] || die "Builder has no public IP — check subnet/IGW"

echo "[builder] $INSTANCE_ID @ $PUBLIC_IP"
wait_ssh "$PUBLIC_IP" 22 "$SSH_USER"

REMOTE=~/fl-image-builder
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${SSH_USER}@${PUBLIC_IP}" "mkdir -p $REMOTE"
rsync -az -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_PRIVATE_KEY" \
  "$repo_root/image-builder/" "${SSH_USER}@${PUBLIC_IP}:$REMOTE/"

PUB=$(ssh-keygen -y -f "$SSH_PRIVATE_KEY" 2>/dev/null || cat "$HOME/.ssh/id_rsa.pub")
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${SSH_USER}@${PUBLIC_IP}" \
  "python3 - <<'PY'
from pathlib import Path
import re
pub = '''$PUB'''.strip()
for name in ['fedora-lane-gold.toml','fl-rhel-gold.blueprint.toml']:
    p = Path('$REMOTE')/name
    if not p.exists(): continue
    t = p.read_text()
    t2, n = re.subn(r'key = \"ssh-[^\"]+\"', f'key = \"{pub}\"', t)
    p.write_text(t2)
    print(name, 'keys', n)
PY"

# Detect distro on builder for --distro
REMOTE_DISTRO=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${SSH_USER}@${PUBLIC_IP}" \
  "source /etc/os-release; echo \"\${ID}-\${VERSION_ID%%.*}\"" | tr -d '\r')
echo "[builder] Host distro hint: $REMOTE_DISTRO (compose uses matching RHEL major)"

python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/builder-outputs.json""").write_text(json.dumps({
  "instance_id": "$INSTANCE_ID",
  "public_ip": "$PUBLIC_IP",
  "ssh": f"ssh -i $SSH_PRIVATE_KEY $SSH_USER@$PUBLIC_IP",
  "bucket": "$AWS_BUCKET",
  "ami_name": "$AWS_AMI_NAME",
}, indent=2)+"\n")
print("Wrote builder-outputs.json")
PY

echo "[builder] Installing Image Builder + composing AMI (this is the long step)..."
# Pass AWS creds so image-builder can upload; unset proxies that break RHDP
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$SSH_PRIVATE_KEY" "${SSH_USER}@${PUBLIC_IP}" \
  "sudo bash -lc '
    set -euo pipefail
    cd $REMOTE
    export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    export AWS_DEFAULT_REGION=${AWS_REGION}
    export AWS_REGION=${AWS_REGION}
    export AWS_BUCKET=${AWS_BUCKET}
    export AWS_AMI_NAME=${AWS_AMI_NAME}
    # Prefer distro matching builder OS (rhel-9 or rhel-10)
    if grep -q \"^VERSION_ID=\\\"10\" /etc/os-release; then
      export DISTRO=rhel-10
    else
      export DISTRO=rhel-9
      # Blueprint may pin distro = rhel-10 — rewrite for RHEL 9 builder
      sed -i \"s/^distro = \\\"rhel-10\\\"/distro = \\\"rhel-9\\\"/\" fedora-lane-gold.toml || true
    fi
    ./scripts/install-image-builder.sh
    ./scripts/generate-blueprint.sh || true
    # re-inject key after generate
    python3 - <<\"PY\"
from pathlib import Path
import re
pub = \"\"\"$PUB\"\"\".strip()
p = Path(\"fedora-lane-gold.toml\")
t = p.read_text()
t2, n = re.subn(r\"key = \\\"ssh-[^\\\"]+\\\"\", f\"key = \\\"{pub}\\\"\", t)
p.write_text(t2)
print(\"keys\", n)
PY
    echo \"=== COMPOSE AMI (AWS gold image) ===\"
    ./scripts/compose.sh ami
    echo \"=== COMPOSE VHD (Azure gold image) ===\"
    ./scripts/compose.sh vhd || echo \"WARN: vhd compose failed — AMI may still succeed\"
    echo \"=== Upload VHD/raw artifacts to S3 ===\"
    if ! command -v aws >/dev/null; then
      dnf install -y awscli || true
    fi
    find /home /var/tmp /tmp . -type f \\( -name '*.vhd' -o -name '*.raw' \\) 2>/dev/null | head -30 | while read -r f; do
      echo \"Uploading \$f\"
      aws s3 cp \"\$f\" \"s3://${AWS_BUCKET}/gold/\$(basename \"\$f\")\" || true
    done
    aws s3 ls \"s3://${AWS_BUCKET}/gold/\" || true
  '"

echo
echo "[builder] Looking up registered AMI named ${AWS_AMI_NAME}..."
sleep 20
GOLD_AMI=$(aws ec2 describe-images --owners self \
  --filters "Name=name,Values=${AWS_AMI_NAME}" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

# Also try broader name match
if [[ -z "$GOLD_AMI" || "$GOLD_AMI" == "None" ]]; then
  GOLD_AMI=$(aws ec2 describe-images --owners self \
    --filters "Name=name,Values=*${AWS_AMI_NAME}*" "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
fi

python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/builder-outputs.json""").write_text(json.dumps({
  "instance_id": "$INSTANCE_ID",
  "public_ip": "$PUBLIC_IP",
  "ssh": f"ssh -i $SSH_PRIVATE_KEY $SSH_USER@$PUBLIC_IP",
  "bucket": "$AWS_BUCKET",
  "ami_name": "$AWS_AMI_NAME",
  "gold_ami_id": None if "$GOLD_AMI" in ("", "None") else "$GOLD_AMI",
  "vhd_s3": f"s3://$AWS_BUCKET/gold/",
}, indent=2)+"\n")
print("Updated builder-outputs.json")
PY

if [[ -z "$GOLD_AMI" || "$GOLD_AMI" == "None" ]]; then
  echo "WARN: AMI not found yet under name ${AWS_AMI_NAME}."
  echo "SSH to builder and check compose output:"
  echo "  ssh -i $SSH_PRIVATE_KEY ${SSH_USER}@${PUBLIC_IP}"
  echo "  aws ec2 describe-images --owners self --output table"
else
  echo "[builder] GOLD AMI = $GOLD_AMI"
  python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/gold-ami.json""").write_text(json.dumps({
  "ami_id": "$GOLD_AMI",
  "ami_name": "$AWS_AMI_NAME",
  "builder_instance_id": "$INSTANCE_ID",
  "vhd_s3_prefix": "s3://$AWS_BUCKET/gold/",
}, indent=2)+"\n")
print("Wrote gold-ami.json")
PY
  if grep -q '^GOLD_AMI_ID=' "$env_file" 2>/dev/null; then
    sed -i.bak "s/^GOLD_AMI_ID=.*/GOLD_AMI_ID=${GOLD_AMI}/" "$env_file"
  else
    echo "GOLD_AMI_ID=${GOLD_AMI}" >>"$env_file"
  fi
  echo
  echo "============================================================"
  echo " Gold AMI ready: $GOLD_AMI"
  echo " VHD (if composed): s3://${AWS_BUCKET}/gold/"
  echo
  echo " AWS PoC next:"
  echo "   ./launch-gold-ami.sh && ./verify-remote.sh"
  echo " Azure PoC: order Azure Blank OPEN, download VHD from S3, see azure-deploy.md"
  echo " Terminate builder when finished:"
  echo "   aws ec2 terminate-instances --instance-ids $INSTANCE_ID"
  echo "============================================================"
fi

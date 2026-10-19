#!/usr/bin/env bash
# If a previous compose left a .raw on the builder, re-upload/register AMI
# without a full rebuild (needs vmimport role).
#
# Usage: ./reupload-ami-from-builder.sh 18.188.250.219
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
: "${AWS_AMI_NAME:=fedora-lane-rhel10-gold}"
: "${AWS_BUCKET:=fl-gold-$(aws sts get-caller-identity --query Account --output text)-${AWS_REGION}}"

echo "[reupload] Looking for .raw on builder..."
RAW=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$KEY" "${SSH_USER}@${IP}" \
  "sudo find ${REMOTE} /var/tmp /tmp /root -name '*.raw' -size +1G 2>/dev/null | head -1")

[[ -n "$RAW" ]] || die "No large .raw found on builder — run ./continue-compose-on-builder.sh $IP"

echo "[reupload] Found: $RAW"
echo "[reupload] Ensuring AWS profile + uploading via image-builder..."

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$KEY" "${SSH_USER}@${IP}" \
  "sudo bash -lc '
    set -euo pipefail
    mkdir -p /root/.aws
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
    export HOME=/root AWS_PROFILE=default AWS_DEFAULT_REGION=${AWS_REGION}
    RAW=\"${RAW}\"
    if command -v image-builder >/dev/null; then
      image-builder upload \"\$RAW\" --to=aws \
        --aws-region=${AWS_REGION} \
        --aws-bucket=${AWS_BUCKET} \
        --aws-ami-name=${AWS_AMI_NAME}
    else
      # Fallback: S3 + import-snapshot + register-image
      KEYNAME=\$(basename \"\$RAW\")
      aws s3 cp \"\$RAW\" \"s3://${AWS_BUCKET}/gold/\$KEYNAME\"
      echo \"Uploaded to s3://${AWS_BUCKET}/gold/\$KEYNAME — import manually if needed\"
    fi
  '"

sleep 10
GOLD_AMI=$(aws ec2 describe-images --owners self \
  --filters "Name=name,Values=${AWS_AMI_NAME}" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

if [[ -z "$GOLD_AMI" || "$GOLD_AMI" == "None" ]]; then
  echo "WARN: AMI not visible yet. Check:"
  echo "  aws ec2 describe-images --owners self --output table"
  exit 1
fi

echo "[reupload] GOLD AMI = $GOLD_AMI"
mkdir -p "$out_dir"
python3 - <<PY
import json
from pathlib import Path
Path(r"""$out_dir/gold-ami.json""").write_text(json.dumps({
  "ami_id": "$GOLD_AMI",
  "ami_name": "$AWS_AMI_NAME",
}, indent=2)+"\n")
PY
if grep -q '^GOLD_AMI_ID=' "$env_file" 2>/dev/null; then
  sed -i.bak "s/^GOLD_AMI_ID=.*/GOLD_AMI_ID=${GOLD_AMI}/" "$env_file"
else
  echo "GOLD_AMI_ID=${GOLD_AMI}" >>"$env_file"
fi
echo "Next: ./launch-gold-ami.sh && ./verify-remote.sh"

#!/usr/bin/env bash
# Create the EC2 VM Import/Export role required for image-builder AMI registration.
# Docs: https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

need_aws
load_env

: "${AWS_BUCKET:=fl-gold-$(aws sts get-caller-identity --query Account --output text)-${AWS_REGION}}"

TRUST=$(mktemp)
POLICY=$(mktemp)
trap 'rm -f "$TRUST" "$POLICY"' EXIT

cat >"$TRUST" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "vmie.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "sts:ExternalId": "vmimport" }
      }
    }
  ]
}
EOF

cat >"$POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject",
        "s3:GetBucketAcl"
      ],
      "Resource": [
        "arn:aws:s3:::${AWS_BUCKET}",
        "arn:aws:s3:::${AWS_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:ModifySnapshotAttribute",
        "ec2:CopySnapshot",
        "ec2:RegisterImage",
        "ec2:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

if aws iam get-role --role-name vmimport >/dev/null 2>&1; then
  echo "[iam] Role vmimport already exists — updating policies"
else
  echo "[iam] Creating role vmimport"
  aws iam create-role \
    --role-name vmimport \
    --assume-role-policy-document "file://${TRUST}"
fi

aws iam put-role-policy \
  --role-name vmimport \
  --policy-name vmimport \
  --policy-document "file://${POLICY}"

echo "[iam] Waiting a few seconds for IAM to propagate..."
sleep 15
aws iam get-role --role-name vmimport --query 'Role.Arn' --output text
echo "[iam] Done. Re-run: ./continue-compose-on-builder.sh <builder-ip>"

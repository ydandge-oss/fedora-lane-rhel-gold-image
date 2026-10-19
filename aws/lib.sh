#!/usr/bin/env bash
# Shared helpers for Fedora Lane AWS PoC scripts.
# shellcheck disable=SC2034

aws_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$aws_dir/.." && pwd)"
out_dir="${FL_AWS_OUT:-$aws_dir/output}"
env_file="${FL_AWS_ENV:-$aws_dir/env.local}"

die() { echo "ERROR: $*" >&2; exit 1; }

need_aws() {
  local vendored="$repo_root/.tools/aws-cli/aws"
  if ! command -v aws >/dev/null 2>&1; then
    if [[ -x "$vendored" ]]; then
      export PATH="$(dirname "$vendored"):$PATH"
    else
      die "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  (macOS) brew install awscli   OR use repo .tools/aws-cli/aws"
    fi
  fi
  command -v aws >/dev/null || die "aws not on PATH"
}

load_env() {
  [[ -f "$env_file" ]] || die "Missing $env_file — copy env.example to env.local and fill RHDP keys"
  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a
  : "${AWS_REGION:?Set AWS_REGION in env.local}"
  : "${INSTANCE_TYPE:=t3.medium}"
  : "${NAME_TAG:=fl-rhel-gold-poc}"
  : "${KEY_NAME:=fl-gold-poc}"
  : "${CREATE_KEY_PAIR:=yes}"
  : "${SSH_USER:=ec2-user}"
  : "${SSH_PRIVATE_KEY:=$HOME/.ssh/fl-gold-poc.pem}"
  : "${SSH_CIDR:=}"
  : "${AMI_ID:=}"
  : "${SUBNET_ID:=}"
  : "${VPC_ID:=}"
  : "${BUILDER_INSTANCE_TYPE:=t3.xlarge}"
  : "${BUILDER_VOLUME_GB:=80}"

  export AWS_DEFAULT_REGION="$AWS_REGION"
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  fi
  mkdir -p "$out_dir"
}

detect_ssh_cidr() {
  if [[ -z "$SSH_CIDR" ]]; then
    local ip
    ip=$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 5 icanhazip.com 2>/dev/null || true)
    [[ -n "$ip" ]] || die "Set SSH_CIDR in env.local (your public IP/32)"
    SSH_CIDR="${ip}/32"
    echo "[aws] Auto SSH_CIDR=$SSH_CIDR"
  fi
}

ensure_keypair() {
  SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY/#\~/$HOME}"
  if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    echo "[aws] Key pair $KEY_NAME exists"
    [[ -f "$SSH_PRIVATE_KEY" ]] || die "Key pair exists in AWS but private key missing at $SSH_PRIVATE_KEY"
    return
  fi
  [[ "$CREATE_KEY_PAIR" == "yes" ]] || die "Key pair $KEY_NAME not found. Create it or set CREATE_KEY_PAIR=yes"
  mkdir -p "$(dirname "$SSH_PRIVATE_KEY")"
  echo "[aws] Creating key pair $KEY_NAME → $SSH_PRIVATE_KEY"
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text >"$SSH_PRIVATE_KEY"
  chmod 600 "$SSH_PRIVATE_KEY"
}

resolve_vpc() {
  if [[ -z "$VPC_ID" ]]; then
    VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
      --query 'Vpcs[0].VpcId' --output text)
  fi
  # RHDP Blank OPEN often has no default VPC — use the first available VPC
  if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID=$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
  fi
  [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || die "No VPC found. Set VPC_ID in env.local"
  echo "[aws] VPC=$VPC_ID"

  if [[ -z "$SUBNET_ID" ]]; then
    # Prefer a subnet that auto-assigns public IPs
    SUBNET_ID=$(aws ec2 describe-subnets \
      --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
      --query 'Subnets[0].SubnetId' --output text)
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
      SUBNET_ID=$(aws ec2 describe-subnets \
        --filters Name=vpc-id,Values="$VPC_ID" \
        --query 'Subnets[0].SubnetId' --output text)
    fi
    [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]] || die "No subnet in $VPC_ID. Set SUBNET_ID in env.local"
    echo "[aws] Auto SUBNET_ID=$SUBNET_ID"
  else
    echo "[aws] SUBNET_ID=$SUBNET_ID"
  fi
}

ensure_sg() {
  local sg_name="${NAME_TAG}-sg"
  SG_ID=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$sg_name" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    echo "[aws] Creating SG $sg_name (2222 + 35443 from $SSH_CIDR)"
    SG_ID=$(aws ec2 create-security-group \
      --group-name "$sg_name" \
      --description "Fedora Lane gold PoC SSH 2222 + httpd 35443" \
      --vpc-id "$VPC_ID" \
      --query GroupId --output text)
    aws ec2 create-tags --resources "$SG_ID" \
      --tags Key=Name,Value="$sg_name" Key=Project,Value=fedora-lane-gold
  else
    echo "[aws] Reusing SG $SG_ID"
  fi
  # Always (re)allow current public IP — RHDP / home IP changes often
  echo "[aws] Ensuring SG ingress from $SSH_CIDR (22/2222/35443)"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=2222,ToPort=2222,IpRanges=[{CidrIp=${SSH_CIDR},Description=SSH}]" \
    "IpProtocol=tcp,FromPort=35443,ToPort=35443,IpRanges=[{CidrIp=${SSH_CIDR},Description=httpd}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${SSH_CIDR},Description=bootstrap-ssh}]" \
    2>/dev/null || true
}

resolve_rhel_ami() {
  if [[ -n "$AMI_ID" ]]; then
    echo "[aws] AMI_ID=$AMI_ID (from env)"
    return
  fi
  echo "[aws] Looking up latest RHEL Hourly x86_64 AMI..."
  for pattern in \
    'RHEL-10.*_HVM-*-x86_64-*-Hourly2-GP3' \
    'RHEL-10.*x86_64*Hourly*' \
    'RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3'
  do
    AMI_ID=$(aws ec2 describe-images \
      --owners 309956199498 \
      --filters \
        "Name=name,Values=$pattern" \
        "Name=architecture,Values=x86_64" \
        "Name=virtualization-type,Values=hvm" \
        "Name=root-device-type,Values=ebs" \
        "Name=state,Values=available" \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
      --output text 2>/dev/null || true)
    if [[ -n "$AMI_ID" && "$AMI_ID" != "None" ]]; then
      echo "[aws] AMI=$AMI_ID (pattern $pattern)"
      return
    fi
  done
  die "Could not find RHEL AMI. Set AMI_ID in env.local (RHDP Marketplace / console)"
}

render_userdata() {
  local pub src dest
  pub=$(ssh-keygen -y -f "$SSH_PRIVATE_KEY" 2>/dev/null || true)
  if [[ -z "$pub" && -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    pub=$(cat "${HOME}/.ssh/id_rsa.pub")
  fi
  [[ -n "$pub" ]] || die "No SSH public key available"
  src="$aws_dir/cloud-init-gold.yaml"
  dest="$out_dir/user-data.yaml"
  # Escape for sed replacement
  python3 - <<PY
from pathlib import Path
src = Path(r"""$src""").read_text()
pub = """$pub""".strip()
Path(r"""$dest""").write_text(src.replace("SSH_PUBLIC_KEY_PLACEHOLDER", pub))
print(f"Wrote {Path(r'''$dest''')}")
PY
  USER_DATA_FILE="$dest"
}

wait_ssh() {
  local host="$1" port="${2:-22}" user="${3:-$SSH_USER}" tries=40
  echo "[aws] Waiting for SSH ${user}@${host}:${port}..."
  for ((i=1; i<=tries; i++)); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      -i "$SSH_PRIVATE_KEY" -p "$port" "$user@$host" 'echo ok' >/dev/null 2>&1; then
      echo "[aws] SSH ready"
      return 0
    fi
    sleep 15
  done
  die "SSH not ready on ${host}:${port}"
}

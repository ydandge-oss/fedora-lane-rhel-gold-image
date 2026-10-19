#!/usr/bin/env bash
# Shared helpers for Fedora Lane Azure PoC scripts.
# shellcheck disable=SC2034

azure_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$azure_dir/.." && pwd)"
out_dir="${FL_AZURE_OUT:-$azure_dir/output}"
env_file="${FL_AZURE_ENV:-$azure_dir/env.local}"

die() { echo "ERROR: $*" >&2; exit 1; }

need_az() {
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) not found. Install: brew install azure-cli"
}

load_env() {
  [[ -f "$env_file" ]] || die "Missing $env_file — copy env.example to env.local and fill RHDP Azure values"
  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a
  : "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID in env.local}"
  : "${AZURE_RESOURCE_GROUP:=fl-gold-rg}"
  : "${AZURE_LOCATION:=eastus}"
  : "${IMAGE_NAME:=fl-rhel-gold}"
  : "${VM_NAME:=fl-rhel-gold-poc}"
  : "${STORAGE_CONTAINER:=vhds}"
  : "${VM_SIZE:=Standard_B2s}"
  : "${ADMIN_USER:=fladmin1}"
  : "${SSH_PRIVATE_KEY:=$HOME/.ssh/fl-gold-poc.pem}"
  : "${SSH_CIDR:=}"
  : "${GOLD_ADMIN_PASSWORD:=FlGoldDemo2026}"
  SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY/#\~/$HOME}"
  mkdir -p "$out_dir"
}

az_login() {
  need_az
  if [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" && -n "${AZURE_TENANT_ID:-}" ]]; then
    echo "[azure] Service principal login"
    az login --service-principal \
      -u "$AZURE_CLIENT_ID" \
      -p "$AZURE_CLIENT_SECRET" \
      --tenant "$AZURE_TENANT_ID" >/dev/null
  elif ! az account show >/dev/null 2>&1; then
    echo "[azure] Interactive login required..."
    az login
  fi
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
  echo "[azure] Subscription: $(az account show --query name -o tsv)"
}

detect_ssh_cidr() {
  if [[ -z "$SSH_CIDR" ]]; then
    local ip
    ip=$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 5 icanhazip.com 2>/dev/null || true)
    [[ -n "$ip" ]] || die "Set SSH_CIDR in env.local (your public IP/32)"
    SSH_CIDR="${ip}/32"
    echo "[azure] Auto SSH_CIDR=$SSH_CIDR"
  fi
}

ensure_ssh_pubkey() {
  if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
    [[ -f "$SSH_PRIVATE_KEY" ]] || die "Missing SSH private key at $SSH_PRIVATE_KEY"
    SSH_PUBLIC_KEY=$(ssh-keygen -y -f "$SSH_PRIVATE_KEY")
  fi
}

ensure_rg() {
  if az group show --name "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "[azure] Resource group $AZURE_RESOURCE_GROUP exists"
  else
    echo "[azure] Creating resource group $AZURE_RESOURCE_GROUP ($AZURE_LOCATION)"
    az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" >/dev/null
  fi
}

wait_ssh() {
  local host="$1" port="${2:-2222}" user="${3:-fladmin1}" tries="${4:-60}"
  local i
  for ((i = 1; i <= tries; i++)); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -i "$SSH_PRIVATE_KEY" -p "$port" \
      "${user}@${host}" 'echo ok' >/dev/null 2>&1; then
      echo "[azure] SSH ready on ${host}:${port}"
      return 0
    fi
    echo "[azure] waiting SSH ${host}:${port} ($i/$tries)..."
    sleep 10
  done
  die "SSH not ready on ${host}:${port}"
}

#!/usr/bin/env bash
# Compose Fedora Lane gold image with local RHEL Image Builder (image-builder CLI).
#
# Usage:
#   sudo ./compose.sh ami          # AWS
#   sudo ./compose.sh vhd          # Azure
#   sudo ./compose.sh qcow2        # local/libvirt test
#
# Env (optional):
#   BLUEPRINT=./fedora-lane-gold.toml
#   DISTRO=rhel-10.1          # versioned; auto-detected if unset/invalid
#   AWS_REGION / AWS_BUCKET / AWS_AMI_NAME  — auto-upload AMI when set
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

IMAGE_TYPE="${1:-}"
if [[ -z "$IMAGE_TYPE" ]]; then
  echo "Usage: $0 <ami|vhd|qcow2|image-installer|...>"
  echo "Supported types: image-builder list"
  exit 1
fi

BLUEPRINT="${BLUEPRINT:-$ROOT/fedora-lane-gold.toml}"

if [[ ! -f "$BLUEPRINT" ]]; then
  echo "Blueprint missing: $BLUEPRINT"
  echo "Run: ./generate-blueprint.sh"
  exit 1
fi

if grep -q 'AAAREPLACE_WITH_REAL_PUBLIC_KEY' "$BLUEPRINT"; then
  echo "ERROR: Replace AAAREPLACE_WITH_REAL_PUBLIC_KEY in $BLUEPRINT with your SSH public key(s)."
  exit 1
fi

if ! command -v image-builder >/dev/null 2>&1; then
  echo "Installing image-builder packages..."
  dnf install -y image-builder osbuild osbuild-depsolve-dnf
fi

# Map friendly aliases to actual image-builder types if needed
resolve_type() {
  local want="$1"
  # Prefer exact type if listed for some rhel-10.* x86_64
  if image-builder list 2>/dev/null | grep -E "^rhel-10" | grep -q "type:${want} arch:x86_64"; then
    echo "$want"
    return
  fi
  # Fallbacks
  case "$want" in
    ami)
      if image-builder list 2>/dev/null | grep -E "^rhel-10" | grep -q "type:ec2 arch:x86_64"; then
        echo "ec2"; return
      fi
      ;;
    vhd)
      if image-builder list 2>/dev/null | grep -E "^rhel-10" | grep -q "type:azure arch:x86_64"; then
        echo "azure"; return
      fi
      if image-builder list 2>/dev/null | grep -E "^rhel-10" | grep -q "type:azure-rhui arch:x86_64"; then
        echo "azure-rhui"; return
      fi
      ;;
  esac
  echo "$want"
}

# Distro must be versioned: rhel-10.0 / rhel-10.1 — not bare "rhel-10"
resolve_distro() {
  local requested="${DISTRO:-}"
  local list
  list=$(image-builder list 2>/dev/null || true)

  if [[ -n "$requested" ]] && echo "$list" | grep -qE "^${requested} type:"; then
    echo "$requested"
    return
  fi

  # Prefer host minor version
  local ver
  ver=$(source /etc/os-release; echo "${VERSION_ID:-}")
  if [[ -n "$ver" ]] && echo "$list" | grep -qE "^rhel-${ver} type:"; then
    echo "rhel-${ver}"
    return
  fi

  # Newest rhel-10.x that supports our image type for x86_64
  local d
  d=$(echo "$list" | grep -E "^rhel-10\.[0-9]+ type:${IMAGE_TYPE} arch:x86_64" | tail -1 | awk '{print $1}')
  if [[ -n "$d" ]]; then
    echo "$d"
    return
  fi

  d=$(echo "$list" | grep -E "^rhel-10\.[0-9]+ type:" | awk '{print $1}' | sort -V | tail -1)
  if [[ -n "$d" ]]; then
    echo "$d"
    return
  fi

  echo "rhel-10.1"
}

IMAGE_TYPE=$(resolve_type "$IMAGE_TYPE")
DISTRO=$(resolve_distro)

# Keep blueprint distro field in sync (image-builder may read it)
if grep -q '^distro =' "$BLUEPRINT"; then
  sed -i.bak "s/^distro = .*/distro = \"${DISTRO}\"/" "$BLUEPRINT"
else
  echo "distro = \"${DISTRO}\"" >>"$BLUEPRINT"
fi

echo "=== Using distro=$DISTRO type=$IMAGE_TYPE ==="
image-builder list 2>/dev/null | grep -E "^${DISTRO} type:${IMAGE_TYPE} arch:x86_64" || {
  echo "ERROR: No match for ${DISTRO} / ${IMAGE_TYPE} / x86_64"
  echo "Available rhel-10 x86_64 types:"
  image-builder list 2>/dev/null | grep -E '^rhel-10' | grep 'arch:x86_64' | head -40
  exit 1
}

BUILD_ARGS=(build "$IMAGE_TYPE" --blueprint "$BLUEPRINT" --distro "$DISTRO")

if [[ "$IMAGE_TYPE" == "ami" || "$IMAGE_TYPE" == "ec2" ]] && [[ -n "${AWS_BUCKET:-}" ]]; then
  BUILD_ARGS+=(
    --aws-region "${AWS_REGION:-us-east-1}"
    --aws-bucket "$AWS_BUCKET"
    --aws-ami-name "${AWS_AMI_NAME:-fl-rhel-gold}"
  )
  echo "AMI will upload to s3://${AWS_BUCKET} as ${AWS_AMI_NAME:-fl-rhel-gold}"
fi

echo "=== Composing $IMAGE_TYPE from $BLUEPRINT (distro=$DISTRO) ==="
image-builder "${BUILD_ARGS[@]}"

echo
echo "Compose finished."
echo "Next: deploy per solution/cloud/aws-deploy.md or azure-deploy.md"

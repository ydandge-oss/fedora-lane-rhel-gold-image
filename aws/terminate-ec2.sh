#!/usr/bin/env bash
# Terminate the Fedora Lane gold PoC EC2 instance (stop RHDP billing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

need_aws
load_env

OUT_JSON="$out_dir/aws-outputs.json"
[[ -f "$OUT_JSON" ]] || die "Missing $OUT_JSON"

INSTANCE_ID=$(python3 -c "import json;print(json.load(open(r'''$OUT_JSON'''))['instance_id'])")
echo "[aws] Terminating $INSTANCE_ID"
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
echo "[aws] Terminated. Safe to delete the RHDP OPEN environment when finished."

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
python3 - <<PY
from pathlib import Path
root = Path(r"""$ROOT""")
t = (root / "fedora-lane-gold.blueprint.toml").read_text()
t = t.replace('name = "fl-rhel-gold"', 'name = "fedora-lane-gold"')
script = (root / "files/fl-gold-firstboot.sh").read_text().rstrip("\n") + "\n"
if '"""' in script:
    raise SystemExit("firstboot must not contain triple quotes")
(root / "fedora-lane-gold.toml").write_text(t.replace("__FIRSTBOOT_SCRIPT__", script))
print("Wrote", root / "fedora-lane-gold.toml")
PY

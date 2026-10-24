#!/usr/bin/env bash
# Collects the license and NOTICE files of every resolved Swift package into one file.
# Usage: scripts/third-party-notices.sh [output]   (default: Resources/THIRD_PARTY_NOTICES.txt)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-Resources/THIRD_PARTY_NOTICES.txt}"
swift package resolve >/dev/null
mkdir -p "$(dirname "$OUT")"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
pins = json.load(open("Package.resolved"))["pins"]
parts = [
    "Tabula includes the following open-source software. Each component is distributed under its own license, reproduced below.\n",
    "SQLite is used through the copy that ships with macOS (public domain) and is not bundled.\n",
]
for pin in sorted(pins, key=lambda p: p["identity"]):
    root = os.path.join(".build", "checkouts", pin["identity"])
    if not os.path.isdir(root):
        continue
    files = sorted(os.listdir(root))
    license = next((f for f in files if f.lower().startswith(("license", "licence", "copying"))), None)
    notice = next((f for f in files if f.lower().startswith("notice")), None)
    version = pin["state"].get("version") or pin["state"].get("revision", "")[:12]
    parts.append("=" * 78)
    parts.append(f"{pin['identity']} {version}\n{pin['location']}")
    parts.append("=" * 78)
    for name in (license, notice):
        if name:
            parts.append(f"--- {name} ---\n" + open(os.path.join(root, name), encoding="utf-8", errors="replace").read().strip() + "\n")
    if not license:
        parts.append("(No license file found in the package checkout.)\n")
open(out, "w").write("\n".join(parts) + "\n")
print(f"Wrote {out} ({len(pins)} packages)")
PY

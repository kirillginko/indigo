#!/usr/bin/env bash
#
# Fails when a release build could show shared DIG enrichment it should not.
# Run before uploading any archive (DIG-REMEDIATION-PLAN.md §13).
#
#   Scripts/release-enrichment-guard.sh <path/to/Indigo.xcarchive>
#
# 1. The binary: the development override (-INDIGO_DIG_CATALOGUE_PILOT) is
#    compiled into development builds only. A release binary containing its
#    key could be forced on from outside the remote switch.
# 2. The remote switch (0084): it must not list the App Store cohort, and must
#    pin a manifest. TestFlight may be listed only when approved.
set -euo pipefail
archive="${1:?the .xcarchive}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

binary=$(find "$archive/Products/Applications" -maxdepth 3 -type f -perm -u+x -path "*Indigo.app/Indigo" | head -1)
[ -n "$binary" ] || { echo "FAIL: no Indigo binary in $archive" >&2; exit 1; }
if strings -a "$binary" | grep -q "INDIGO_DIG_CATALOGUE_PILOT"; then
    echo "FAIL: the release binary contains the development enrichment override" >&2
    exit 1
fi
echo "ok: no development override in $(basename "$(dirname "$binary")")"

config=$(supabase db query --linked "select public.dig_enrichment_config() as c" 2>/dev/null)
python3 - "$config" <<'PY'
import json, sys
t = sys.argv[1]
c = json.loads(t[t.find("{"):t.rfind("}") + 1])["rows"][0]["c"]
problems = []
if "appstore" in c["cohorts"]:
    problems.append("the App Store cohort is enabled")
if len(c.get("manifest", "")) != 64:
    problems.append("no pinned manifest")
if problems:
    print("FAIL: " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"ok: switch {'on' if c['enabled'] else 'off'} for {', '.join(c['cohorts']) or 'nobody'}; App Store excluded; manifest {c['manifest'][:12]}")
PY

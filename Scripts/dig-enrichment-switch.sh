#!/usr/bin/env bash
#
# Turns shared DIG enrichment on or off for every device, or changes who gets
# it, by replacing public.dig_enrichment_config() (0084). Devices see it within
# its ttlSeconds (15 min) of their next check; offline ones within the grace.
#
#   Scripts/dig-enrichment-switch.sh off
#   Scripts/dig-enrichment-switch.sh on debug            # development builds only
#   Scripts/dig-enrichment-switch.sh on debug testflight # and TestFlight
#   Scripts/dig-enrichment-switch.sh show
#   Scripts/dig-enrichment-switch.sh pin <manifest-digest>   # an approved, verified manifest
#
# on/off keep the pinned manifest as it is; only pin changes what devices
# may read, and only to a manifest that has been approved and verified.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode="${1:-show}"; shift || true
current=$(supabase db query --linked "select public.dig_enrichment_config() as c" 2>/dev/null)
manifest=$(python3 -c 'import sys,json;t=sys.stdin.read();print(json.loads(t[t.find("{"):t.rfind("}")+1])["rows"][0]["c"]["manifest"])' <<<"$current")
if [ "$mode" = show ]; then echo "$current" | python3 -c 'import sys,json;t=sys.stdin.read();print(json.dumps(json.loads(t[t.find("{"):t.rfind("}")+1])["rows"][0]["c"],indent=1))'; exit; fi
current_json=$(python3 -c 'import sys,json;t=sys.stdin.read();print(json.dumps(json.loads(t[t.find("{"):t.rfind("}")+1])["rows"][0]["c"]))' <<<"$current")
case "$mode" in
  pin)
    manifest="${1:?the manifest digest}"
    [[ "$manifest" =~ ^[0-9a-f]{64}$ ]] || { echo "not a digest: $manifest" >&2; exit 1; }
    enabled=$(python3 -c 'import sys,json;print(str(json.loads(sys.argv[1])["enabled"]).lower())' "$current_json")
    read -r -a cohorts <<<"$(python3 -c 'import sys,json;print(" ".join(json.loads(sys.argv[1])["cohorts"]))' "$current_json")" ;;
  off) enabled=false; cohorts=("$@") ;;
  on) enabled=true; cohorts=("$@"); [ ${#cohorts[@]} -gt 0 ] || { echo "name the cohorts" >&2; exit 1; } ;;
  *) echo "usage: $0 off | on <cohort>... | pin <digest> | show" >&2; exit 1 ;;
esac
for c in "${cohorts[@]:-}"; do case "$c" in ""|debug|testflight|appstore) ;; *) echo "unknown cohort $c" >&2; exit 1 ;; esac; done
list=$(printf "'%s'," "${cohorts[@]:-}" | sed "s/,$//; s/''//")
supabase db query --linked "create or replace function public.dig_enrichment_config() returns jsonb language sql immutable as \$f\$ select jsonb_build_object('version', 1, 'enabled', $enabled, 'cohorts', jsonb_build_array($list), 'manifest', '$manifest', 'ttlSeconds', 900, 'offlineGraceSeconds', 86400); \$f\$" >/dev/null
"$0" show

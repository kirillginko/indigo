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
#
# The pinned manifest is kept as it is: this never widens the pilot.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode="${1:-show}"; shift || true
current=$(supabase db query --linked "select public.dig_enrichment_config() as c" 2>/dev/null)
manifest=$(python3 -c 'import sys,json;t=sys.stdin.read();print(json.loads(t[t.find("{"):t.rfind("}")+1])["rows"][0]["c"]["manifest"])' <<<"$current")
if [ "$mode" = show ]; then echo "$current" | python3 -c 'import sys,json;t=sys.stdin.read();print(json.dumps(json.loads(t[t.find("{"):t.rfind("}")+1])["rows"][0]["c"],indent=1))'; exit; fi
case "$mode" in
  off) enabled=false; cohorts=("$@") ;;
  on) enabled=true; cohorts=("$@"); [ ${#cohorts[@]} -gt 0 ] || { echo "name the cohorts" >&2; exit 1; } ;;
  *) echo "usage: $0 off | on <cohort>... | show" >&2; exit 1 ;;
esac
for c in "${cohorts[@]:-}"; do case "$c" in ""|debug|testflight|appstore) ;; *) echo "unknown cohort $c" >&2; exit 1 ;; esac; done
list=$(printf "'%s'," "${cohorts[@]:-}" | sed "s/,$//; s/''//")
supabase db query --linked "create or replace function public.dig_enrichment_config() returns jsonb language sql immutable as \$f\$ select jsonb_build_object('version', 1, 'enabled', $enabled, 'cohorts', jsonb_build_array($list), 'manifest', '$manifest', 'ttlSeconds', 900, 'offlineGraceSeconds', 86400); \$f\$" >/dev/null
"$0" show

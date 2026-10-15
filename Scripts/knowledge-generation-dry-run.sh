#!/usr/bin/env bash
#
# Plans today's knowledge generation from the live database and reports its
# size, object count, R2 reads and writes, bundle coverage, publication time
# and cost (SHARED-KNOWLEDGE.md §9, §12). Writes nothing anywhere: the cut is
# one read-only statement (0075's knowledge_cut, run through the linked CLI),
# and R2 is only read, through the bucket's public host.
#
#   Scripts/knowledge-generation-dry-run.sh [out-dir]
#
# Needs the 00:23 UTC edge rebuild to have finished today; before that, the
# cut refuses and so does this.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$(mktemp -d)}"
DEMAND="$ROOT/supabase/functions/_shared/testdata/pilot_demand_v1.json"
HOST="$(sed -n 's/^CATALOG_CACHE_HOST *= *//p' "$ROOT/Config/Indigo.xcconfig" | tr -d '[:space:]')"
[ -n "$HOST" ] || { echo "no CATALOG_CACHE_HOST in Config/Indigo.xcconfig" >&2; exit 1; }
mkdir -p "$OUT"

python3 - "$DEMAND" > "$OUT/cut.sql" <<'EOF'
import sys
demand = open(sys.argv[1]).read()
assert "$demand$" not in demand
print("select public.knowledge_cut((now() at time zone 'utc')::date, $demand$" + demand + "$demand$::jsonb) as cut;")
EOF

cd "$ROOT"
started=$(python3 -c 'import time; print(int(time.time()*1000))')
supabase db query --linked -f "$OUT/cut.sql" > "$OUT/cut.json"
ended=$(python3 -c 'import time; print(int(time.time()*1000))')
supabase db query --linked "select public.r2_budget() as b;" > "$OUT/budget.json"

deno run --allow-read="$OUT,$ROOT" --allow-net="$HOST" "$ROOT/Scripts/knowledge-generation-dry-run.ts" \
    "$OUT/cut.json" "$((ended - started))" "$OUT/budget.json" "$DEMAND" "$HOST" | tee "$OUT/report.json"

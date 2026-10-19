#!/usr/bin/env bash
#
# Rehearses P2 (DATABASE-CAPACITY-PLAN.md §9) on a throwaway Postgres 17
# built from our migrations, with the live table's own rows restored from an
# export (Scripts/b2-export.py). Nothing here touches the live database.
#
#   1. restore: every row of music_relationships from the export; every
#      slice's row count and md5 must equal what live reported;
#   2. the window: delete single-broadcast played_by, VACUUM FULL, timed,
#      with the database size sampled every 50 ms throughout;
#   3. integrity: the kept rows unchanged, none deleted that P1's readers
#      read, indexes, trigger and RLS present, the rebuild runs;
#   4. rollback: the deleted rows restored from the export, checked by md5.
#
#   Scripts/p2-rehearsal.sh <export-dir> > rehearsal.txt
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORT="$(cd "$1" && pwd)"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}"
PORT="${PGPORT_TEST:-55434}"
export PATH="$PGBIN:$PATH"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

DATA="$(mktemp -d)"
SOCKET="$(mktemp -d /tmp/indigop2.XXXXXX)"
SAMPLER=""
cleanup() {
    [ -n "$SAMPLER" ] && kill "$SAMPLER" 2>/dev/null || true
    pg_ctl -D "$DATA/data" stop -m immediate >/dev/null 2>&1 || true
    rm -rf "$DATA" "$SOCKET"
}
trap cleanup EXIT

initdb -D "$DATA/data" -U postgres --auth=trust >"$DATA/initdb.log" 2>&1
pg_ctl -D "$DATA/data" -o "-p $PORT -k $SOCKET -c listen_addresses='' -c timezone=UTC" -l "$DATA/server.log" start >/dev/null
for _ in $(seq 1 30); do pg_isready -h "$SOCKET" -p "$PORT" -q && break; sleep 0.5; done
run() { psql -h "$SOCKET" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }
mib() { run -c "select round(pg_database_size(current_database())/1048576.0, 1)"; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

echo "== schema from the migrations"
run -f "$ROOT/supabase/tests/00_supabase_stubs.sql" >/dev/null
run -f "$ROOT/supabase/tests/01_cron_stubs.sql" >/dev/null
for m in "$ROOT"/supabase/migrations/*.sql; do run -f "$m" >/dev/null 2>"$DATA/err.log" || { echo "migration $m failed"; cat "$DATA/err.log"; exit 1; }; done
EMPTY=$(mib)
echo "empty database: $EMPTY MiB"

echo "== 1. restore from the export"
T=$(now_ms)
python3 - "$EXPORT" "" > "$DATA/all.csv" <<'PY'
import csv, json, os, sys
out = csv.writer(sys.stdout)
only_singles = sys.argv[2] == "singles"
m = json.load(open(os.path.join(sys.argv[1], "manifest.json")))
for s in m["slices"]:
    for r in json.load(open(os.path.join(sys.argv[1], s["file"]))):
        if only_singles and not (r[5] == "radio_neighbor" and r[10] == 1):
            continue
        r[11] = None if r[11] is None else json.dumps(r[11])
        out.writerow(["" if v is None else v for v in r])
PY
printf '%s\n' "set session_replication_role = replica;" "\\copy public.music_relationships (id, from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type, confidence, source, created_at, updated_at, evidence_count, metadata, episode_count) from '$DATA/all.csv' with (format csv)" > "$DATA/load.sql"
run -f "$DATA/load.sql" >/dev/null
run -c "vacuum analyze public.music_relationships"
echo "restored in $(( $(now_ms) - T )) ms"
python3 - "$EXPORT" > "$DATA/check.sql" <<'PY'
import json, os, sys
m = json.load(open(os.path.join(sys.argv[1], "manifest.json")))
cols = m["columns"]
print("set timezone = 'UTC';")
print("select string_agg(format('%s %s %s', s, n, md5), E'\\n' order by s) from (")
print(" select left(id::text, 1) as s, count(*) as n, md5(string_agg(row(" + cols + ")::text, E'\\n' order by id)) as md5")
print(" from public.music_relationships group by 1) z;")
for s in m["slices"]:
    print(f"-- {s['slice']} {s['rows']} {s['md5']}", file=sys.stderr)
PY
python3 - "$EXPORT" > "$DATA/expected.txt" <<'PY'
import json, os, sys
for s in json.load(open(os.path.join(sys.argv[1], "manifest.json")))["slices"]:
    print(f"{s['slice']} {s['rows']} {s['md5']}")
PY
run -f "$DATA/check.sql" | grep -v '^SET$' > "$DATA/restored.txt"
if diff -q "$DATA/expected.txt" "$DATA/restored.txt" >/dev/null; then
    echo "restore: all 16 slices match live (rows and md5)"
else
    echo "restore: MISMATCH"; diff "$DATA/expected.txt" "$DATA/restored.txt" | head; exit 1
fi
run -c "select format('restored: %s rows, %s single-broadcast played_by, %s played_by without episode_count', count(*), count(*) filter (where relationship_type = 'played_by' and episode_count = 1), count(*) filter (where relationship_type = 'played_by' and episode_count is null))
        from public.music_relationships"
run -c "select format('table %s MiB = heap %s + indexes %s', round(pg_total_relation_size('public.music_relationships')/1048576.0,1), round(pg_relation_size('public.music_relationships')/1048576.0,1), round(pg_indexes_size('public.music_relationships')/1048576.0,1))"
START=$(mib)
echo "database with the table: $START MiB (the table is $(echo "$START - $EMPTY" | bc) MiB of it)"

echo "== 2. the window, step by step"
( while true; do psql -h "$SOCKET" -p "$PORT" -U postgres -qAt -c "select pg_database_size(current_database())" 2>/dev/null >> "$DATA/sizes.txt" || true; sleep 0.05; done ) &
SAMPLER=$!

step() {
    local name="$1"; shift
    local t; t=$(now_ms)
    run -c "$@" >/dev/null
    echo "$name: $(( $(now_ms) - t )) ms, database $(mib) MiB"
}

step "3 record checksums" "create table public.p2_before as
    select 'kept' as part, md5(string_agg(concat_ws('|', id, from_entity_id, to_entity_id, relationship_type, evidence_count, episode_count, confidence, updated_at, source), E'\n' order by id)) as md5, count(*) as n
    from public.music_relationships where not (relationship_type = 'played_by' and coalesce(episode_count, 0) < 2)"
step "4 delete single-broadcast played_by" "delete from public.music_relationships where relationship_type = 'played_by' and coalesce(episode_count, 0) < 2"
T=$(now_ms)
run -c "vacuum full analyze public.music_relationships" >/dev/null
echo "5 vacuum full analyze: $(( $(now_ms) - T )) ms, database $(mib) MiB"
sleep 0.3
kill "$SAMPLER" 2>/dev/null || true; SAMPLER=""
PEAK=$(sort -n "$DATA/sizes.txt" | tail -1)
END=$(mib)
echo "peak during the window: $(python3 -c "print(round($PEAK/1048576, 1))") MiB (start $START); after: $END MiB; freed $(echo "$START - $END" | bc) MiB"
run -c "select format('table after: %s MiB = heap %s + indexes %s', round(pg_total_relation_size('public.music_relationships')/1048576.0,2), round(pg_relation_size('public.music_relationships')/1048576.0,2), round(pg_indexes_size('public.music_relationships')/1048576.0,2))"
run -c "select format('%s: %s MiB', indexrelname, round(pg_relation_size(indexrelid)/1048576.0,2)) from pg_stat_user_indexes where relname = 'music_relationships' order by 1"

echo "== 3. integrity"
run -c "select case when (select md5 from public.p2_before where part = 'kept') =
    (select md5(string_agg(concat_ws('|', id, from_entity_id, to_entity_id, relationship_type, evidence_count, episode_count, confidence, updated_at, source), E'\n' order by id)) from public.music_relationships)
    then 'kept rows unchanged (ids, endpoints, counts, episodes, confidence, updated_at, source): ' || (select n from public.p2_before) else 'KEPT ROWS CHANGED' end"
run -c "select format('single-broadcast played_by left: %s; played_by kept: %s; radio_neighbor kept: %s', count(*) filter (where relationship_type = 'played_by' and coalesce(episode_count, 0) < 2), count(*) filter (where relationship_type = 'played_by'), count(*) filter (where relationship_type = 'radio_neighbor')) from public.music_relationships"
run -c "select format('primary key present: %s; edge_idx unique: %s; trigger present: %s; RLS on: %s',
    exists (select 1 from pg_constraint where conname = 'music_relationships_pkey' and contype = 'p'),
    (select indisunique from pg_index where indexrelid = 'public.music_relationships_edge_idx'::regclass),
    exists (select 1 from pg_trigger where tgname = 'music_relationships_touch_updated_at'),
    (select relrowsecurity from pg_class where oid = 'public.music_relationships'::regclass))"
run -c "select 'rebuild after the window: ' || public.rebuild_radio_dig_edges() || ' rows written (no appearances here, so none expected)'"

echo "== 4. rollback: the deleted rows back from the export"
T=$(now_ms)
python3 - "$EXPORT" > "$DATA/deleted.csv" <<'PY'
import csv, json, os, sys
out = csv.writer(sys.stdout)
m = json.load(open(os.path.join(sys.argv[1], "manifest.json")))
for s in m["slices"]:
    for r in json.load(open(os.path.join(sys.argv[1], s["file"]))):
        if r[5] == "played_by" and (r[12] or 0) < 2:
            r[11] = None if r[11] is None else json.dumps(r[11])
            out.writerow(["" if v is None else v for v in r])
PY
printf '%s\n' "create temp table back (like public.music_relationships including defaults);" "\\copy back (id, from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type, confidence, source, created_at, updated_at, evidence_count, metadata, episode_count) from '$DATA/deleted.csv' with (format csv)" "set session_replication_role = replica;" "insert into public.music_relationships select * from back on conflict do nothing;" > "$DATA/rollback.sql"
run -f "$DATA/rollback.sql" >/dev/null
echo "restored the deleted rows in $(( $(now_ms) - T )) ms; database $(mib) MiB"
run -f "$DATA/check.sql" | grep -v '^SET$' > "$DATA/rolledback.txt"
if diff -q "$DATA/expected.txt" "$DATA/rolledback.txt" >/dev/null; then
    echo "rollback: all 16 slices equal live again (rows and md5, every column)"
else
    echo "ROLLBACK MISMATCH"; diff "$DATA/expected.txt" "$DATA/rolledback.txt" | head
fi

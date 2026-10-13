#!/usr/bin/env python3 -I
# B2 backup (DATABASE-CAPACITY-PLAN.md): every row of public.music_relationships,
# every column, exported read-only through the linked CLI in 16 slices (by the
# first hex digit of id). Each slice carries its own row count and an md5 over
# its rows' text, computed in the same statement -- one snapshot per slice --
# so a restore can be checked exactly. Also the table's definition: columns,
# constraints, indexes, trigger, RLS policies and grants.
#
#   Scripts/b2-export.py <out-dir>
import json, os, subprocess, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def query(sql):
    r = subprocess.run(["supabase", "db", "query", "--linked", sql], capture_output=True, text=True, timeout=600)
    t = r.stdout
    try:
        return json.loads(t[t.find("{"):t.rfind("}") + 1])["rows"]
    except Exception:
        raise SystemExit(f"query failed: {(r.stdout + r.stderr)[:400]}")

COLUMNS = ("id, from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type, "
           "confidence, source, created_at, updated_at, evidence_count, metadata, episode_count")
manifest = {"table": "public.music_relationships", "columns": COLUMNS, "slices": []}
for h in "0123456789abcdef":
    rows = query(f"""set timezone = 'UTC';
      select count(*) as n,
             md5(string_agg(row({COLUMNS})::text, E'\\n' order by id)) as md5,
             json_agg(json_build_array({COLUMNS}) order by id) as rows
      from public.music_relationships where left(id::text, 1) = '{h}';""")[-1]
    path = os.path.join(out, f"music_relationships-{h}.json")
    with open(path, "w") as f:
        json.dump(rows["rows"] or [], f)
    manifest["slices"].append({"slice": h, "rows": rows["n"], "md5": rows["md5"], "file": os.path.basename(path)})
    print(f"slice {h}: {rows['n']} rows", file=sys.stderr)

ddl = query("""select json_build_object(
  'columns', (select json_agg(json_build_object('name', column_name, 'type', format_type(a.atttypid, a.atttypmod),
              'not_null', a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid)) order by a.attnum)
              from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
              join information_schema.columns c on c.table_schema = 'public' and c.table_name = 'music_relationships' and c.column_name = a.attname
              where a.attrelid = 'public.music_relationships'::regclass and a.attnum > 0 and not a.attisdropped),
  'constraints', (select json_agg(pg_get_constraintdef(oid) || ' -- ' || conname) from pg_constraint where conrelid = 'public.music_relationships'::regclass),
  'indexes', (select json_agg(pg_get_indexdef(indexrelid)) from pg_index where indrelid = 'public.music_relationships'::regclass),
  'triggers', (select json_agg(pg_get_triggerdef(oid)) from pg_trigger where tgrelid = 'public.music_relationships'::regclass and not tgisinternal),
  'policies', (select json_agg(json_build_object('name', policyname, 'cmd', cmd, 'roles', roles, 'qual', qual)) from pg_policies where schemaname = 'public' and tablename = 'music_relationships'),
  'rls', (select relrowsecurity from pg_class where oid = 'public.music_relationships'::regclass),
  'grants', (select json_agg(grantee || ':' || privilege_type) from information_schema.role_table_grants where table_schema = 'public' and table_name = 'music_relationships')
) as d;""")[-1]["d"]
manifest["definition"] = ddl
manifest["total_rows"] = sum(s["rows"] for s in manifest["slices"])
with open(os.path.join(out, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=1)
print(json.dumps({"rows": manifest["total_rows"], "slices": len(manifest["slices"])}))

#!/usr/bin/env python3
"""Guard/rollback integration checks against an isolated, Unix-socket-only local PostgreSQL.

Requires the temporary batchcheck cluster at /private/tmp/indigo-radio-batch2-socket:55439.
No connection arguments or environment-derived production destination are accepted.
"""
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'manifest.json').read_text())
ready = manifest['ready']
q = lambda s: "'" + str(s).replace("'", "''") + "'"
cmd = ['/opt/homebrew/opt/postgresql@17/bin/psql', '-X', '-h',
       '/private/tmp/indigo-radio-batch2-socket', '-p', '55439', '-U', 'batchcheck',
       '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At']
log = []


def sql(statement, succeeds=True):
    result = subprocess.run(cmd, input=statement, text=True, capture_output=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    return result.stdout.strip()


schema = """
drop schema public cascade; create schema public;
create table artists(id uuid primary key,name text,normalized_name text);
create table external_ids(id uuid primary key,entity_type text,entity_id uuid,provider text,
 external_id text,source_url text,unique(provider,entity_type,external_id));
create table radio_appearances(artist_id uuid,musicbrainz_recording_id text);
create table artwork(entity_type text,entity_id uuid,portrait_state text,portrait_discogs_id bigint);
create table local_portrait_jobs(artist_id text);
create function enqueue_enrichment_job(text,text,text,jsonb,integer,text,text) returns void
language sql as $$insert into local_portrait_jobs values($3);$$;
"""
repo = pathlib.Path(__file__).resolve().parents[1]
portrait = (repo / 'supabase/migrations/0083_portrait_follows_identity.sql').read_text()
portrait = portrait[portrait.index('create or replace function'):portrait.index('-- MARK: - Telling devices')]
# Revoke targets are roles on Supabase; the temporary cluster only needs the trigger bodies.
portrait = '\n'.join(line for line in portrait.splitlines() if not line.startswith('revoke all'))
view = (repo / 'supabase/migrations/0076_identity_corrections.sql').read_text()
view = view[view.index('create or replace view'):view.index('alter view')]
seed = []
for row in ready:
    seed.append(f"insert into artists values({q(row['id'])}::uuid,{q(row['name'])},{q(row['normalized_name'])});")
    seed.append(f"insert into artwork values('artist',{q(row['id'])}::uuid,null,null);")
    for recording in row['recordings']:
        seed.append(f"insert into radio_appearances values({q(row['id'])}::uuid,{q(recording)});")


def reset():
    sql(schema + view + portrait + '\n'.join(seed))


apply = (root / 'apply.NOT-EXECUTED.sql').read_text()
rollback = (root / 'rollback.NOT-EXECUTED.sql').read_text()
reset()
sql(apply)
assert int(sql('select count(*) from external_ids')) == len(ready)
assert int(sql('select count(*) from local_portrait_jobs')) == len(ready)
sql(apply, succeeds=False)
assert int(sql('select count(*) from external_ids')) == len(ready)
log.append('PASS: exact apply count, actual 0083 portrait trigger, duplicate apply refused atomically')
sql(rollback)
assert sql('select count(*) from external_ids') == '0'
assert int(sql('select count(*) from local_portrait_jobs')) == 2 * len(ready)
sql(rollback)
log.append('PASS: exact rollback removes this batch; repeated rollback is harmless')
first = ready[0]
foreign = '00000000-0000-4000-8000-000000000001'
collision = f"insert into external_ids values('{foreign}'::uuid,'artist',{q(first['id'])}::uuid,'discogs','999999999',null);"
for name, change in [
    ('existing conflicting identity', collision),
    ('destination held elsewhere', f"insert into external_ids values('{foreign}'::uuid,'artist','00000000-0000-4000-8000-000000000002','discogs',{q(first['discogs_ids'][0])},null);"),
    ('publisher witness changed', f"insert into radio_appearances values({q(first['id'])}::uuid,'00000000-0000-4000-8000-000000000003');"),
    ('artist disappeared', f"delete from artists where id={q(first['id'])}::uuid;"),
    ('artist billing changed', f"update artists set normalized_name='changed billing' where id={q(first['id'])}::uuid;"),
]:
    reset()
    sql(change)
    before = sql('select count(*) from external_ids')
    sql(apply, succeeds=False)
    assert sql('select count(*) from external_ids') == before
    assert sql("select count(*) from external_ids where provider='musicbrainz_discogs'") == '0'
    log.append('PASS: ' + name + ' rejects whole batch without partial writes')
reset()
sql(f"insert into external_ids values('{foreign}'::uuid,'artist',{q(first['id'])}::uuid,'musicbrainz_discogs',{q(first['discogs_ids'][0])},{q(first['insert']['source_url'])});")
sql(rollback)
assert sql('select count(*) from external_ids') == '1'
log.append('PASS: rollback preserves an independently inserted identical identity with another primary key')
(root / 'rehearsal.txt').write_text('\n'.join(log) + '\n')
print('\n'.join(log))

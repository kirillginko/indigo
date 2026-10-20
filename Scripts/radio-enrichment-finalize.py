#!/usr/bin/env python3
"""Build local approval artifacts. Usage: script batch-dir [--finish]. No network or DB writes."""
import collections
import datetime
import hashlib
import json
import pathlib
import sys
import uuid

root = pathlib.Path(sys.argv[1])
load = lambda f: json.loads((root / f).read_text())
quote = lambda s: "'" + str(s).replace("'", "''") + "'"
verification = load('verification.json')
rows = verification['results']
assert len(rows) == len(load('candidates.json')['rows']), 'Evidence run is incomplete'
assert not set(r['id'] for r in rows) & set(load('prior-decisions-ledger.json')['entries'])
details = load('candidate-details.json')['rows'][0]['report']
proposed = [r for r in rows if r['status'] == 'evidence_ready']
values = ',\n'.join('(%s::uuid,%s,%s)' % (quote(r['id']), quote(r['discogs_ids'][0]), quote(r['normalized_name'])) for r in proposed)
cte = f'with proposed(id,did,normalized_name) as (values {values})'
guard = """exists(select 1 from artists a where a.id=p.id and a.normalized_name=p.normalized_name)
and not exists(select 1 from external_ids x where x.entity_type='artist' and x.entity_id=p.id and x.provider in ('discogs','musicbrainz_discogs'))
and not exists(select 1 from external_ids x where x.entity_type='artist' and x.external_id=p.did and x.provider in ('discogs','musicbrainz_discogs'))
and not exists(select 1 from artists a join external_ids x on x.entity_id=a.id and x.entity_type='artist' and x.provider in ('discogs','musicbrainz_discogs') where a.id<>p.id and a.normalized_name=p.normalized_name and x.external_id<>p.did)
and not exists(select 1 from split_artist_halves s where s.keep_id=p.id or s.merge_id=p.id)"""
query = f"""begin read only;
{cte}
select jsonb_build_object('checked_at',now(),'database_bytes',pg_database_size(current_database()),
 'guards',(select jsonb_agg(jsonb_build_object('id',p.id,'did',p.did,'clear',({guard}))) from proposed p),
 'existing_recordings',(select coalesce(jsonb_agg(z),'[]') from(select r.id,r.artist_id,r.musicbrainz_recording_id,r.isrc from recordings r where r.musicbrainz_recording_id in(select distinct a.musicbrainz_recording_id from radio_appearances a join proposed p on p.id=a.artist_id where a.musicbrainz_recording_id is not null))z),
 'sizes',(select jsonb_agg(z) from(select c.relname,pg_total_relation_size(c.oid) as bytes,s.n_live_tup from pg_class c join pg_namespace n on n.oid=c.relnamespace left join pg_stat_user_tables s on s.relid=c.oid where n.nspname='public' and c.relname in ('external_ids','radio_appearances','recordings','artists','radio_episodes'))z),
 'reader_checks',(select jsonb_agg(z) from(select p.id,(select count(*) from artist_radio_appearances(p.id,500)) as appearances,(select count(*) from artist_radio_relations(p.id,20)) as relations from (select * from proposed order by id limit 5)p)z),
 'live_witnesses',(select jsonb_agg(z) from(select a.artist_id,array_agg(distinct a.musicbrainz_recording_id order by a.musicbrainz_recording_id) as ids from radio_appearances a join proposed p on p.id=a.artist_id where a.musicbrainz_recording_id is not null group by a.artist_id)z)
) as report;commit;
"""
(root / 'preflight.sql').write_text(query)
if '--finish' not in sys.argv:
    print('Prepared read-only preflight.sql for', len(proposed), 'evidence-ready candidates')
    sys.exit()
preflight = load('preflight.json')['rows'][0]['report']
guards = {r['id']: r['clear'] for r in preflight['guards']}
witnesses = {r['artist_id']: r['ids'] for r in preflight['live_witnesses']}
counts = collections.Counter(r['discogs_ids'][0] for r in proposed)
for row in proposed:
    if not guards.get(row['id']):
        row['reasons'].append('production_destination_or_merge_conflict')
    if witnesses.get(row['id']) != sorted(row['recordings']):
        row['reasons'].append('publisher_witness_set_changed_or_unchecked')
    if counts[row['discogs_ids'][0]] != 1:
        row['reasons'].append('duplicate_destination_within_batch')
    row['status'] = 'ready' if not row['reasons'] else 'review'
ready = [r for r in rows if r['status'] == 'ready']
assert ready, 'No safe rows'
assert preflight['database_bytes'] < 440_000_000, 'Capacity guard'
manifest_rows = []
metadata = []
cache = [json.loads(p.read_text()) for p in (root / 'evidence').glob('*.json')]
for row in ready:
    did = str(row['discogs_ids'][0])
    changes = dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL,
                   'indigo:radio-tier1:batch2:' + row['id'] + ':' + did)),
                   entity_type='artist', entity_id=row['id'],
                   provider='musicbrainz_discogs', external_id=did,
                   source_url='https://musicbrainz.org/artist/' + row['musicbrainz_artist'])
    appearances = [a for a in details['appearances'] if a['artist_id'] == row['id']]
    manifest_rows.append(dict(**row, insert=changes, source_appearances=appearances,
                              portrait_before=next((p for p in details['portraits'] if p['entity_id'] == row['id']), None)))
    artist = next(c['body'] for c in cache if c['status']==200 and c['body'].get('id') == row['musicbrainz_artist'])
    metadata.append(dict(artist_id=row['id'], musicbrainz_artist=row['musicbrainz_artist'],
                         source_url=changes['source_url'], genres=artist.get('genres', []),
                         tags=artist.get('tags', []), relationships=artist.get('relations', []),
                         recording_ids=row['recordings'], writes_production=False,
                         policy='Preserve relation type and target; tags are source claims, never curator affinity. Releases need their own verified credits.'))
manifest = dict(generated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                status='AWAITING_EXPLICIT_APPROVAL', production_writes=0,
                ready=manifest_rows, review=[r for r in rows if r['status']!='ready'],
                preflight_checked_at=preflight['checked_at'])
(root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
(root / 'metadata-staging.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n')
vals = ',\n'.join('('+','.join(quote(r['insert'][k])+('::uuid' if k in ('id','entity_id') else '') for k in ('id','entity_id','external_id','source_url'))+')' for r in manifest_rows)
checks = []
for r in ready:
    ids = ','.join(quote(i) for i in sorted(r['recordings']))
    checks.append(f"if (select array_agg(distinct musicbrainz_recording_id order by musicbrainz_recording_id) from radio_appearances where artist_id={quote(r['id'])}::uuid and musicbrainz_recording_id is not null) is distinct from array[{ids}]::text[] then raise exception 'Publisher witnesses changed for {r['id']}'; end if;")
readyvals = ',\n'.join('(%s::uuid,%s,%s)' % (quote(r['id']), quote(r['discogs_ids'][0]), quote(r['normalized_name'])) for r in ready)
apply = f"""-- NOT EXECUTED. Explicit user approval and fresh remote evidence required.
-- Inserts identities only. Trigger may enqueue portrait jobs. No merges or ranking changes.
begin;
set local lock_timeout='3s';
set local statement_timeout='20s';
lock table artists,external_ids,radio_appearances in share row exclusive mode;
do $batch$
declare inserted_count integer;
begin
if pg_database_size(current_database()) >= 440000000 then raise exception 'Capacity guard'; end if;
{' '.join(checks)}
if ({'with proposed(id,did,normalized_name) as (values '+readyvals+')'} select count(*) from proposed p where {guard}) <> {len(ready)} then raise exception 'Identity guards changed'; end if;
insert into external_ids(id,entity_type,entity_id,provider,external_id,source_url)
select x.id,'artist',x.entity_id,'musicbrainz_discogs',x.external_id,x.source_url
from (values {vals}) x(id,entity_id,external_id,source_url);
get diagnostics inserted_count = row_count;
if inserted_count <> {len(ready)} then raise exception 'Unexpected inserted count: %',inserted_count; end if;
end $batch$;
commit;
"""
(root / 'apply.NOT-EXECUTED.sql').write_text(apply)
rollback = f"""-- NOT EXECUTED. Exact batch-owned primary keys only; portrait trigger rechecks identity.
begin;
delete from external_ids e using (values {vals}) x(id,entity_id,external_id,source_url)
where e.id=x.id and e.entity_id=x.entity_id and e.entity_type='artist'
and e.provider='musicbrainz_discogs' and e.external_id=x.external_id and e.source_url=x.source_url;
commit;
"""
(root / 'rollback.NOT-EXECUTED.sql').write_text(rollback)
print('Approval manifest:',len(ready),'ready;',len(rows)-len(ready),'review')

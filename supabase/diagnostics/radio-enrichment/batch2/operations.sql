begin read only;
select jsonb_build_object(
 'identity_collisions',(select jsonb_agg(z) from(select m.entity_id as linked_artist,a.name as linked_name,m.external_id,d.entity_id as other_artist,b.name as other_name,d.provider from external_ids m join external_ids d on d.entity_type='artist' and d.provider in ('discogs','musicbrainz_discogs') and d.external_id=m.external_id and d.entity_id<>m.entity_id join artists a on a.id=m.entity_id join artists b on b.id=d.entity_id where m.provider='musicbrainz_discogs' and m.entity_type='artist') z),
 'queue',(select jsonb_agg(z) from(select provider,job_type,status,count(*) as n,min(updated_at) as oldest,max(updated_at) as newest,left(max(last_error),350) as example_error from enrichment_jobs where updated_at>now()-interval '3 days' and provider in ('youtube','nts','lotradio') group by provider,job_type,status)z),
 'cursors',(select jsonb_agg(z) from(select * from enrichment_cursors where name like 'nts%' or name like 'lotradio%' or name like 'youtube%')z),
 'youtube_channels',(select jsonb_agg(z) from(select * from youtube_channels where enabled)z),
 'cron',(select jsonb_agg(z) from(select jobname,schedule,active from cron.job where jobname ilike '%discover%' or jobname ilike '%youtube%' or jobname ilike '%lotradio%' or jobname ilike '%merge%')z)
) as report;commit;
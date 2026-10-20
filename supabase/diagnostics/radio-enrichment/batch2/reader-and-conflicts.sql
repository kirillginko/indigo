begin read only;
select jsonb_build_object(
 'held_destinations',(select jsonb_agg(z) from(select x.entity_id,a.name,x.provider,x.external_id from external_ids x join artists a on a.id=x.entity_id where x.entity_type='artist' and x.provider in ('discogs','musicbrainz_discogs') and x.external_id in ('4981772','5852757','4304488','8270419','2835065','8722','1622339','29966','20560','5975825','55738','866','534','44126','3519986','5648334','270578','48720','3150192','1029','41249','3563778','59249','36860','97988','1300441','269','98545'))z),
 'readers',(select jsonb_agg(z) from(select a.id,a.name,(select count(*) from artist_radio_appearances(a.id,500)) as appearance_count,(select count(*) from artist_radio_relations(a.id,20)) as relation_count from artists a where a.id in ('fcc75b03-80c1-49cc-b675-eb6ac916d3b0'::uuid,'cc49be7c-cd9b-4eaa-88a2-06f3f202c6c4'::uuid,'9dbaa8ab-bef4-4690-9d1e-0f2e64f5a483'::uuid,'d1ba9a33-dee7-41f0-85a6-f8e87bf7c8c7'::uuid,'d3739140-435f-43da-8bd1-24e92aff6c70'::uuid))z),
 'links',(select count(*) from external_ids where provider='musicbrainz_discogs' and entity_type='artist'),
 'database_bytes',pg_database_size(current_database())
) as report;commit;
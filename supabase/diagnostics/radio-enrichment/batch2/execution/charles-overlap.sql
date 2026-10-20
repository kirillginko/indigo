begin read only;
select jsonb_build_object('checked_at',now(),'charles',(select jsonb_agg(z) from(select x.id as mapping_id,x.entity_id,a.name,x.provider,x.external_id,x.source_url from external_ids x join artists a on a.id=x.entity_id where x.entity_type='artist' and (x.external_id='258371' and x.provider in ('discogs','musicbrainz_discogs') or x.entity_id in ('cdae3f80-e82b-40ad-8ee5-740138cb886b'::uuid,'a3eac22a-2595-49f1-8e6b-330a4889e2bf'::uuid)))z)) as report;
commit;

insert into public.external_ids (entity_type, entity_id, provider, external_id)
values ('artist', '12947170-ce77-42a3-a8c6-06ec2f5e856d', 'discogs', '455494')
on conflict do nothing;

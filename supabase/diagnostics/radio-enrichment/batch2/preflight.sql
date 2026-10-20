begin read only;
with proposed(id,did,normalized_name) as (values ('345cd5ec-5106-44b8-a5dc-eb2a34805909'::uuid,'4981772','klein'),
('91f7756c-10c2-47f9-ad29-87b4790ae413'::uuid,'5852757','mike'),
('fcc75b03-80c1-49cc-b675-eb6ac916d3b0'::uuid,'4304488','lolina'),
('cc49be7c-cd9b-4eaa-88a2-06f3f202c6c4'::uuid,'8270419','nala sinephro'),
('03f3634e-9ab3-438a-b5ef-e3253a88db13'::uuid,'2835065','moin'),
('9dbaa8ab-bef4-4690-9d1e-0f2e64f5a483'::uuid,'8722','piero umiliani'),
('d1ba9a33-dee7-41f0-85a6-f8e87bf7c8c7'::uuid,'1622339','blawan'),
('d3739140-435f-43da-8bd1-24e92aff6c70'::uuid,'29966','gene harris'),
('8941dae6-4879-46d8-bf42-721166f7880a'::uuid,'20560','manu dibango'),
('df6a03e2-4348-4211-bef0-5ecbe86fc8c6'::uuid,'5975825','priori'),
('2c8e9ead-44b9-4482-b1a6-814480c33074'::uuid,'55738','ramsey lewis'),
('46812b32-b9b5-48a9-9905-f79cd8b4cf44'::uuid,'866','paul johnson'),
('3bc0ad49-5d5a-495f-8189-04425126743a'::uuid,'534','monolake'),
('fd2407d9-32b9-4184-9476-c6f5f66a48ea'::uuid,'44126','les mccann'),
('03af9ee7-dc11-49f4-8423-a32dfbacaa8e'::uuid,'3519986','tinashe'),
('57f69e78-3ecf-494c-ba68-bf5a2fdf4200'::uuid,'5648334','rosalia'),
('464eeab3-e2ff-4dff-a7ec-6b499b6b88fe'::uuid,'270578','spirit'),
('a2d05287-c666-46ef-8a60-57c750e1596d'::uuid,'48720','barbara mason'),
('49965312-72d0-4998-b59c-02e965bc8e58'::uuid,'3150192','sophie'),
('515ee18c-571b-403f-a371-d359c2c4c4a8'::uuid,'1029','i cube'),
('16806488-f939-4cac-bc1f-56987318badf'::uuid,'41249','eddie harris'),
('d362f060-be2a-4e38-9f6e-0202df4b90b3'::uuid,'3563778','sepehr'),
('1d2e7ab4-f4e1-4cc2-81ba-5ab92941d37c'::uuid,'59249','bill withers'),
('a750aa2f-956a-4dd4-ac68-0746c7f2e09f'::uuid,'36860','martin denny'),
('c5582c58-475c-4778-9af7-5c061fe4a87e'::uuid,'97988','letta mbulu'),
('f9250721-b691-4571-8ef5-4cdf3165bcd1'::uuid,'1300441','salem'),
('3d117c1a-850d-4577-b432-abae11642042'::uuid,'269','squarepusher'),
('6ab1be02-3723-4082-89f3-fd82e9ec2a69'::uuid,'98545','the s o s band'))
select jsonb_build_object('checked_at',now(),'database_bytes',pg_database_size(current_database()),
 'guards',(select jsonb_agg(jsonb_build_object('id',p.id,'did',p.did,'clear',(exists(select 1 from artists a where a.id=p.id and a.normalized_name=p.normalized_name)
and not exists(select 1 from external_ids x where x.entity_type='artist' and x.entity_id=p.id and x.provider in ('discogs','musicbrainz_discogs'))
and not exists(select 1 from external_ids x where x.entity_type='artist' and x.external_id=p.did and x.provider in ('discogs','musicbrainz_discogs'))
and not exists(select 1 from artists a join external_ids x on x.entity_id=a.id and x.entity_type='artist' and x.provider in ('discogs','musicbrainz_discogs') where a.id<>p.id and a.normalized_name=p.normalized_name and x.external_id<>p.did)
and not exists(select 1 from split_artist_halves s where s.keep_id=p.id or s.merge_id=p.id)))) from proposed p),
 'existing_recordings',(select coalesce(jsonb_agg(z),'[]') from(select r.id,r.artist_id,r.musicbrainz_recording_id,r.isrc from recordings r where r.musicbrainz_recording_id in(select distinct a.musicbrainz_recording_id from radio_appearances a join proposed p on p.id=a.artist_id where a.musicbrainz_recording_id is not null))z),
 'sizes',(select jsonb_agg(z) from(select c.relname,pg_total_relation_size(c.oid) as bytes,s.n_live_tup from pg_class c join pg_namespace n on n.oid=c.relnamespace left join pg_stat_user_tables s on s.relid=c.oid where n.nspname='public' and c.relname in ('external_ids','radio_appearances','recordings','artists','radio_episodes'))z),
 'reader_checks',(select jsonb_agg(z) from(select p.id,(select count(*) from artist_radio_appearances(p.id,500)) as appearances,(select count(*) from artist_radio_relations(p.id,20)) as relations from (select * from proposed order by id limit 5)p)z),
 'live_witnesses',(select jsonb_agg(z) from(select a.artist_id,array_agg(distinct a.musicbrainz_recording_id order by a.musicbrainz_recording_id) as ids from radio_appearances a join proposed p on p.id=a.artist_id where a.musicbrainz_recording_id is not null group by a.artist_id)z)
) as report;commit;

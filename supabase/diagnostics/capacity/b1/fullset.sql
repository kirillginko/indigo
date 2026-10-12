-- Read-only: the whole neighbour set per artist, old rule vs new, no limit.
with ids(id) as (select unnest(array['785fa052-f495-4dbd-9253-cbc39ea286d8'::uuid,'61d2d619-9d1a-4276-b947-786b85e394a2'::uuid,'57dd7219-75f9-4771-b761-6cf8f619c5da'::uuid,'bfaf3732-7663-4054-85af-2c56304e48ea'::uuid,'d182206e-d956-49cd-9ce3-0e28e45fe9ac'::uuid,'bfe15208-c772-4862-8a8c-1045eab01084'::uuid,'c3bf07ff-567f-4f22-a161-bece1411d391'::uuid,'58539bda-1f4b-4a6a-a561-a33713b6bef2'::uuid,'8dbba6d5-026c-4c73-857d-75fd605e8963'::uuid,'a2347d9c-4ff8-4c9e-9727-96546ae7f9ca'::uuid,'e4145285-fbd6-40c3-9d08-26bfbed0ff9e'::uuid,'868c3d4e-c65e-4e69-a140-9ad583b8a7d9'::uuid,'3e575492-0925-4946-9299-97e128716d28'::uuid,'d7664329-9589-4e87-a24e-943dd0d8235e'::uuid,'c45c9dcf-58d0-47fa-a03b-486a10c7959b'::uuid,'fcec65c1-5136-49c5-bb1f-eb06f72917a6'::uuid,'81a21d5d-b4e0-4615-9051-2b2cb1853304'::uuid,'dc7a6f84-e657-4651-85ae-5badc54fa787'::uuid,'862d255e-237d-49d9-83dd-31ff526722c3'::uuid,'d9ea42e1-5b3c-44d2-a4b6-a50933b70e12'::uuid,'ebc8aeb3-04b5-4a6a-b340-a02a7ea17cb8'::uuid,'c1052d95-5759-4890-9372-8394a1ceb995'::uuid,'bd5d93bb-f21c-413f-b7d1-0923fa935595'::uuid,'3a2926cb-877b-40c5-a581-5e4e257cea8e'::uuid,'c77b63e0-5532-4c2d-8bf3-43a9fa27deaa'::uuid,'db4182df-5b8c-4a13-b81a-672802f98cdd'::uuid,'ca7da774-3171-4faf-9e25-997001a5e16d'::uuid,'d997295d-2cb0-4456-b830-97a254d4e0a1'::uuid,'cbc45cac-9b66-411a-873c-a696206aba78'::uuid,'db468e87-ded5-4980-a382-d191ac231a06'::uuid,'f221b873-21fc-440d-8ced-e75918b02eb7'::uuid,'f2d7a970-68db-4fd6-a83b-26b5d9e83da7'::uuid,'e2694ac8-81c5-4c65-9684-d62a1f27b6bf'::uuid,'e9532a59-06ed-41b9-8c99-f6208242baf5'::uuid,'da18239a-7dd1-440b-b109-6f3b828c7b9a'::uuid,'f327fb75-8fba-4cce-a41e-81ff0df5f07c'::uuid,'6a3995a1-5e6f-4da3-a2fc-3e5f7d285647'::uuid,'6b8989b0-bb43-456f-8912-099621ca6524'::uuid,'6c3cec37-fa41-4d8e-8ba2-64baaf28419f'::uuid,'686ecee0-c1be-479a-b9f9-bb6e8da6cb64'::uuid,'6c531a7f-97ac-4f2d-8435-26eaf12e0d20'::uuid,'69fb04fe-bc4a-455d-b938-79cff03e6e04'::uuid,'68f4ab09-f311-4d7e-8931-e3758206d35e'::uuid,'692a3b71-3313-4de4-935b-8ceffc7e0f07'::uuid,'6c20271a-2548-420d-baef-677fc00ad859'::uuid,'6c26ccb0-606e-4845-906f-03b67d19adcf'::uuid,'69a0e1f3-5090-4577-aa87-fd0ccdfeed42'::uuid,'6af6c301-9301-4c07-aacb-5638acd31607'::uuid,'c56ae1b0-d0f1-4150-ad2e-02d9dc756efb'::uuid,'c76b3ecc-8e4c-4abd-896f-0926e336dc94'::uuid,'c515a672-7243-4dd2-a099-9da50e37ccbe'::uuid,'c68c0167-fbd6-4194-a9c0-cb182e8e9ec3'::uuid,'c5721030-271c-4c61-bf55-bd7f50d9f080'::uuid,'c7823511-6fb5-4a70-bda4-0f3248ff770c'::uuid,'c7224505-8479-496f-9a36-8fe4d26fd3f1'::uuid,'c5fa9b60-8759-402c-9216-ef1c9207e6a4'::uuid,'c5921006-80f3-4d34-acb5-cad1209e5349'::uuid,'c7c5c731-c4fe-4296-b18c-5dfa60f19864'::uuid,'c8b7a068-0c54-40ce-966f-b406f1138b3f'::uuid,'c5b29344-1214-449e-97c3-6a9126883a20'::uuid])),
stored as (
  select i.id, case when m.from_entity_id = i.id then m.to_entity_id else m.from_entity_id end as other, m.evidence_count as n
  from ids i join public.music_relationships m on m.relationship_type = 'radio_neighbor' and (m.from_entity_id = i.id or m.to_entity_id = i.id)),
live as (
  select i.id, b.artist_id as other, count(*)::int as n
  from ids i join public.radio_appearances a on a.artist_id = i.id
  join public.radio_appearances b on b.radio_episode_id = a.radio_episode_id and b.track_index in (a.track_index-1, a.track_index+1)
  where b.artist_id is not null and b.artist_id <> i.id group by 1, 2),
old_rule as (select s.id, s.other, s.n from stored s where exists (select 1 from live l where l.id = s.id and l.other = s.other)),
new_rule as (
  select id, other, n from stored where n >= 2
  union all
  select l.id, l.other, l.n from live l where not exists (select 1 from stored s where s.id = l.id and s.other = l.other and s.n >= 2)),
per_artist as (
  select i.id,
    (select count(*) from old_rule o where o.id = i.id) as old_n,
    (select count(*) from new_rule n where n.id = i.id) as new_n,
    (select count(*) from (select other, n from old_rule where id = i.id except select other, n from new_rule where id = i.id) z) as old_not_new,
    (select count(*) from (select other, n from new_rule where id = i.id except select other, n from old_rule where id = i.id) z) as new_not_old,
    (select count(*) from stored s where s.id = i.id and not exists (select 1 from live l where l.id = s.id and l.other = s.other)) as stale
  from ids i)
select json_build_object(
  'artists', count(*), 'identical_sets', count(*) filter (where old_not_new = 0 and new_not_old = 0),
  'old_total', sum(old_n), 'new_total', sum(new_n), 'old_not_new', sum(old_not_new), 'new_not_old', sum(new_not_old), 'stale_stored_dropped', sum(stale),
  'worst', (select json_agg(z) from (select id, old_n, new_n, old_not_new, new_not_old from per_artist where old_not_new + new_not_old > 0 order by old_not_new + new_not_old desc limit 5) z)
) as r from per_artist;

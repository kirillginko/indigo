-- 0076's identity corrections, on the live rows' own ids, in a transaction
-- that is rolled back. The migration has already run on this empty database
-- (and done nothing); the fixtures below are the live state the audit found,
-- and the migration is applied to them again.

begin;

insert into public.labels (id, name, normalized_name) values
    ('11000000-0000-0000-0000-000000000001', 'Hippos In Tanks', 'hippos in tanks'),
    ('11000000-0000-0000-0000-000000000002', 'Warp Records', 'warp records'),
    ('11000000-0000-0000-0000-000000000003', 'Def Jam', 'def jam');
insert into public.artists (id, name, normalized_name, musicbrainz_id) values
    ('5dbab0e3-b85a-42e9-8c35-64529418a062', 'Hype Williams', 'hype williams', 'fdd6ea04-81fa-45a2-96d8-c29ba08bfbde'),
    ('8c74e06d-4b24-44c6-9a18-e69160d402ea', 'Hype Williams (2)', 'hype williams 2', null),
    ('cc290916-e418-457f-81e4-8e97b8a910bb', 'Prefuse73', 'prefuse73', null),
    ('36133fd1-32cc-4b26-8375-6d0583a5c346', 'Prefuse 73', 'prefuse 73', 'fc61dd75-880b-44ba-9ba9-c7b643d33413'),
    ('21000000-0000-0000-0000-000000000001', 'Gatekeeper', 'gatekeeper', null),          -- duo's label peer
    ('21000000-0000-0000-0000-000000000002', 'Boards Of Canada', 'boards of canada', null), -- Prefuse 73's label peer
    ('21000000-0000-0000-0000-000000000003', 'Speedy J', 'speedy j', null),               -- a namesake row more,
    ('21000000-0000-0000-0000-000000000004', 'Speedy J', 'speedy j', null);               -- beside any already here
insert into public.external_ids (entity_type, entity_id, provider, external_id) values
    ('artist', '5dbab0e3-b85a-42e9-8c35-64529418a062', 'nts', 'hype williams'),
    ('artist', '5dbab0e3-b85a-42e9-8c35-64529418a062', 'musicbrainz_discogs', '1874027'),
    ('artist', '5dbab0e3-b85a-42e9-8c35-64529418a062', 'discogs', '398459'),        -- what the merge left
    ('artist', '8c74e06d-4b24-44c6-9a18-e69160d402ea', 'discogs', '1874027'),
    ('artist', 'cc290916-e418-457f-81e4-8e97b8a910bb', 'nts', 'prefuse73'),
    ('artist', '36133fd1-32cc-4b26-8375-6d0583a5c346', 'discogs', '3722'),
    ('artist', '36133fd1-32cc-4b26-8375-6d0583a5c346', 'nts', 'prefuse 73'),
    ('artist', '21000000-0000-0000-0000-000000000001', 'discogs', '9100001'),
    ('artist', '21000000-0000-0000-0000-000000000002', 'discogs', '9100002'),
    ('artist', '21000000-0000-0000-0000-000000000003', 'discogs', '9400823'),
    ('artist', '21000000-0000-0000-0000-000000000004', 'discogs', '9400316');
insert into public.releases (title, artist_id, label_id, discogs_id) values
    ('One Nation', '8c74e06d-4b24-44c6-9a18-e69160d402ea', '11000000-0000-0000-0000-000000000001', 4211816),
    ('Gatekeeper''s Record', '21000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001', 9200001),
    ('One Word Extinguisher', '36133fd1-32cc-4b26-8375-6d0583a5c346', '11000000-0000-0000-0000-000000000002', 9200002),
    ('Music Has The Right To Children', '21000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000002', 9200003);

-- Before: the radio row reads as the director as well as the duo.
create temp table speedy_before as
select public.knowledge_answers('[{"id":"artist:speedy j","kind":"artist","key":"speedy j","provider":"","handle":""}]'::jsonb, '{}')
       ->'nodes'->'artist:speedy j' as answer;
do $$
declare a jsonb;
begin
    a := public.knowledge_answers(
        '[{"id":"artist:hype williams","kind":"artist","key":"hype williams","provider":"","handle":""},
          {"id":"artist:prefuse73","kind":"artist","key":"prefuse73","provider":"","handle":""}]'::jsonb, '{}');
    if not (a->'nodes'->'artist:hype williams'->'identities') @> '[{"discogsID":"398459"}]' then
        raise exception 'fixture: the radio row should start out holding the director''s id';
    end if;
    if jsonb_array_length(coalesce(a->'nodes'->'artist:prefuse73'->'identities', '[]')) <> 0 then
        raise exception 'fixture: prefuse73 should start out with no identity';
    end if;
end $$;

\i :root/supabase/migrations/0076_identity_corrections.sql

do $$
declare a jsonb; hype jsonb; pre jsonb; spaced jsonb; n int;
begin
    a := public.knowledge_answers(
        '[{"id":"artist:hype williams","kind":"artist","key":"hype williams","provider":"","handle":""},
          {"id":"artist:prefuse73","kind":"artist","key":"prefuse73","provider":"","handle":""},
          {"id":"artist:prefuse 73","kind":"artist","key":"prefuse 73","provider":"","handle":""},
          {"id":"artist:speedy j","kind":"artist","key":"speedy j","provider":"","handle":""}]'::jsonb, '{}');
    hype := a->'nodes'->'artist:hype williams';
    pre := a->'nodes'->'artist:prefuse73';
    spaced := a->'nodes'->'artist:prefuse 73';

    -- Hype Williams: the duo through MusicBrainz only; no director anywhere.
    if hype->'identities' <> '[{"via": "musicbrainz", "discogsID": "1874027", "catalogued": true}]'::jsonb then
        raise exception 'hype williams identities: %', hype->'identities';
    end if;
    if hype::text like '%398459%' then raise exception 'the director is still in the answer'; end if;
    if not exists (select 1 from jsonb_array_elements(hype->'edges') e where e->'to'->>'name' = 'Gatekeeper') then
        raise exception 'the duo''s label peer is not reached: %', hype->'edges';
    end if;
    if not exists (select 1 from public.external_ids where entity_id = '5dbab0e3-b85a-42e9-8c35-64529418a062' and provider = 'nts') then
        raise exception 'the radio name was lost';
    end if;
    if (select count(*) from public.external_ids where external_id = '1874027') <> 2 then
        raise exception 'the duo''s own row lost its id';
    end if;

    -- Prefuse73: Prefuse 73 through the recorded link; its own row unchanged.
    if pre->'identities' <> '[{"via": "musicbrainz", "discogsID": "3722", "catalogued": true}]'::jsonb then
        raise exception 'prefuse73 identities: %', pre->'identities';
    end if;
    if not exists (select 1 from jsonb_array_elements(pre->'edges') e where e->'to'->>'name' = 'Boards Of Canada') then
        raise exception 'prefuse73 does not reach Prefuse 73''s label peers';
    end if;
    if spaced->'identities' <> '[{"via": "discogs", "discogsID": "3722", "catalogued": true}]'::jsonb then
        raise exception 'prefuse 73 identities changed: %', spaced->'identities';
    end if;
    if (select name from public.artists where id = 'cc290916-e418-457f-81e4-8e97b8a910bb') <> 'Prefuse73' then
        raise exception 'the radio spelling was rewritten';
    end if;
    if (select source_url from public.external_ids where provider = 'musicbrainz_discogs' and external_id = '3722')
       <> 'https://musicbrainz.org/artist/fc61dd75-880b-44ba-9ba9-c7b643d33413' then
        raise exception 'the link does not say where it came from';
    end if;

    -- Namesakes untouched: Speedy J's answer is exactly what it was.
    if (a->'nodes'->'artist:speedy j') <> (select answer from speedy_before)
       or (a->'nodes'->'artist:speedy j'->>'ambiguousName')::boolean is not true then
        raise exception 'speedy j changed: %', a->'nodes'->'artist:speedy j';
    end if;
end $$;

-- Applying it again changes nothing.
create temp table before_again as select provider, entity_id, external_id from public.external_ids;
\i :root/supabase/migrations/0076_identity_corrections.sql
do $$
begin
    if exists (select provider, entity_id, external_id from public.external_ids
               except select * from before_again)
       or exists (select * from before_again
                  except select provider, entity_id, external_id from public.external_ids) then
        raise exception 'the second run changed identities';
    end if;
end $$;

-- The merge rule: a Discogs search makes a director row again; it is not a
-- split half of the radio row, whose MusicBrainz link says otherwise. A
-- name-only radio row still pairs, and so does one whose MusicBrainz link
-- agrees.
insert into public.artists (id, name, normalized_name) values
    ('22000000-0000-0000-0000-000000000001', 'Hype Williams', 'hype williams'),
    ('22000000-0000-0000-0000-000000000002', 'Somebody', 'somebody'),
    ('22000000-0000-0000-0000-000000000003', 'Somebody', 'somebody'),
    ('22000000-0000-0000-0000-000000000004', 'Agreed', 'agreed'),
    ('22000000-0000-0000-0000-000000000005', 'Agreed', 'agreed');
insert into public.external_ids (entity_type, entity_id, provider, external_id) values
    ('artist', '22000000-0000-0000-0000-000000000001', 'discogs', '398459'),
    ('artist', '22000000-0000-0000-0000-000000000002', 'nts', 'somebody'),
    ('artist', '22000000-0000-0000-0000-000000000003', 'discogs', '9300001'),
    ('artist', '22000000-0000-0000-0000-000000000004', 'nts', 'agreed'),
    ('artist', '22000000-0000-0000-0000-000000000004', 'musicbrainz_discogs', '9300002'),
    ('artist', '22000000-0000-0000-0000-000000000005', 'discogs', '9300002');
do $$
begin
    if exists (select 1 from public.split_artist_halves where normalized_name = 'hype williams') then
        raise exception 'the director would be merged into the duo again';
    end if;
    if not exists (select 1 from public.split_artist_halves where normalized_name = 'somebody') then
        raise exception 'a plain split half no longer pairs';
    end if;
    if not exists (select 1 from public.split_artist_halves where normalized_name = 'agreed') then
        raise exception 'a radio row whose MusicBrainz link agrees no longer pairs';
    end if;
end $$;

rollback;

select 'identity corrections: director removed, duo through MusicBrainz, prefuse73 -> 3722, namesakes kept, merge refuses contradictions' as ok;

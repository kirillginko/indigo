-- 0081: portraits carry their state; namesakes that disagree are withheld.
begin;
insert into public.artists (id, name, normalized_name) values
    ('41000000-0000-0000-0000-000000000001', 'Hype Williams', 'hype williams'),     -- the duo's radio row
    ('41000000-0000-0000-0000-000000000002', 'Speedy J', 'speedy j'),
    ('41000000-0000-0000-0000-000000000003', 'Speedy J', 'speedy j'),               -- a namesake row
    ('41000000-0000-0000-0000-000000000004', 'Purelink', 'purelink'),               -- old rule, no state
    ('41000000-0000-0000-0000-000000000005', 'Nez', 'nez'),                          -- withheld
    ('41000000-0000-0000-0000-000000000006', 'Logic', 'logic'),                      -- own entry, no picture (0082)
    ('41000000-0000-0000-0000-000000000007', 'Om', 'om'),                            -- the same, beside a namesake's face
    ('41000000-0000-0000-0000-000000000008', 'Om', 'om'),
    ('41000000-0000-0000-0000-000000000009', 'Danny Brown', 'danny brown'),         -- 0085: two identities,
    ('41000000-0000-0000-0000-00000000000a', 'Danny Brown', 'danny brown');         -- one picture
select public.record_artist_portrait('41000000-0000-0000-0000-000000000001', 'https://i.discogs.com/duo.jpeg', 150, 150, 'verified', 1874027);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000002', 'https://i.discogs.com/paap.jpeg', 150, 150, 'verified', 823);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000003', 'https://i.discogs.com/other-speedy.jpeg', 150, 150, 'unresolved', 316464);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000004', 'https://i.discogs.com/purelink.jpeg', 150, 150);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000005', 'https://i.discogs.com/nez13.jpeg', 150, 150, 'withheld', null);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000006', null, null, null, 'verified', 15177);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000007', null, null, null, 'verified', 17004);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000008', 'https://i.discogs.com/om-other.jpeg', 150, 150, 'unresolved', 9);
insert into public.external_ids (entity_type, entity_id, provider, external_id) values
    ('artist', '41000000-0000-0000-0000-000000000009', 'discogs', '990455494'),
    ('artist', '41000000-0000-0000-0000-00000000000a', 'discogs', '992146925');
select public.record_artist_portrait('41000000-0000-0000-0000-000000000009', 'https://i.discogs.com/engineer.jpeg', 600, 600, 'verified', 990455494);
do $$
declare r jsonb := public.portrait_states_for_artists(array['hype williams','speedy j','purelink','nez','nobody','logic','om','danny brown']);
begin
    if r->'hype williams' <> '{"url": "https://i.discogs.com/duo.jpeg", "state": "verified", "discogsID": 1874027}'::jsonb then
        raise exception 'verified: %', r->'hype williams'; end if;
    -- Two Speedy J rows, two different faces: no name can say which.
    if r->'speedy j' <> '{"state": "withheld"}'::jsonb then raise exception 'namesakes: %', r->'speedy j'; end if;
    if r->'purelink' <> '{"url": "https://i.discogs.com/purelink.jpeg", "state": "unresolved"}'::jsonb then
        raise exception 'legacy: %', r->'purelink'; end if;
    if r->'nez' <> '{"state": "withheld"}'::jsonb then raise exception 'withheld: %', r->'nez'; end if;
    if r ? 'nobody' then raise exception 'a name with nothing answered'; end if;
    -- 0085: two identities under one name, one picture: no face by name.
    if r->'danny brown' <> '{"state": "withheld"}'::jsonb then raise exception 'namesake pair: %', r->'danny brown'; end if;
    -- 0082: a row whose own entry has no picture answers no face, so a device drops the one it cached.
    if r->'logic' <> '{"state": "withheld"}'::jsonb then raise exception 'verified without picture: %', r->'logic'; end if;
    if r->'om' <> '{"url": "https://i.discogs.com/om-other.jpeg", "state": "unresolved", "discogsID": 9}'::jsonb then
        raise exception 'beside another row''s face: %', r->'om'; end if;
    if (select original_url from public.artwork where entity_id = '41000000-0000-0000-0000-000000000005') is not null then
        raise exception 'a withheld portrait kept its address'; end if;
    -- The name-only reader installed builds use: same addresses, nothing for namesakes or withheld.
    if public.portraits_for_artists(array['hype williams','speedy j','purelink','nez'])
       <> '{"hype williams": "https://i.discogs.com/duo.jpeg", "purelink": "https://i.discogs.com/purelink.jpeg"}'::jsonb then
        raise exception 'legacy reader: %', public.portraits_for_artists(array['hype williams','speedy j','purelink','nez']); end if;
    if not has_function_privilege('anon', 'public.portrait_states_for_artists(text[])', 'execute') then
        raise exception 'the app cannot call it'; end if;
    if has_function_privilege('anon', 'public.record_artist_portrait(uuid,text,integer,integer,text,bigint)', 'execute') then
        raise exception 'anon can write portraits'; end if;
end $$;
rollback;
select 'portrait state: verified, unresolved and withheld kept apart; disagreeing namesakes withheld; installed builds see the same' as ok;

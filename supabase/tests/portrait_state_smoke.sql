-- 0081: portraits carry their state; namesakes that disagree are withheld.
begin;
insert into public.artists (id, name, normalized_name) values
    ('41000000-0000-0000-0000-000000000001', 'Hype Williams', 'hype williams'),     -- the duo's radio row
    ('41000000-0000-0000-0000-000000000002', 'Speedy J', 'speedy j'),
    ('41000000-0000-0000-0000-000000000003', 'Speedy J', 'speedy j'),               -- a namesake row
    ('41000000-0000-0000-0000-000000000004', 'Purelink', 'purelink'),               -- old rule, no state
    ('41000000-0000-0000-0000-000000000005', 'Nez', 'nez');                          -- withheld
select public.record_artist_portrait('41000000-0000-0000-0000-000000000001', 'https://i.discogs.com/duo.jpeg', 150, 150, 'verified', 1874027);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000002', 'https://i.discogs.com/paap.jpeg', 150, 150, 'verified', 823);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000003', 'https://i.discogs.com/other-speedy.jpeg', 150, 150, 'unresolved', 316464);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000004', 'https://i.discogs.com/purelink.jpeg', 150, 150);
select public.record_artist_portrait('41000000-0000-0000-0000-000000000005', 'https://i.discogs.com/nez13.jpeg', 150, 150, 'withheld', null);
do $$
declare r jsonb := public.portrait_states_for_artists(array['hype williams','speedy j','purelink','nez','nobody']);
begin
    if r->'hype williams' <> '{"url": "https://i.discogs.com/duo.jpeg", "state": "verified", "discogsID": 1874027}'::jsonb then
        raise exception 'verified: %', r->'hype williams'; end if;
    -- Two Speedy J rows, two different faces: no name can say which.
    if r->'speedy j' <> '{"state": "withheld"}'::jsonb then raise exception 'namesakes: %', r->'speedy j'; end if;
    if r->'purelink' <> '{"url": "https://i.discogs.com/purelink.jpeg", "state": "unresolved"}'::jsonb then
        raise exception 'legacy: %', r->'purelink'; end if;
    if r->'nez' <> '{"state": "withheld"}'::jsonb then raise exception 'withheld: %', r->'nez'; end if;
    if r ? 'nobody' then raise exception 'a name with nothing answered'; end if;
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

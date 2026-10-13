-- 0083: an identity change queues the artist's portrait, once, unless it is
-- already verified for an id the row still holds.
begin;
delete from public.enrichment_jobs where job_type = 'fetch_artist_portrait';
insert into public.artists (id, name, normalized_name) values
    ('42000000-0000-0000-0000-000000000001', 'Hype Williams', 'hype williams'),   -- old rule's face, then an identity
    ('42000000-0000-0000-0000-000000000002', 'Speedy J', 'speedy j'),             -- verified for 990000823
    ('42000000-0000-0000-0000-000000000003', 'Purelink', 'purelink');             -- no portrait yet
select public.record_artist_portrait('42000000-0000-0000-0000-000000000001', 'https://i.discogs.com/director.jpeg', 150, 150);
select public.record_artist_portrait('42000000-0000-0000-0000-000000000002', 'https://i.discogs.com/paap.jpeg', 150, 150, 'verified', 990000823);
insert into public.external_ids (entity_type, entity_id, provider, external_id) values
    ('artist', '42000000-0000-0000-0000-000000000002', 'discogs', '990000823');
do $$
declare queued int;
begin
    -- Speedy J's id is the one his portrait is verified for: nothing to do.
    if exists (select 1 from public.enrichment_jobs where dedupe_key = '42000000-0000-0000-0000-000000000002') then
        raise exception 'a verified portrait was queued again'; end if;

    -- The duo's row gains its identity: its old-rule face is looked at again.
    insert into public.external_ids (entity_type, entity_id, provider, external_id) values
        ('artist', '42000000-0000-0000-0000-000000000001', 'musicbrainz_discogs', '991874027');
    -- And a second id in the same breath is the same job, not another.
    insert into public.external_ids (entity_type, entity_id, provider, external_id) values
        ('artist', '42000000-0000-0000-0000-000000000001', 'discogs', '991874027');
    select count(*) into queued from public.enrichment_jobs
     where job_type = 'fetch_artist_portrait' and dedupe_key = '42000000-0000-0000-0000-000000000001' and status = 'pending';
    if queued <> 1 then raise exception 'gained: % jobs', queued; end if;

    -- Speedy J loses the id his portrait is verified for: looked at again.
    delete from public.external_ids where entity_id = '42000000-0000-0000-0000-000000000002';
    if not exists (select 1 from public.enrichment_jobs where dedupe_key = '42000000-0000-0000-0000-000000000002' and status = 'pending') then
        raise exception 'lost: not queued'; end if;

    -- A row with no portrait is the ordinary lane's, not this.
    insert into public.external_ids (entity_type, entity_id, provider, external_id) values
        ('artist', '42000000-0000-0000-0000-000000000003', 'discogs', '990000077');
    if exists (select 1 from public.enrichment_jobs where dedupe_key = '42000000-0000-0000-0000-000000000003') then
        raise exception 'no portrait, still queued'; end if;

    -- Other kinds of ids change nothing.
    insert into public.external_ids (entity_type, entity_id, provider, external_id) values
        ('artist', '42000000-0000-0000-0000-000000000002', 'musicbrainz', 'x-mbid-test-0083');
    select count(*) into queued from public.enrichment_jobs where dedupe_key = '42000000-0000-0000-0000-000000000002';
    if queued <> 1 then raise exception 'a musicbrainz id queued: %', queued; end if;

    -- Devices hear about a change of answer, not about a fetch that changed nothing.
    declare since timestamptz := clock_timestamp(); changes jsonb;
    begin
        perform public.record_artist_portrait('42000000-0000-0000-0000-000000000002', 'https://i.discogs.com/paap.jpeg', 150, 150, 'verified', 990000823);
        perform public.record_artist_portrait('42000000-0000-0000-0000-000000000001', null, null, null, 'withheld', null);
        update public.artwork set portrait_changed_at = clock_timestamp()
         where entity_id = '42000000-0000-0000-0000-000000000001' and portrait_changed_at < since;  -- now() is the transaction's
        changes := public.portrait_changes_since(since);
        if changes->'names' <> '["hype williams"]'::jsonb then raise exception 'changes: %', changes; end if;
    end;
    if not has_function_privilege('anon', 'public.portrait_changes_since(timestamptz,integer)', 'execute') then
        raise exception 'the app cannot ask what changed'; end if;
    if has_function_privilege('anon', 'public.portrait_needs_another_look(uuid)', 'execute') then
        raise exception 'anon can call the check'; end if;
end $$;
rollback;
select 'portrait follows identity: gained, changed and lost ids queue one look; verified and unrelated ids do not' as ok;

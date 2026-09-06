-- Smoke test for the scene roster schema.
--
-- Written for the same reason `radio_smoke.sql` was: everything here is
-- reached from the app through one function and drained by a worker, and none
-- of that is exercised by applying the migrations. What is checked is the
-- whole path — asking for a scene, the crawler recording a page of it, the
-- resume pass picking up what stalled — because each of those is a place a
-- mistake would only show as a scene page that stays empty for a month.
--
-- Run against a throwaway Postgres 17 with the migrations applied:
--
--     psql -f supabase/tests/scene_smoke.sql
--
-- Every check raises on failure, so a clean run means a clean run.

\set ON_ERROR_STOP on
begin;

-- ---------------------------------------------------------------------------
-- Asking for one
-- ---------------------------------------------------------------------------

do $$
declare
    answer jsonb;
    roster_id uuid;
    queued int;
begin
    answer := public.request_scene_roster('Manchester', 'manchester', 'Hip Hop', 'hip hop');
    roster_id := (answer ->> 'roster_id')::uuid;

    if roster_id is null then
        raise exception 'request_scene_roster returned no roster: %', answer;
    end if;
    if (answer ->> 'status') <> 'pending' then
        raise exception 'a new roster should be pending, got %', answer ->> 'status';
    end if;

    -- And it asked for the work. This is the join the app cannot make itself:
    -- `enqueue_enrichment_job` is revoked from anon, so a caller naming a
    -- scene has to reach the queue through here or not at all.
    select count(*) into queued
    from public.enrichment_jobs
    where provider = 'musicbrainz'
      and job_type = 'fetch_scene_roster'
      and dedupe_key = 'manchester|hip hop'
      and status = 'pending';
    if queued <> 1 then
        raise exception 'expected one queued scene job, found %', queued;
    end if;

    -- Asked for twice is asked for once. A page opened repeatedly must not
    -- become repeated upstream requests.
    perform public.request_scene_roster('Manchester', 'manchester', 'Hip Hop', 'hip hop');
    select count(*) into queued
    from public.enrichment_jobs
    where dedupe_key = 'manchester|hip hop' and status in ('pending', 'running');
    if queued <> 1 then
        raise exception 'a second ask queued more work: %', queued;
    end if;

    -- A place and a different sound is a different scene, not the same one.
    perform public.request_scene_roster('Manchester', 'manchester', 'Hard Techno', 'hard techno');
    if (select count(*) from public.scene_rosters where place_key = 'manchester') <> 2 then
        raise exception 'two sounds in one place should be two rosters';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Recording a page of it
-- ---------------------------------------------------------------------------

do $$
declare
    v_roster uuid;
    members int;
    state text;
begin
    select id into v_roster from public.scene_rosters
    where place_key = 'manchester' and sound_key = 'hip hop';

    -- A page that does not finish the crawl leaves it filling.
    perform public.record_scene_members(
        v_roster,
        '[{"name":"Iceboy Violet","normalized_name":"iceboy violet","mbid":"mb-1",
           "area":"Manchester","began":"2018","score":100},
          {"name":"Space Afrika","normalized_name":"space afrika","mbid":"mb-2",
           "area":"Manchester","began":"2014","score":98}]'::jsonb,
        2, 40, false);

    select member_count, status into members, state
    from public.scene_rosters where id = v_roster;
    if members <> 2 then raise exception 'expected 2 members, got %', members; end if;
    if state <> 'filling' then raise exception 'expected filling, got %', state; end if;

    -- The same name again is the same person. A crawl that overlaps its own
    -- pages must not double the scene.
    perform public.record_scene_members(
        v_roster,
        '[{"name":"Space Afrika","normalized_name":"space afrika","score":50},
          {"name":"Blackhaine","normalized_name":"blackhaine","score":90}]'::jsonb,
        4, 40, true);

    select member_count, status into members, state
    from public.scene_rosters where id = v_roster;
    if members <> 3 then raise exception 'expected 3 members, got %', members; end if;
    if state <> 'ready' then raise exception 'expected ready, got %', state; end if;

    -- The better score survives, so a roster reads best-first however the
    -- pages arrived.
    if (select score from public.scene_members
        where scene_members.roster_id = v_roster
          and normalized_name = 'space afrika') <> 98 then
        raise exception 'a repeated member should keep its best score';
    end if;

    -- A row with no usable name is not a member.
    perform public.record_scene_members(
        v_roster, '[{"name":"","normalized_name":""}]'::jsonb, 4, 40, true);
    if (select member_count from public.scene_rosters where id = v_roster) <> 3 then
        raise exception 'an unnamed row became a member';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Picking up what stalled
-- ---------------------------------------------------------------------------

do $$
declare
    resumed int;
begin
    -- Nothing is owed: one roster is ready and fresh, the other is pending but
    -- already has a job waiting, so the dedupe index holds.
    update public.scene_rosters set filled_at = now() where status = 'ready';

    -- A roster that finished long ago is walked again.
    update public.scene_rosters
    set filled_at = now() - interval '90 days'
    where sound_key = 'hip hop';
    delete from public.enrichment_jobs where dedupe_key = 'manchester|hip hop';

    resumed := public.resume_scene_rosters(4);
    if resumed < 1 then
        raise exception 'a stale roster was not resumed';
    end if;
    if (select count(*) from public.enrichment_jobs
        where dedupe_key = 'manchester|hip hop' and status = 'pending') <> 1 then
        raise exception 'resume did not queue the stale roster';
    end if;

    -- And running it again does not queue it twice.
    perform public.resume_scene_rosters(4);
    if (select count(*) from public.enrichment_jobs
        where dedupe_key = 'manchester|hip hop' and status in ('pending','running')) <> 1 then
        raise exception 'resume queued the same roster twice';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- The shelf it starts with
-- ---------------------------------------------------------------------------

do $$
declare
    shelved int;
    again int;
begin
    -- Idempotent, which is what lets it run on a timer — and why this counts
    -- the shelf rather than what one call added. Turning the schedule on
    -- already put it up, so a second call is expected to add nothing.
    perform public.seed_scene_rosters();
    select count(*) into shelved from public.scene_rosters;
    if shelved < 10 then
        raise exception 'the shelf holds only % scenes', shelved;
    end if;

    -- A sound with no place is a scene. Fourth World is not from anywhere.
    if not exists (
        select 1 from public.scene_rosters
        where sound_key = 'fourth world' and coalesce(place_key, '') = ''
    ) then
        raise exception 'a placeless scene was not seeded';
    end if;

    again := public.seed_scene_rosters();
    if again <> 0 then
        raise exception 'seeding twice added % more', again;
    end if;

    -- And a seeded scene is something the resume pass will pick up, so the
    -- crawl runs with nobody using the app at all.
    if public.resume_scene_rosters(4) < 1 then
        raise exception 'seeded scenes were not resumed';
    end if;
end $$;

-- Neither half is optional to the point of being nothing.
do $$
begin
    begin
        insert into public.scene_rosters (place, place_key, sound, sound_key)
        values (null, '', null, '');
        raise exception 'a scene with no place and no sound was accepted';
    exception
        when check_violation then null;
    end;
end $$;

rollback;

\echo 'scene smoke: all checks passed'

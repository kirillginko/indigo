-- Smoke test for the radio and enrichment schema.
--
-- Everything here was written against a database nobody could run: no Docker on
-- the machine it was authored on, so the migrations were checked by parsing and
-- shipped by hope. Three bugs reached the live project that way, two of them in
-- the same function. This is the thing that would have caught all three.
--
-- Run against a throwaway Postgres 17 with the migrations applied:
--
--     psql -f supabase/tests/radio_smoke.sql
--
-- Every check raises on failure, so a clean run means a clean run.

\set ON_ERROR_STOP on
begin;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- A label with an artist who has three records on it. Three, deliberately: a
-- label edge counted across a join to `releases` multiplies every play by the
-- artist's release count, and one release would hide that.
insert into public.labels (id, name, normalized_name)
values ('00000000-0000-4000-8000-0000000000b1'::uuid, 'Ilian Tape', 'ilian tape');

insert into public.artists (id, name, normalized_name)
values
    ('00000000-0000-4000-8000-0000000000A1'::uuid, 'Skee Mask', 'skee mask'),
    ('00000000-0000-4000-8000-0000000000A2'::uuid, 'Zenker Brothers', 'zenker brothers');

insert into public.releases (id, title, artist_id, label_id)
values
    ('00000000-0000-4000-8000-0000000000c1'::uuid, 'Compro',  '00000000-0000-4000-8000-0000000000A1'::uuid, '00000000-0000-4000-8000-0000000000b1'::uuid),
    ('00000000-0000-4000-8000-0000000000c2'::uuid, 'ISS004',  '00000000-0000-4000-8000-0000000000A1'::uuid, '00000000-0000-4000-8000-0000000000b1'::uuid),
    ('00000000-0000-4000-8000-0000000000c3'::uuid, 'Shred',   '00000000-0000-4000-8000-0000000000A1'::uuid, '00000000-0000-4000-8000-0000000000b1'::uuid);

insert into public.radio_shows (id, provider, external_id, station, title)
values ('00000000-0000-4000-8000-0000000000d1'::uuid, 'nts', 'ben-ufo', 'NTS', 'Ben UFO');

insert into public.radio_episodes (id, radio_show_id, provider, external_id, title, aired_at, tracklist_status)
values
    ('00000000-0000-4000-8000-0000000000E1'::uuid, '00000000-0000-4000-8000-0000000000d1'::uuid,
     'nts', 'ben-ufo/one', 'Ben UFO 1', now() - interval '2 days', 'available'),
    ('00000000-0000-4000-8000-0000000000E2'::uuid, '00000000-0000-4000-8000-0000000000d1'::uuid,
     'nts', 'ben-ufo/two', 'Ben UFO 2', now() - interval '1 day', 'available');

-- Episode one: a known artist, an unknown one next to it, and a placeholder.
-- The placeholder arrives the way the ingester writes them — raw text kept, no
-- normalized form — so it must never become an artist.
insert into public.radio_appearances
    (radio_episode_id, track_index, raw_artist_name, raw_track_title,
     normalized_artist_name, normalized_title, offset_seconds)
values
    ('00000000-0000-4000-8000-0000000000E1'::uuid, 0, 'Skee Mask', 'Rev8617', 'skee mask', 'rev8617', 60),
    ('00000000-0000-4000-8000-0000000000E1'::uuid, 1, 'Sofia Kourtesis', 'By Your Side', 'sofia kourtesis', 'by your side', 300),
    ('00000000-0000-4000-8000-0000000000E1'::uuid, 2, 'Unknown', 'White Label', null, 'white label', 600),
    ('00000000-0000-4000-8000-0000000000E2'::uuid, 0, 'Skee Mask', 'Flyby VFR', 'skee mask', 'flyby vfr', 120),
    ('00000000-0000-4000-8000-0000000000E2'::uuid, 1, 'Sofia Kourtesis', 'Madres', 'sofia kourtesis', 'madres', 480);

-- ---------------------------------------------------------------------------
-- Resolution and adoption
-- ---------------------------------------------------------------------------

select public.resolve_radio_appearances(null);

do $$
declare n int;
begin
    select count(*) into n from public.radio_appearances
    where artist_id = '00000000-0000-4000-8000-0000000000A1'::uuid;
    if n <> 2 then
        raise exception 'expected 2 appearances matched to the existing artist, got %', n;
    end if;

    -- Adopted, because nothing in the catalogue was called this.
    select count(*) into n from public.artists where normalized_name = 'sofia kourtesis';
    if n <> 1 then raise exception 'expected the unknown name to be adopted once, got %', n; end if;

    select count(*) into n from public.external_ids
    where provider = 'nts' and entity_type = 'artist' and external_id = 'sofia kourtesis';
    if n <> 1 then raise exception 'adopted artist should carry its provenance, got %', n; end if;

    -- And the placeholder must not be.
    select count(*) into n from public.artists where lower(name) = 'unknown';
    if n <> 0 then raise exception 'a placeholder became an artist'; end if;

    select count(*) into n from public.radio_appearances
    where raw_artist_name = 'Unknown' and artist_id is not null;
    if n <> 0 then raise exception 'a placeholder appearance was resolved'; end if;
end $$;

-- Re-running must be a no-op rather than a second set of artists.
select public.resolve_radio_appearances(null);
do $$
declare n int;
begin
    select count(*) into n from public.artists where normalized_name = 'sofia kourtesis';
    if n <> 1 then raise exception 'resolution is not idempotent: % artists', n; end if;
end $$;

-- ---------------------------------------------------------------------------
-- Derived edges
-- ---------------------------------------------------------------------------

select public.rebuild_radio_dig_edges();

do $$
declare
    played record;
    neighbours int;
    label_edge record;
begin
    select * into played from public.music_relationships
    where relationship_type = 'played_by'
      and from_entity_type = 'artist'
      and from_entity_id = '00000000-0000-4000-8000-0000000000A1'::uuid;
    if played is null then raise exception 'no played_by edge for the known artist'; end if;
    if (played.metadata->>'episodes')::int <> 2 then
        raise exception 'expected 2 episodes of evidence, got %', played.metadata->>'episodes';
    end if;

    select count(*) into neighbours from public.music_relationships
    where relationship_type = 'radio_neighbor';
    if neighbours <> 1 then
        raise exception 'expected one canonical neighbour edge, got % (stored in both directions?)', neighbours;
    end if;

    -- The multiplication guard. The artist was played twice and has three
    -- releases on the label; a join straight to `releases` reports six.
    select * into label_edge from public.music_relationships
    where relationship_type = 'played_by' and from_entity_type = 'label';
    if label_edge is null then raise exception 'no label edge'; end if;
    if label_edge.evidence_count <> 2 then
        raise exception 'label edge multiplied by release count: expected 2 appearances, got %',
            label_edge.evidence_count;
    end if;
end $$;

-- Rebuilding is a function of the evidence, so twice must equal once.
select public.rebuild_radio_dig_edges();
do $$
declare n int;
begin
    -- Two artists played by the show, one neighbour pair, one label.
    select count(*) into n from public.music_relationships where source like 'radio%';
    if n <> 4 then raise exception 'rebuild is not idempotent: % edges', n; end if;
end $$;

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------

do $$
declare
    summary jsonb;
    rows int;
begin
    summary := public.artist_radio_summary('00000000-0000-4000-8000-0000000000A1'::uuid);
    if (summary->>'appearance_count')::int <> 2 then
        raise exception 'artist summary appearance_count = %', summary->>'appearance_count';
    end if;
    if (summary->>'show_count')::int <> 1 then
        raise exception 'artist summary show_count = %', summary->>'show_count';
    end if;
    if jsonb_array_length(summary->'top_shows') <> 1 then
        raise exception 'artist summary top_shows = %', summary->'top_shows';
    end if;

    select count(*) into rows from public.artist_radio_appearances(
        '00000000-0000-4000-8000-0000000000A1'::uuid, 50);
    if rows <> 2 then raise exception 'artist_radio_appearances returned %', rows; end if;

    select count(*) into rows from public.episode_tracklist(
        '00000000-0000-4000-8000-0000000000E1'::uuid);
    if rows <> 3 then raise exception 'episode_tracklist returned % (placeholder dropped?)', rows; end if;

    -- Both ends of an edge. The neighbour edge is stored once under the lower
    -- uuid, so an artist on the other end must still find it.
    select count(*) into rows from public.artist_radio_relations(
        '00000000-0000-4000-8000-0000000000A1'::uuid, 24);
    if rows < 2 then raise exception 'artist_radio_relations returned % for the low end', rows; end if;

    select count(*) into rows from public.artist_radio_relations(
        (select id from public.artists where normalized_name = 'sofia kourtesis'), 24);
    if rows < 2 then raise exception 'artist_radio_relations returned % for the high end', rows; end if;

    summary := public.label_radio_summary('00000000-0000-4000-8000-0000000000b1'::uuid);
    if (summary->>'appearance_count')::int <> 2 then
        raise exception 'label summary counted % appearances (multiplied?)', summary->>'appearance_count';
    end if;
    if summary->>'derivation' <> 'artist_roster' then
        raise exception 'label summary must say how it was derived';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- The queue
-- ---------------------------------------------------------------------------

do $$
declare
    first_id uuid;
    second_id uuid;
    claimed int;
    state text;
begin
    first_id := public.enqueue_enrichment_job(
        'nts', 'fetch_nts_episode', 'ben-ufo/three',
        jsonb_build_object('show', 'ben-ufo', 'episode', 'three'), 0, null, null);

    -- The same work asked for twice is one job, or a burst of clients becomes
    -- a burst of upstream requests.
    second_id := public.enqueue_enrichment_job(
        'nts', 'fetch_nts_episode', 'ben-ufo/three',
        jsonb_build_object('show', 'ben-ufo', 'episode', 'three'), 9, null, null);
    if first_id <> second_id then raise exception 'duplicate work was queued twice'; end if;

    -- Asking again is evidence it matters.
    if (select priority from public.enrichment_jobs where id = first_id) <> 9 then
        raise exception 'a repeated request did not raise the priority';
    end if;

    select count(*) into claimed from public.claim_enrichment_jobs(5);
    if claimed <> 1 then raise exception 'claimed % jobs, expected 1', claimed; end if;

    select status into state from public.enrichment_jobs where id = first_id;
    if state <> 'running' then raise exception 'claimed job is %', state; end if;

    -- A claimed job is not offered again.
    select count(*) into claimed from public.claim_enrichment_jobs(5);
    if claimed <> 0 then raise exception 'a running job was claimed again'; end if;

    perform public.complete_enrichment_job(first_id, false, 'upstream 503');
    select status into state from public.enrichment_jobs where id = first_id;
    if state <> 'pending' then raise exception 'a failed job should retry, got %', state; end if;
    if (select next_attempt_at from public.enrichment_jobs where id = first_id) <= now() then
        raise exception 'a failed job should back off before retrying';
    end if;

    perform public.complete_enrichment_job(first_id, true, null);
    select status into state from public.enrichment_jobs where id = first_id;
    if state <> 'done' then raise exception 'a succeeded job is %', state; end if;

    -- Done means the dedupe key is free again.
    if public.enqueue_enrichment_job(
        'nts', 'fetch_nts_episode', 'ben-ufo/three', null, 0, null, null) = first_id then
        raise exception 'finished work could not be requested again';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- The crawl cursor
-- ---------------------------------------------------------------------------

do $$
declare a int; b int;
begin
    a := public.advance_enrichment_cursor('nts.test', 12);
    b := public.advance_enrichment_cursor('nts.test', 12);
    if a <> 0 or b <> 12 then
        raise exception 'cursor handed out % then %, expected 0 then 12', a, b;
    end if;

    perform public.reset_enrichment_cursor('nts.test');
    if (select position from public.enrichment_cursors where name = 'nts.test') <> 0 then
        raise exception 'cursor did not reset';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

do $$
declare status jsonb;
begin
    status := public.enrichment_status();
    if (status->'radio'->>'appearances')::int <> 5 then
        raise exception 'status reported % appearances', status->'radio'->>'appearances';
    end if;
    if (status->'radio'->>'radio_edges')::int <> 4 then
        raise exception 'status reported % edges', status->'radio'->>'radio_edges';
    end if;
    if status->'extensions' is null then
        raise exception 'status should say which extensions are enabled';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Worker secrets
-- ---------------------------------------------------------------------------

do $$
declare complaint text;
begin
    -- The exact value that was accepted, stored, and then failed every five
    -- minutes for a month.
    complaint := public.worker_url_problem(
        'https://<project-ref>.supabase.co/functions/v1/enrichment-worker');
    if complaint is null then raise exception 'a placeholder URL was accepted'; end if;

    if public.worker_url_problem('') is null then raise exception 'an empty URL was accepted'; end if;
    if public.worker_url_problem('http://x.supabase.co/functions/v1/enrichment-worker') is null then
        raise exception 'a plaintext URL was accepted';
    end if;
    if public.worker_url_problem('https://example.supabase.co/rest/v1/rpc/whatever') is null then
        raise exception 'a URL that names no Edge Function was accepted';
    end if;

    -- And the real thing has to pass, or the guard is just an outage.
    if public.worker_url_problem(
        'https://example.supabase.co/functions/v1/enrichment-worker') is not null then
        raise exception 'a valid worker URL was refused: %',
            public.worker_url_problem('https://example.supabase.co/functions/v1/enrichment-worker');
    end if;

    if public.worker_key_problem('<publishable-anon-key>') is null then
        raise exception 'a placeholder key was accepted';
    end if;
    if public.worker_key_problem('sb_publishable_abc123') is not null then
        raise exception 'a real key was refused';
    end if;
end $$;

-- Refused where it is set, rather than reported as scheduled.
do $$
declare scheduled text;
begin
    begin
        scheduled := public.schedule_indigo_enrichment(
            'https://<project-ref>.supabase.co/functions/v1/enrichment-worker', 'key');
        raise exception 'scheduling accepted a placeholder URL';
    exception when others then
        if sqlerrm like '%scheduling accepted%' then raise; end if;
    end;
end $$;

-- And the status leads with the problem rather than burying it.
do $$
declare status jsonb;
begin
    perform public.set_indigo_secret(
        'indigo_worker_url', 'https://<project-ref>.supabase.co/functions/v1/enrichment-worker');
    status := public.enrichment_status();

    if (status->>'healthy')::boolean then
        raise exception 'status called a placeholder URL healthy';
    end if;
    if not (status->'problems')::text like '%placeholder%' then
        raise exception 'status did not name the problem: %', status->'problems';
    end if;
end $$;

rollback;

\echo 'radio smoke: all checks passed'

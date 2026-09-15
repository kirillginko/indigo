-- The records behind the tracklist.
--
-- Searching for a label is the slowest thing the app does, and the reason is
-- that there are almost no labels to find. Measured on the live project: 44,696
-- artists against 250 labels and 475 releases, every one of them a side effect
-- of somebody having opened a Discogs page. Thirty real imprints typed into
-- search -- Ilian Tape, Timedance, Livity Sound, Music From Memory -- and five
-- of them came back. The other twenty-five fall through to a Discogs round trip
-- that the listener waits on, every time, for ever, because nothing about
-- falling through writes anything down.
--
-- Radio already knows the answer and Indigo has been throwing it away. Every
-- line of an NTS tracklist arrives carrying `isrc_id`, `deezer_track_id` and
-- sometimes `musicbrainz_track_id` -- 43%, 33% and 9% of lines in a sample of
-- twenty episodes -- and the ingest kept the artist, the title and nothing
-- else. Those are exact identities for the record that was played, which is the
-- one thing name matching can never recover: two tracks called "Drift" are the
-- same string and different records, and no amount of normalizing tells them
-- apart.
--
-- So: keep the identities, and resolve them into the release and the imprint
-- they came from. MusicBrainz was the obvious place to resolve them and it
-- cannot -- thirty of these ISRCs looked up there returned nothing at all, and
-- took eight minutes to do it. Deezer answered all twenty-five it was asked and
-- named the label on twenty-three: Honest Jon's Records, Deep Medi Musik, Buh
-- Records, Quindi. Those are the imprints this app is for.
--
-- Nothing here fetches anything. It records what NTS already sent, queues the
-- lookups, and writes down what comes back; `deezer.ts` does the asking.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- What the tracklist already told us
-- ---------------------------------------------------------------------------

alter table public.radio_appearances
    add column if not exists isrc text,
    add column if not exists deezer_track_id text,
    add column if not exists musicbrainz_recording_id text,
    -- Distinguishes "not looked up yet" from "looked up and Deezer had no
    -- album for it", the same bargain `record_artist_portrait` makes. Without
    -- it a track Deezer cannot place comes back round on every pass for ever.
    add column if not exists release_checked_at timestamptz;

create index if not exists radio_appearances_isrc_idx
    on public.radio_appearances(isrc) where isrc is not null;

-- Exactly the shape the queue below reads: lines with an identity, not yet
-- asked about.
create index if not exists radio_appearances_pending_release_idx
    on public.radio_appearances(deezer_track_id)
    where deezer_track_id is not null and release_checked_at is null;

-- A recording can now be addressed the way the tracklist addresses it.
alter table public.recordings
    add column if not exists deezer_track_id text;

create index if not exists recordings_deezer_track_idx
    on public.recordings(deezer_track_id) where deezer_track_id is not null;

-- ---------------------------------------------------------------------------
-- Asking
-- ---------------------------------------------------------------------------

-- How long before a track Deezer could not place is asked about again.
create or replace function public.track_release_lifetime()
returns interval language sql immutable as $$ select interval '180 days' $$;

-- Queues release lookups for tracklist lines that carry a Deezer id.
--
-- Ordered by how recently the record was on air rather than by how often. This
-- is the queue that fills the search index, and what somebody types into search
-- is far more often something they heard last week than something a residency
-- has played nine times since 2019.
--
-- One job per Deezer track, not per appearance: the same record played on four
-- shows is one album to look up, and the write below points every appearance of
-- it at the recording it creates.
create or replace function public.enqueue_track_releases(p_limit int default 40)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_queued int := 0;
    v_limit int := greatest(1, least(coalesce(p_limit, 40), 200));
begin
    for v_row in
        select ra.deezer_track_id as track_id,
               max(re.aired_at) as last_aired
        from public.radio_appearances ra
        join public.radio_episodes re on re.id = ra.radio_episode_id
        where ra.deezer_track_id is not null
          -- Deliberately not narrowed to lines with no recording yet.
          -- `resolve_radio_appearances` can match a line to a recording by
          -- name, and a recording matched that way carries no release and no
          -- imprint -- which is the only thing this queue is for. The stamp
          -- below is what bounds the work: one lookup per track, not one per
          -- line and not one per pass.
          and (
              ra.release_checked_at is null
              or ra.release_checked_at < now() - public.track_release_lifetime()
          )
          and not exists (
              select 1 from public.enrichment_jobs j
              where j.provider = 'deezer'
                and j.job_type = 'fetch_track_release'
                and j.dedupe_key = ra.deezer_track_id
                and j.status in ('pending', 'running')
          )
        group by ra.deezer_track_id
        order by max(re.aired_at) desc nulls last
        limit v_limit
    loop
        perform public.enqueue_enrichment_job(
            'deezer',
            'fetch_track_release',
            v_row.track_id,
            jsonb_build_object('deezer_track_id', v_row.track_id),
            -- Above portraits, below the live crawl and origins. Nobody is
            -- waiting on any one of these, but the whole of search is waiting
            -- on the set of them.
            -1,
            null,
            null
        );
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.enqueue_track_releases(int) from public, anon, authenticated;
grant execute on function public.enqueue_track_releases(int) to service_role;

-- ---------------------------------------------------------------------------
-- Writing down what came back
-- ---------------------------------------------------------------------------

-- One resolved track: its label, its release, its recording, and every
-- appearance of it pointed at that recording.
--
-- A null album is a finding, not a failure -- it stamps `release_checked_at`
-- and stops there, which is what keeps the queue from re-asking for ever.
--
-- The artist is never looked up here. Whichever artist the appearances already
-- resolved to is the artist, because that resolution is Indigo's own and a
-- second one against Deezer's spelling would be free to disagree with it.
-- The two normalized keys are the caller's because the app's normalizer is the
-- one everything else in Indigo agrees with, and a second definition here would
-- be free to drift from it. Same bargain `search_catalog` makes in 0018; see
-- `_shared/normalize.ts`, pinned by NormalizationParityTests.
create or replace function public.record_track_release(
    p_deezer_track_id text,
    p_track_title text default null,
    p_title_key text default null,
    p_album_title text default null,
    p_deezer_album_id text default null,
    p_label text default null,
    p_label_key text default null,
    p_release_year int default null,
    p_isrc text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_track text := nullif(btrim(coalesce(p_deezer_track_id, '')), '');
    v_label_name text := nullif(btrim(coalesce(p_label, '')), '');
    v_label_key text := nullif(btrim(coalesce(p_label_key, '')), '');
    v_album text := nullif(btrim(coalesce(p_album_title, '')), '');
    v_album_id text := nullif(btrim(coalesce(p_deezer_album_id, '')), '');
    v_title text := nullif(btrim(coalesce(p_track_title, '')), '');
    v_artist uuid;
    v_label uuid;
    v_release uuid;
    v_recording uuid;
begin
    if v_track is null then
        raise exception 'record_track_release needs a deezer track id';
    end if;

    update public.radio_appearances
    set release_checked_at = now()
    where deezer_track_id = v_track;

    -- Nothing to file. The stamp above is the whole point of the call.
    if v_album is null and v_label_name is null then
        return null;
    end if;

    -- The artist these appearances already belong to, where they agree. Two
    -- different artists sharing a Deezer track id is not a thing Deezer does,
    -- but a tracklist line resolved to the wrong person is, and the release
    -- would inherit that. Ambiguity leaves the release uncredited instead.
    select (array_agg(distinct ra.artist_id))[1] into v_artist
    from public.radio_appearances ra
    where ra.deezer_track_id = v_track and ra.artist_id is not null
    having count(distinct ra.artist_id) = 1;

    -- MARK: the imprint
    --
    -- Deezer names a label rather than identifying one, so the normalized name
    -- is the identity -- exactly as `adopt_radio_artists` treats a name NTS
    -- has no id for. The external_ids row is written second and is unique, so
    -- it decides who won a race rather than the label row itself.
    if v_label_name is not null and v_label_key is not null then
        select entity_id into v_label
        from public.external_ids
        where provider = 'deezer' and entity_type = 'label' and external_id = v_label_key;

        -- An imprint Discogs already filed under this name. Adopting it rather
        -- than inserting beside it is what stops search offering the listener
        -- the same label twice, once with a Discogs page behind it and once
        -- without.
        if v_label is null then
            select id into v_label
            from public.labels where normalized_name = v_label_key limit 1;
        end if;

        if v_label is null then
            insert into public.labels (name, normalized_name)
            values (v_label_name, v_label_key)
            returning id into v_label;

            begin
                insert into public.external_ids
                    (entity_type, entity_id, provider, external_id)
                values ('label', v_label, 'deezer', v_label_key);
            exception when unique_violation then
                delete from public.labels where id = v_label;
                select entity_id into v_label
                from public.external_ids
                where provider = 'deezer' and entity_type = 'label'
                  and external_id = v_label_key;
            end;
        end if;
    end if;

    -- MARK: the release
    if v_album is not null then
        if v_album_id is not null then
            select entity_id into v_release
            from public.external_ids
            where provider = 'deezer' and entity_type = 'release' and external_id = v_album_id;
        end if;

        if v_release is null then
            insert into public.releases (title, artist_id, label_id, release_year)
            values (v_album, v_artist, v_label, p_release_year)
            returning id into v_release;

            if v_album_id is not null then
                begin
                    insert into public.external_ids
                        (entity_type, entity_id, provider, external_id, source_url)
                    values ('release', v_release, 'deezer', v_album_id,
                            'https://www.deezer.com/album/' || v_album_id);
                exception when unique_violation then
                    delete from public.releases where id = v_release;
                    select entity_id into v_release
                    from public.external_ids
                    where provider = 'deezer' and entity_type = 'release'
                      and external_id = v_album_id;
                end;
            end if;
        else
            -- A release filed from another track on the same album. Fill in
            -- what that call could not answer rather than overwrite it: a
            -- compilation's first track should not make the whole album its
            -- artist's, so the credit is only ever added where there is none.
            update public.releases
            set label_id = coalesce(label_id, v_label),
                artist_id = coalesce(artist_id, v_artist),
                release_year = coalesce(release_year, p_release_year)
            where id = v_release;
        end if;
    end if;

    -- MARK: the recording
    select entity_id into v_recording
    from public.external_ids
    where provider = 'deezer' and entity_type = 'recording' and external_id = v_track;

    if v_recording is null and v_title is not null then
        insert into public.recordings
            (title, normalized_title, artist_id, release_id, isrc, deezer_track_id)
        values (v_title, nullif(btrim(coalesce(p_title_key, '')), ''), v_artist, v_release,
                nullif(btrim(coalesce(p_isrc, '')), ''), v_track)
        returning id into v_recording;

        begin
            insert into public.external_ids
                (entity_type, entity_id, provider, external_id, source_url)
            values ('recording', v_recording, 'deezer', v_track,
                    'https://www.deezer.com/track/' || v_track);
        exception when unique_violation then
            delete from public.recordings where id = v_recording;
            select entity_id into v_recording
            from public.external_ids
            where provider = 'deezer' and entity_type = 'recording' and external_id = v_track;
        end;
    elsif v_recording is not null then
        update public.recordings
        set release_id = coalesce(release_id, v_release),
            artist_id = coalesce(artist_id, v_artist)
        where id = v_recording;
    end if;

    -- Every appearance of this record, on every show, now points at it.
    if v_recording is not null then
        update public.radio_appearances
        set recording_id = v_recording,
            identification_source = coalesce(identification_source, 'deezer_track'),
            confidence = greatest(coalesce(confidence, 0), 0.9)
        where deezer_track_id = v_track and recording_id is null;
    end if;

    return v_recording;
end $$;

revoke all on function
    public.record_track_release(text, text, text, text, text, text, text, int, text)
    from public, anon, authenticated;
grant execute on function
    public.record_track_release(text, text, text, text, text, text, text, int, text)
    to service_role;

-- ---------------------------------------------------------------------------
-- Going back for what was already ingested
-- ---------------------------------------------------------------------------

-- The identities above are only on rows written after this migration. The
-- 74,548 appearances already in the table were ingested by a version of
-- `nts.ts` that dropped them, and re-reading an episode is the only way to get
-- them -- NTS sends them with the tracklist and nowhere else.
--
-- Oldest-touched first, so the pass walks the archive once rather than circling
-- the same episodes. The dedupe key is the one `fetch_nts_episode` already
-- uses, so an episode the live crawl is about to read anyway is not read twice.
create or replace function public.requeue_nts_episodes(p_limit int default 20)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_queued int := 0;
    v_limit int := greatest(1, least(coalesce(p_limit, 20), 200));
begin
    for v_row in
        select re.id, re.external_id
        from public.radio_episodes re
        where re.provider = 'nts'
          and re.tracklist_status = 'available'
          and exists (
              select 1 from public.radio_appearances ra
              where ra.radio_episode_id = re.id
          )
          -- Nothing in it carries an identity, so it predates this migration.
          and not exists (
              select 1 from public.radio_appearances ra
              where ra.radio_episode_id = re.id
                and (ra.deezer_track_id is not null or ra.isrc is not null)
          )
          and not exists (
              select 1 from public.enrichment_jobs j
              where j.provider = 'nts'
                and j.job_type = 'fetch_nts_episode'
                and j.dedupe_key = re.external_id
                and j.status in ('pending', 'running')
          )
        order by re.updated_at
        limit v_limit
    loop
        -- `external_id` is "show/episode", which is both the dedupe key the
        -- crawl uses and the two halves the worker needs.
        if position('/' in v_row.external_id) = 0 then continue; end if;

        perform public.enqueue_enrichment_job(
            'nts',
            'fetch_nts_episode',
            v_row.external_id,
            jsonb_build_object(
                'show', split_part(v_row.external_id, '/', 1),
                'episode', split_part(v_row.external_id, '/', 2)),
            -- Below the fresh crawl at 5 and below a residency's back
            -- catalogue at 0. This is history; what went out this morning is
            -- worth having first.
            -1,
            null,
            null
        );
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.requeue_nts_episodes(int) from public, anon, authenticated;
grant execute on function public.requeue_nts_episodes(int) to service_role;

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

create or replace function public.schedule_track_releases()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    -- Forty every five minutes against a lane that drains thirty. The queue
    -- runs a little ahead of the drain on purpose: the dedupe index means a
    -- track already waiting is never queued twice, so the surplus costs
    -- nothing and the lane never finds itself idle with work outstanding.
    perform cron.schedule(
        'indigo-track-releases',
        '*/5 * * * *',
        $job$select public.enqueue_track_releases(40)$job$);
    scheduled := array_append(scheduled, 'indigo-track-releases');

    -- Twenty episodes every quarter hour is eighty an hour against an archive
    -- of about four thousand, so the backfill is done in a little over two
    -- days and then finds nothing, which costs one query.
    perform cron.schedule(
        'indigo-requeue-episodes',
        '*/15 * * * *',
        $job$select public.requeue_nts_episodes(20)$job$);
    scheduled := array_append(scheduled, 'indigo-requeue-episodes');

    -- Its own lane, for the same reason portraits got one in 0024: these are
    -- two quick requests to a service with no per-minute ceiling worth
    -- speaking of, and queued at -1 they would sit behind the NTS crawl for
    -- ever. Four minutes past, so it starts on top of neither the main drain
    -- nor the portrait lane two minutes before it.
    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-drain-releases',
            '4-59/5 * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 30, 'job_type', 'fetch_track_release')
            )$job$);
        scheduled := array_append(scheduled, 'indigo-drain-releases');
    end if;

    return array_to_string(scheduled, ', ');
end $$;

-- Added to the umbrella, so a project set up from scratch gets the lane along
-- with everything else. Carries 0019's composition forward unchanged.
create or replace function public.schedule_scene_rosters()
returns text
language plpgsql
as $$
declare
    scheduled text[] := '{}';
begin
    if not public.has_function('cron', 'schedule') then
        raise exception 'pg_cron is not installed; enable it before scheduling';
    end if;

    perform cron.schedule(
        'indigo-resume-scenes',
        '*/10 * * * *',
        $job$select public.resume_scene_rosters(4)$job$);
    scheduled := array_append(scheduled, 'indigo-resume-scenes');

    perform cron.schedule(
        'indigo-seed-scenes',
        '41 3 * * *',
        $job$select public.seed_scene_rosters()$job$);
    scheduled := array_append(scheduled, 'indigo-seed-scenes');

    scheduled := array_append(scheduled, public.schedule_nts_retag());
    scheduled := array_append(scheduled, public.schedule_scene_radio_fill());
    scheduled := array_append(scheduled, public.schedule_artist_origins());
    scheduled := array_append(scheduled, public.schedule_artist_portraits());
    scheduled := array_append(scheduled, public.schedule_track_releases());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;

-- A project whose drain is already running gets the lane now, exactly as 0024
-- handed one to portraits.
do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_track_releases();
    end if;
end $$;

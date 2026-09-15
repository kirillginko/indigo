-- One artist, filed twice.
--
-- Opening The Beatles created a second Beatles. Measured on the live project:
-- `the beatles` names two artist rows -- one adopted from radio on 4 September
-- carrying 23 appearances, a country and every graph edge, and one created at
-- 17:49 UTC on 14 September carrying Discogs id 82730 and nothing else. The
-- second was written by the page open itself.
--
-- `resolveEntity` in `_shared/discogs.ts` looks an artist up by
-- `external_ids(provider, entity_type, external_id)` and inserts when it finds
-- nothing. That is right for the question it asks -- two artists can share a
-- name, so a name is not an identity -- but `adopt_radio_artists` files an
-- artist under the *name* precisely because NTS gives no id. The two never
-- meet, so every artist radio knows and Discogs also knows ends up as two rows.
--
-- What it costs, measured:
--
--   * 85 names split this way, against 49 that are genuine Discogs namesakes
--     -- Disorder (2), Disorder (3) -- which must never be merged.
--   * 332 radio appearances sitting on the half with no Discogs id, so the
--     half a search returns has no radio history and the half with the history
--     has no portrait and no page.
--   * 174 appearances that can no longer resolve at all:
--     `resolve_radio_appearances` only ever matches a name held by exactly one
--     artist, which is the right refusal and is now triggered by our own
--     duplicate rather than by real ambiguity.
--   * 7 of the Discogs halves created on one day, one per artist page opened.
--
-- Two halves to the fix. This migration joins the rows that are already split;
-- `resolveEntity` stops making new ones.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- Which rows are two halves of one artist
-- ---------------------------------------------------------------------------

-- Deliberately narrow, and the narrowness is the whole point.
--
-- A name qualifies only when it holds exactly two rows: one whose sole identity
-- is the NTS name-key -- which means "somebody called this, and nothing else is
-- known" -- and one carrying a Discogs id. Anything else is left alone.
--
-- In particular a name held by two Discogs ids is two artists, and Discogs says
-- so by numbering them. Merging those would do what `adopt_radio_artists`
-- refuses to do: put one band's records on another band's page with nothing on
-- screen to say it had happened.
create or replace view public.split_artist_halves as
with keyed as (
    select
        a.id,
        a.normalized_name,
        count(*) filter (where x.provider = 'nts') as nts_keys,
        count(*) filter (where x.provider = 'discogs') as discogs_keys,
        count(x.id) as any_keys
    from public.artists a
    left join public.external_ids x
        on x.entity_type = 'artist' and x.entity_id = a.id
    where coalesce(a.normalized_name, '') <> ''
    group by a.id, a.normalized_name
),
grouped as (
    select
        normalized_name,
        count(*) as rows_for_name,
        count(*) filter (where nts_keys > 0 and discogs_keys = 0) as name_only,
        count(*) filter (where discogs_keys > 0) as discogs_rows,
        count(*) filter (where any_keys = 0) as unkeyed,
        (array_agg(id) filter (where nts_keys > 0 and discogs_keys = 0))[1] as keep_id,
        (array_agg(id) filter (where discogs_keys > 0))[1] as merge_id
    from keyed
    group by normalized_name
)
select normalized_name, keep_id, merge_id
from grouped
where rows_for_name = 2
  and name_only = 1
  and discogs_rows = 1
  and unkeyed = 0
  and keep_id is not null
  and merge_id is not null;

grant select on public.split_artist_halves to service_role;

-- ---------------------------------------------------------------------------
-- Joining them
-- ---------------------------------------------------------------------------

-- The radio-adopted row survives.
--
-- It holds the appearances, the origin MusicBrainz found, and every edge
-- `rebuild_radio_dig_edges` derived -- hundreds of rows against the Discogs
-- half's one external id. Moving the id onto it is a single update; moving the
-- history the other way is the same merge done the expensive way round.
create or replace function public.merge_artist_halves(p_keep uuid, p_merge uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if p_keep is null or p_merge is null or p_keep = p_merge then
        return;
    end if;

    -- Identities. The pair is one nts key and one discogs key by construction,
    -- so nothing collides on (provider, entity_type, external_id) -- but a
    -- re-run might, and the survivor's own row is the one to keep.
    update public.external_ids x
    set entity_id = p_keep
    where x.entity_type = 'artist' and x.entity_id = p_merge
      and not exists (
          select 1 from public.external_ids other
          where other.entity_type = 'artist'
            and other.entity_id = p_keep
            and other.provider = x.provider
      );
    delete from public.external_ids
    where entity_type = 'artist' and entity_id = p_merge;

    -- Everything filed against the losing row.
    update public.releases   set artist_id = p_keep where artist_id = p_merge;
    update public.recordings set artist_id = p_keep where artist_id = p_merge;
    update public.radio_appearances set artist_id = p_keep where artist_id = p_merge;

    -- Artwork is unique per entity, so the survivor keeps what it has and
    -- inherits only where it has nothing.
    update public.artwork w
    set entity_id = p_keep
    where w.entity_type = 'artist' and w.entity_id = p_merge
      and not exists (
          select 1 from public.artwork other
          where other.entity_type = 'artist' and other.entity_id = p_keep
      );
    delete from public.artwork where entity_type = 'artist' and entity_id = p_merge;

    -- Edges, both ends. An edge that would now point the survivor at itself is
    -- dropped rather than moved: "played beside themselves" is not a fact.
    delete from public.music_relationships
    where (from_entity_type = 'artist' and from_entity_id = p_merge
           and to_entity_type = 'artist' and to_entity_id = p_keep)
       or (from_entity_type = 'artist' and from_entity_id = p_keep
           and to_entity_type = 'artist' and to_entity_id = p_merge);

    -- Re-pointed one end at a time, and only where the survivor has no such
    -- edge already. Where it has one, the evidence is added to it instead --
    -- the same record seen from both halves is one edge that has been seen
    -- twice, not two edges.
    update public.music_relationships mr
    set from_entity_id = p_keep
    where mr.from_entity_type = 'artist' and mr.from_entity_id = p_merge
      and not exists (
          select 1 from public.music_relationships other
          where other.from_entity_type = 'artist' and other.from_entity_id = p_keep
            and other.to_entity_type = mr.to_entity_type
            and other.to_entity_id = mr.to_entity_id
            and other.relationship_type = mr.relationship_type
      );

    update public.music_relationships keep
    set evidence_count = keep.evidence_count + loser.evidence_count
    from public.music_relationships loser
    where loser.from_entity_type = 'artist' and loser.from_entity_id = p_merge
      and keep.from_entity_type = 'artist' and keep.from_entity_id = p_keep
      and keep.to_entity_type = loser.to_entity_type
      and keep.to_entity_id = loser.to_entity_id
      and keep.relationship_type = loser.relationship_type;

    delete from public.music_relationships
    where from_entity_type = 'artist' and from_entity_id = p_merge;

    update public.music_relationships mr
    set to_entity_id = p_keep
    where mr.to_entity_type = 'artist' and mr.to_entity_id = p_merge
      and not exists (
          select 1 from public.music_relationships other
          where other.to_entity_type = 'artist' and other.to_entity_id = p_keep
            and other.from_entity_type = mr.from_entity_type
            and other.from_entity_id = mr.from_entity_id
            and other.relationship_type = mr.relationship_type
      );

    update public.music_relationships keep
    set evidence_count = keep.evidence_count + loser.evidence_count
    from public.music_relationships loser
    where loser.to_entity_type = 'artist' and loser.to_entity_id = p_merge
      and keep.to_entity_type = 'artist' and keep.to_entity_id = p_keep
      and keep.from_entity_type = loser.from_entity_type
      and keep.from_entity_id = loser.from_entity_id
      and keep.relationship_type = loser.relationship_type;

    delete from public.music_relationships
    where to_entity_type = 'artist' and to_entity_id = p_merge;

    -- What the losing row knew that the survivor does not. Never the other way
    -- round: the survivor's own answers were found for the artist that has the
    -- radio history, which is the one this row now is.
    update public.artists keep
    set country = coalesce(keep.country, loser.country),
        area = coalesce(keep.area, loser.area),
        area_key = coalesce(keep.area_key, loser.area_key),
        began_year = coalesce(keep.began_year, loser.began_year),
        musicbrainz_id = coalesce(keep.musicbrainz_id, loser.musicbrainz_id),
        origin_checked_at = greatest(keep.origin_checked_at, loser.origin_checked_at),
        shelf_cached_at = least(keep.shelf_cached_at, loser.shelf_cached_at)
    from public.artists loser
    where keep.id = p_keep and loser.id = p_merge;

    delete from public.artists where id = p_merge;
end $$;

revoke all on function public.merge_artist_halves(uuid, uuid) from public, anon, authenticated;
grant execute on function public.merge_artist_halves(uuid, uuid) to service_role;

-- Joins every pair the view names. Bounded so it can be run from cron without
-- ever being a long transaction, and re-running simply finds fewer.
create or replace function public.merge_split_artists(p_limit int default 50)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_row record;
    v_merged int := 0;
begin
    for v_row in
        select keep_id, merge_id from public.split_artist_halves
        limit greatest(1, least(coalesce(p_limit, 50), 500))
    loop
        perform public.merge_artist_halves(v_row.keep_id, v_row.merge_id);
        v_merged := v_merged + 1;
    end loop;

    -- Names that were only ambiguous because of the duplicate can resolve now.
    if v_merged > 0 then
        perform public.resolve_radio_appearances(null);
    end if;

    return v_merged;
end $$;

revoke all on function public.merge_split_artists(int) from public, anon, authenticated;
grant execute on function public.merge_split_artists(int) to service_role;

-- ---------------------------------------------------------------------------
-- Joining the ones already split
-- ---------------------------------------------------------------------------

do $$
declare
    v_merged int;
begin
    v_merged := public.merge_split_artists(500);
    if v_merged > 0 then
        raise notice 'merged % artists that were filed twice', v_merged;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

-- `resolveEntity` stops making these, but an app in somebody's hands is a
-- version behind for as long as they leave it there. A nightly pass costs one
-- query against a view and, once the deployed function has caught up, finds
-- nothing.
create or replace function public.schedule_artist_merge()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    perform cron.schedule(
        'indigo-merge-split-artists',
        '23 4 * * *',
        $job$select public.merge_split_artists(200)$job$);

    return 'indigo-merge-split-artists';
end $$;

-- Added to the umbrella, carrying 0027's composition forward unchanged.
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
    scheduled := array_append(scheduled, public.schedule_nts_hosts());
    scheduled := array_append(scheduled, public.schedule_release_cache());
    scheduled := array_append(scheduled, public.schedule_artist_merge());

    perform public.seed_scene_rosters();
    perform public.fill_scenes_from_radio(60);

    return array_to_string(scheduled, ', ');
end $$;

do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'indigo-drain-queue') then
        perform public.schedule_artist_merge();
    end if;
end $$;

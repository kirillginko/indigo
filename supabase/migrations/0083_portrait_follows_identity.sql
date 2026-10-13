-- 0083: a portrait is looked at again when the artist's identity changes
-- (DIG-REMEDIATION-PLAN.md §9). Approved with the portrait remediation,
-- 2026-10-13.
--
-- A portrait is chosen once, by whatever the row knew at the time. Six rows
-- gained a Discogs identity after the October 12 audit and went on showing a
-- namesake's face (Hype Williams the duo, with the film director's), because
-- nothing ever asked again. Now the identity itself says when to ask: a
-- Discogs id added to an artist, moved between rows, or taken off one queues
-- that artist's portrait job -- once, through the queue's own dedupe -- unless
-- the portrait it has is already verified for an id the row still holds.
--
-- Event-driven: nothing is looked up on a page visit, and an artist whose
-- identity never changes is never asked again. A row with no portrait yet is
-- left to the ordinary lane, which asks by identity already.

create or replace function public.portrait_needs_another_look(p_artist uuid)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
    -- An artist being deleted takes its ids with it; nothing to look at.
    select exists (select 1 from public.artists a where a.id = p_artist) and exists (
        select 1 from public.artwork w
        where w.entity_type = 'artist' and w.entity_id = p_artist
          -- Coalesced: an old-rule portrait has no state, and `not null` is
          -- null, which would skip exactly the rows this is for.
          and not coalesce(
              w.portrait_state = 'verified'
              and w.portrait_discogs_id in (
                  select e.external_id::bigint from public.external_ids e
                  where e.entity_type = 'artist' and e.entity_id = p_artist
                    and e.provider in ('discogs', 'musicbrainz_discogs')
                    and e.external_id ~ '^[0-9]+$'), false)
    );
$$;

create or replace function public.queue_portrait_after_identity_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    artist uuid;
begin
    foreach artist in array array_remove(array[
        case when tg_op <> 'DELETE' and new.entity_type = 'artist'
                  and new.provider in ('discogs', 'musicbrainz_discogs') then new.entity_id end,
        case when tg_op <> 'INSERT' and old.entity_type = 'artist'
                  and old.provider in ('discogs', 'musicbrainz_discogs') then old.entity_id end
    ], null)
    loop
        if public.portrait_needs_another_look(artist) then
            perform public.enqueue_enrichment_job(
                'discogs', 'fetch_artist_portrait', artist::text,
                jsonb_build_object('artist_id', artist,
                                   'name', (select a.name from public.artists a where a.id = artist),
                                   'reason', 'identity changed'),
                5, null, null);
        end if;
    end loop;
    return null;
end $$;

drop trigger if exists external_ids_portrait_follows_identity on public.external_ids;
create trigger external_ids_portrait_follows_identity
    after insert or delete or update of entity_id, external_id, provider, entity_type on public.external_ids
    for each row execute function public.queue_portrait_after_identity_change();

revoke all on function public.portrait_needs_another_look(uuid) from public, anon, authenticated;
revoke all on function public.queue_portrait_after_identity_change() from public, anon, authenticated;

-- MARK: - Telling devices

-- A device keeps the portraits it has seen, and asks the catalogue about a
-- name only when it has none. So a face the catalogue later withholds or
-- replaces stays on every device that cached it. The portrait says when its
-- answer last changed -- its address or its state, not merely that it was
-- fetched again, which happens thousands of times a day to no effect -- and a
-- device asks once per launch which names changed since it last asked, and
-- re-reads only those of them it holds.

alter table public.artwork add column if not exists portrait_changed_at timestamptz;
create index if not exists artwork_portrait_changed_idx on public.artwork (portrait_changed_at)
    where entity_type = 'artist' and portrait_changed_at is not null;

create or replace function public.record_artist_portrait(
    p_artist_id uuid,
    p_url text default null,
    p_width integer default null,
    p_height integer default null,
    p_state text default null,
    p_discogs_id bigint default null
)
returns void
language sql
security definer
set search_path = public
as $function$
    insert into public.artwork (
        entity_type, entity_id, provider, original_url, width, height, fetched_at,
        portrait_state, portrait_discogs_id, portrait_changed_at
    )
    values (
        'artist', p_artist_id, 'discogs',
        -- A withheld portrait is never an address, whatever was passed.
        case when p_state = 'withheld' then null else nullif(btrim(coalesce(p_url, '')), '') end,
        p_width, p_height, now(), p_state, p_discogs_id, now()
    )
    on conflict (entity_type, entity_id) do update
        set provider = excluded.provider,
            original_url = excluded.original_url,
            width = excluded.width,
            height = excluded.height,
            fetched_at = excluded.fetched_at,
            portrait_state = excluded.portrait_state,
            portrait_discogs_id = excluded.portrait_discogs_id,
            portrait_changed_at = case
                when artwork.original_url is distinct from excluded.original_url
                  or artwork.portrait_state is distinct from excluded.portrait_state
                then excluded.portrait_changed_at else artwork.portrait_changed_at end;
$function$;

revoke all on function public.record_artist_portrait(uuid, text, integer, integer, text, bigint) from public, anon, authenticated;
grant execute on function public.record_artist_portrait(uuid, text, integer, integer, text, bigint) to service_role;

-- The names whose portrait answer changed after `p_since`, oldest first, at
-- most `p_limit`; `until` is where the next ask starts. A device sends no
-- names: it intersects the answer with what it holds.
create or replace function public.portrait_changes_since(p_since timestamptz, p_limit integer default 2000)
returns jsonb
language sql
stable
set search_path = public
as $function$
    with changed as (
        select a.normalized_name as name, w.portrait_changed_at as at
        from public.artwork w join public.artists a on a.id = w.entity_id
        where w.entity_type = 'artist' and w.portrait_changed_at > p_since
        order by w.portrait_changed_at
        limit least(greatest(coalesce(p_limit, 2000), 1), 5000)
    )
    select jsonb_build_object(
        'names', coalesce((select jsonb_agg(distinct name) from changed), '[]'::jsonb),
        'until', coalesce((select max(at) from changed), p_since),
        'more', (select count(*) from changed) >= least(greatest(coalesce(p_limit, 2000), 1), 5000));
$function$;

create or replace function public.app_callable_functions()
returns text[]
language sql
immutable
as $function$
    select array[
        'app_callable_functions',
        'artist_radio_appearances',
        'artist_radio_relations',
        'artist_radio_summary',
        'credit_row_count',
        'dig_radio_for_artists',
        'enrichment_queue_health',
        'episode_tracklist',
        'explore_knowledge',
        'label_radio_summary',
        'portrait_changes_since',
        'portrait_states_for_artists',
        'portraits_for_artists',
        'release_cache_coverage',
        'request_artist_shelf',
        'request_release_cache',
        'request_scene_roster',
        'search_archives',
        'search_catalog'
    ]
$function$;

grant execute on function public.portrait_changes_since(timestamptz, integer) to anon, authenticated, service_role;

-- 0081: a portrait says how it was chosen (DIG-REMEDIATION-PLAN.md §9).
-- Approved 2026-10-13.
--
-- Every artist portrait used to come from one rule: a Discogs search by name,
-- first match. 121 rows showed another artist's face, and 962 more a namesake
-- chosen by search order. The worker now chooses by identity (0081's
-- companion change in discogs.ts); this records what it chose:
--
--   portrait_state       'verified'   -- the row's own Discogs artist (its id,
--                                        or one MusicBrainz recorded for it)
--                        'unresolved' -- no identity; the only Discogs artist
--                                        with the name. Shown, never promoted
--                                        to an identity.
--                        'withheld'   -- no identity and several namesakes:
--                                        no portrait rather than a stranger's
--                        null         -- written before this, by the old rule
--   portrait_discogs_id  the Discogs artist the picture belongs to, when known
--
-- Nullable columns with no default: a catalog change, no rewrite. Only rows
-- the new rule writes carry values.

alter table public.artwork
    add column if not exists portrait_state text,
    add column if not exists portrait_discogs_id bigint;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'artwork_portrait_state_check') then
        alter table public.artwork add constraint artwork_portrait_state_check
            check (portrait_state is null or portrait_state in ('verified', 'unresolved', 'withheld'));
    end if;
end $$;

-- The recorder takes the state and the pictured artist. The old four-argument
-- form is replaced; a worker still calling it by name (p_artist_id, p_url,
-- p_width, p_height) keeps working through the defaults, and writes a state of
-- null, as before.
drop function if exists public.record_artist_portrait(uuid, text, integer, integer);

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
        portrait_state, portrait_discogs_id
    )
    values (
        'artist', p_artist_id, 'discogs',
        -- A withheld portrait is never an address, whatever was passed.
        case when p_state = 'withheld' then null else nullif(btrim(coalesce(p_url, '')), '') end,
        p_width, p_height, now(), p_state, p_discogs_id
    )
    on conflict (entity_type, entity_id) do update
        set provider = excluded.provider,
            original_url = excluded.original_url,
            width = excluded.width,
            height = excluded.height,
            fetched_at = excluded.fetched_at,
            portrait_state = excluded.portrait_state,
            portrait_discogs_id = excluded.portrait_discogs_id;
$function$;

revoke all on function public.record_artist_portrait(uuid, text, integer, integer, text, bigint) from public, anon, authenticated;
grant execute on function public.record_artist_portrait(uuid, text, integer, integer, text, bigint) to service_role;

-- Portraits by name, with their state. A name the catalogue files under more
-- than one row whose portraits disagree is a namesake question no name can
-- answer: it comes back withheld, with no address. So does a name whose only
-- answer was withheld.
create or replace function public.portrait_states_for_artists(p_names text[])
returns jsonb
language sql
stable
set search_path = public
as $function$
    with named as (
        select a.normalized_name as name, w.original_url as url,
               coalesce(w.portrait_state, 'unresolved') as state, w.portrait_discogs_id as pictured
        from public.artists a
        join public.artwork w on w.entity_type = 'artist' and w.entity_id = a.id
        where a.normalized_name = any(p_names)
          and (w.original_url is not null or w.portrait_state = 'withheld')
    ),
    per_name as (
        select name,
               count(distinct url) filter (where url is not null) as addresses,
               bool_or(state = 'withheld') as any_withheld,
               bool_or(state = 'verified') as any_verified,
               (array_agg(url order by (state = 'verified') desc, url) filter (where url is not null))[1] as url,
               (array_agg(state order by (state = 'verified') desc, url) filter (where url is not null))[1] as state,
               (array_agg(pictured order by (state = 'verified') desc, url) filter (where url is not null))[1] as pictured
        from named group by name
    )
    select coalesce(jsonb_object_agg(name,
        case when addresses > 1 or addresses = 0 or (any_withheld and not any_verified)
             then jsonb_build_object('state', 'withheld')
             else jsonb_strip_nulls(jsonb_build_object('url', url, 'state', state, 'discogsID', pictured)) end), '{}'::jsonb)
    from per_name;
$function$;

-- The name-only reader installed builds use keeps its shape, and stops
-- answering a name whose rows disagree, or whose portrait was withheld.
create or replace function public.portraits_for_artists(p_names text[])
returns jsonb
language sql
stable
as $function$
    select coalesce(jsonb_object_agg(name, value->>'url'), '{}'::jsonb)
    from jsonb_each(public.portrait_states_for_artists(p_names)) as e(name, value)
    where value ? 'url';
$function$;

-- The app may call it: on the one list (see 0023), and granted by name.
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

grant execute on function public.portrait_states_for_artists(text[]) to anon, authenticated, service_role;

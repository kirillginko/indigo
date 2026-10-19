-- A relabel that settles.
--
-- 0032's `relabel_credited_artists` names an artist after the primary credit's
-- own spelling. But it filters out the current name *before* choosing:
--
--     where ... and a.name is distinct from ra.credited_artist_names[1]
--     order by a.id, ra.created_at
--
-- which means "the earliest spelling that is not the one we have". An artist
-- whose lines spell them two ways ("Jam City" / "JAM CITY") is renamed to the
-- other spelling on every run, and back again on the next. On 2026-10-18 that
-- was 262 of 9,192 credited artists, every one of them rewritten every 15
-- minutes: about 25k rewrites a day, each changing a name DIG and
-- explore_knowledge show.
--
-- The name is now chosen first and compared second. The spelling chosen is the
-- one the lines use most; on a tie the earliest seen, then the lowest by byte
-- order, so the choice never depends on plan order. Once it is set, later runs
-- find nothing to do. The name changes again only when new appearances change
-- the counts.
--
-- No backfill here: the cron job's next run settles the 262.
--
-- Safe to re-run.

create or replace function public.relabel_credited_artists(p_limit int default 500)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_renamed int;
begin
    with spellings as (
        select a.id, a.name, ra.credited_artist_names[1] as proper,
               count(*) as uses, min(ra.created_at) as first_seen
        from public.artists a
        join public.radio_appearances ra
            on ra.normalized_artist_name = a.normalized_name
        where ra.credited_artist_keys is not null
          and array_length(ra.credited_artist_keys, 1) > 1
          and a.normalized_name = ra.credited_artist_keys[1]
          and coalesce(ra.credited_artist_names[1], '') <> ''
        group by a.id, a.name, ra.credited_artist_names[1]
    ), chosen as (
        select distinct on (id) id, name, proper
        from spellings
        order by id, uses desc, first_seen, proper collate "C"
    ), wanted as (
        -- Compared after the choice, never before it.
        select id, proper
        from chosen
        where name is distinct from proper
        order by id
        limit greatest(1, least(coalesce(p_limit, 500), 5000))
    )
    update public.artists a
    set name = wanted.proper
    from wanted
    where a.id = wanted.id;

    get diagnostics v_renamed = row_count;
    return v_renamed;
end $$;

revoke all on function public.relabel_credited_artists(int) from public, anon, authenticated;
grant execute on function public.relabel_credited_artists(int) to service_role;

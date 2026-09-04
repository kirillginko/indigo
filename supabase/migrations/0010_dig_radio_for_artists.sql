-- What radio has to say about the artists this listener actually keeps.
--
-- Everything radio-derived so far answers a question about one entity you are
-- already looking at. The way into DIG is a list of artists and nothing else,
-- so the graph has had no way to reach the one page where somebody is deciding
-- what to dig into next.
--
-- This takes the names the listener's crate and library produce and answers two
-- things: where those artists have turned up on air lately, and who gets played
-- beside them that they do not already have. The second is the recommendation —
-- and it excludes what they have, because telling somebody about a record they
-- own is not a discovery.
--
-- Safe to re-run.

create or replace function public.dig_radio_for_artists(
    p_names text[],
    p_limit int default 8
)
returns jsonb
language sql
stable
as $$
with bounded as (
    select greatest(1, least(coalesce(p_limit, 8), 50)) as n
),
-- Matched on the normalized name the app already sends everywhere else, so
-- "DJ  Koze!!!" and "dj koze" are the same artist here as they are anywhere.
mine as (
    select a.id, a.name
    from public.artists a
    where a.normalized_name = any(p_names)
),
-- One row per artist per broadcast. A show that played three of an artist's
-- records is one appearance on this page, not three.
plays as (
    select distinct on (m.id, re.id)
        m.id as artist_id,
        m.name as artist_name,
        rs.title as show_title,
        rs.station,
        re.provider,
        re.external_id as episode_external_id,
        re.aired_at,
        ra.raw_track_title
    from mine m
    join public.radio_appearances ra on ra.artist_id = m.id
    join public.radio_episodes re on re.id = ra.radio_episode_id
    left join public.radio_shows rs on rs.id = re.radio_show_id
    order by m.id, re.id, ra.track_index
),
recent as (
    select * from plays
    order by aired_at desc nulls last
    limit (select n from bounded)
),
-- The edge is stored once under the lower uuid, so it has to be read from
-- either end and the far side worked out per row.
neighbour as (
    select
        other.id,
        other.name,
        sum(mr.evidence_count)::int as evidence,
        (array_agg(m.name order by mr.evidence_count desc))[1] as via
    from public.music_relationships mr
    join mine m
        on m.id = mr.from_entity_id or m.id = mr.to_entity_id
    join public.artists other
        on other.id = case when mr.from_entity_id = m.id
                           then mr.to_entity_id else mr.from_entity_id end
    where mr.relationship_type = 'radio_neighbor'
      and mr.from_entity_type = 'artist'
      and mr.to_entity_type = 'artist'
      -- Not somebody they already have. A recommendation that names a record
      -- in your own crate is not a recommendation.
      and other.normalized_name <> all(p_names)
    group by other.id, other.name
    order by sum(mr.evidence_count) desc, other.name
    limit (select n from bounded)
)
select jsonb_build_object(
    'on_radio', coalesce((
        select jsonb_agg(jsonb_build_object(
            'artist_id', artist_id,
            'artist_name', artist_name,
            'show_title', show_title,
            'station', station,
            'provider', provider,
            'episode_external_id', episode_external_id,
            'aired_at', aired_at,
            'raw_track_title', raw_track_title))
        from recent), '[]'::jsonb),
    'alongside', coalesce((
        select jsonb_agg(jsonb_build_object(
            'artist_id', id,
            'name', name,
            'via', via,
            'evidence_count', evidence))
        from neighbour), '[]'::jsonb)
);
$$;

grant execute on function public.dig_radio_for_artists(text[], int) to anon, authenticated;

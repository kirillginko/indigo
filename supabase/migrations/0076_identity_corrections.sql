-- 0076: two identity corrections, and the merge rule that caused one of them
-- (SHARED-KNOWLEDGE.md §18). Approved 2026-10-12; read-only impact audit in
-- supabase/diagnostics/identity-audit/corrections-impact.sql.
--
-- Safe to run again: every write is keyed by exact row id and external id,
-- and guarded by the evidence that justifies it, so on any database where
-- that evidence is absent (a fresh one, or one already corrected) it does
-- nothing.

-- ---------------------------------------------------------------------------
-- 1. A radio row that MusicBrainz has already identified is not a name.
--
-- `split_artist_halves` (0028) pairs a name-only radio row with the one
-- same-named row carrying a Discogs id, and `merge_split_artists` folds the
-- second into the first every night. "Name-only" meant "no `discogs` key" --
-- which a radio row with a MusicBrainz-recorded Discogs id
-- (`musicbrainz_discogs`, the worker's link_discogs_identity) also is. So on
-- 2026-10-11 the radio row "Hype Williams", which MusicBrainz says is the
-- duo (Discogs 1874027), was merged with a row a Discogs search had just
-- made for Hype Williams the music-video director (398459), and took the
-- director's id. Its MusicBrainz link contradicted the merge; nothing read it.
--
-- Now a radio row with a MusicBrainz-recorded Discogs id pairs only with the
-- row holding that same id. A radio row with none pairs as before.
create or replace view public.split_artist_halves as
with keyed as (
    select
        a.id,
        a.normalized_name,
        count(*) filter (where x.provider = 'nts') as nts_keys,
        count(*) filter (where x.provider = 'discogs') as discogs_keys,
        count(x.id) as any_keys,
        array_agg(x.external_id) filter (where x.provider = 'musicbrainz_discogs') as musicbrainz_discogs,
        array_agg(x.external_id) filter (where x.provider = 'discogs') as discogs
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
select g.normalized_name, g.keep_id, g.merge_id
from grouped g
join keyed k on k.id = g.keep_id
join keyed m on m.id = g.merge_id
where g.rows_for_name = 2
  and g.name_only = 1
  and g.discogs_rows = 1
  and g.unkeyed = 0
  and (k.musicbrainz_discogs is null or k.musicbrainz_discogs && m.discogs);

alter view public.split_artist_halves set (security_invoker = on);
revoke all on public.split_artist_halves from public, anon, authenticated;
grant select on public.split_artist_halves to service_role;

-- ---------------------------------------------------------------------------
-- 2. Hype Williams: the radio row loses the director's Discogs id.
--
-- Row 5dbab0e3 is the radio name "Hype Williams" (NTS key "hype williams",
-- 19 radio appearances, three of the duo's records). MusicBrainz identifies
-- it -- its MBID fdd6ea04, "lo-fi music duo" -- as Discogs 1874027, and that
-- link stays: it is how the duo's catalogue row (8c74e06d, "Hype Williams
-- (2)") is reached, so the duo identity is assigned only through it. Discogs
-- 398459 is Harold "Hype" Williams, the director (Discogs document;
-- MusicBrainz 9b825c18, "music video director"). Removed here, and only
-- while the row still carries the contradicting MusicBrainz link. Nothing
-- else on the row came from the director (the merge moved no release,
-- appearance or edge; its portrait predates the merge and is reported in
-- §18, not changed here).
delete from public.external_ids d
where d.provider = 'discogs' and d.entity_type = 'artist' and d.external_id = '398459'
  and d.entity_id = '5dbab0e3-b85a-42e9-8c35-64529418a062'
  and exists (
      select 1 from public.external_ids m
      where m.provider = 'musicbrainz_discogs' and m.entity_type = 'artist'
        and m.entity_id = d.entity_id and m.external_id = '1874027'
  );

-- ---------------------------------------------------------------------------
-- 3. Prefuse73: the radio spelling gains Prefuse 73's identity.
--
-- Row cc290916 is the radio name "Prefuse73" (NTS key "prefuse73", nothing
-- else; its one release is Prefuse 73's Vocal Studies and Uprock
-- Narratives). Discogs lists "Prefuse73" among the name variations of 3722
-- (Prefuse 73, Guillermo Scott Herren), and MusicBrainz records "Prefuse73"
-- as an alias of fc61dd75, the artist it links to Discogs 3722. The row keeps
-- its own name and NTS key; the link is filed the way MusicBrainz-recorded
-- identities are (`musicbrainz_discogs`, source the MusicBrainz artist), so
-- the catalogue's own Prefuse 73 row (36133fd1, discogs 3722) is untouched
-- and the radio row reaches it the way the Hype Williams radio row reaches
-- the duo. Only while the row is still that radio name, nothing else holds
-- this link, and 3722 is still Prefuse 73's row with that MBID.
insert into public.external_ids (entity_type, entity_id, provider, external_id, source_url)
select 'artist', a.id, 'musicbrainz_discogs', '3722',
       'https://musicbrainz.org/artist/fc61dd75-880b-44ba-9ba9-c7b643d33413'
from public.artists a
where a.id = 'cc290916-e418-457f-81e4-8e97b8a910bb'
  and a.normalized_name = 'prefuse73'
  and exists (select 1 from public.external_ids n
              where n.entity_type = 'artist' and n.entity_id = a.id and n.provider = 'nts' and n.external_id = 'prefuse73')
  and not exists (select 1 from public.external_ids o
                  where o.entity_type = 'artist' and o.entity_id = a.id and o.provider <> 'nts')
  and exists (select 1 from public.external_ids d join public.artists p on p.id = d.entity_id
              where d.provider = 'discogs' and d.entity_type = 'artist' and d.external_id = '3722'
                and p.musicbrainz_id = 'fc61dd75-880b-44ba-9ba9-c7b643d33413')
on conflict (provider, entity_type, external_id) do nothing;

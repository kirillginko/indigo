-- Read-only: every artist portrait served from Discogs, with the row's own
-- Discogs identities (its own and MusicBrainz-recorded), for the portrait
-- audit (§20; Scripts/portrait-audit.py decodes which artist each image is).
select json_agg(json_build_object('id', a.id, 'n', a.name, 'u', w.original_url,
       'd', (select array_agg(e.external_id) from public.external_ids e
             where e.entity_type = 'artist' and e.entity_id = a.id and e.provider in ('discogs', 'musicbrainz_discogs')))) as rows
from public.artwork w join public.artists a on a.id = w.entity_id
where w.entity_type = 'artist' and w.original_url like 'https://i.discogs.com/%';

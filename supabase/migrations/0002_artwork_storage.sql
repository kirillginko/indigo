-- Artwork cache bucket.
--
-- Layout mirrors the entity tables, keyed by Indigo UUID so a path stays valid
-- even when an upstream provider reshuffles its own ids:
--
--   artwork/releases/{release_uuid}/thumb.webp    128-160 px
--   artwork/releases/{release_uuid}/medium.webp   512 px
--   artwork/releases/{release_uuid}/large.webp    1200 px
--
-- Safe to re-run.

-- Public so the app can render straight from the CDN URL with no signing round
-- trip — the whole point of the cache is that artwork appears without a wait.
-- Nothing private belongs in this bucket.
insert into storage.buckets (id, name, public)
values ('artwork', 'artwork', true)
on conflict (id) do update set public = true;

-- Read for everyone, writes for no one. As with the tables, uploads happen
-- through the service-role key, which bypasses RLS.
drop policy if exists artwork_objects_read on storage.objects;
create policy artwork_objects_read on storage.objects
    for select to anon, authenticated
    using (bucket_id = 'artwork');

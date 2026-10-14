-- Danny Brown: the NTS radio row "Danny Brown" (12947170-...) carries Discogs
-- 455494, "Danny Brown" the Dallas engineer, by an old name match. Its one
-- release, Stardust on Warp, credits Danny Brown (2), 1059062 (Discogs release
-- 36557014 and its pressings), whose own row already exists ("Danny Brown (2)",
-- 1b18b6f4-...). The wrong id is removed; the 0083 trigger re-asks the row's
-- portrait, which by name alone is withheld (a dozen Discogs Danny Browns).
-- Rollback: danny-brown-rollback.sql.
begin;
delete from public.external_ids
 where entity_type = 'artist' and entity_id = '12947170-ce77-42a3-a8c6-06ec2f5e856d'
   and provider = 'discogs' and external_id = '455494';
commit;

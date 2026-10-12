-- Read-only: a reproducible sample of artists for validating B1 (radio
-- single adjacencies derived on demand), across popularity on the radio.
with counts as materialized (
  select artist_id, count(*) as n from public.radio_appearances where artist_id is not null group by 1),
ranked as (select artist_id, n, ntile(100) over (order by n desc) as pct from counts),
pick as (
  (select artist_id, n, 'top' as band from ranked order by n desc limit 12)
  union all (select artist_id, n, 'p5' from ranked where pct = 5 order by md5(artist_id::text) limit 12)
  union all (select artist_id, n, 'p25' from ranked where pct = 25 order by md5(artist_id::text) limit 12)
  union all (select artist_id, n, 'median' from ranked where pct = 50 order by md5(artist_id::text) limit 12)
  union all (select artist_id, n, 'obscure' from ranked where pct = 95 order by md5(artist_id::text) limit 12))
select json_agg(json_build_object('id', p.artist_id, 'appearances', p.n, 'band', p.band, 'name', a.name, 'key', a.normalized_name)) as sample
from pick p join public.artists a on a.id = p.artist_id;

-- The portrait queue, reading radio the way radio is actually written.
--
-- 0019 found the artists worth a picture by walking artists -> recordings ->
-- radio_appearances, copied from `enqueue_artist_origins`. In production that
-- walk finds nobody. Of 65,671 radio appearances none carries a recording_id,
-- and no recording carries an artist_id: appearances are resolved to an artist
-- directly, which is what `dig_radio_for_artists` in 0010 has always joined on.
-- So the queue asked every ten minutes and was answered with nothing, and the
-- per-listener fill it exists to replace carried on spending the shared budget.
--
-- 0019's smoke test filled both links in its fixture and passed. The fixture
-- is now shaped like the real tables, so the same mistake would fail it.
--
-- Safe to re-run.

create or replace function public.enqueue_artist_portraits(p_limit int default 20)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_queued int := 0;
    v_limit int := greatest(1, least(coalesce(p_limit, 20), 200));
begin
    for v_row in
        select a.id, a.name, count(*) as plays
        from public.artists a
        join public.radio_appearances ap on ap.artist_id = a.id
        left join public.artwork w
            on w.entity_type = 'artist' and w.entity_id = a.id
        where coalesce(btrim(a.name), '') <> ''
          -- Never looked, or looked long enough ago to be worth another try.
          -- A row with a null `original_url` is a recorded miss rather than an
          -- absence: see `record_artist_portrait`.
          and (
              w.id is null
              or (w.original_url is null
                  and w.fetched_at < now() - public.artist_portrait_lifetime())
          )
          and not exists (
              select 1 from public.enrichment_jobs j
              where j.provider = 'discogs'
                and j.job_type = 'fetch_artist_portrait'
                and j.dedupe_key = a.id::text
                and j.status in ('pending', 'running')
          )
        group by a.id, a.name, w.id
        order by count(*) desc, a.name
        limit v_limit
    loop
        perform public.enqueue_enrichment_job(
            'discogs',
            'fetch_artist_portrait',
            v_row.id::text,
            jsonb_build_object('artist_id', v_row.id, 'name', v_row.name),
            -2,
            'artist',
            v_row.id
        );
        v_queued := v_queued + 1;
    end loop;
    return v_queued;
end $$;

revoke all on function public.enqueue_artist_portraits(int) from public;
grant execute on function public.enqueue_artist_portraits(int) to service_role;

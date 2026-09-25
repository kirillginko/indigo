-- One call per batch, not one per job.
--
-- Every call the worker makes to its own database goes through the API
-- gateway, and the gateway writes a log line for each -- a fat one, headers
-- and all. The free plan includes 1 GB of log ingestion a month; the project
-- was at 7.9. Most of that was the two cache moves, now over, but the steady
-- part is the worker: claim, then a `record_track_release` and a
-- `complete_enrichment_job` for every job, ~70k gateway lines a day for
-- ~20k jobs. These take a whole batch at once, so a drain of thirty is three
-- calls instead of sixty-one.
--
-- Both keep the single-row functions' behaviour exactly; the single-row
-- functions stay, for any caller still using them.
--
-- Safe to re-run.

-- `p_results`: [{"id": uuid, "ok": bool, "error": text|null}, ...]
create or replace function public.complete_enrichment_jobs(p_results jsonb)
returns int
language sql
security definer
set search_path = public, pg_temp
as $$
    with r as (
        select (x->>'id')::uuid as id,
               coalesce((x->>'ok')::boolean, false) as ok,
               x->>'error' as error
        from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) as x
    ),
    done as (
        update public.enrichment_jobs j
        set status = case
                when r.ok then 'done'
                when j.attempts >= j.max_attempts then 'failed'
                else 'pending'
            end,
            last_error = case when r.ok then null else left(coalesce(r.error, ''), 500) end,
            next_attempt_at = case
                when r.ok then j.next_attempt_at
                -- 1, 2, 4, 8 … minutes, capped at an hour. As 0005.
                else now() + (least(60, power(2, least(j.attempts, 6))::int) || ' minutes')::interval
            end
        from r
        where j.id = r.id
        returning 1
    )
    select count(*)::int from done;
$$;

revoke all on function public.complete_enrichment_jobs(jsonb) from public, anon, authenticated;
grant execute on function public.complete_enrichment_jobs(jsonb) to service_role;

-- `p_rows`: [{"deezer_track_id", "track_title", "title_key", "album_title",
-- "deezer_album_id", "label", "label_key", "release_year", "isrc"}, ...]
--
-- Each row is its own subtransaction, so one bad row fails that job alone,
-- as it would have on its own call. Returns the track ids that failed, with
-- why, so the worker can fail exactly those jobs.
create or replace function public.record_track_releases(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    x jsonb;
    failed jsonb := '{}'::jsonb;
begin
    for x in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
        begin
            perform public.record_track_release(
                x->>'deezer_track_id',
                x->>'track_title',
                x->>'title_key',
                x->>'album_title',
                x->>'deezer_album_id',
                x->>'label',
                x->>'label_key',
                (x->>'release_year')::int,
                x->>'isrc');
        exception when others then
            failed := failed || jsonb_build_object(coalesce(x->>'deezer_track_id', ''), sqlerrm);
        end;
    end loop;
    return failed;
end $$;

revoke all on function public.record_track_releases(jsonb) from public, anon, authenticated;
grant execute on function public.record_track_releases(jsonb) to service_role;

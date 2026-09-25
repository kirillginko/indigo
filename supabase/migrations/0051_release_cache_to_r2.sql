-- Move the release cache from Supabase Storage to Cloudflare R2.
--
-- The free plan allows 1 GB of file storage and 500 MB of database. The
-- release cache was 151,782 files and 1.37 GB in Storage, and Storage keeps a
-- metadata row per file in Postgres: 73 MB of table and 82 MB of index in
-- `storage.objects`. R2's free tier is 10 GB with nothing charged for reads,
-- and nothing of it lands in Postgres.
--
-- New releases are written to R2 as soon as the R2_* secrets are set (see
-- supabase/functions/_shared/r2.ts); a row pointing there reads
-- `r2:releases/<id>.json`. The ones already stored are moved in batches by
-- `move_release_payloads_to_r2`, scheduled by `schedule_r2_move()` below --
-- defined here, and run once the secrets are in place.
--
-- Also: three indexes that duplicated a unique index column for column, 34 MB
-- read by nothing the unique one does not already serve, and written on every
-- insert.
--
-- Safe to re-run.

create or replace function public.mark_release_payloads_in_r2(p_resource_ids text[])
returns int
language sql
security definer
set search_path = public
as $$
    with moved as (
        update public.metadata_cache
        set payload_path = 'r2:' || payload_path
        where provider = 'discogs'
          and resource_type = 'release'
          and resource_id = any (p_resource_ids)
          and payload_path is not null
          and payload_path not like 'r2:%'
        returning 1
    )
    select count(*)::int from moved;
$$;

revoke all on function public.mark_release_payloads_in_r2(text[]) from public, anon, authenticated;
grant execute on function public.mark_release_payloads_in_r2(text[]) to service_role;

-- Each is the same columns, in the same order, as a unique index beside it.
drop index if exists public.external_ids_lookup_idx;        -- = external_ids_provider_entity_type_external_id_key
drop index if exists public.metadata_cache_lookup_idx;      -- = metadata_cache_provider_resource_type_resource_id_key
drop index if exists public.radio_appearances_episode_idx;  -- = radio_appearances_slot_idx

-- The move's lane: a batch of 300 a minute, about eight and a half hours for
-- the lot. Deduped on one key, so a batch still waiting is never queued twice
-- and the checkpoint has one writer. Once the walk is done each job finds
-- nothing and finishes in one query; `unschedule_r2_move()` then stops it.
create or replace function public.schedule_r2_move()
returns text
language plpgsql
as $$
begin
    if not public.has_function('cron', 'schedule') then
        return 'skipped: pg_cron unavailable';
    end if;

    perform cron.schedule(
        'indigo-r2-move-enqueue',
        '* * * * *',
        $job$select public.enqueue_enrichment_job(
            'indigo', 'move_release_payloads_to_r2', 'r2-move',
            jsonb_build_object('batch', 300), 2, null, null)$job$);

    if public.has_function('net', 'http_post') then
        perform cron.schedule(
            'indigo-r2-move-drain',
            '* * * * *',
            $job$select net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 1, 'job_type', 'move_release_payloads_to_r2')
            )$job$);
    end if;

    return 'indigo-r2-move-enqueue, indigo-r2-move-drain';
end $$;

create or replace function public.unschedule_r2_move()
returns text
language plpgsql
as $$
begin
    if public.has_function('cron', 'schedule') then
        perform cron.unschedule(jobname) from cron.job
        where jobname in ('indigo-r2-move-enqueue', 'indigo-r2-move-drain');
    end if;
    return 'r2 move unscheduled';
end $$;

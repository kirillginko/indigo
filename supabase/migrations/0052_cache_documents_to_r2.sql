-- The rest of the cache's documents to R2, beside the releases (0051).
--
-- Releases moved to Storage in 0036; searches, artist and label pages, shelves
-- and NTS documents stayed inline in `metadata_cache`: 4,927 rows, 36 MB of
-- the database's 500. Supabase Storage was no answer for them -- it writes a
-- row per file into Postgres -- but R2 keeps nothing here. catalog-refresh and
-- the shelf crawl now write them there once the R2 secrets are set; this moves
-- the ones already held.
--
-- A moved row keeps its key and expiry; `payload` is cleared and
-- `payload_path` names the object (`r2:cache/<provider>/<digest>.json`). The
-- app and the backend already read either shape.
--
-- Safe to re-run.

create or replace function public.mark_inline_payloads_in_r2(p_ids uuid[], p_paths text[])
returns int
language sql
security definer
set search_path = public
as $$
    with moved as (
        update public.metadata_cache m
        set payload = null,
            payload_path = t.path
        from unnest(p_ids, p_paths) as t(id, path)
        where m.id = t.id
          and m.payload is not null
          and t.path like 'r2:%'
        returning 1
    )
    select count(*)::int from moved;
$$;

revoke all on function public.mark_inline_payloads_in_r2(uuid[], text[]) from public, anon, authenticated;
grant execute on function public.mark_inline_payloads_in_r2(uuid[], text[]) to service_role;

-- The same lane as the release move, one more job on it. The inline set is
-- small -- about twenty-five batches -- so it finishes long before the
-- releases do.
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
                jsonb_build_object('batch', 300), 2, null, null),
             public.enqueue_enrichment_job(
                'indigo', 'move_inline_payloads_to_r2', 'r2-inline-move',
                jsonb_build_object('batch', 200), 2, null, null)$job$);

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
            ),
            net.http_post(
                url := (select decrypted_secret from vault.decrypted_secrets
                        where name = 'indigo_worker_url'),
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || (select decrypted_secret
                        from vault.decrypted_secrets where name = 'indigo_worker_key')),
                body := jsonb_build_object('limit', 1, 'job_type', 'move_inline_payloads_to_r2')
            )$job$);
    end if;

    return 'indigo-r2-move-enqueue, indigo-r2-move-drain';
end $$;

-- Makes a mis-set worker URL fail where it is set, not silently every five
-- minutes for a month.
--
-- The scheduler accepted the literal placeholder out of its own documentation —
-- `https://<project-ref>.supabase.co/...` — stored it in Vault and reported
-- success. Every drain since then failed with "Bad hostname", the queue grew to
-- 139 jobs, and the only reason anything moved was the app draining it by hand
-- while somebody was browsing. Status called the secrets present, because all
-- it checked was that a row existed.
--
-- Two changes: the value is checked before it is stored, and the status says
-- what is wrong rather than what exists.
--
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- What is wrong with this value
-- ---------------------------------------------------------------------------

-- Returns a complaint, or null when there is nothing to complain about.
--
-- Shared by the setter and the status deliberately: the check that refuses a
-- bad value and the check that reports one have to be the same check, or the
-- second will keep insisting a value is fine after the first stopped accepting
-- it.
create or replace function public.worker_url_problem(p_url text)
returns text
language sql
immutable
as $$
    select case
        when coalesce(p_url, '') = '' then
            'no worker URL is set'
        -- The failure that prompted all of this.
        when p_url ~ '[<>]' then
            'the worker URL still has a placeholder in it: ' || p_url
        when p_url !~ '^https://' then
            'the worker URL must be https: ' || p_url
        when p_url ~ '\s' then
            'the worker URL contains whitespace'
        when split_part(split_part(p_url, '://', 2), '/', 1)
             !~ '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$' then
            'the worker URL has no usable hostname: ' || p_url
        when p_url !~ '/functions/v1/[A-Za-z0-9_-]+$' then
            'the worker URL does not name an Edge Function: ' || p_url
        else null
    end;
$$;

create or replace function public.worker_key_problem(p_key text)
returns text
language sql
immutable
as $$
    select case
        when coalesce(p_key, '') = '' then 'no worker key is set'
        when p_key ~ '[<>]' then 'the worker key still has a placeholder in it'
        when p_key ~ '\s' then 'the worker key contains whitespace'
        else null
    end;
$$;

grant execute on function public.worker_url_problem(text) to anon, authenticated;
grant execute on function public.worker_key_problem(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Refuse it at the door
-- ---------------------------------------------------------------------------

create or replace function public.schedule_indigo_enrichment(
    p_worker_url text,
    p_worker_key text
)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    problem text;
begin
    problem := coalesce(
        public.worker_url_problem(p_worker_url),
        public.worker_key_problem(p_worker_key));

    if problem is not null then
        raise exception '%', problem
            using hint = 'Pass this project''s own function URL and its publishable key.';
    end if;

    perform public.set_indigo_secret('indigo_worker_url', p_worker_url);
    perform public.set_indigo_secret('indigo_worker_key', p_worker_key);

    return public.schedule_indigo_enrichment();
end $$;

revoke all on function public.schedule_indigo_enrichment(text, text) from public;

-- ---------------------------------------------------------------------------
-- Say what is wrong, not what exists
-- ---------------------------------------------------------------------------

create or replace function public.enrichment_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    schedule jsonb := '[]'::jsonb;
    recent jsonb := '[]'::jsonb;
    secrets jsonb := '{}'::jsonb;
    problems text[] := '{}';
    worker_url text;
    worker_key text;
    drain_status text;
    drain_message text;
    pending int;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
        problems := array_append(problems, 'pg_cron is not enabled; nothing is scheduled');
    end if;
    if not exists (select 1 from pg_extension where extname = 'pg_net') then
        problems := array_append(problems, 'pg_net is not enabled; the queue cannot be drained on a schedule');
    end if;

    begin
        select decrypted_secret into worker_url
        from vault.decrypted_secrets where name = 'indigo_worker_url';
        select decrypted_secret into worker_key
        from vault.decrypted_secrets where name = 'indigo_worker_key';

        secrets := jsonb_build_object(
            'indigo_worker_url', worker_url is not null,
            'indigo_worker_key', worker_key is not null);

        -- The value, not merely the row. Reporting presence is what let a
        -- placeholder sit there being called fine.
        problems := array_cat(problems, array_remove(array[
            public.worker_url_problem(worker_url),
            public.worker_key_problem(worker_key)
        ], null));
    exception when others then
        secrets := jsonb_build_object('error', sqlerrm);
    end;

    if public.has_function('cron', 'schedule') then
        execute $q$
            select coalesce(jsonb_agg(jsonb_build_object(
                'job', jobname, 'schedule', schedule, 'active', active)
                order by jobname), '[]'::jsonb)
            from cron.job where jobname like 'indigo-%'
        $q$ into schedule;

        begin
            execute $q$
                select coalesce(jsonb_agg(jsonb_build_object(
                    'job', j.jobname, 'status', d.status, 'ran', d.start_time,
                    'detail', left(coalesce(d.return_message, ''), 200))
                    order by d.start_time desc), '[]'::jsonb)
                from (select * from cron.job_run_details order by start_time desc limit 5) d
                join cron.job j on j.jobid = d.jobid
            $q$ into recent;

            -- The drain is the job whose failure is invisible: discovery keeps
            -- succeeding, the queue keeps growing, and nothing says why.
            execute $q$
                select d.status, left(coalesce(d.return_message, ''), 300)
                from cron.job_run_details d
                join cron.job j on j.jobid = d.jobid
                where j.jobname = 'indigo-drain-queue'
                order by d.start_time desc limit 1
            $q$ into drain_status, drain_message;

            if drain_status is not null and drain_status <> 'succeeded' then
                problems := array_append(problems,
                    'the last queue drain ' || drain_status || ': ' || drain_message);
            end if;
        exception when others then
            recent := '[]'::jsonb;
        end;
    end if;

    select count(*) into pending from public.enrichment_jobs where status = 'pending';
    if pending > 200 then
        problems := array_append(problems,
            pending || ' jobs are waiting; the queue is filling faster than it drains');
    end if;

    return jsonb_build_object(
        'healthy', cardinality(problems) = 0,
        'problems', to_jsonb(problems),
        'extensions', jsonb_build_object(
            'pg_cron', exists (select 1 from pg_extension where extname = 'pg_cron'),
            'pg_net', exists (select 1 from pg_extension where extname = 'pg_net')),
        'schedule', schedule,
        'recent_runs', recent,
        'secrets', secrets,
        'jobs', coalesce((
            select jsonb_object_agg(status, n)
            from (select status, count(*) as n from public.enrichment_jobs group by status) as s
        ), '{}'::jsonb),
        'by_type', coalesce((
            select jsonb_object_agg(job_type, n)
            from (select job_type, count(*) as n from public.enrichment_jobs
                  where status in ('pending', 'running') group by job_type) as t
        ), '{}'::jsonb),
        'cursors', coalesce((
            select jsonb_object_agg(name, position) from public.enrichment_cursors
        ), '{}'::jsonb),
        'radio', jsonb_build_object(
            'shows', (select count(*) from public.radio_shows),
            'episodes', (select count(*) from public.radio_episodes),
            'appearances', (select count(*) from public.radio_appearances),
            'resolved_appearances', (select count(*) from public.radio_appearances
                                     where artist_id is not null),
            'artists', (select count(*) from public.artists),
            'radio_edges', (select count(*) from public.music_relationships
                            where source like 'radio%')),
        'last_job_error', (select last_error from public.enrichment_jobs
                           where last_error is not null order by updated_at desc limit 1));
end $$;

grant execute on function public.enrichment_status() to anon, authenticated;

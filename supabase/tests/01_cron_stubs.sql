-- Stand-ins for pg_cron and pg_net, which cannot be installed into a throwaway
-- cluster. Same schemas and same signatures, including the two-argument
-- cron.schedule overload — which is the whole reason to_regproc returned NULL
-- and the scheduler locked itself out. Without that overload the stub would be
-- easier than reality and would not have caught the bug.

-- signatures and same schemas, so the scheduler exercises its real code path.
create schema if not exists cron;
create table if not exists cron.job (
    jobid bigserial primary key, jobname text unique, schedule text,
    command text, active boolean default true);
create table if not exists cron.job_run_details (
    jobid bigint, status text, start_time timestamptz default now(), return_message text);
create or replace function cron.schedule(p_name text, p_schedule text, p_command text)
returns bigint language sql as $$
    insert into cron.job (jobname, schedule, command) values (p_name, p_schedule, p_command)
    on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
    returning jobid;
$$;
-- The two-argument overload is the whole reason to_regproc returned NULL.
create or replace function cron.schedule(p_schedule text, p_command text)
returns bigint language sql as $$ select 0::bigint; $$;
create or replace function cron.unschedule(p_name text)
returns boolean language sql as $$ delete from cron.job where jobname = p_name returning true; $$;

create schema if not exists net;
create or replace function net.http_post(url text, headers jsonb default '{}', body jsonb default '{}')
returns bigint language sql as $$ select 1::bigint; $$;

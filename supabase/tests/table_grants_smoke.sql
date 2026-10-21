-- A fresh database must work without Supabase's former default table grants.
-- Check effective privileges and real queries as the API roles, not postgres.
\set ON_ERROR_STOP on
begin;

do $$
declare
    app_tables text[] := array[
        'artists', 'labels', 'releases', 'recordings', 'external_ids',
        'artwork', 'metadata_cache', 'radio_shows', 'radio_appearances',
        'music_relationships', 'radio_episodes', 'scene_rosters', 'scene_members'
    ];
    backend_tables text[] := array[
        'enrichment_jobs', 'enrichment_cursors', 'youtube_channels', 'r2_usage'
    ];
    tbl record;
    api_role text;
    privilege text;
    table_name text;
    app_readable boolean;
begin
    for tbl in
        select c.relname, c.relrowsecurity
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('r', 'p')
    loop
        table_name := format('public.%I', tbl.relname);
        app_readable := tbl.relname = any(app_tables);
        if not app_readable and not (tbl.relname = any(backend_tables)) then
            raise exception 'classify Data API access for new table %', table_name;
        end if;
        if not tbl.relrowsecurity then
            raise exception 'RLS is disabled on %', table_name;
        end if;
        foreach api_role in array array['anon', 'authenticated'] loop
            if has_table_privilege(api_role, table_name, 'SELECT') <> app_readable then
                raise exception 'unexpected SELECT access for % on %', api_role, table_name;
            end if;
            foreach privilege in array array[
                'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'
            ] loop
                if has_table_privilege(api_role, table_name, privilege) then
                    raise exception '% can % on %', api_role, privilege, table_name;
                end if;
            end loop;
            execute format('set local role %I', api_role);
            if app_readable then
                execute format('select * from %s limit 0', table_name);
            else
                begin
                    execute format('select * from %s limit 0', table_name);
                    raise exception '% can query private table %', api_role, table_name;
                exception when insufficient_privilege then
                    null;
                end;
            end if;
            reset role;
        end loop;
        foreach privilege in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
            if not has_table_privilege('service_role', table_name, privilege) then
                raise exception 'service_role lacks % on %', privilege, table_name;
            end if;
        end loop;
    end loop;
end $$;

-- An actual backend write followed by an app read exercises both grants and
-- RLS. Everything is rolled back, including these fixture rows.
set local role service_role;
insert into public.artists (id, name)
values ('00000000-0000-0000-0000-000000000030', 'Explicit grants smoke test');
update public.artists set country = 'GB'
where id = '00000000-0000-0000-0000-000000000030';
reset role;

set local role anon;
do $$
begin
    if not exists (
        select 1 from public.artists
        where id = '00000000-0000-0000-0000-000000000030' and country = 'GB'
    ) then
        raise exception 'anon cannot read the backend-created artist';
    end if;
    begin
        insert into public.artists (name) values ('App writes must fail');
        raise exception 'anon can insert an artist';
    exception when insufficient_privilege then
        null;
    end;
end $$;
reset role;

set local role service_role;
delete from public.artists where id = '00000000-0000-0000-0000-000000000030';
reset role;
rollback;

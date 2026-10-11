-- knowledge_cut (0075): who may call it, when it refuses, what it proves,
-- and what its relationship targets carry. Run by Scripts/test-migrations.sh
-- with the frozen pilot demand set in :'demand'.

\set ON_ERROR_STOP on

-- psql does not substitute variables inside DO blocks, so the demand set and
-- today's UTC date are kept here. The function decides "today" in UTC; the
-- test cluster's own time zone must not.
create temp table pilot as
select :'demand'::jsonb as demand, (now() at time zone 'UTC')::date as day,
       (((now() at time zone 'UTC')::date)::timestamp at time zone 'UTC') as midnight;

-- Privileges: the publishing worker only. Supabase's default privileges
-- (stubbed in 00_supabase_stubs.sql) grant every new function to anon and
-- authenticated by name; 0075 must have taken both back, and PUBLIC.
do $$
begin
    if has_function_privilege('anon', 'public.knowledge_cut(date, jsonb)', 'execute') then
        raise exception 'anon can execute knowledge_cut';
    end if;
    if has_function_privilege('authenticated', 'public.knowledge_cut(date, jsonb)', 'execute') then
        raise exception 'authenticated can execute knowledge_cut';
    end if;
    if has_function_privilege('anon', 'public.knowledge_answers(jsonb, text[])', 'execute')
       or has_function_privilege('authenticated', 'public.knowledge_answers(jsonb, text[])', 'execute') then
        raise exception 'a client role can execute knowledge_answers';
    end if;
    if exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.proname in ('knowledge_cut', 'knowledge_answers') and a.grantee = 0) then
        raise exception 'PUBLIC can execute a knowledge function';
    end if;
    if not has_function_privilege('service_role', 'public.knowledge_cut(date, jsonb)', 'execute') then
        raise exception 'service_role cannot execute knowledge_cut';
    end if;
    if 'knowledge_cut' = any(public.app_callable_functions()) then
        raise exception 'knowledge_cut is on the app''s list';
    end if;
end $$;
\echo 'knowledge_cut: only service_role may execute it'

-- A small catalogue around one pilot starting point, Dean Blunt.
insert into public.labels (id, name, normalized_name) values
    ('10000000-0000-0000-0000-000000000001', 'World Music', 'world music');
insert into public.artists (id, name, normalized_name) values
    ('20000000-0000-0000-0000-000000000001', 'Dean Blunt', 'dean blunt'),
    ('20000000-0000-0000-0000-000000000002', 'Inga Copeland', 'inga copeland'),     -- Discogs release peer
    ('20000000-0000-0000-0000-000000000003', 'Rare Name', 'rare name'),             -- peer by a release without a Discogs id
    ('20000000-0000-0000-0000-000000000004', 'Panda Bear', 'panda bear'),           -- radio neighbour, name-joined id
    ('20000000-0000-0000-0000-000000000005', 'Speedy J', 'speedy j'),               -- two rows,
    ('20000000-0000-0000-0000-000000000006', 'Speedy J', 'speedy j');               -- one name
insert into public.external_ids (entity_type, entity_id, provider, external_id) values
    ('artist', '20000000-0000-0000-0000-000000000001', 'discogs', '2419343'),
    ('artist', '20000000-0000-0000-0000-000000000002', 'discogs', '2365200'),
    ('artist', '20000000-0000-0000-0000-000000000003', 'discogs', '9000001'),
    ('artist', '20000000-0000-0000-0000-000000000004', 'discogs', '218809'),
    ('artist', '20000000-0000-0000-0000-000000000004', 'nts', 'panda bear'),
    ('artist', '20000000-0000-0000-0000-000000000005', 'discogs', '823'),
    ('artist', '20000000-0000-0000-0000-000000000006', 'discogs', '9000002');
insert into public.releases (title, artist_id, label_id, discogs_id) values
    ('Black Metal', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 3),
    ('Because I''m Worth It', '20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 4),
    ('A Record Nobody Catalogued', '20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', null),
    ('Ride', '20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 5),
    ('Loudboxer', '20000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', 6);
insert into public.music_relationships
    (from_entity_type, from_entity_id, to_entity_type, to_entity_id, relationship_type, confidence, source, evidence_count)
values ('artist', '20000000-0000-0000-0000-000000000001', 'artist', '20000000-0000-0000-0000-000000000004',
        'radio_neighbor', 0.6, 'radio', 2);

-- Refusals, each answering nothing.
do $$
declare cut jsonb;
begin
    cut := public.knowledge_cut((select day from pilot), (select demand from pilot));
    if cut->>'reason' <> 'no-completed-rebuild-today' or cut->'nodes' <> '{}'::jsonb then
        raise exception 'without a rebuild run: %', cut->>'reason';
    end if;
end $$;
\echo 'knowledge_cut: refuses without a completed rebuild today'

insert into cron.job (jobname, schedule, command)
values ('indigo-rebuild-edges', '23 */3 * * *', 'select public.rebuild_radio_dig_edges()')
on conflict (jobname) do nothing;
-- A run that started in today's slot but has not finished is no proof.
insert into cron.job_run_details (jobid, status, start_time, end_time)
select jobid, 'running', (select midnight from pilot) + interval '23 minutes', null from cron.job where jobname = 'indigo-rebuild-edges';
do $$
begin
    if public.knowledge_cut((select day from pilot), (select demand from pilot))->>'reason' <> 'no-completed-rebuild-today' then
        raise exception 'an unfinished rebuild was taken as proof';
    end if;
end $$;
-- Yesterday's run is no proof for today.
insert into cron.job_run_details (jobid, status, start_time, end_time)
select jobid, 'succeeded', (select midnight from pilot) - interval '1 day' + interval '23 minutes',
       (select midnight from pilot) - interval '1 day' + interval '23 minutes 18 seconds'
from cron.job where jobname = 'indigo-rebuild-edges';
do $$
begin
    if public.knowledge_cut((select day from pilot), (select demand from pilot))->>'reason' <> 'no-completed-rebuild-today' then
        raise exception 'yesterday''s rebuild was taken as proof for today';
    end if;
end $$;
\echo 'knowledge_cut: an unfinished run or yesterday''s is no proof'

-- Today's run, finished.
insert into cron.job_run_details (jobid, status, start_time, end_time)
select jobid, 'succeeded', (select midnight from pilot) + interval '23 minutes',
       (select midnight from pilot) + interval '23 minutes 18 seconds'
from cron.job where jobname = 'indigo-rebuild-edges';

do $$
declare cut jsonb;
begin
    cut := public.knowledge_cut((select day from pilot) - 1, (select demand from pilot));
    if cut->>'reason' <> 'not-today' then raise exception 'another day: %', cut->>'reason'; end if;
    cut := public.knowledge_cut((select day from pilot), jsonb_set((select demand from pilot), '{artists}', '[]'::jsonb));
    if cut->>'reason' <> 'not-the-frozen-demand-set' then raise exception 'another demand set: %', cut->>'reason'; end if;
end $$;
\echo 'knowledge_cut: refuses another day and another demand set'

-- The cut.
do $$
declare
    cut jsonb;
    edges jsonb;
    blunt jsonb;
    target jsonb;
begin
    cut := public.knowledge_cut((select day from pilot), (select demand from pilot));
    if cut->>'status' <> 'ok' then raise exception 'cut refused: %', cut->>'reason'; end if;
    if cut->'rebuild'->'proof'->>'runid' is null or cut->'rebuild'->'latest' is null then
        raise exception 'the rebuild proof is not recorded: %', cut->'rebuild';
    end if;
    if (cut->>'batches')::int <> 4 then raise exception 'batches: %', cut->>'batches'; end if;
    if jsonb_typeof(cut->'nodes') <> 'object' or (select count(*) from jsonb_object_keys(cut->'nodes')) <> 24 then
        raise exception 'not every demanded node answered';
    end if;
    if (select count(*) from jsonb_object_keys(cut->'artists')) <> 163 then
        raise exception 'not every demanded artist answered';
    end if;

    -- Statuses stay explicit.
    if cut->'nodes'->'artist:zzz nobody files this name'->>'status' <> 'unknown' then
        raise exception 'an unknown name is not unknown';
    end if;
    if cut->'nodes'->'station:n10as'->>'status' <> 'unsupported' then
        raise exception 'a station is not unsupported';
    end if;

    blunt := cut->'nodes'->'artist:dean blunt';
    if blunt->>'status' <> 'found' then raise exception 'Dean Blunt not found'; end if;
    edges := blunt->'edges';

    -- A peer a Discogs release document reached carries its id.
    select e->'to' into target from jsonb_array_elements(edges) e
    where e->'to'->>'name' = 'Inga Copeland' and e->>'kind' = 'sharedLabel';
    if target->>'discogsID' <> '2365200' or target->>'idEvidence' <> 'discogs-document' or target->>'rowID' is null then
        raise exception 'a Discogs-backed peer: %', target;
    end if;
    -- Reached only through a release with no Discogs id: name-matched.
    select e->'to' into target from jsonb_array_elements(edges) e where e->'to'->>'name' = 'Rare Name';
    if target->>'idEvidence' <> 'name-matched' then raise exception 'a peer by an uncatalogued release: %', target; end if;
    -- A radio neighbour: its id was joined to a radio name by name.
    select e->'to' into target from jsonb_array_elements(edges) e
    where e->'to'->>'name' = 'Panda Bear' and e->>'kind' = 'frequentlyPlayedNearby';
    if target->>'idEvidence' <> 'adopted-by-name' then raise exception 'a radio neighbour: %', target; end if;
    -- Two rows, one name: two targets, both flagged, never combined.
    if (select count(distinct e->'to'->>'rowID') from jsonb_array_elements(edges) e
        where e->'to'->>'name' = 'Speedy J' and (e->'to'->>'sharedName')::boolean) <> 2 then
        raise exception 'two Speedy J rows were combined or not flagged';
    end if;
    -- Two rows answer to one starting point's name: walked as one, and said.
    if not (cut->'nodes'->'artist:speedy j'->>'ambiguousName')::boolean
       or jsonb_array_length(cut->'nodes'->'artist:speedy j'->'seeds') <> 2 then
        raise exception 'a starting point two rows answer to is not marked: %', cut->'nodes'->'artist:speedy j';
    end if;
    if cut->'nodes'->'artist:dean blunt' ? 'ambiguousName' then
        raise exception 'a starting point with one row is marked ambiguous';
    end if;
    -- Labels and releases keep their ids as before, with no evidence field.
    if not exists (select 1 from jsonb_array_elements(edges) e
                   where e->'to'->>'kind' = 'release' and e->'to'->>'discogsID' = '3' and e->'to'->'idEvidence' is null) then
        raise exception 'a release target changed';
    end if;
end $$;
\echo 'knowledge_cut: statuses explicit; Discogs-backed peers carry ids, radio and name-matched targets do not place, namesake rows stay apart, an ambiguous starting point is said'

-- Strip the new fields and the answer is explore_knowledge's, from the same
-- statement.
do $$
declare
    nodes jsonb := (select jsonb_agg(n - 'why' order by n->>'id') from jsonb_array_elements((select demand from pilot)->'nodes') n
                    where n->>'id' in ('artist:dean blunt', 'artist:zzz nobody files this name', 'station:n10as'));
    artists text[] := array['dean blunt', 'panda bear', 'zzz nobody files this name'];
    mine jsonb;
    theirs jsonb;
    stripped jsonb;
begin
    select public.knowledge_answers(nodes, artists), public.explore_knowledge(nodes, artists) into mine, theirs;
    select jsonb_object_agg(k, case when v ? 'edges' then jsonb_set(v - 'seeds' - 'ambiguousName', '{edges}', coalesce((
               select jsonb_agg(case when e->'to'->>'kind' = 'artist'
                                     then e #- '{to,rowID}' #- '{to,discogsID}' #- '{to,idEvidence}' #- '{to,sharedName}'
                                     else e end order by (case when e->'to'->>'kind' = 'artist'
                                     then e #- '{to,rowID}' #- '{to,discogsID}' #- '{to,idEvidence}' #- '{to,sharedName}'
                                     else e end)::text)
               from jsonb_array_elements(v->'edges') e), '[]'::jsonb)) else v end)
    into stripped from jsonb_each(mine->'nodes') as x(k, v);
    if stripped <> theirs->'nodes' then raise exception 'nodes differ from explore_knowledge'; end if;
    if mine->'artists' <> theirs->'artists' then raise exception 'artists differ from explore_knowledge'; end if;
    if (mine->>'format')::int <> 3 or (theirs->>'format')::int <> 2 then raise exception 'formats'; end if;
end $$;
\echo 'knowledge_cut: without its new fields, knowledge_answers is explore_knowledge'

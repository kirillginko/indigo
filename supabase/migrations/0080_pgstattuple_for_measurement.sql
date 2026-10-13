-- 0080: pgstattuple, for read-only density measurements before the
-- music_relationships compaction (DATABASE-CAPACITY-PLAN.md, B2). Approved
-- 2026-10-12. An extension adds catalog entries only (functions), no data.
-- Its functions read whole relations, so they are not for the app: revoked
-- from the client roles by name (revoking from PUBLIC alone leaves anon its
-- grant; see 0023).

create extension if not exists pgstattuple with schema extensions;

do $$
declare f regprocedure;
begin
    for f in
        select p.oid::regprocedure
        from pg_proc p join pg_depend d on d.objid = p.oid and d.deptype = 'e'
        join pg_extension e on e.oid = d.refobjid and e.extname = 'pgstattuple'
    loop
        execute format('revoke all on function %s from public, anon, authenticated', f);
    end loop;
end $$;

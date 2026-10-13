-- 0084: the switch is readable by the app, off unless it says on, and pinned to one manifest.
do $$
declare c jsonb := public.dig_enrichment_config();
begin
    if not has_function_privilege('anon', 'public.dig_enrichment_config()', 'execute') then raise exception 'the app cannot read the switch'; end if;
    if not ('dig_enrichment_config' = any(public.app_callable_functions())) then raise exception 'not on the one list'; end if;
    if c->>'manifest' !~ '^[0-9a-f]{64}$' then raise exception 'no pinned manifest: %', c; end if;
    if (c->>'ttlSeconds')::int > 3600 or (c->>'offlineGraceSeconds')::int > 7 * 86400 then raise exception 'too trusting: %', c; end if;
    if c->'cohorts' ? 'appstore' then raise exception 'the App Store cohort is not approved: %', c; end if;
end $$;
select 'dig enrichment switch: readable, pinned, short-lived, no App Store cohort' as ok;

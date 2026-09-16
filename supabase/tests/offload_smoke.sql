-- Moving release payloads out of the database (0036).
--
-- The worker does the uploads; what the database owns is choosing what to
-- move, marking it moved, and refusing to leave a row with nowhere to find its
-- payload. Those are what is checked.

begin;

insert into public.metadata_cache (provider, resource_type, resource_id, payload)
values
    ('discogs', 'release', '100', '{"id":100,"title":"One"}'::jsonb),
    ('discogs', 'release', '200', '{"id":200,"title":"Two"}'::jsonb),
    ('discogs', 'database/search', 'q=x', '{"results":[]}'::jsonb),
    ('nts', 'episode', 'show/ep', '{"name":"ep"}'::jsonb);

do $$
declare
    n bigint;
begin
    if public.release_payloads_left() <> 2 then
        raise exception 'expected two releases to move, counted %', public.release_payloads_left();
    end if;

    select count(*) into n from public.release_payloads_to_offload(10);
    if n <> 2 then raise exception 'offered % rows, expected only the two releases', n; end if;

    -- Only the one whose upload succeeded is marked.
    if public.mark_release_payloads_offloaded(array['100']) <> 1 then
        raise exception 'marking one uploaded release did not mark exactly one row';
    end if;
    if (select payload_path from public.metadata_cache where resource_id = '100')
        is distinct from 'releases/100.json' then
        raise exception 'a moved release does not point at its object';
    end if;
    if (select payload from public.metadata_cache where resource_id = '100') is not null then
        raise exception 'a moved release still holds its inline payload';
    end if;

    -- Marking again is a no-op, so a slow duplicate batch changes nothing.
    if public.mark_release_payloads_offloaded(array['100']) <> 0 then
        raise exception 'marking an already moved release touched it again';
    end if;

    if public.release_payloads_left() <> 1 then
        raise exception 'expected one release left, counted %', public.release_payloads_left();
    end if;

    -- Searches and NTS stay inline whatever anybody marks.
    perform public.mark_release_payloads_offloaded(array['q=x', 'show/ep']);
    select count(*) into n from public.metadata_cache
    where resource_id in ('q=x', 'show/ep') and payload is not null;
    if n <> 2 then raise exception 'a payload that is not a release was moved'; end if;

    -- A row with neither is refused.
    begin
        insert into public.metadata_cache (provider, resource_type, resource_id, payload, payload_path)
        values ('discogs', 'release', '300', null, null);
        raise exception 'a row with no payload anywhere was accepted';
    exception when check_violation then
        null;
    end;

    -- And the app's key can do none of it.
    if has_function_privilege('anon', 'public.mark_release_payloads_offloaded(text[])', 'execute') then
        raise exception 'the app key can mark releases moved';
    end if;

    raise notice 'offload smoke: all checks passed';
end $$;

rollback;

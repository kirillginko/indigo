-- 0082: an artist whose own Discogs entry has no picture says so
-- (DIG-REMEDIATION-PLAN.md §9). Approved with the portrait remediation,
-- 2026-10-13.
--
-- 0081 recorded that as a plain miss: no address, no state. The reader skips
-- such rows, so the name simply went unanswered -- and a device keeps a face
-- for a name the catalogue does not answer. 25 of the 121 wrong portraits
-- were corrected this way: the stranger's face was taken off the row, and
-- every device that had cached it went on showing it.
--
-- The worker now records them as 'verified' with no address and the entry's
-- id: the row knows who it is, and who it is has no picture. The reader counts
-- such rows, so a name all of whose rows say so answers 'withheld' -- no face
-- -- which is what tells a device to drop the one it cached. A name with a
-- picture on another row still shows it, as before.

create or replace function public.portrait_states_for_artists(p_names text[])
returns jsonb
language sql
stable
set search_path = public
as $function$
    with named as (
        select a.normalized_name as name, w.original_url as url,
               coalesce(w.portrait_state, 'unresolved') as state, w.portrait_discogs_id as pictured
        from public.artists a
        join public.artwork w on w.entity_type = 'artist' and w.entity_id = a.id
        where a.normalized_name = any(p_names)
          and (w.original_url is not null or w.portrait_state in ('withheld', 'verified'))
    ),
    per_name as (
        select name,
               count(distinct url) filter (where url is not null) as addresses,
               bool_or(state = 'withheld') as any_withheld,
               bool_or(state = 'verified' and url is not null) as any_verified,
               (array_agg(url order by (state = 'verified') desc, url) filter (where url is not null))[1] as url,
               (array_agg(state order by (state = 'verified') desc, url) filter (where url is not null))[1] as state,
               (array_agg(pictured order by (state = 'verified') desc, url) filter (where url is not null))[1] as pictured
        from named group by name
    )
    select coalesce(jsonb_object_agg(name,
        case when addresses > 1 or addresses = 0 or (any_withheld and not any_verified)
             then jsonb_build_object('state', 'withheld')
             else jsonb_strip_nulls(jsonb_build_object('url', url, 'state', state, 'discogsID', pictured)) end), '{}'::jsonb)
    from per_name;
$function$;

grant execute on function public.portrait_states_for_artists(text[]) to anon, authenticated, service_role;

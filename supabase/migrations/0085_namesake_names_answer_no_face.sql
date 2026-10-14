-- 0085: a name the catalogue files under two Discogs identities answers no
-- face by name (DIG-REMEDIATION-PLAN.md §14). Approved with the TestFlight
-- review, 2026-10-14.
--
-- "Danny Brown" was two rows: an NTS row wrongly carrying 455494 (an engineer
-- in Dallas, with a verified picture) and 2146925 (another engineer, no
-- picture). Asked by name, the catalogue answered the one picture there was,
-- and For You showed the engineer's face on a card about the Warp rapper,
-- who is a third Danny Brown (1059062). Where a name's rows carry more than
-- one identity, the name is a known namesake pair: no answer by name can say
-- whose face it is. Pages that know their artist's id are not affected.

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
    identities as (
        select a.normalized_name as name, count(distinct e.external_id) as entries
        from public.artists a
        join public.external_ids e on e.entity_type = 'artist' and e.entity_id = a.id
                                  and e.provider in ('discogs', 'musicbrainz_discogs')
        where a.normalized_name = any(p_names)
        group by 1
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
    select coalesce(jsonb_object_agg(p.name,
        case when p.addresses > 1 or p.addresses = 0 or (p.any_withheld and not p.any_verified)
                  or coalesce(i.entries, 0) > 1
             then jsonb_build_object('state', 'withheld')
             else jsonb_strip_nulls(jsonb_build_object('url', p.url, 'state', p.state, 'discogsID', p.pictured)) end), '{}'::jsonb)
    from per_name p left join identities i on i.name = p.name;
$function$;

grant execute on function public.portrait_states_for_artists(text[]) to anon, authenticated, service_role;

-- Devices hear of it through the change feed (0083): the portraits of those
-- names are stamped as changed, so a face cached under the name is dropped.
update public.artwork w
   set portrait_changed_at = now()
  from public.artists a
 where w.entity_type = 'artist' and w.entity_id = a.id and w.original_url is not null
   and a.normalized_name in (
       select a2.normalized_name from public.artists a2
       join public.external_ids e on e.entity_type = 'artist' and e.entity_id = a2.id
                                 and e.provider in ('discogs', 'musicbrainz_discogs')
       group by 1 having count(distinct e.external_id) > 1);

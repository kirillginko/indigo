-- 0084: the remote switch for shared DIG enrichment (DIG-REMEDIATION-PLAN.md
-- §11). Approved 2026-10-13.
--
-- DIG reads the catalogue pilot's bundles only while this says so. It is a
-- function, not a table -- nothing to store, nothing to grow -- and it is
-- independent of every knowledge generation: the October 11 generation is not
-- read or touched. Turning enrichment off, or changing who receives it, is
-- one `create or replace` (Scripts/dig-enrichment-switch.sh); no app release.
--
--   enabled               false switches every device off at its next check
--   cohorts               who receives it: "debug" (development builds),
--                         "testflight", "appstore". Nobody else, ever.
--   manifest              the one pilot manifest devices may read, by digest:
--                         the 300 approved artists and nothing a later
--                         publication adds
--   ttlSeconds            how long a device trusts this before asking again
--   offlineGraceSeconds   how long a device that cannot ask keeps the last
--                         answer before treating enrichment as off
--
-- Devices that have never read this treat enrichment as off.

create or replace function public.dig_enrichment_config()
returns jsonb
language sql
immutable
as $function$
    select jsonb_build_object(
        'version', 1,
        'enabled', true,
        'cohorts', jsonb_build_array('debug'),
        'manifest', '5d20a44c4bc755b009b4ddd5c5906b3289db31c7d91c542fea520df06623de4a',
        'ttlSeconds', 900,
        'offlineGraceSeconds', 86400
    );
$function$;

create or replace function public.app_callable_functions()
returns text[]
language sql
immutable
as $function$
    select array[
        'app_callable_functions',
        'artist_radio_appearances',
        'artist_radio_relations',
        'artist_radio_summary',
        'credit_row_count',
        'dig_enrichment_config',
        'dig_radio_for_artists',
        'enrichment_queue_health',
        'episode_tracklist',
        'explore_knowledge',
        'label_radio_summary',
        'portrait_changes_since',
        'portrait_states_for_artists',
        'portraits_for_artists',
        'release_cache_coverage',
        'request_artist_shelf',
        'request_release_cache',
        'request_scene_roster',
        'search_archives',
        'search_catalog'
    ]
$function$;

grant execute on function public.dig_enrichment_config() to anon, authenticated, service_role;

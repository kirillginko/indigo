-- The R2 move's lane stops itself when the move is done.
--
-- Scheduled every minute (0051, 0052). Once there is nothing left to move,
-- the release job finds nothing in one indexed query, but the inline job's
-- "anything still inline?" is a scan of `metadata_cache` -- every minute, for
-- nothing, on a plan whose disk budget has already run low once. So the
-- worker unschedules the lane when the release move reports done, and the
-- inline job remembers it finished (a checkpoint row) and asks nothing after.
--
-- Security definer so the worker, as service_role, may unschedule a cron job.
--
-- Safe to re-run.

create or replace function public.unschedule_r2_move()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
    if public.has_function('cron', 'schedule') then
        perform cron.unschedule(jobname) from cron.job
        where jobname in ('indigo-r2-move-enqueue', 'indigo-r2-move-drain');
    end if;
    return 'r2 move unscheduled';
end $$;

revoke all on function public.unschedule_r2_move() from public, anon, authenticated;
grant execute on function public.unschedule_r2_move() to service_role;

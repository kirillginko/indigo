-- A budget for R2, so the free tier is never exceeded.
--
-- R2's free tier (Cloudflare's pricing page, 2026-09-24): 10 GB-month of
-- Standard storage, 1 million Class A operations (writes: PutObject,
-- ListObjects) and 10 million Class B (reads) a month. Past it, Cloudflare
-- bills; there is no cap to set on their side. So the cap is here: every
-- write to R2 reserves its place first, and is refused once the month's
-- writes reach 80% of the free million, or once everything ever written
-- reaches 8 GB.
--
-- The storage figure is every byte ever written, never reduced by an
-- overwrite or a delete. It overstates what R2 holds -- a release fetched
-- twice is counted twice -- which is the safe direction: it stops early,
-- never late. `r2_budget_reset_storage()` is for after checking the real
-- figure in the Cloudflare dashboard.
--
-- Reads are not counted. The app reads the public bucket directly, past the
-- backend; ten million a month is about 330,000 artist pages.
--
-- Safe to re-run.

create table if not exists public.r2_usage (
    -- 'YYYY-MM' for a month's writes; 'all' for everything ever written.
    period text primary key,
    writes bigint not null default 0,
    bytes bigint not null default 0,
    refused bigint not null default 0,
    updated_at timestamptz not null default now()
);

alter table public.r2_usage enable row level security;
revoke all on public.r2_usage from anon, authenticated;

create or replace function public.r2_monthly_write_cap()
returns bigint language sql immutable as $$ select 800000::bigint $$;

create or replace function public.r2_storage_cap_bytes()
returns bigint language sql immutable as $$ select (8::bigint * 1024 * 1024 * 1024) $$;

-- Reserves room for `p_writes` objects totalling `p_bytes`, and says whether
-- it may go ahead. Both counters move together or not at all; a refusal is
-- counted too, so the report says when the cap started to bite.
create or replace function public.r2_reserve(p_writes int, p_bytes bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_month text := to_char(now() at time zone 'utc', 'YYYY-MM');
    v_month_writes bigint;
    v_total_bytes bigint;
begin
    if coalesce(p_writes, 0) <= 0 then
        return true;
    end if;

    insert into public.r2_usage (period) values (v_month), ('all')
    on conflict (period) do nothing;

    -- Locked in a fixed order, so two writers cannot each see room the
    -- other is about to take.
    select writes into v_month_writes from public.r2_usage where period = v_month for update;
    select bytes into v_total_bytes from public.r2_usage where period = 'all' for update;

    if v_month_writes + p_writes > public.r2_monthly_write_cap()
       or v_total_bytes + coalesce(p_bytes, 0) > public.r2_storage_cap_bytes() then
        update public.r2_usage set refused = refused + p_writes, updated_at = now()
        where period = v_month;
        return false;
    end if;

    update public.r2_usage
    set writes = writes + p_writes, bytes = bytes + coalesce(p_bytes, 0), updated_at = now()
    where period in (v_month, 'all');
    return true;
end $$;

revoke all on function public.r2_reserve(int, bigint) from public, anon, authenticated;
grant execute on function public.r2_reserve(int, bigint) to service_role;

-- Where the budget stands, for a person to read.
create or replace function public.r2_budget()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'month', to_char(now() at time zone 'utc', 'YYYY-MM'),
        'month_writes', coalesce((select writes from public.r2_usage
                                  where period = to_char(now() at time zone 'utc', 'YYYY-MM')), 0),
        'month_write_cap', public.r2_monthly_write_cap(),
        'month_refused', coalesce((select refused from public.r2_usage
                                   where period = to_char(now() at time zone 'utc', 'YYYY-MM')), 0),
        'bytes_written_ever', coalesce((select bytes from public.r2_usage where period = 'all'), 0),
        'storage_cap_bytes', public.r2_storage_cap_bytes()
    );
$$;

revoke all on function public.r2_budget() from public, anon, authenticated;
grant execute on function public.r2_budget() to service_role;

-- After checking the bucket's real size in Cloudflare: sets the running
-- total to it, so overwrites counted twice stop counting against the cap.
create or replace function public.r2_budget_reset_storage(p_actual_bytes bigint)
returns void
language sql
security definer
set search_path = public
as $$
    insert into public.r2_usage (period, bytes) values ('all', greatest(p_actual_bytes, 0))
    on conflict (period) do update set bytes = excluded.bytes, updated_at = now();
$$;

revoke all on function public.r2_budget_reset_storage(bigint) from public, anon, authenticated;
grant execute on function public.r2_budget_reset_storage(bigint) to service_role;

-- The one release written by the test on 2026-09-24, before this existed.
select public.r2_reserve(1, 12488);

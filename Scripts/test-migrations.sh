#!/usr/bin/env bash
#
# Applies every migration to a throwaway Postgres and runs the schema's own
# checks against it.
#
# The backend was built without one of these. Migrations were validated by
# parsing, which catches syntax and nothing else, and three bugs reached the
# live project as a result — a scheduler that could not detect pg_cron, an
# array append that was really an array concatenation, and a label edge that
# multiplied its evidence by the artist's release count. All three are the kind
# of thing that only shows up when the SQL actually runs.
#
# Needs a local Postgres 17 (`brew install postgresql@17`). Nothing here touches
# the real project: it builds a cluster in a temporary directory, uses it, and
# deletes it.
#
#   Scripts/test-migrations.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}"
PORT="${PGPORT_TEST:-55432}"

if [ ! -x "$PGBIN/initdb" ]; then
    echo "No Postgres at $PGBIN — brew install postgresql@17, or set PGBIN" >&2
    exit 1
fi
export PATH="$PGBIN:$PATH"
# initdb refuses to start a postmaster that went multithreaded, which is what
# an unset locale does on macOS.
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

DATA="$(mktemp -d)"
# Kept short deliberately: a Unix socket path over 103 bytes is refused, and the
# obvious place for scratch files on this machine is already longer than that.
SOCKET="$(mktemp -d /tmp/indigopg.XXXXXX)"

cleanup() {
    pg_ctl -D "$DATA/data" stop -m immediate >/dev/null 2>&1 || true
    rm -rf "$DATA" "$SOCKET"
}
trap cleanup EXIT

initdb -D "$DATA/data" -U postgres --auth=trust >"$DATA/initdb.log" 2>&1
pg_ctl -D "$DATA/data" \
    -o "-p $PORT -k $SOCKET -c listen_addresses=''" \
    -l "$DATA/server.log" start >/dev/null

for _ in $(seq 1 30); do
    pg_isready -h "$SOCKET" -p "$PORT" -q && break
    sleep 0.5
done

run() { psql -h "$SOCKET" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

echo "· stubbing what Supabase provides"
run -f "$ROOT/supabase/tests/00_supabase_stubs.sql"
run -f "$ROOT/supabase/tests/01_cron_stubs.sql"

echo "· applying migrations"
for migration in "$ROOT"/supabase/migrations/*.sql; do
    printf '    %s ' "$(basename "$migration")"
    if run -f "$migration" >/dev/null 2>"$DATA/err.log"; then
        echo "ok"
    else
        echo "FAILED"
        sed 's/^/        /' "$DATA/err.log" >&2
        exit 1
    fi
done

echo "· scheduling"
run -tAc "select public.schedule_indigo_enrichment(
    'https://example.supabase.co/functions/v1/enrichment-worker', 'test-key');" \
    | sed 's/^/    /'

echo "· drain batch"
# As a project that scheduled the drain before 0022 existed: its job still asks
# for fifteen. Applying 0022 again has to move it to thirty.
run -c "update cron.job set command = replace(command, '''limit'', 30', '''limit'', 15') where jobname = 'indigo-drain-queue';"
run -f "$ROOT/supabase/migrations/0022_drain_thirty_jobs.sql" >/dev/null
run -c "do \$\$ begin if not exists (select 1 from cron.job where jobname = 'indigo-drain-queue' and command like '%''limit'', 30%') then raise exception 'the running drain job still asks for fewer than thirty'; end if; end \$\$;"
echo "    a drain that was already running now asks for thirty"

echo "· portrait lane"
# As a project whose drain was running before 0024: no lane yet. Applying 0024
# again has to add one that claims only portraits.
run -c "delete from cron.job where jobname = 'indigo-drain-portraits';"
run -f "$ROOT/supabase/migrations/0024_portrait_lane.sql" >/dev/null
run -c "do \$\$ begin if not exists (select 1 from cron.job where jobname = 'indigo-drain-portraits' and command like '%''job_type'', ''fetch_artist_portrait''%') then raise exception 'a running drain did not get a portrait lane'; end if; end \$\$;"
echo "    a drain that was already running now has a portrait lane"

echo "· privileges"
# As a project from before 0023: its internal functions granted to the app's
# key by name. Applying 0023 again has to take that back.
run -c "grant execute on function public.enqueue_enrichment_job(text, text, text, jsonb, int, text, uuid) to anon, authenticated;"
run -f "$ROOT/supabase/migrations/0023_keep_the_queue_private.sql" >/dev/null
run -c "do \$\$ begin if has_function_privilege('anon', 'public.enqueue_enrichment_job(text, text, text, jsonb, int, text, uuid)', 'execute') then raise exception 'the app key can still fill the queue'; end if; end \$\$;"
echo "    a queue the app key could fill no longer can be"

echo "· checks"
run -f "$ROOT/supabase/tests/radio_smoke.sql" | sed 's/^/    /'
run -f "$ROOT/supabase/tests/scene_smoke.sql" | sed 's/^/    /'
run -f "$ROOT/supabase/tests/search_smoke.sql" | sed 's/^/    /'
run -f "$ROOT/supabase/tests/portrait_smoke.sql" | sed 's/^/    /'
run -f "$ROOT/supabase/tests/queue_smoke.sql" | sed 's/^/    /'

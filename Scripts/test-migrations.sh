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

echo "· checks"
run -f "$ROOT/supabase/tests/radio_smoke.sql" | sed 's/^/    /'

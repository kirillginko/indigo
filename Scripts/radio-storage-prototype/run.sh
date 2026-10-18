#!/usr/bin/env bash
#
# Radio storage prototype: synthetic tracklists in five shapes, measured in a
# throwaway local Postgres. Nothing here talks to the linked Supabase project
# or to R2: the cluster lives in a temporary directory, listens only on a unix
# socket inside it, and is deleted on exit.
#
#   Scripts/radio-storage-prototype/run.sh [lines]      # default 262478, the live table's size
#
# Needs a local Postgres (initdb, pg_ctl, psql; brew install postgresql@17) with
# pg_trgm, and python3.
#
set -euo pipefail

# Postgres on macOS refuses to start ("postmaster became multithreaded")
# without a valid locale in the environment.
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

LINES="${1:-262478}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/radio-storage.XXXXXX")"
DATA="$WORK/data"
# A unix socket path must fit in ~100 bytes, which $TMPDIR on macOS does not.
SOCKET="$(mktemp -d /tmp/rsp.XXXXXX)"

stop() {
    pg_ctl -D "$DATA" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$WORK" "$SOCKET"
}
trap stop EXIT

echo "· generating $LINES synthetic lines"
python3 -I "$HERE/generate.py" "$LINES" "$WORK/synth"

echo "· starting a throwaway cluster in $WORK"
initdb -D "$DATA" -U prototype --auth=trust --no-instructions >/dev/null
pg_ctl -D "$DATA" -o "-k $SOCKET -c listen_addresses='' -p 54329 -c shared_buffers=256MB -c work_mem=32MB -c maintenance_work_mem=256MB" \
    -l "$WORK/postgres.log" -w start >/dev/null || { cat "$WORK/postgres.log" >&2; exit 1; }
createdb -h "$SOCKET" -p 54329 -U prototype radio
PSQL=(psql -X -q -h "$SOCKET" -p 54329 -U prototype -d radio -v ON_ERROR_STOP=1)

"${PSQL[@]}" -f "$HERE/schema.sql"
"${PSQL[@]}" -c "\copy artists from '$WORK/synth/artists.tsv'"
"${PSQL[@]}" -c "\copy radio_shows (id, title) from '$WORK/synth/shows.tsv'"
"${PSQL[@]}" -c "\copy radio_episodes (id, radio_show_id, provider, external_id, title, aired_at, archive_url, tracklist_status) from '$WORK/synth/episodes.tsv'"
"${PSQL[@]}" -c "\copy staging_lines from '$WORK/synth/lines.tsv'"

echo "· building every plan"
"${PSQL[@]}" -f "$HERE/build.sql"
"${PSQL[@]}" -f "$HERE/measure.sql"
"${PSQL[@]}" -f "$HERE/queries.sql"
"${PSQL[@]}" -f "$HERE/migration.sql"

echo
echo "· R2 documents, one per broadcast episode"
python3 -I "$HERE/documents.py" "$WORK/synth"

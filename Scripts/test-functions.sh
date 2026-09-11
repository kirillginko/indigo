#!/usr/bin/env bash
#
# Runs the Edge Functions' own tests.
#
# `Scripts/test-migrations.sh` proves the SQL runs; nothing proved the
# TypeScript in front of it did anything sensible. What these cover is the
# normalizer — which search hits become rows in `artists` and `labels`, and
# under what name — because every mistake it can make is silent. A row filed
# under Discogs' own "Nirvana (2)" matches a search perfectly and then opens
# onto a page nothing is stored behind.
#
#   Scripts/test-functions.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v deno >/dev/null 2>&1; then
    echo "No deno on PATH — brew install deno" >&2
    exit 1
fi

echo "· type checking"
for entry in "$ROOT"/supabase/functions/*/index.ts; do
    printf '    %s ' "$(basename "$(dirname "$entry")")"
    deno check "$entry" >/dev/null 2>&1 && echo "ok" || { echo "FAILED"; deno check "$entry"; exit 1; }
done

echo "· tests"
deno test --allow-net --allow-env "$ROOT/supabase/functions/"

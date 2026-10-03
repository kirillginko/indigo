#!/usr/bin/env bash
#
# The controlled move of the real UserData store to schema V7 (counter
# components). Read-only against the store, except for the backup it writes.
#
#   Scripts/v7-move.sh pre     before the first V7 launch: refuse if anything
#                              Indigo is running, back the store up, and record
#                              what it holds and what the move must produce
#   Scripts/v7-move.sh post    after a V7 launch (run it after every relaunch):
#                              check the store against what `pre` recorded
#
# The expected counts are derived from the store as it is read here, never
# from a number in a plan.
#
set -uo pipefail
MODE="${1:-}"
SUPPORT="${INDIGO_SUPPORT:-$HOME/Library/Containers/com.oblaststudio.Indigo/Data/Library/Application Support}"
STORE="$SUPPORT/UserData.store"
STATE="$SUPPORT/v7-move"
q() { sqlite3 -readonly "$STORE" "$1"; }

running() { ps -axo command | grep -E "Indigo.app/Contents/MacOS/Indigo" | grep -v grep; }

# One line per visit and step: what it says. The move must not change a line.
projection() {
    q "select 'visit|'||ZNODEID||'|'||ZVISITS||'|'||printf('%.6f',ZFIRSTVISITEDAT)||'|'||printf('%.6f',ZLASTVISITEDAT) from ZDIGVISIT
       union all select 'step|'||ZIDENTITY||'|'||ZCOUNT||'|'||printf('%.6f',ZLASTAT) from ZDIGSTEP" | sort
}

digest() { "$(dirname "$0")/userdata-digest.py" "$STORE"; }

case "$MODE" in
pre)
    if running >/dev/null; then echo "REFUSED: Indigo is running:"; running; exit 2; fi
    if q "select 1 from sqlite_master where name='ZDIGCOUNTER'" | grep -q 1; then echo "REFUSED: the store is already V7"; exit 2; fi
    BACKUP="$HOME/Documents/IndigoBackups/before-v7-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP" "$STATE"
    sqlite3 -readonly "$STORE" ".backup '$BACKUP/UserData.store'"
    for f in UserData.store UserData.store-wal UserData.store-shm split-state.json; do
        [ -e "$SUPPORT/$f" ] && cp -p "$SUPPORT/$f" "$BACKUP/raw-$f"
    done
    (cd "$BACKUP" && shasum -a 256 * > SHA256SUMS)
    echo "backup: $BACKUP"

    projection > "$STATE/projection-before.txt"
    digest | grep -E "CrateItem|ListeningEvent" > "$STATE/untouched-before.txt"
    q "select count(distinct ZNODEID) from ZDIGVISIT where ZVISITS > 0" > "$STATE/expected-visit-counters"
    q "select count(distinct ZIDENTITY) from ZDIGSTEP where ZCOUNT > 0" > "$STATE/expected-step-counters"
    q "select coalesce(sum(ZVISITS),0) from ZDIGVISIT" > "$STATE/visit-total"
    q "select coalesce(sum(ZCOUNT),0) from ZDIGSTEP" > "$STATE/step-total"
    echo "$BACKUP" > "$STATE/backup-path"
    echo "store now:"; digest
    echo "visit rows $(q 'select count(*) from ZDIGVISIT'), total $(cat "$STATE/visit-total"); step rows $(q 'select count(*) from ZDIGSTEP'), total $(cat "$STATE/step-total")"
    echo "rows for one node twice: visits $(q 'select count(*) from (select 1 from ZDIGVISIT group by ZNODEID having count(*)>1)'), steps $(q 'select count(*) from (select 1 from ZDIGSTEP group by ZIDENTITY having count(*)>1)')"
    echo "the move must write: $(cat "$STATE/expected-visit-counters") visit and $(cat "$STATE/expected-step-counters") step base components, and 1 generation row"
    ;;
post)
    [ -f "$STATE/projection-before.txt" ] || { echo "no 'pre' record"; exit 2; }
    fail=0
    ok() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got $1, expected $2)"; fail=1; fi; }
    sqlite3 "$STORE" 'pragma wal_checkpoint(passive)' >/dev/null 2>&1 || true
    echo "checks:"
    ok "$(q "select 1 from sqlite_master where name='ZDIGCOUNTER'")" "1" "the store is V7"
    ok "$([ -e "$SUPPORT/counter-baseline-pending" ] && echo pending || echo clear)" "clear" "no move left owing"
    if digest | grep -E "CrateItem|ListeningEvent" | diff -q - "$STATE/untouched-before.txt" >/dev/null; then echo "  ok    crate and listening events identical"; else echo "  NOTE  crate or events changed (expected only if you used the app):"; digest | grep -E "CrateItem|ListeningEvent"; fi
    if projection | diff -q - "$STATE/projection-before.txt" >/dev/null; then echo "  ok    every visit and step says exactly what it said"; else echo "  NOTE  visits or steps changed (expected only if you used the app):"; projection | diff - "$STATE/projection-before.txt" | head -6; fi
    ok "$(q 'select coalesce(sum(ZVISITS),0) from ZDIGVISIT')" "$(cat "$STATE/visit-total")" "visit total"
    ok "$(q 'select coalesce(sum(ZCOUNT),0) from ZDIGSTEP')" "$(cat "$STATE/step-total")" "step total"
    ok "$(q "select count(*) from ZDIGCOUNTER where ZKINDRAW='visit' and ZDEVICEID='base'")" "$(cat "$STATE/expected-visit-counters")" "one base component per visit counter"
    ok "$(q "select count(*) from ZDIGCOUNTER where ZKINDRAW='step' and ZDEVICEID='base'")" "$(cat "$STATE/expected-step-counters")" "one base component per step counter"
    ok "$(q "select count(*) from ZDIGCOUNTER where ZKINDRAW='generation'")" "1" "one generation row"
    ok "$(q 'select count(*) from (select 1 from ZDIGCOUNTER group by ZKINDRAW, ZKEY, ZDEVICEID having count(*)>1)')" "0" "no (kind, key, device) twice"
    ok "$(q 'select count(*) from (select 1 from ZDIGCOUNTER group by ZID having count(*)>1)')" "0" "no component id twice"
    python3 - "$STORE" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
comps = {}
for kind, key, dev, count in db.execute("select ZKINDRAW, ZKEY, ZDEVICEID, ZCOUNT from ZDIGCOUNTER where ZKINDRAW in ('visit','step')"):
    d = comps.setdefault((kind, key), {}); d[dev] = max(d.get(dev, 0), count)
bad = sum(1 for n, v in db.execute("select ZNODEID, ZVISITS from ZDIGVISIT") if v > 0 and sum(comps.get(("visit", n), {}).values()) != v)
bad += sum(1 for i, c in db.execute("select ZIDENTITY, ZCOUNT from ZDIGSTEP") if c > 0 and sum(comps.get(("step", i), {}).values()) != c)
writers = sorted({w for d in comps.values() for w in d})
print(f"  {'ok  ' if bad == 0 else 'FAIL'}  every visit and step equals the sum of its components ({bad} differ); writers {writers}")
sys.exit(1 if bad else 0)
PY
    [ $? -eq 0 ] || fail=1
    echo "store now:"; digest
    [ $fail -eq 0 ] && echo "RESULT: the move holds" || echo "RESULT: FAILED"
    exit $fail
    ;;
*)
    echo "usage: $0 pre|post"; exit 2 ;;
esac

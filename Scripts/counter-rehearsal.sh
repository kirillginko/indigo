#!/usr/bin/env bash
#
# Rehearses the move of the counts into components (schema V7) on a copy of
# UserData.store, and checks it from outside the app: every visit and step must
# say exactly what it said before, and must equal the sum of its components.
# Reads the real store; writes only the copy.
#
#   Scripts/counter-rehearsal.sh <path-to-Indigo.app>
#
set -euo pipefail
APP="$1"
SUPPORT="${INDIGO_SUPPORT:-$HOME/Library/Containers/com.oblaststudio.Indigo/Data/Library/Application Support}"
DEST="$SUPPORT/CounterRehearsal"
rm -rf "$DEST"; mkdir -p "$DEST"
sqlite3 -readonly "$SUPPORT/UserData.store" ".backup '$DEST/UserData.store'"
sqlite3 "$DEST/UserData.store" 'pragma journal_mode=delete' >/dev/null

dump() {
    sqlite3 -readonly "$1" "select 'visit|'||ZNODEID||'|'||ZVISITS||'|'||printf('%.6f',ZFIRSTVISITEDAT)||'|'||printf('%.6f',ZLASTVISITEDAT) from ZDIGVISIT
                            union all select 'step|'||ZIDENTITY||'|'||ZCOUNT||'|'||printf('%.6f',ZLASTAT) from ZDIGSTEP" | sort
}
dump "$DEST/UserData.store" > "$DEST/before.txt"
echo "before: $(sqlite3 -readonly "$DEST/UserData.store" "select count(*)||' visits summing '||sum(ZVISITS) from ZDIGVISIT"), $(sqlite3 -readonly "$DEST/UserData.store" "select count(*)||' steps summing '||sum(ZCOUNT) from ZDIGSTEP")"

"$APP/Contents/MacOS/Indigo" -INDIGO_REHEARSE_COUNTERS 2>&1 | grep -vE "CoreData: |^\s*$|flock|metallib|AFIsDevice"

sqlite3 "$DEST/UserData.store" 'pragma wal_checkpoint(truncate)' >/dev/null 2>&1 || true
dump "$DEST/UserData.store" > "$DEST/after.txt"
if diff -q "$DEST/before.txt" "$DEST/after.txt" >/dev/null; then echo "every visit and step says exactly what it said before"; else echo "CHANGED:"; diff "$DEST/before.txt" "$DEST/after.txt" | head -10; fi

python3 - "$DEST/UserData.store" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
comps = {}
for kind, key, dev, count in db.execute("select ZKINDRAW, ZKEY, ZDEVICEID, ZCOUNT from ZDIGCOUNTER"):
    comps.setdefault((kind, key), {}).setdefault(dev, 0)
    comps[(kind, key)][dev] = max(comps[(kind, key)][dev], count)
devices = {d for c in comps.values() for d in c}
bad = 0
for node, visits in db.execute("select ZNODEID, ZVISITS from ZDIGVISIT"):
    total = sum(comps.get(("visit", node), {}).values())
    if visits > 0 and total != visits: bad += 1
for ident, count in db.execute("select ZIDENTITY, ZCOUNT from ZDIGSTEP"):
    total = sum(comps.get(("step", ident), {}).values())
    if count > 0 and total != count: bad += 1
print(f"components: {sum(len(c) for c in comps.values())} over {len(comps)} counters; writers {sorted(devices)}")
print(f"rows whose count is not the sum of their components: {bad}")
PY

#!/usr/bin/env bash
#
# Read-only look at where the move from one store to two has got to. Opens
# nothing for writing and changes nothing.
#
#   Scripts/split-inspect.sh [backup-directory]
#
# With a backup directory (from split-backup.sh) it also checks that the three
# old store files still have the checksums they had before the move.
#
set -uo pipefail

SUPPORT="${INDIGO_SUPPORT:-$HOME/Library/Containers/com.oblaststudio.Indigo/Data/Library/Application Support}"
BACKUP="${1:-}"
EXPECT_CRATE="${EXPECT_CRATE:-91}"
EXPECT_EVENTS="${EXPECT_EVENTS:-1097}"
EXPECT_VISITS="${EXPECT_VISITS:-1268}"
EXPECT_STEPS="${EXPECT_STEPS:-1482}"

q() { sqlite3 -readonly "$1" "$2" 2>/dev/null; }
flag() { if [ "$1" = "$2" ]; then echo "ok"; else echo "CHECK (expected $2)"; fi; }

echo "== files"
for f in default.store default.store-wal default.store-shm UserData.store Local.store split-state.json pre-split-v5.store; do
    if [ -e "$SUPPORT/$f" ]; then printf "  %-22s %s bytes\n" "$f" "$(stat -f %z "$SUPPORT/$f")"; else printf "  %-22s absent\n" "$f"; fi
done

echo "== state"
if [ -f "$SUPPORT/split-state.json" ]; then
    python3 - "$SUPPORT/split-state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for k in ("phase", "fresh", "splitLaunches", "finalized", "archived", "legacyCounts", "migratedCounts"):
    print(f"  {k}: {s.get(k)}")
PY
else
    echo "  no split-state.json: the move has not run (or has not been recorded)"
fi

if [ -n "$BACKUP" ] && [ -f "$BACKUP/SHA256SUMS" ]; then
    echo "== the old store, against the backup"
    ( cd "$SUPPORT" && for f in default.store default.store-wal default.store-shm; do
        want=$(grep " $f\$" "$BACKUP/SHA256SUMS" | awk '{print $1}')
        [ -z "$want" ] && continue
        if [ -f "$f" ]; then have=$(shasum -a 256 "$f" | awk '{print $1}'); else have="(absent)"; fi
        if [ "$want" = "$have" ]; then echo "  $f: identical to the backup"; else echo "  $f: DIFFERS from the backup ($have)"; fi
    done )
fi

if [ -f "$SUPPORT/UserData.store" ]; then
    U="$SUPPORT/UserData.store"
    echo "== UserData.store"
    c=$(q "$U" "select count(*) from ZCRATEITEM");     echo "  crate items      $c   $(flag "$c" "$EXPECT_CRATE")"
    c=$(q "$U" "select count(*) from ZLISTENINGEVENT"); echo "  listening events $c   $(flag "$c" "$EXPECT_EVENTS")"
    c=$(q "$U" "select count(*) from ZDIGVISIT");      echo "  dig visits       $c   $(flag "$c" "$EXPECT_VISITS")"
    c=$(q "$U" "select count(*) from ZDIGSTEP");       echo "  dig steps        $c   $(flag "$c" "$EXPECT_STEPS")"
    echo "  rows that must not be here:"
    for t in ZRECORDING ZMEDIAAPPEARANCE ZSTOREDEDGE ZDISCOGSARTIST ZTRACK; do
        printf "    %-18s %s\n" "$t" "$(q "$U" "select count(*) from $t")"
    done
    echo "  crate rows with a snapshot: $(q "$U" "select count(*) from ZCRATEITEM where ZKINDRAW='recording' and (ZMATCHKEY<>'' or ZUNKNOWNCODE is not null)") of $(q "$U" "select count(*) from ZCRATEITEM where ZKINDRAW='recording'")"
    echo "  placeholder visits (key#code):"
    q "$U" "select '    '||replace(ZNODEID, char(31), '|')||'  visits='||ZVISITS from ZDIGVISIT where ZNODEID like 'recording:%#%'"
    echo "  duplicate visit nodes: $(q "$U" "select count(*) from (select ZNODEID from ZDIGVISIT group by 1 having count(*)>1)")   duplicate steps: $(q "$U" "select count(*) from (select ZIDENTITY from ZDIGSTEP group by 1 having count(*)>1)")"
fi

if [ -f "$SUPPORT/Local.store" ]; then
    L="$SUPPORT/Local.store"
    echo "== Local.store"
    for t in ZRECORDING ZTRACK ZSTOREDEDGE ZDISCOGSRELEASERECORD ZARTISTPORTRAIT; do
        printf "  %-22s %s\n" "$t" "$(q "$L" "select count(*) from $t")"
    done
    echo "  the listener's tables here (must be 0): crate=$(q "$L" "select count(*) from ZCRATEITEM") events=$(q "$L" "select count(*) from ZLISTENINGEVENT") visits=$(q "$L" "select count(*) from ZDIGVISIT") steps=$(q "$L" "select count(*) from ZDIGSTEP")"
    echo "  recording identity collisions (must be 0): $(q "$L" "select count(*) from (select ZMATCHKEY, coalesce(ZUNKNOWNCODE,'') c from ZRECORDING where ZMATCHKEY<>'' group by 1,2 having count(*)>1)")"
fi

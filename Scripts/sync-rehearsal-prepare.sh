#!/usr/bin/env bash
#
# Makes the copy of UserData.store that the sync rehearsal runs on. Uses
# sqlite's own backup, so the copy is consistent even if the log has not been
# folded in. Reads the real store; writes only the copy.
#
#   Scripts/sync-rehearsal-prepare.sh
#
set -euo pipefail
SUPPORT="${INDIGO_SUPPORT:-$HOME/Library/Containers/com.oblaststudio.Indigo/Data/Library/Application Support}"
DEST="$SUPPORT/SyncRehearsal"
rm -rf "$DEST"; mkdir -p "$DEST"
sqlite3 -readonly "$SUPPORT/UserData.store" ".backup '$DEST/UserDataSyncRehearsal.store'"
sqlite3 "$DEST/UserDataSyncRehearsal.store" 'pragma journal_mode=delete' >/dev/null
echo "copy: $DEST/UserDataSyncRehearsal.store"
"$(dirname "$0")/userdata-digest.py" "$DEST/UserDataSyncRehearsal.store"

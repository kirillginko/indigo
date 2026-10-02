#!/usr/bin/env bash
#
# One extra copy of the listener's old store, outside Indigo's own directory,
# before the first real two-store launch. The move does not need it -- it never
# opens or changes default.store -- but this is the one time a second copy is
# worth having.
#
#   Scripts/split-backup.sh [destination-directory]
#
# Copies default.store, default.store-wal and default.store-shm, and writes
# their SHA-256 sums and sizes beside them. Deletes nothing. Refuses to run
# while Indigo is open. The default destination is in your home folder, not
# /tmp, so it survives a reboot.
#
# What this is a way back to: the store as it was *before* the move. Going back
# to it, and to a build that opens it, is safe only while no one has used the
# split build for real. Once something has been crated, played or dug into on
# UserData.store, reverting discards those newer changes, and the old store --
# or this copy -- does not have them.
#
set -euo pipefail

SUPPORT="${INDIGO_SUPPORT:-$HOME/Library/Containers/com.oblaststudio.Indigo/Data/Library/Application Support}"
DEST="${1:-$HOME/Indigo-pre-split-backup-$(date +%Y%m%d-%H%M%S)}"

if pgrep -f "Indigo.app/Contents/MacOS/Indigo" >/dev/null; then
    echo "Indigo is running. Quit it (and stop the Xcode run) first." >&2
    exit 1
fi
if [ ! -f "$SUPPORT/default.store" ]; then
    echo "No default.store at $SUPPORT" >&2
    exit 1
fi
if [ -e "$DEST" ]; then
    echo "$DEST already exists; refusing to write over it." >&2
    exit 1
fi

mkdir -p "$DEST"
for f in default.store default.store-wal default.store-shm; do
    if [ -f "$SUPPORT/$f" ]; then cp -p "$SUPPORT/$f" "$DEST/$f"; fi
done

(
    cd "$DEST"
    shasum -a 256 default.store* > SHA256SUMS
    ls -l default.store* | awk '{print $5, $9}' > SIZES
)

echo "Backed up to: $DEST"
cat "$DEST/SHA256SUMS"
echo
echo "Check it later against the original with:"
echo "  Scripts/split-inspect.sh \"$DEST\""

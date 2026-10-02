#!/usr/bin/env python3
"""Counts and id digests of a UserData store, read-only, in the form the debug
runners print: sha256 of the row ids, upper case, sorted, one per line.

    Scripts/userdata-digest.py [path-to-store]

Prints only counts and digests -- nothing the listener made."""
import hashlib, sqlite3, sys, uuid, os

default = os.path.expanduser(
    "~/Library/Containers/com.oblaststudio.Indigo/Data/Library/Application Support/UserData.store")
path = sys.argv[1] if len(sys.argv) > 1 else default
db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
for entity, table in [("CrateItem", "ZCRATEITEM"), ("ListeningEvent", "ZLISTENINGEVENT"),
                      ("DigVisit", "ZDIGVISIT"), ("DigStep", "ZDIGSTEP")]:
    ids = [str(uuid.UUID(bytes=bytes(r[0]))).upper() for r in db.execute(f"select ZID from {table}")]
    digest = hashlib.sha256("\n".join(sorted(ids)).encode()).hexdigest()
    print(f"CD_{entity}: rows {len(ids)}, distinct ids {len(set(ids))}, digest {digest}")

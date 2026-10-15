#!/usr/bin/env python3 -I
# Which Discogs artist each artist portrait actually shows, against the row's
# own identity (SHARED-KNOWLEDGE.md §20). Discogs image addresses carry the
# picture's source path, base64-encoded, e.g. s3://discogs-database-images/
# A-398459-....jpeg: "A-<id>" is the Discogs artist the image belongs to.
# Read-only.
#
#   supabase db query --linked -f supabase/diagnostics/remediation/portraits.sql > portraits.json
#   Scripts/portrait-audit.py portraits.json > owners.sql     # then run owners.sql the same way
#   Scripts/portrait-audit.py portraits.json owners.json      # the classification
import base64, collections, json, re, sys

def rows_of(path, key):
    text = open(path).read()
    return json.loads(text[text.find("{"):text.rfind("}") + 1])["rows"][0][key]

def pictured(url):
    match = re.search(r"/w:\d+/(.*)$", url or "")
    if not match:
        return None
    s = "".join(match.group(1).split("/")).split(".")[0]
    s += "=" * (-len(s) % 4)
    try:
        path = base64.urlsafe_b64decode(s).decode("utf-8", "ignore")
    except Exception:
        return None
    found = re.search(r"/A-(\d+)-", path)
    return found.group(1) if found else None

portraits = rows_of(sys.argv[1], "rows")
ids = sorted({p for p in (pictured(r["u"]) for r in portraits) if p})
if len(sys.argv) == 2:
    print("select json_build_object('pictured', (select json_object_agg(e.external_id, e.entity_id) from public.external_ids e "
          "where e.provider='discogs' and e.entity_type='artist' and e.external_id = any(array["
          + ",".join(f"'{i}'" for i in ids) + "]::text[])), 'numbered', (select json_agg(distinct regexp_replace(lower(a.name), "
          "'\\s*\\(\\d+\\)$', '')) from public.artists a where a.name ~ '\\(\\d+\\)$')) as p;")
    sys.exit()

owners = rows_of(sys.argv[2], "p")
by_id, numbered = owners["pictured"] or {}, set(owners["numbered"] or [])
counts, wrong = collections.Counter(), []
for row in portraits:
    image, own = pictured(row["u"]), set(row["d"] or [])
    if image is None:
        counts["undecodable"] += 1
    elif own:
        if image in own:
            counts["verified: the row's own Discogs id"] += 1
        else:
            counts["wrong: the row has an id, the image is another artist"] += 1
            wrong.append({"row": row["id"], "name": row["n"], "pictured": image, "row_ids": sorted(own)})
    elif by_id.get(image) and by_id[image] != row["id"]:
        counts["ambiguous: no identity; the image is a numbered namesake's catalogue row"] += 1
    elif (row["n"] or "").lower() in numbered:
        counts["ambiguous: no identity; the name has numbered Discogs namesakes"] += 1
    else:
        counts["unverified: no identity, no evidence either way"] += 1
print(json.dumps({"counts": counts, "wrong": wrong}, indent=1, ensure_ascii=False))

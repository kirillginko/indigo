#!/usr/bin/env python3 -I
# Identity and bundle-provenance audit for the pilot's missing starting-point
# bundles (SHARED-KNOWLEDGE.md §16). Read-only, everywhere:
#
#   - the catalogue's rows for each Discogs id and each name (passed in as the
#     JSON the linked CLI returned, `audit1.sql` in §16);
#   - Discogs' public artist document for each id (name, name variations,
#     aliases, groups, members, profile) -- unauthenticated, under 25 a minute;
#   - MusicBrainz's own Discogs links, both ways: the MBID's url-rels, and the
#     artist a Discogs URL is attached to -- one request a second;
#   - the release documents R2 holds for the catalogue's releases under each
#     row, counted for credits naming that exact Discogs id.
#
# Nothing is inferred from names: a name only says where to look.
#
#   Scripts/bundle-identity-audit.py <audit1.json> <r2-public-host> > audit.json

import json, sys, time, urllib.request, urllib.error

UA = "IndigoIdentityAudit/1 (kirillginko@gmail.com)"
catalogue_path, host = sys.argv[1], sys.argv[2]

def get(url, pause):
    time.sleep(pause)
    request = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        return {"_status": error.code}

text = open(catalogue_path).read()
catalogue = json.loads(text[text.find("{"):text.rfind("}") + 1])["rows"][0]["audit"]

def discogs(artist_id):
    doc = get(f"https://api.discogs.com/artists/{artist_id}", 2.6)
    if "_status" in doc:
        return {"status": doc["_status"]}
    pick = lambda xs: [{"id": x.get("id"), "name": x.get("name")} for x in xs or []]
    return {
        "name": doc.get("name"), "realname": doc.get("realname"),
        "namevariations": doc.get("namevariations") or [],
        "aliases": pick(doc.get("aliases")), "groups": pick(doc.get("groups")), "members": pick(doc.get("members")),
        "profile": (doc.get("profile") or "")[:240],
        "urls": [u for u in doc.get("urls") or [] if "musicbrainz" in u or "wikipedia" in u][:4],
    }

def musicbrainz_by_mbid(mbid):
    doc = get(f"https://musicbrainz.org/ws/2/artist/{mbid}?inc=url-rels+aliases&fmt=json", 1.1)
    if "_status" in doc:
        return {"status": doc["_status"]}
    links = [r["url"]["resource"] for r in doc.get("relations", []) if "discogs.com/artist/" in r.get("url", {}).get("resource", "")]
    return {"name": doc.get("name"), "disambiguation": doc.get("disambiguation"),
            "discogs": sorted({l.rstrip("/").split("/artist/")[1].split("-")[0] for l in links}),
            "aliases": sorted({a["name"] for a in doc.get("aliases", [])})[:12]}

def musicbrainz_by_discogs(artist_id):
    doc = get(f"https://musicbrainz.org/ws/2/url?resource=https://www.discogs.com/artist/{artist_id}&inc=artist-rels&fmt=json", 1.1)
    if "_status" in doc:
        return []
    return [{"mbid": r["artist"]["id"], "name": r["artist"]["name"], "disambiguation": r["artist"].get("disambiguation")}
            for r in doc.get("relations", []) if "artist" in r]

def credits(release_ids, artist_id):
    """Release documents in R2 crediting this exact id, and how."""
    found = {"documents": 0, "main": 0, "extra": 0, "track": 0, "unreadable": 0}
    for release in release_ids:
        try:
            with urllib.request.urlopen(urllib.request.Request(f"https://{host}/releases/{release}.json",
                                                               headers={"User-Agent": UA}), timeout=20) as r:
                doc = json.loads(r.read())
        except Exception:
            found["unreadable"] += 1
            continue
        found["documents"] += 1
        if any(a.get("id") == artist_id for a in doc.get("artists", [])): found["main"] += 1
        if any(a.get("id") == artist_id for a in doc.get("extraartists", [])): found["extra"] += 1
        if any(a.get("id") == artist_id for t in doc.get("tracklist", []) for a in (t.get("artists", []) + t.get("extraartists", []))):
            found["track"] += 1
    return found

out = []
for row in catalogue["by_id"]:
    artist_id = int(row["discogs"])
    entry = {"label": row["label"], "discogsID": artist_id,
             "catalogue": {k: row.get(k) for k in ("id", "name", "musicbrainz_id", "releases", "cached_docs", "shelf", "ids")},
             "discogs": discogs(artist_id),
             "musicbrainzForDiscogsURL": musicbrainz_by_discogs(artist_id)}
    if row.get("musicbrainz_id"):
        entry["musicbrainzForRowMBID"] = musicbrainz_by_mbid(row["musicbrainz_id"])
    entry["credits"] = credits(row.get("release_ids") or [], artist_id)
    out.append(entry)
    print(f"· {row['label']} {artist_id}", file=sys.stderr)

names = []
for row in catalogue["by_name"]:
    item = {"label": row["label"], "row": row["id"], "name": row["name"], "musicbrainz_id": row.get("musicbrainz_id"), "ids": row.get("ids")}
    if row.get("musicbrainz_id"):
        item["musicbrainz"] = musicbrainz_by_mbid(row["musicbrainz_id"])
    names.append(item)

print(json.dumps({"byDiscogsID": out, "byName": names}, indent=1, ensure_ascii=False))

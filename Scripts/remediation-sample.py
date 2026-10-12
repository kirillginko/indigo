#!/usr/bin/env python3 -I
# Reads a sample of cached Discogs release documents from R2's public host
# and extracts what the DIG remediation plan measures (SHARED-KNOWLEDGE.md
# §20): every main artist and label with its Discogs id, the credits with
# their ids and credited spellings (ANV), styles, genres and year. Read-only.
#
#   Scripts/remediation-sample.py <sample.json from sample.sql> <r2-public-host> > docs.json

import json, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

sample_path, host = sys.argv[1], sys.argv[2]
text = open(sample_path).read()
sample = json.loads(text[text.find("{"):text.rfind("}") + 1])["rows"][0]["sample"]

def fetch(item):
    url = f"https://{host}/releases/{item['r']}.json"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "indigo-remediation/1"}), timeout=20) as r:
            doc = json.loads(r.read())
    except Exception as error:
        return {"release": item["r"], "row": item["a"], "error": str(error)[:80]}
    credits = []
    for extra in doc.get("extraartists", []) + [x for t in doc.get("tracklist", []) for x in t.get("extraartists", [])]:
        credits.append({"id": extra.get("id"), "name": extra.get("name"), "anv": extra.get("anv") or "", "role": extra.get("role", "")})
    return {
        "release": item["r"], "row": item["a"], "year": doc.get("year"),
        "artists": [{"id": a.get("id"), "name": a.get("name"), "anv": a.get("anv") or "", "join": a.get("join") or ""}
                    for a in doc.get("artists", [])],
        "labels": [{"id": l.get("id"), "name": l.get("name"), "catno": l.get("catno")} for l in doc.get("labels", [])],
        "styles": doc.get("styles") or [], "genres": doc.get("genres") or [],
        "credits": credits,
    }

out = {}
with ThreadPoolExecutor(8) as pool:
    for name in ("everyone", "dead"):
        out[name] = list(pool.map(fetch, sample[name]))
print(json.dumps(out, ensure_ascii=False))

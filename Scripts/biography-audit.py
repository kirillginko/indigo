#!/usr/bin/env python3 -I
# What can be said about an enriched artist without making anything up
# (DIG-REMEDIATION-PLAN.md §12). Read-only.
#
#   Scripts/biography-audit.py <bundles-dir>... --db <catalogue.json> [--sample N]
#
# For every bundle in the directories (the worker's own builds, rebuilt
# locally): which facts its documents state -- years, labels, styles,
# collaborators, credits. From the catalogue export: MusicBrainz id, area,
# first year. For a deterministic sample, the Discogs entry itself (DISCOGS_TOKEN
# from the environment): whether it has a written profile, a real name,
# members or groups, links. Then each artist is put in the first tier that
# applies:
#   written      the Discogs entry has a profile of 80+ characters: show it
#   factual      no profile, but the documents say enough for a sourced
#                summary (two of: a year span, a label, a style, a person)
#   thin         some single fact only
#   nothing      nothing to say
# An AI summary would only ever restate the "factual" tier's facts; for
# "thin" and "nothing" there is no source to summarise.
import glob, json, os, sys, time, urllib.request, hashlib

args = sys.argv[1:]
db_path = args[args.index("--db") + 1]
sample = int(args[args.index("--sample") + 1]) if "--sample" in args else 0
dirs = [a for a in args if not a.startswith("--") and a not in (db_path, str(sample))]
db = {int(k): v for k, v in json.load(open(db_path)).items()}

facts = {}
for d in dirs:
    for path in glob.glob(os.path.join(d, "*.json")):
        b = json.load(open(path))
        aid = b["artist"]["discogsID"]
        people = {p["artist"].get("discogsID") for p in b["collaborators"] + b["credits"] if p["artist"].get("discogsID")}
        labels = [l for l in b["labels"] if not l["placeholder"]]
        facts[aid] = {
            "years": b["years"] is not None, "labels": len(labels) > 0, "styles": len(b["styles"]) > 0,
            "people": len(people) > 0, "releases": len(b["releases"]),
        }

token = os.environ.get("DISCOGS_TOKEN", "")
ids = sorted(facts)
chosen = sorted(ids, key=lambda i: hashlib.md5(f"bio{i}".encode()).hexdigest())[:sample] if sample else []
entries = {}
for aid in chosen:
    req = urllib.request.Request(f"https://api.discogs.com/artists/{aid}",
                                 headers={"User-Agent": "indigo-biography-audit/1", **({"Authorization": f"Discogs token={token}"} if token else {})})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                e = json.loads(r.read())
            entries[aid] = {"profile": len((e.get("profile") or "").strip()), "realname": bool(e.get("realname")),
                            "members": len(e.get("members") or []), "groups": len(e.get("groups") or []),
                            "aliases": len(e.get("aliases") or []), "urls": len(e.get("urls") or [])}
            break
        except urllib.error.HTTPError as err:
            if err.code == 404: entries[aid] = None; break
            time.sleep(5)
        except Exception:
            time.sleep(5)
    time.sleep(1.1)

def tier(aid):
    f, e = facts[aid], entries.get(aid)
    if e and e["profile"] >= 80: return "written"
    known = sum([f["years"], f["labels"], f["styles"], f["people"]])
    if known >= 2: return "factual"
    if known == 1: return "thin"
    return "nothing"

from collections import Counter
report = {
    "artists": len(ids),
    "documents_state": {k: sum(1 for a in ids if facts[a][k]) for k in ("years", "labels", "styles", "people")},
    "two_or_more_facts": sum(1 for a in ids if sum([facts[a][k] for k in ("years", "labels", "styles", "people")]) >= 2),
    "catalogue": {
        "musicbrainz_id": sum(1 for a in ids if (db.get(a) or {}).get("mb")),
        "area": sum(1 for a in ids if (db.get(a) or {}).get("area")),
        "began_year": sum(1 for a in ids if (db.get(a) or {}).get("began")),
    },
    "discogs_sample": {
        "asked": len(chosen), "read": sum(1 for a in chosen if a in entries),
        "profile_80plus": sum(1 for a in chosen if entries.get(a) and entries[a]["profile"] >= 80),
        "profile_any": sum(1 for a in chosen if entries.get(a) and entries[a]["profile"] > 0),
        "realname": sum(1 for a in chosen if entries.get(a) and entries[a]["realname"]),
        "members_or_groups": sum(1 for a in chosen if entries.get(a) and (entries[a]["members"] or entries[a]["groups"])),
        "urls": sum(1 for a in chosen if entries.get(a) and entries[a]["urls"]),
    },
    "sample_tiers": dict(Counter(tier(a) for a in chosen if a in entries)),
}
print(json.dumps(report, indent=1))

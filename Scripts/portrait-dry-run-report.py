#!/usr/bin/env python3 -I
# Reads the worker's portrait dry run (DIG-REMEDIATION-PLAN.md §9) for the
# ambiguous portraits, from R2's public host, and classifies what the
# identity-safe rule would do against what each row shows today. Read-only.
#
#   Scripts/portrait-dry-run-report.py <ambiguous.json> <r2-public-host>
import collections, json, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

rows = json.load(open(sys.argv[1]))
host = sys.argv[2]

def read(row):
    url = f"https://{host}/diagnostics/portrait-dry-run/{row['id']}.json"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "indigo-portrait-report/1"}), timeout=20) as r:
            return row, json.loads(r.read())
    except Exception:
        return row, None

counts = collections.Counter()
examples = collections.defaultdict(list)
with ThreadPoolExecutor(8) as pool:
    for row, result in pool.map(read, rows):
        if result is None:
            counts["not run yet"] += 1
            continue
        choice = result["choice"]
        today = int(row["pictured"]) if row.get("pictured") else None
        if result["discogs_ids"]:
            bucket = "resolvable by a verified identity"
        elif choice["kind"] == "ambiguous":
            bucket = "still ambiguous (namesakes, no identity)"
        elif choice["kind"] == "found":
            bucket = ("unique name, same face as today" if choice["discogsID"] == today
                      else "unique name, a different face from today's")
        else:
            bucket = "no picture to be had by name"
        counts[bucket] += 1
        # Whether today's face is potentially someone else's.
        if choice["kind"] == "ambiguous" or (choice["kind"] == "found" and choice["discogsID"] != today) or choice["kind"] == "none":
            counts["~ today's image potentially incorrect"] += 1
        if len(examples[bucket]) < 5:
            examples[bucket].append(f"{row['name']} (today {today}) -> {choice}")
print(json.dumps({"rows": len(rows), "counts": counts, "examples": examples}, indent=1, ensure_ascii=False))

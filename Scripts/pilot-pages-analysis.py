#!/usr/bin/env python3 -I
# Reads the attachments of CataloguePilotPagesUITests (exported with
# `xcrun xcresulttool export attachments`) and attributes each page's change
# to its published bundle: a name new with the pilot on counts for the pilot
# only when the artist's bundle names that person; any other difference is
# the app's own live discovery varying between two openings. Read-only.
#
#   Scripts/pilot-pages-analysis.py <attachments-dir> <r2-public-host>
import json, re, sys, urllib.request

out, host = sys.argv[1], sys.argv[2]
def get(key):
    with urllib.request.urlopen(urllib.request.Request(f"https://{host}/{key}", headers={"User-Agent": "indigo-pages/1"}), timeout=20) as r:
        return json.loads(r.read())
ts = open("supabase/functions/_shared/catalogue_pilot.ts").read()
ids = {json.loads(n).split(" (")[0]: int(i) for i, n in re.findall(r'^  \[(\d+), (".*")\],$', ts, re.M)}
manifest = get(get("knowledge/v1/catalogue/pilot.json")["manifest"])["artists"]
attachments = json.load(open(f"{out}/manifest.json"))
files = {a["suggestedHumanReadableName"].split("_")[0]: a["exportedFileName"] for t in attachments for a in t["attachments"]}
summary = open(f"{out}/{files['summary']}").read().splitlines()
nav = {line.split("\t")[0]: line.split("\t")[-1] for line in summary if "\t" in line}
totals = dict(pages=0, bundle_rows_shown=0, new_from_bundle=0, new_other=0, gone=0, rescued=0, nav_ok=0, nav_checked=0)
rows = []
for name, file in files.items():
    text = open(f"{out}/{file}").read().split("\n")
    if "--- off" not in text:
        continue
    off = {l.split(", ")[0] for l in text[text.index("--- off") + 1:text.index("--- on")] if l}
    on = {l.split(", ")[0] for l in text[text.index("--- on") + 1:] if l}
    pid = ids.get(name)
    bundle = set()
    if pid and str(pid) in manifest:
        b = get(manifest[str(pid)]["key"])
        people = b["collaborators"] + b["credits"]
        bundle = {re.sub(r" \(\d+\)$", "", p["artist"]["name"]) for p in people} | {p["artist"]["anv"] for p in people if p["artist"].get("anv")}
    new = on - off
    row = dict(name=name, inPilot=bool(bundle), off=len(off), on=len(on), newFromBundle=len(new & bundle),
               newOther=len(new - bundle), gone=sorted(off - on), bundleShown=len(on & bundle), bundleSize=len(bundle), nav=nav.get(name, ""))
    rows.append(row)
    if bundle:
        totals["pages"] += 1
        totals["bundle_rows_shown"] += row["bundleShown"]
        totals["new_from_bundle"] += row["newFromBundle"]
        totals["new_other"] += row["newOther"]
        totals["gone"] += len(row["gone"])
        totals["rescued"] += row["off"] == 0 and row["on"] > 0
        if row["nav"].startswith(("opened", "did NOT")):
            totals["nav_checked"] += 1
            totals["nav_ok"] += row["nav"].startswith("opened")
print(json.dumps({"totals": totals, "pages": sorted(rows, key=lambda r: (not r["inPilot"], r["name"]))}, indent=1, ensure_ascii=False))

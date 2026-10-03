#!/usr/bin/env python3
"""Counts, id digests and invariants of UserData as CloudKit holds it, read
through cktool with the user token, in the form UserDataAuditTests prints for a
local store: sha256 of the distinct row ids, upper case, sorted, one per line.

    scripts/cloudkit-audit.py production|development

Also checks what counts cannot: that no natural key repeats, that every visit
and step says what its counter components add up to, and who wrote the
components. Read-only. Prints only counts, digests and writer prefixes --
nothing the listener made. Needs Keychain access, so run it outside a sandbox.
"""
import hashlib, json, subprocess, sys
from collections import Counter, defaultdict

environment = sys.argv[1] if len(sys.argv) > 1 else "production"
assert environment in ("production", "development"), environment
BASE = "base"


def fetch(entity, fields):
    """Every record of one type, following continuation tokens."""
    records, token = [], None
    while True:
        command = ["xcrun", "cktool", "query-records", "--team-id", "M3D5972R39",
                   "--container-id", "iCloud.com.oblaststudio.Indigo", "--environment", environment,
                   "--database-type", "private", "--zone-name", "com.apple.coredata.cloudkit.zone",
                   "--record-type", f"CD_{entity}", "--filters", f"CD_entityName EQUALS {entity}",
                   "--requested-fields", *fields, "--limit", "200"]
        if token:
            command += ["--continuation-token", token]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0 or not result.stdout.lstrip().startswith("{"):
            sys.exit(f"CD_{entity}: {(result.stdout + result.stderr).strip()}")
        page = json.loads(result.stdout)
        records += [{k: v.get("value") for k, v in r.get("fields", {}).items()} for r in page["records"]]
        token = page.get("continuationToken")
        if not token:
            return records


def digest(ids):
    return hashlib.sha256("\n".join(sorted({i.upper() for i in ids})).encode()).hexdigest()


problems = []
data = {
    "CrateItem": fetch("CrateItem", ["CD_id"]),
    "ListeningEvent": fetch("ListeningEvent", ["CD_id"]),
    "DigVisit": fetch("DigVisit", ["CD_id", "CD_nodeID", "CD_visits"]),
    "DigStep": fetch("DigStep", ["CD_id", "CD_identity", "CD_count"]),
    "DigCounter": fetch("DigCounter", ["CD_id", "CD_kindRaw", "CD_key", "CD_deviceID", "CD_count"]),
}
print(f"environment: {environment}")
for entity, rows in data.items():
    ids = [r.get("CD_id") for r in rows if r.get("CD_id")]
    print(f"{entity}: records {len(rows)}, distinct ids {len(set(ids))}, digest {digest(ids)}")
    if len(ids) != len(rows):
        problems.append(f"{entity}: {len(rows) - len(ids)} records without an id")
    if len(set(ids)) != len(ids):
        problems.append(f"{entity}: {len(ids) - len(set(ids))} repeated ids")

for entity, key in [("DigVisit", "CD_nodeID"), ("DigStep", "CD_identity")]:
    repeated = sum(1 for n in Counter(r.get(key) for r in data[entity]).values() if n > 1)
    if repeated:
        problems.append(f"{entity}: {repeated} natural keys repeat")

counters = data["DigCounter"]
generation = [r.get("CD_count") for r in counters if r.get("CD_kindRaw") == "generation"]
print(f"generation: {max(generation) if generation else 'none'}")
writers = Counter(r.get("CD_deviceID") for r in counters if r.get("CD_kindRaw") != "generation")
print("writers: " + ", ".join(sorted(f"{BASE if w == BASE else (w or '?')[:8]} {n}" for w, n in writers.items())))

totals = defaultdict(int)
for r in counters:
    if r.get("CD_kindRaw") in ("visit", "step"):
        totals[(r["CD_kindRaw"], r.get("CD_key"))] += r.get("CD_count") or 0
for kind, entity, key, field in [("visit", "DigVisit", "CD_nodeID", "CD_visits"), ("step", "DigStep", "CD_identity", "CD_count")]:
    off = sum(1 for r in data[entity]
              if (kind, r.get(key)) in totals and totals[(kind, r.get(key))] != (r.get(field) or 0))
    if off:
        problems.append(f"{entity}: {off} disagree with the sum of their components")

print(f"invariant violations: {len(problems)}")
for p in problems:
    print(f"  {p}")
sys.exit(1 if problems else 0)

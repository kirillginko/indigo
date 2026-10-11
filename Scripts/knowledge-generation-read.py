#!/usr/bin/env python3 -I
# Reader B: an independent implementation of reader A's fetch-and-verify --
# Python's urllib, hashlib and json, nothing shared with the TypeScript. Reads
# the day pointer, the manifest and everything the manifest names, checks every
# digest, keeps every byte under <out-dir>/<key>, and prints the same
# fingerprint reader A prints.
#
#   Scripts/knowledge-generation-read.py <host> <out-dir> <date>
import hashlib, json, os, sys, urllib.request

host, out, date = sys.argv[1:4]
root = "knowledge/v1/generations"
read, problems = [], []

def fetch(key):
    with urllib.request.urlopen(f"https://{host}/{key}") as response:
        data = response.read()
    os.makedirs(os.path.join(out, os.path.dirname(key)), exist_ok=True)
    with open(os.path.join(out, key), "wb") as f:
        f.write(data)
    read.append((key, hashlib.sha256(data).hexdigest()))
    return data

def at(kind, digest):
    return f"{root}/{kind}/{digest[:2]}/{digest}.json"

day = json.loads(fetch(f"{root}/days/{date}.json"))
data = fetch(at("manifests", day["manifest"]))
if hashlib.sha256(data).hexdigest() != day["manifest"]:
    problems.append("manifest digest mismatch")
manifest = json.loads(data)
wanted = {}
for kind in ("nodes", "artists"):
    for entry in manifest[kind].values():
        if "answer" in entry:
            wanted[at("objects", entry["answer"])] = entry["answer"]
        for bundle in entry.get("bundles", []):
            if "digest" in bundle:
                d = bundle["digest"]
                wanted[f"knowledge/v1/bundles/{d[:2]}/{d}.json"] = d
wanted[at("identity", manifest["identity"])] = manifest["identity"]
for key, digest in wanted.items():
    if hashlib.sha256(fetch(key)).hexdigest() != digest:
        problems.append(f"{key} digest mismatch")

read.sort()
fingerprint = hashlib.sha256("\n".join(f"{k} {d}" for k, d in read).encode()).hexdigest()
print(json.dumps({"reader": "B (python)", "date": date, "manifest": day["manifest"], "fingerprint": fingerprint,
                  "objectsRead": len(read), "problems": problems}, indent=2))
sys.exit(1 if problems else 0)

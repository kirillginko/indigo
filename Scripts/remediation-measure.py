#!/usr/bin/env python3 -I
# What the sampled release documents say about each remediation workstream
# (SHARED-KNOWLEDGE.md §20). Read-only; inputs from remediation-sample.py and
# the catalogue mapping query.
#
#   Scripts/remediation-measure.py <docs.json> <map.json> > measures.json

import collections, json, sys

docs = json.load(open(sys.argv[1]))
text = open(sys.argv[2]).read()
catalogue = json.loads(text[text.find("{"):text.rfind("}") + 1])["rows"][0]["m"]
artist_rows = catalogue["artists"] or {}
label_rows = catalogue["labels"] or {}
kept = catalogue["kept"] or {}

VARIOUS, NOT_ON_LABEL = 194, 750   # Discogs' "Various" artist and "Not On Label" label

def real_labels(doc):
    seen = {}
    for l in doc["labels"]:
        if not l.get("id") or l["id"] == NOT_ON_LABEL:
            continue
        row = label_rows.get(str(l["id"]))
        if row and not row["real"]:
            continue
        seen[l["id"]] = l
    return list(seen.values())

def main_artists(doc):
    return list({a["id"]: a for a in doc["artists"] if a.get("id") and a["id"] != VARIOUS}.values())

def measure(sample):
    m = collections.Counter()
    style_counts = collections.Counter()
    genre_counts = collections.Counter()
    for doc in sample:
        m["releases"] += 1
        artists, labels = main_artists(doc), real_labels(doc)
        row = kept.get(str(doc["release"]), {})
        kept_label = row.get("label")

        # Release indexing: what one artist and one label per row drops.
        if len(artists) > 1:
            m["joint"] += 1
            extra = artists[1:]
            m["joint_extra_artists"] += len(extra)
            in_cat = [a for a in extra if str(a["id"]) in artist_rows]
            m["joint_extra_in_catalogue"] += len(in_cat)
            if in_cat:
                m["joint_with_catalogued_partner"] += 1
        if len(labels) > 1:
            m["multi_label"] += 1
            dropped = [l for l in labels if label_rows.get(str(l["id"]), {}).get("row") != kept_label]
            m["multi_label_dropped"] += len(dropped)
            with_roster = [l for l in dropped if label_rows.get(str(l["id"]), {}).get("artists", 0) >= 1]
            m["multi_label_dropped_with_roster"] += len(with_roster)
            m["multi_label_dropped_roster_artists"] += sum(label_rows[str(l["id"])]["artists"] for l in with_roster)
            if with_roster:
                m["multi_label_gains_peers"] += 1

        # Credit identity: ids, credited spellings, catalogue rows.
        for c in doc["credits"]:
            m["credits"] += 1
            if c.get("id"):
                m["credits_with_id"] += 1
                if str(c["id"]) in artist_rows:
                    m["credits_in_catalogue"] += 1
            if c.get("anv") and c["anv"] != c.get("name"):
                m["credits_with_anv"] += 1
        if any(c.get("id") and str(c["id"]) in artist_rows for c in doc["credits"]):
            m["releases_with_catalogued_credit"] += 1

        # Styles and eras.
        if doc["styles"]:
            m["with_style"] += 1
        if doc["year"]:
            m["with_year"] += 1
        for s in set(doc["styles"]):
            style_counts[s] += 1
        for g in set(doc["genres"]):
            genre_counts[g] += 1
    return m, style_counts, genre_counts

out = {}
everyone_m, styles, genres = measure(docs["everyone"])
dead_m, dead_styles, _ = measure(docs["dead"])
n = everyone_m["releases"]
breadth = {s: round(c / n * 100, 1) for s, c in styles.most_common()}
out["everyone"] = dict(everyone_m)
out["dead"] = dict(dead_m)
out["styles_by_share_of_releases"] = dict(list(breadth.items())[:25])
out["genres_by_share_of_releases"] = {g: round(c / n * 100, 1) for g, c in genres.most_common(15)}
out["distinct_styles"] = len(styles)

# A dead-end artist's release with a style at most this common catalogue-wide
# is the narrow evidence a style relationship would use.
for cut in (2.0, 5.0):
    narrow = {s for s, p in breadth.items() if p <= cut}
    unseen = lambda s: s not in styles   # rarer than one in six hundred
    out[f"dead_with_style_at_most_{cut}pct"] = sum(
        1 for d in docs["dead"] if any((s in narrow) or unseen(s) for s in d["styles"]))

# Dead ends a structural fix would reach: a catalogued joint partner, a
# dropped label with a roster, or a catalogued credit.
reach = collections.Counter()
for d in docs["dead"]:
    artists, labels = main_artists(d), real_labels(d)
    row = kept.get(str(d["release"]), {})
    partner = any(str(a["id"]) in artist_rows for a in artists[1:])
    dropped_label = any(label_rows.get(str(l["id"]), {}).get("row") != row.get("label")
                        and label_rows.get(str(l["id"]), {}).get("artists", 0) >= 1 for l in labels)
    credit = any(c.get("id") and str(c["id"]) in artist_rows for c in d["credits"])
    style = bool(d["styles"])
    reach["joint partner"] += partner
    reach["dropped label with a roster"] += dropped_label
    reach["catalogued credit"] += credit
    reach["indexing (partner or label)"] += partner or dropped_label
    reach["indexing or credit"] += partner or dropped_label or credit
    reach["any style"] += style
    reach["nothing structural"] += not (partner or dropped_label or credit)
out["dead_reached_by"] = dict(reach)
print(json.dumps(out, indent=1, ensure_ascii=False))

#!/usr/bin/env python3
"""The R2 half of the plan, sized: one gzip JSON document per broadcast
episode, holding every line in full -- including what the one-row-per-episode
table drops (raw credits, credited names, normalized keys, Deezer and
MusicBrainz ids, how each line was identified).

Writes nothing anywhere: documents are built and compressed in memory and only
their sizes are printed.

    python3 -I documents.py <synth dir>
"""

import collections
import gzip
import json
import os
import sys

synth = sys.argv[1]
COLUMNS = ["id", "recording_id", "offset_seconds", "confidence", "radio_episode_id", "track_index",
           "raw_artist_name", "raw_track_title", "normalized_artist_name", "normalized_title", "artist_id",
           "identification_source", "isrc", "deezer_track_id", "musicbrainz_recording_id",
           "credited_artist_names", "media_url", "credited_artist_keys"]
DOCUMENT_COLUMNS = ["slot", "artist", "title", "artist_key", "title_key", "artist_id", "recording_id",
                    "offset", "isrc", "deezer", "musicbrainz", "identified_by", "credited"]


def value(raw: str):
    if raw == "\\N":
        return None
    if raw.startswith("{") and raw.endswith("}"):
        return [part.strip('"') for part in raw[1:-1].split('","')]
    return raw


episodes = {}
with open(os.path.join(synth, "episodes.tsv"), encoding="utf-8") as f:
    for line in f:
        cells = line.rstrip("\n").split("\t")
        episodes[cells[0]] = {"id": cells[0], "provider": cells[2], "external_id": cells[3],
                              "title": value(cells[4]), "aired_at": cells[5], "archive_url": value(cells[6])}

by_episode = collections.defaultdict(list)
with open(os.path.join(synth, "lines.tsv"), encoding="utf-8") as f:
    for line in f:
        row = dict(zip(COLUMNS, (value(c) for c in line.rstrip("\n").split("\t"))))
        if row["media_url"] is not None:
            continue
        by_episode[row["radio_episode_id"]].append(row)

sizes = []
raw_total = 0
lines_total = 0
for episode_id, rows in sorted(by_episode.items()):
    rows.sort(key=lambda r: int(r["track_index"]))
    document = {
        "v": 1,
        "episode": episodes[episode_id],
        "columns": DOCUMENT_COLUMNS,
        "lines": [[int(r["track_index"]), r["raw_artist_name"], r["raw_track_title"], r["normalized_artist_name"],
                   r["normalized_title"], r["artist_id"], r["recording_id"],
                   int(r["offset_seconds"]) if r["offset_seconds"] else None, r["isrc"], r["deezer_track_id"],
                   r["musicbrainz_recording_id"], r["identification_source"], r["credited_artist_names"]]
                  for r in rows],
    }
    text = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()
    raw_total += len(text)
    sizes.append(len(gzip.compress(text, compresslevel=6, mtime=0)))
    lines_total += len(rows)

sizes.sort()
total = sum(sizes)
print(f"  documents                 {len(sizes)}")
print(f"  lines                     {lines_total}")
print(f"  JSON bytes                {raw_total}  ({raw_total / lines_total:.1f} per line)")
print(f"  gzip bytes                {total}  ({total / lines_total:.1f} per line, {total / len(sizes):.0f} per document)")
print(f"  gzip document p50 / p90 / max   {sizes[len(sizes) // 2]} / {sizes[int(len(sizes) * 0.9)]} / {sizes[-1]}")

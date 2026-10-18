#!/usr/bin/env python3
"""Synthetic radio tracklists, shaped like Indigo's live radio tables.

No real artist, title or episode is used. Every name is generated. The
*shape* -- how many lines an episode has, how often an artist recurs, how
long a title is, how often a line carries an offset, ISRC or recording -- is
calibrated on read-only aggregates of the live tables taken 2026-10-17:

    262,478 lines in 11,125 episodes across 2,031 shows
    101,562 distinct artists (0.39 per line); 64% heard once; max 251 lines
    lines per episode: p10 10, p50 18, p90 34, p99 149 (one 5,393-line upload list)
    artist_id null 4.1%   recording_id 13.0%   offset 69.6%   isrc 23.0%
    deezer 17.9%   musicbrainz 5.9%   media_url 30.4% (YouTube)   credited 7.1%
    raw title 18.0 B   raw artist 13.8 B   normalized title 17.3 B   artist 12.3 B
    raw artist differs from the resolved artist's name on 11.4% of broadcast lines

Artists recur by preferential attachment: each resolved line names a new
artist with probability 0.39, otherwise someone already played, chosen in
proportion to how often they have been. That gives the observed long tail
(about 62% heard once) without copying anyone's real catalogue.

    python3 -I generate.py <lines> <outdir> [--seed N] [--media-share 0.304]

Writes artists.tsv, shows.tsv, episodes.tsv, lines.tsv in COPY text format.
"""

import math
import os
import random
import sys
import uuid

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if len(args) != 2:
    sys.exit(__doc__)
TARGET_LINES = int(args[0])
OUT = args[1]
SEED = 20261018
MEDIA_SHARE = 0.304
for i, a in enumerate(sys.argv):
    if a == "--seed":
        SEED = int(sys.argv[i + 1])
    if a == "--media-share":
        MEDIA_SHARE = float(sys.argv[i + 1])

rng = random.Random(SEED)
# Episodes that are upload lists, chosen so their lines are ~30% of all lines
# (160 lines each on average against ~20 for a broadcast).
MEDIA_EPISODE_SHARE = MEDIA_SHARE * 20 / (160 * (1 - MEDIA_SHARE) + MEDIA_SHARE * 20)
os.makedirs(OUT, exist_ok=True)


def uid() -> str:
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


SYLLABLES = ["ka", "lo", "mi", "ra", "ve", "to", "su", "ne", "dor", "lin", "mar", "sel",
             "qu", "ost", "val", "ber", "an", "is", "el", "um", "ok", "ry", "ze", "ha",
             "ø", "é", "ü", "ō"]


def word(min_len: int) -> str:
    w = ""
    while len(w) < min_len:
        w += rng.choice(SYLLABLES)
    return w


def phrase(mean_bytes: float) -> str:
    """Words until the UTF-8 length reaches a lognormal draw around the mean."""
    target = max(2, int(rng.lognormvariate(math.log(mean_bytes) - 0.36, 0.6)))
    parts = []
    while len(" ".join(parts).encode()) < target:
        parts.append(word(rng.randint(2, 7)).capitalize())
    return " ".join(parts)


def key(text: str) -> str:
    # Close enough to normalizeName for sizing: fold case, keep letters/digits.
    import unicodedata
    folded = "".join(c for c in unicodedata.normalize("NFD", text) if not unicodedata.category(c).startswith("M")).lower()
    return " ".join("".join(c if c.isalnum() else " " for c in folded).split())


def lines_in_episode(is_media: bool) -> int:
    # A curated channel's uploads list is long (79,885 lines in 679 lists).
    if is_media:
        return rng.randint(20, 300)
    # Lognormal fitted to p10 10 / p50 18 / p90 34, with a 1% long tail.
    if rng.random() < 0.01:
        return rng.randint(120, 600)
    return max(1, int(round(rng.lognormvariate(math.log(18), 0.47))))


# Shows ---------------------------------------------------------------------
shows = []
for _ in range(max(10, TARGET_LINES // 130)):  # 2,031 shows for 262k lines
    shows.append((uid(), phrase(14)))

# Artists, lines ------------------------------------------------------------
artists = []          # (id, name, key)
weights = []          # one entry per appearance: preferential attachment
episodes = []
lines = []
day = 0
while len(lines) < TARGET_LINES:
    episode_id = uid()
    show_id, show_title = rng.choice(shows) if rng.random() < 0.97 else (None, None)
    is_media = rng.random() < MEDIA_EPISODE_SHARE
    day += 1
    aired = f"20{17 + (day // 1600) % 10:02d}-{1 + (day // 130) % 12:02d}-{1 + day % 28:02d} {day % 24:02d}:00:00+00"
    episodes.append((episode_id, show_id, "youtube" if is_media else rng.choice(["nts", "lotradio"]),
                     f"ext-{episode_id[:13]}", phrase(28), aired,
                     f"https://example.invalid/archive/{episode_id[:8]}",
                     "available"))
    for index in range(lines_in_episode(is_media)):
        if len(lines) >= TARGET_LINES:
            break
        resolved = rng.random() >= 0.041
        if resolved:
            if not artists or rng.random() < 0.39:
                name = phrase(13.8)
                artists.append((uid(), name, key(name)))
                artist_index = len(artists) - 1
            else:
                artist_index = rng.choice(weights)
            weights.append(artist_index)
            artist_id, artist_name, artist_key = artists[artist_index]
            # 11.4% of resolved broadcast lines credit the artist in words
            # other than their canonical name ("X & Y", "X (live)", case).
            if rng.random() < 0.114:
                artist_name = artist_name.upper() if rng.random() < 0.4 else f"{artist_name} & {phrase(9)}"
        else:
            artist_id, artist_name = None, phrase(13.8)
            artist_key = key(artist_name)
        title = phrase(18.0)
        # Every NTS and Lot line has an offset; no YouTube line does.
        has_offset = not is_media
        credited = rng.random() < 0.071
        lines.append({
            "id": uid(),
            "recording_id": uid() if resolved and rng.random() < 0.13 / 0.959 else None,
            "offset_seconds": index * 210 + rng.randint(0, 60) if has_offset else None,
            "confidence": 0.8 if rng.random() < 0.02 else None,
            "radio_episode_id": episode_id,
            "track_index": index,
            "raw_artist_name": artist_name,
            "raw_track_title": title,
            "normalized_artist_name": artist_key or None,
            "normalized_title": key(title) or None,
            "artist_id": artist_id,
            "identification_source": rng.choice(["normalized_artist", "radio_adopted", "deezer_track"]) if resolved and rng.random() < 0.676 else None,
            "isrc": f"ZZX0Y{rng.randint(0, 25):02d}{rng.randint(0, 99999):05d}" if not is_media and rng.random() < 0.23 / (1 - MEDIA_SHARE) else None,
            "deezer_track_id": str(rng.randint(10**6, 10**9)) if not is_media and rng.random() < 0.179 / (1 - MEDIA_SHARE) else None,
            "musicbrainz_recording_id": uid() if not is_media and rng.random() < 0.059 / (1 - MEDIA_SHARE) else None,
            "credited_artist_names": [artist_name, phrase(12)] if credited else None,
            "media_url": f"https://www.youtube.com/watch?v={uid()[:11]}" if is_media else None,
        })


def cell(value) -> str:
    if value is None:
        return "\\N"
    if isinstance(value, list):
        return "{" + ",".join('"' + v.replace('"', '\\\\"') + '"' for v in value) + "}"
    return str(value).replace("\\", "\\\\").replace("\t", " ").replace("\n", " ")


with open(os.path.join(OUT, "shows.tsv"), "w") as f:
    for show_id, title in shows:
        f.write(f"{show_id}\t{cell(title)}\n")
with open(os.path.join(OUT, "artists.tsv"), "w") as f:
    for artist_id, name, artist_key in artists:
        f.write(f"{artist_id}\t{cell(name)}\t{cell(artist_key)}\n")
with open(os.path.join(OUT, "episodes.tsv"), "w") as f:
    for row in episodes:
        f.write("\t".join(cell(v) for v in row) + "\n")
COLUMNS = ["id", "recording_id", "offset_seconds", "confidence", "radio_episode_id", "track_index",
           "raw_artist_name", "raw_track_title", "normalized_artist_name", "normalized_title", "artist_id",
           "identification_source", "isrc", "deezer_track_id", "musicbrainz_recording_id",
           "credited_artist_names", "media_url"]
with open(os.path.join(OUT, "lines.tsv"), "w") as f:
    for line in lines:
        row = dict(line)
        names = row["credited_artist_names"]
        f.write("\t".join(cell(row[c]) for c in COLUMNS) + "\t" + cell([key(n) for n in names] if names else None) + "\n")

singles = sum(1 for c in __import__("collections").Counter(weights).values() if c == 1)
print(f"lines {len(lines)}  episodes {len(episodes)}  shows {len(shows)}  artists {len(artists)} "
      f"({len(artists) / len(lines):.2f}/line, {singles / max(1, len(artists)):.0%} heard once)")

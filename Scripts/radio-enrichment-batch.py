#!/usr/bin/env python3
"""Read-only Tier 1 evidence collector. Never connects to Supabase or writes production.

Input: batch directory containing candidates.json and candidate-details.json (CLI exports).
Only GETs MusicBrainz and Discogs. Responses are checkpointed; remove evidence/ to reverify.
All publisher recording witnesses must agree. Alias-only and multi-page identities are review.
Database destination guards are a separate, mandatory step before producing apply SQL.
"""
import collections
import datetime
import hashlib
import json
import pathlib
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request


def normalize(value):
    value = ''.join(c for c in unicodedata.normalize('NFD', value.lower())
                    if unicodedata.category(c) != 'Mn')
    return ' '.join(''.join(c if c.isalnum() else ' ' for c in value).split())


def read_rows(path):
    return json.loads(path.read_text())['rows']


def main():
    root = pathlib.Path(sys.argv[1])
    cache = root / 'evidence'
    cache.mkdir(exist_ok=True)
    candidates = read_rows(root / 'candidates.json')
    details = read_rows(root / 'candidate-details.json')[0]['report']
    last = {}
    requests = collections.Counter()

    def get(url):
        key = hashlib.sha256(url.encode()).hexdigest()
        path = cache / (key + '.json')
        if path.exists():
            saved = json.loads(path.read_text())
            if saved['status'] in (200, 404):
                return saved
        host = urllib.parse.urlparse(url).netloc
        for attempt in range(3):
            time.sleep(max(0, last.get(host, 0) + 1.1 - time.monotonic()))
            last[host] = time.monotonic()
            requests[host] += 1
            request = urllib.request.Request(url, headers={
                'User-Agent': 'Indigo/1.0 (+https://github.com/kirillginko/indigo)',
                'Accept': 'application/json'})
            try:
                with urllib.request.urlopen(request, timeout=35) as response:
                    saved = dict(url=url, status=response.status,
                                 checked_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                 body=json.load(response))
            except urllib.error.HTTPError as error:
                if error.code in (403, 429):
                    raise RuntimeError(f'Stopping on {host} HTTP {error.code}') from error
                saved = dict(url=url, status=error.code, body={})
                if error.code >= 500 and attempt < 2:
                    time.sleep(3 * (attempt + 1))
                    continue
            path.write_text(json.dumps(saved, ensure_ascii=False, indent=2) + '\n')
            return saved

    def mb(path, **params):
        return get('https://musicbrainz.org/ws/2/' + path + '?' +
                   urllib.parse.urlencode(dict(params, fmt='json')))

    results = []
    for candidate in candidates:
        row = dict(candidate, status='review', reasons=[], witnesses=[])
        wanted = normalize(candidate['name'])
        matched = set()
        for recording in candidate['recordings']:
            response = mb('recording/' + recording, inc='artist-credits+isrcs+releases')
            credit = response['body'].get('artist-credit', [])
            ids = {part['artist']['id'] for part in credit
                   if 'artist' in part and wanted in
                   (normalize(part.get('name', '')), normalize(part['artist'].get('name', '')))}
            row['witnesses'].append(dict(recording=recording, status=response['status'],
                                         exact_credit_ids=sorted(ids), credit=credit))
            if response['status'] != 200:
                row['reasons'].append('recording_lookup_failed')
            elif len(ids) != 1:
                row['reasons'].append('credit_mismatch_or_alias_requires_review')
            matched.update(ids)
        if len(matched) != 1:
            row['reasons'].append('contradictory_or_missing_artist_credit')
        if len(matched) == 1:
            artist_id = next(iter(matched))
            row['musicbrainz_artist'] = artist_id
            entry = mb('artist/' + artist_id, inc='aliases+url-rels+artist-rels+genres+tags')
            row['musicbrainz_status'] = entry['status']
            artist = entry['body']
            row['musicbrainz_name'] = artist.get('name')
            # A credit alias that points at a substantively different billing is review too.
            if normalize(artist.get('name', '')) != wanted:
                row['reasons'].append('substantive_billing_change')
            discogs = sorted({int(m.group(1)) for relation in artist.get('relations', [])
                              if (m := re.match(r'^https?://(?:www\.)?discogs\.com/(?:[a-z]{2}/)?artist/(\d+)(?:[-/?#].*)?$',
                                                relation.get('url', {}).get('resource', '')))})
            row['discogs_ids'] = discogs
            if entry['status'] != 200:
                row['reasons'].append('artist_lookup_failed')
            elif len(discogs) != 1:
                row['reasons'].append('no_discogs' if not discogs else 'multiple_discogs_pages')
            else:
                did = discogs[0]
                reverse = mb('url', resource=f'https://www.discogs.com/artist/{did}', inc='artist-rels')
                claimants = sorted({r['artist']['id'] for r in reverse['body'].get('relations', []) if 'artist' in r})
                row['discogs_claimants'] = claimants
                if reverse['status'] != 200 or claimants != [artist_id]:
                    row['reasons'].append('not_sole_discogs_claimant')
                discogs_entry = get(f'https://api.discogs.com/artists/{did}')
                row['discogs_name'] = discogs_entry['body'].get('name')
                if discogs_entry['status'] != 200 or discogs_entry['body'].get('id') != did:
                    row['reasons'].append('discogs_destination_unverified')
                elif normalize(re.sub(r'\s+\(\d+\)$', '', row['discogs_name'] or '')) != wanted:
                    row['reasons'].append('discogs_billing_change')
                # Existing title corroboration rule: any returned exact title/name hit on
                # another artist is contradictory. Search is a veto, never identity proof.
                appearances = [r for r in details['appearances'] if r['artist_id'] == candidate['id']]
                titles = sorted({r['raw_track_title'] for r in appearances if r['raw_track_title']})
                row['title_checks'] = []
                for title in titles[:2]:
                    escape = lambda s: re.sub(r'[+\-!(){}\[\]^"~*?:\\/]', ' ', s).strip()
                    search = mb('recording', query=f'recording:"{escape(title)}" AND artist:"{escape(candidate["name"])}"', limit='100')
                    hits = {part['artist']['id'] for rec in search['body'].get('recordings', [])
                            if normalize(rec.get('title', '')) == normalize(title)
                            for part in rec.get('artist-credit', []) if 'artist' in part
                            and wanted in (normalize(part.get('name', '')), normalize(part['artist'].get('name', '')))}
                    row['title_checks'].append(dict(title=title, status=search['status'], artist_ids=sorted(hits)))
                    if search['status'] != 200 or search['body'].get('count', 0) > 100:
                        row['reasons'].append('title_check_incomplete')
                    if hits - {artist_id}:
                        row['reasons'].append('contradictory_title')
        row['reasons'] = sorted(set(row['reasons']))
        row['status'] = 'evidence_ready' if not row['reasons'] else 'review'
        results.append(row)
        (root / 'verification.json').write_text(json.dumps(dict(
            writes_production=False, results=results, requests_this_invocation=dict(requests)),
            ensure_ascii=False, indent=2) + '\n')
        print(f'{len(results)}/{len(candidates)} {candidate["name"]}: {row["status"]} {row["reasons"]}', flush=True)


if __name__ == '__main__':
    main()

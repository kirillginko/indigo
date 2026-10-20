# Conditional approval recorded — no insertion performed

The user approved only the frozen 21-link Batch 2, subject to all six execution
conditions in the chat. This approval persists; no second approval is required
for these same identities while its conditions remain satisfied. It does not
cover the 19 review cases, a wider backfill, merges, or recommendation changes.

Current production checks pass for all 21 approved destinations and all source
recording witness sets remain unchanged. Production still has 463 links and
zero orphan mappings. All 459 prior applied mappings remain intact, and all
459 portraits are verified against their linked IDs. Charles Sullivan's shared
Discogs 258371 and both involved artist rows do not overlap the approved subset.

**Execution condition 5 is unmet:** latest completed merge started October 19
04:23 UTC, before Batch 1 was inserted October 19 at 17:12 UTC. The next scheduled
merge is October 20 at 04:23 UTC / October 20 at 12:23 am EDT. Current integrity
is not a substitute for a post-merge check. No manual merge was invoked.

## Resume under the existing approval

1. Confirm a completed successful merge after Batch 1's insertion and re-run
   `../integrity.sql`. Verify the 326 links/rows, portraits and no conflicting
   direct identities. Inspect Charles Sullivan specifically; pause on a relevant
   identity-integrity issue. Preserve the recorded 19 exclusions.
2. Verify the frozen manifest/apply/rollback SHA-256 values in
   `execution-status.json`. Create an isolated fresh verification directory with
   candidates restricted to the 21 approved IDs and the source details. Run
   `Scripts/radio-enrichment-batch.py` against fresh MusicBrainz and Discogs
   responses. Require all 21 exact identities, all publisher credits, sole reverse
   claims and unchanged single Discogs destinations. Do not reuse old cache files.
3. Immediately re-run production guards, require all 21 would insert, 463 total
   baseline links, no orphans or conflicts, no changed witness sets, and no
   overlap with Charles Sullivan. If any guard fails, write nothing.
4. Execute only the hash-verified, rehearsed `../apply.NOT-EXECUTED.sql` atomic
   transaction. Preserve the exact `../rollback.NOT-EXECUTED.sql` manifest.
5. Capture exact inserted primary-key ownership and before/after identity mappings:
   21 new mappings, total 484, no reassignment. Confirm expected portrait jobs
   were enqueued (or already processed), then verify their actual Discogs IDs
   after drain. Run `../post-apply-checks.sql` and the next relevant merge check.

No production data was written. Fresh remote checks were deferred so they can
be performed immediately before an eligible write. No unattended retry or
scheduler was created. Next substantive work remains YouTube 403 diagnosis and
recoverable published tracklists, without enabling the DIG release gate or
changing recommendation experiments.

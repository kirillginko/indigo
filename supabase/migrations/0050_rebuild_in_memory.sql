-- Let the graph rebuild sort in memory.
--
-- The instance runs with work_mem at 2 MB, so the rebuild spilled every sort
-- and hash to disk: after 0049, about 200 MB of temporary files per run, which
-- spends the same Disk IO budget 0049 was written to save. At 16 MB it spills
-- about 86 MB. Not more: this is a 0.5 GB instance with 224 MB of shared
-- buffers, and a hash may use twice work_mem, so a larger setting is room
-- the rest of the database would need.
--
-- Only for this function, and only while it runs.
--
-- Safe to re-run.

alter function public.rebuild_radio_dig_edges() set work_mem = '16MB';

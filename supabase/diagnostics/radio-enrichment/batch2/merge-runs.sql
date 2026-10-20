begin read only; select jobname,start_time,end_time,status,return_message from cron.job_run_details join cron.job using(jobid) where jobname ilike '%merge%' order by start_time desc limit 3; commit;

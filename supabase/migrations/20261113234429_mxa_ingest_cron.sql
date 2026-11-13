-- MxA ingest cron jobs (inactive until Vault credentials are set).
-- 11:15 UTC is 5:15 AM CST.
-- Does not touch existing cron job 1 (gmail poller).

do $$
declare
  r record;
begin
  for r in
    select jobid, jobname
    from cron.job
    where jobname in (
      'mxa-ingest-podbean',
      'mxa-ingest-podbean-retry',
      'mxa-ingest-x',
      'mxa-ingest-x-retry'
    )
  loop
    perform cron.unschedule(r.jobid);
  end loop;
end $$;

-- Primary daily runs at 11:15 UTC (5:15 AM CST)
select cron.schedule(
  'mxa-ingest-podbean',
  '15 11 * * *',
  $$select public.invoke_ingest('ingest-podbean');$$
);

select cron.schedule(
  'mxa-ingest-x',
  '15 11 * * *',
  $$select public.invoke_ingest('ingest-x');$$
);

-- Retry one hour later
select cron.schedule(
  'mxa-ingest-podbean-retry',
  '15 12 * * *',
  $$select public.invoke_ingest('ingest-podbean', true);$$
);

select cron.schedule(
  'mxa-ingest-x-retry',
  '15 12 * * *',
  $$select public.invoke_ingest('ingest-x', true);$$
);

-- Leave inactive until credentials are in Vault
do $$
declare
  r record;
begin
  for r in
    select jobid
    from cron.job
    where jobname in (
      'mxa-ingest-podbean',
      'mxa-ingest-podbean-retry',
      'mxa-ingest-x',
      'mxa-ingest-x-retry'
    )
  loop
    perform cron.alter_job(r.jobid, active := false);
  end loop;
end $$;

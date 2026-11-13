# Rollback Phase 1 (MxA audience warehouse)

Safe to run after reviewing. Does not touch `sponsor_sheet`, `sponsor_unlocks`, emails, summaries, or the existing gmail poller cron job.

Migrations in this phase:

- `20261113234404_mxa_audience_warehouse.sql`
- `20261113234411_mxa_ingest_functions.sql`
- `20261113234418_mxa_metric_views.sql`
- `20261113234429_mxa_ingest_cron.sql`
- `20261113235136_mxa_ingest_apply_fixes.sql`

## 1. Unschedule ingest cron jobs

```sql
select cron.unschedule(jobid)
from cron.job
where jobname in (
  'mxa-ingest-podbean',
  'mxa-ingest-podbean-retry',
  'mxa-ingest-x',
  'mxa-ingest-x-retry'
);
```

## 2. Drop views and functions (dependency order)

```sql
drop view if exists public.v_sponsor_sheet;
drop view if exists public.v_episode_delivery;
drop view if exists public.v_podbean_l30d_platforms;
drop view if exists public.v_podbean_l30d_countries;
drop view if exists public.v_podbean_l30d_apps;
drop view if exists public.v_metrics_l12m;
drop view if exists public.v_metrics_l30d;

drop function if exists public.sponsor_sheet_candidate(date);
drop function if exists public.metrics_months(date, int);
drop function if exists public.metrics_window(date, int);
drop function if exists public.invoke_ingest(text, boolean);
drop function if exists public.ingest_apply(text, jsonb);
drop function if exists public.ingest_log(text, text, text, jsonb);
drop function if exists public.ingest_secret_ok(text);
drop function if exists public.ingest_secret(text);
```

## 3. Drop tables (dependency order)

```sql
drop table if exists public.sponsor_webhooks;
drop table if exists public.sponsor_flights;
drop table if exists public.ingest_runs;
drop table if exists public.metrics_daily_dims;
drop table if exists public.metrics_daily;
drop table if exists public.episodes;
drop table if exists public.audience_sources;
```

## 4. Delete Vault secrets created for this phase

```sql
delete from vault.secrets
where name in (
  'PODBEAN_CLIENT_ID',
  'PODBEAN_CLIENT_SECRET',
  'PODBEAN_REFRESH_TOKEN',
  'X_BEARER_TOKEN',
  'INGEST_SECRET'
);
```

## 5. Delete edge functions

Dashboard: Edge Functions -> delete `ingest-podbean` and `ingest-x`.

Or CLI (run yourself; this repo does not deploy):

```bash
supabase functions delete ingest-podbean --project-ref dmqzmnggiswmocettldx
supabase functions delete ingest-x --project-ref dmqzmnggiswmocettldx
```

## Untouched by this change

- `public.sponsor_sheet`
- `public.sponsor_unlocks`
- sponsor-unlock edge function / site files
- `public.emails`, `public.summaries`
- Existing cron job 1 (gmail poller)

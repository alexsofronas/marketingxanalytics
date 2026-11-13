# MxA audience data pipeline (Phase 1)

Warehouse, ingest RPCs, reporting views, and edge functions for Podbean and X.
Project: `dmqzmnggiswmocettldx`. Does not change `sponsor_sheet`, unlock, emails, or summaries.

## Objects

### Tables (`20261113234404_mxa_audience_warehouse.sql`)

| Table | Role |
| --- | --- |
| `audience_sources` | Catalog of platforms and their native unit (download, view, etc.) |
| `episodes` | Podbean episode catalog (optional YouTube / Spotify / Apple ids) |
| `metrics_daily` | Daily (and monthly) metric facts; `episode_id` is not a FK |
| `metrics_daily_dims` | App / country / platform breakdowns |
| `ingest_runs` | Run log for every ingest (success, failed, skipped) |
| `sponsor_flights` | Future sponsor delivery windows |
| `sponsor_webhooks` | Optional push targets for flight events |

All tables have RLS on, privileges revoked from `anon` / `authenticated` / `public`, granted to `service_role`.

### Functions (`20261113234411_mxa_ingest_functions.sql`)

| Function | Role |
| --- | --- |
| `ingest_apply(job, payload)` | Single write path: upsert episodes / metrics / dims, unit guard, complete-day guard, quality flags, reconciliation |
| `ingest_log(...)` | Record a finished run (skipped / missing creds / API errors) |
| `ingest_secret(name)` | Read one allowlisted Vault secret (never returns `UNSET`) |
| `ingest_secret_ok(given)` | Constant-time-ish check of `INGEST_SECRET` |
| `invoke_ingest(fn, retry)` | pg_cron helper: posts to the edge function with the Vault secret in the header |

Vault placeholders created if missing: `PODBEAN_CLIENT_ID`, `PODBEAN_CLIENT_SECRET`, `PODBEAN_REFRESH_TOKEN`, `X_BEARER_TOKEN` (value `UNSET`), and `INGEST_SECRET` (random hex).

### Views / reporting (`20261113234418_mxa_metric_views.sql`)

- `metrics_window` / `v_metrics_l30d`: show-level window aggregates (America/Chicago). Downloads sum; unique listeners avg_daily; EOD latest. Flagged days excluded from `value_excl_flagged`.
- `metrics_months` / `v_metrics_l12m`: monthly downloads from `downloads_monthly` plus monthly sums for other additive sources.
- `v_podbean_l30d_apps|countries|platforms`: dim share for the last 30 complete days.
- `v_episode_delivery`: per-episode Podbean / YouTube / X columns kept separate (never summed across platforms).
- `sponsor_sheet_candidate` / `v_sponsor_sheet`: builds a candidate sheet JSON from current `sponsor_sheet.rows` without writing.

### Cron (`20261113234429_mxa_ingest_cron.sql`)

Four jobs, created inactive:

- `mxa-ingest-podbean` / `mxa-ingest-x` at `15 11 * * *` (11:15 UTC = 5:15 AM CST)
- `mxa-ingest-podbean-retry` / `mxa-ingest-x-retry` at `15 12 * * *`

Commands call `public.invoke_ingest(...)` only. The secret is read from Vault inside the function, never embedded in `cron.job.command`. Existing gmail poller job is untouched.

### Edge functions

- `ingest-podbean`: OAuth + Podbean stats / listeners / dims / episodes -> `ingest_apply`
- `ingest-x`: followers EOD + post impressions / video views -> `ingest_apply`

Both require header `x-ingest-secret` and deploy with `verify_jwt=false`.

## Set credentials

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'PODBEAN_CLIENT_ID'),
  '<value>'
);
select vault.update_secret(
  (select id from vault.secrets where name = 'PODBEAN_CLIENT_SECRET'),
  '<value>'
);
-- optional refresh-token fallback:
select vault.update_secret(
  (select id from vault.secrets where name = 'PODBEAN_REFRESH_TOKEN'),
  '<value>'
);
select vault.update_secret(
  (select id from vault.secrets where name = 'X_BEARER_TOKEN'),
  '<value>'
);
-- INGEST_SECRET is random at create time; rotate if needed:
select vault.update_secret(
  (select id from vault.secrets where name = 'INGEST_SECRET'),
  encode(extensions.gen_random_bytes(32), 'hex')
);
```

## Turn cron on

After credentials are in Vault and edge functions are deployed:

```sql
select cron.alter_job(jobid, active := true)
from cron.job
where jobname like 'mxa-ingest-%';
```

## Run tests

Paste `supabase/tests/phase1_tests.sql` into the SQL editor. It creates `pg_temp` helpers, runs fixtures inside rolled-back subtransactions, and returns `(test_name, pass, detail)`. Nothing is left behind.

## Manual backfill

The first load on Nov 13, 2026 was written with `ingest_apply` from Podbean and X data pulled through the interactive connectors (job names `podbean-mcp-backfill` and `x-mcp-backfill`), because no Podbean API client or X token was in Vault yet.

Later catch-ups can use the same payload shape the edge functions build:

```sql
select public.ingest_apply('ingest-podbean', '{ ... }'::jsonb);
```

Or POST to the edge function with `x-ingest-secret` and body `{ "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "mode": "catchup" }`.

## Prepared, not applied

Files under `supabase/prepared/` are ready to run only after explicit approval. They are not migrations.

- `sponsor_sheet_update.sql` - updates `public.sponsor_sheet` id 1 with downloads figures (preview SELECT included; run only after Alexander approves)
- `sponsor-html-teaser.patch` - teaser row, footnote rendering, and CSS for `sponsor.html` (`git apply` when ready; not applied in this repo pass)

-- MxA audience warehouse: sources, episodes, metrics, ingest runs, sponsor flights.
-- Does not alter sponsor_sheet, sponsor_unlocks, emails, or summaries.

-- ---------------------------------------------------------------------------
-- audience_sources
-- ---------------------------------------------------------------------------
create table public.audience_sources (
  source_id text primary key,
  display_name text not null,
  unit text not null
    check (unit in (
      'download',
      'unique_listener',
      'view',
      'impression',
      'play',
      'subscriber',
      'follower',
      'session'
    )),
  in_podbean_host_total boolean not null default false,
  notes text
);

alter table public.audience_sources enable row level security;
revoke all on table public.audience_sources from anon, authenticated, public;
grant all on table public.audience_sources to service_role;

insert into public.audience_sources (source_id, display_name, unit, in_podbean_host_total, notes)
values
  ('podbean', 'Podbean', 'download', true, null),
  ('x', 'X (Twitter)', 'impression', false, null),
  ('youtube', 'YouTube', 'view', false, 'stub'),
  ('spotify_creators', 'Spotify for Creators', 'play', false, 'stub'),
  ('apple_connect', 'Apple Podcasts Connect', 'play', false, 'stub'),
  ('linkedin_page', 'LinkedIn Page', 'view', false, 'stub'),
  ('linkedin_newsletter', 'LinkedIn Newsletter', 'subscriber', false, 'stub'),
  ('tiktok', 'TikTok', 'view', false, 'stub'),
  ('ga4', 'Google Analytics 4', 'session', false, 'stub')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- episodes
-- ---------------------------------------------------------------------------
create table public.episodes (
  podbean_episode_id text primary key,
  title text,
  publish_at timestamptz,
  season_number int,
  episode_number int,
  duration_sec int,
  permalink_url text,
  youtube_video_ids text[],
  spotify_episode_uri text,
  apple_episode_id text,
  is_sponsored boolean not null default false,
  sponsor_name text,
  raw jsonb,
  updated_at timestamptz not null default now()
);

alter table public.episodes enable row level security;
revoke all on table public.episodes from anon, authenticated, public;
grant all on table public.episodes to service_role;

-- ---------------------------------------------------------------------------
-- metrics_daily
-- episode_id is intentionally NOT a FK (X posts may have no episode;
-- podbean episode metrics may arrive before episode sync).
-- ---------------------------------------------------------------------------
create table public.metrics_daily (
  id bigserial primary key,
  metric_date date not null,
  source_id text not null references public.audience_sources (source_id),
  episode_id text null,
  metric text not null
    check (metric in (
      'downloads',
      'downloads_monthly',
      'unique_listeners_daily',
      'views',
      'watch_seconds',
      'impressions',
      'video_views',
      'plays',
      'followers_eod',
      'subscribers_eod',
      'newsletter_subscribers_eod'
    )),
  value numeric not null,
  quality_flag text
    check (quality_flag in ('ok', 'suspect_bot', 'partial_day', 'definition_change')),
  raw jsonb,
  ingested_at timestamptz not null default now()
);

create unique index metrics_daily_uq
  on public.metrics_daily (metric_date, source_id, metric, (coalesce(episode_id, '')));

create index metrics_daily_episode_id_idx
  on public.metrics_daily (episode_id);

alter table public.metrics_daily enable row level security;
revoke all on table public.metrics_daily from anon, authenticated, public;
grant all on table public.metrics_daily to service_role;
grant all on sequence public.metrics_daily_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- metrics_daily_dims
-- ---------------------------------------------------------------------------
create table public.metrics_daily_dims (
  id bigserial primary key,
  metric_date date not null,
  source_id text not null references public.audience_sources (source_id),
  metric text not null default 'downloads',
  dim_type text not null
    check (dim_type in ('app', 'country', 'platform', 'youtube_format')),
  dim_value text not null,
  value numeric not null,
  raw jsonb,
  ingested_at timestamptz default now()
);

create unique index metrics_daily_dims_uq
  on public.metrics_daily_dims (metric_date, source_id, metric, dim_type, dim_value);

alter table public.metrics_daily_dims enable row level security;
revoke all on table public.metrics_daily_dims from anon, authenticated, public;
grant all on table public.metrics_daily_dims to service_role;
grant all on sequence public.metrics_daily_dims_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- ingest_runs
-- ---------------------------------------------------------------------------
create table public.ingest_runs (
  id bigserial primary key,
  job_name text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null
    check (status in ('running', 'success', 'failed', 'skipped')),
  rows_upserted int not null default 0,
  error text,
  window_start date,
  window_end date,
  meta jsonb not null default '{}'::jsonb
);

alter table public.ingest_runs enable row level security;
revoke all on table public.ingest_runs from anon, authenticated, public;
grant all on table public.ingest_runs to service_role;
grant all on sequence public.ingest_runs_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- sponsor_flights
-- ---------------------------------------------------------------------------
create table public.sponsor_flights (
  id bigserial primary key,
  sponsor_name text not null,
  sponsor_email text,
  episode_ids text[],
  starts_on date,
  ends_on date,
  committed_metric text,
  committed_value numeric,
  notes text,
  created_at timestamptz default now()
);

alter table public.sponsor_flights enable row level security;
revoke all on table public.sponsor_flights from anon, authenticated, public;
grant all on table public.sponsor_flights to service_role;
grant all on sequence public.sponsor_flights_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- sponsor_webhooks
-- ---------------------------------------------------------------------------
create table public.sponsor_webhooks (
  id bigserial primary key,
  sponsor_flight_id bigint references public.sponsor_flights (id) on delete cascade,
  url text not null,
  secret_vault_id uuid,
  events text[] not null default '{}'::text[]
    check (events <@ array['daily_close', 'flight_weekly', 'flight_final']::text[]),
  active boolean not null default false
);

alter table public.sponsor_webhooks enable row level security;
revoke all on table public.sponsor_webhooks from anon, authenticated, public;
grant all on table public.sponsor_webhooks to service_role;
grant all on sequence public.sponsor_webhooks_id_seq to service_role;

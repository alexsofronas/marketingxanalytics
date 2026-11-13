-- MxA metric windows, reporting views, and sponsor sheet candidate.
-- Never mix views/impressions/plays into downloads.
-- Never sum unique_listeners_daily.
-- Flagged days stay in raw tables; excluded from _reported / value_excl_flagged.
-- Timezone: America/Chicago.

-- ---------------------------------------------------------------------------
-- metrics_window
-- ---------------------------------------------------------------------------
create or replace function public.metrics_window(
  p_end date default null,
  p_days int default 30
)
returns table (
  source_id text,
  unit text,
  metric text,
  aggregation text,
  window_start date,
  window_end date,
  days_present int,
  value numeric,
  value_excl_flagged numeric,
  flagged_dates date[]
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_end date;
  v_start date;
begin
  v_end := coalesce(
    p_end,
    ((now() at time zone 'America/Chicago')::date - 1)
  );
  v_start := v_end - (p_days - 1);

  return query
  with base as (
    select
      md.source_id,
      src.unit,
      md.metric,
      md.metric_date,
      md.value,
      md.quality_flag
    from public.metrics_daily md
    join public.audience_sources src on src.source_id = md.source_id
    where md.episode_id is null
      and md.metric <> 'downloads_monthly'
      and md.metric_date between v_start and v_end
  ),
  agg as (
    select
      b.source_id,
      b.unit,
      b.metric,
      case
        when b.metric in (
          'downloads', 'views', 'watch_seconds', 'impressions',
          'video_views', 'plays'
        ) then 'sum'
        when b.metric = 'unique_listeners_daily' then 'avg_daily'
        when b.metric like '%_eod' then 'latest'
        else 'sum'
      end as aggregation,
      v_start as window_start,
      v_end as window_end,
      count(distinct b.metric_date)::int as days_present,
      case
        when b.metric = 'unique_listeners_daily' then
          round(avg(b.value), 1)
        when b.metric like '%_eod' then
          (array_agg(b.value order by b.metric_date desc))[1]
        else
          sum(b.value)
      end as value,
      case
        when b.metric = 'unique_listeners_daily' then
          round(avg(b.value) filter (
            where coalesce(b.quality_flag, 'ok') = 'ok'
          ), 1)
        when b.metric like '%_eod' then
          (array_agg(b.value order by b.metric_date desc) filter (
            where coalesce(b.quality_flag, 'ok') = 'ok'
          ))[1]
        else
          coalesce(sum(b.value) filter (
            where coalesce(b.quality_flag, 'ok') = 'ok'
          ), 0)
      end as value_excl_flagged,
      coalesce(
        array_agg(distinct b.metric_date) filter (
          where b.quality_flag is not null and b.quality_flag <> 'ok'
        ),
        '{}'::date[]
      ) as flagged_dates
    from base b
    group by b.source_id, b.unit, b.metric
  )
  select
    a.source_id,
    a.unit,
    a.metric,
    a.aggregation,
    a.window_start,
    a.window_end,
    a.days_present,
    a.value,
    a.value_excl_flagged,
    a.flagged_dates
  from agg a;
end;
$$;

revoke execute on function public.metrics_window(date, int) from public, anon, authenticated;
grant execute on function public.metrics_window(date, int) to service_role;

-- ---------------------------------------------------------------------------
-- metrics_months
-- ---------------------------------------------------------------------------
create or replace function public.metrics_months(
  p_last_complete_month date default null,
  p_months int default 12
)
returns table (
  source_id text,
  unit text,
  metric text,
  aggregation text,
  window_start date,
  window_end date,
  months_present int,
  value numeric,
  value_excl_flagged numeric,
  flagged_dates date[]
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_last_month date;
  v_first_month date;
  v_window_end date;
begin
  -- First day of the previous month in America/Chicago when null
  v_last_month := coalesce(
    date_trunc('month', p_last_complete_month)::date,
    (
      date_trunc(
        'month',
        (now() at time zone 'America/Chicago')::date
      )::date - interval '1 month'
    )::date
  );
  v_first_month := (v_last_month - make_interval(months => p_months - 1))::date;
  v_window_end := (v_last_month + interval '1 month' - interval '1 day')::date;

  return query
  -- Podbean monthly downloads from downloads_monthly rows
  with monthly_podbean as (
    select
      md.source_id,
      src.unit,
      'downloads'::text as metric,
      'sum_monthly'::text as aggregation,
      v_first_month as window_start,
      v_window_end as window_end,
      count(distinct md.metric_date)::int as months_present,
      sum(md.value) as value,
      coalesce(sum(md.value) filter (
        where coalesce(md.quality_flag, 'ok') = 'ok'
      ), 0) as value_excl_flagged,
      coalesce(
        array_agg(distinct md.metric_date) filter (
          where md.quality_flag is not null and md.quality_flag <> 'ok'
        ),
        '{}'::date[]
      ) as flagged_dates
    from public.metrics_daily md
    join public.audience_sources src on src.source_id = md.source_id
    where md.source_id = 'podbean'
      and md.metric = 'downloads_monthly'
      and md.episode_id is null
      and md.metric_date between v_first_month and v_last_month
    group by md.source_id, src.unit
  ),
  -- Other sources: monthly sums of additive daily metrics
  daily_as_months as (
    select
      md.source_id,
      src.unit,
      md.metric,
      'sum_monthly'::text as aggregation,
      v_first_month as window_start,
      v_window_end as window_end,
      count(distinct date_trunc('month', md.metric_date)::date)::int as months_present,
      sum(md.value) as value,
      coalesce(sum(md.value) filter (
        where coalesce(md.quality_flag, 'ok') = 'ok'
      ), 0) as value_excl_flagged,
      coalesce(
        array_agg(distinct md.metric_date) filter (
          where md.quality_flag is not null and md.quality_flag <> 'ok'
        ),
        '{}'::date[]
      ) as flagged_dates
    from public.metrics_daily md
    join public.audience_sources src on src.source_id = md.source_id
    where md.episode_id is null
      and md.source_id <> 'podbean'
      and md.metric in (
        'downloads', 'views', 'watch_seconds', 'impressions',
        'video_views', 'plays'
      )
      and md.metric_date between v_first_month and v_window_end
    group by md.source_id, src.unit, md.metric
  )
  select * from monthly_podbean
  union all
  select * from daily_as_months;
end;
$$;

revoke execute on function public.metrics_months(date, int) from public, anon, authenticated;
grant execute on function public.metrics_months(date, int) to service_role;

-- ---------------------------------------------------------------------------
-- Simple window views
-- ---------------------------------------------------------------------------
create or replace view public.v_metrics_l30d
with (security_invoker = false)
as
select * from public.metrics_window();

create or replace view public.v_metrics_l12m
with (security_invoker = false)
as
select * from public.metrics_months();

revoke all on table public.v_metrics_l30d from anon, authenticated, public;
grant select on table public.v_metrics_l30d to service_role;

revoke all on table public.v_metrics_l12m from anon, authenticated, public;
grant select on table public.v_metrics_l12m to service_role;

-- ---------------------------------------------------------------------------
-- Podbean L30d dimension breakdowns
-- ---------------------------------------------------------------------------
create or replace view public.v_podbean_l30d_apps
with (security_invoker = false)
as
with w as (
  select
    ((now() at time zone 'America/Chicago')::date - 1) as window_end,
    ((now() at time zone 'America/Chicago')::date - 30) as window_start
),
agg as (
  select
    d.dim_value,
    sum(d.value) as downloads
  from public.metrics_daily_dims d, w
  where d.source_id = 'podbean'
    and d.dim_type = 'app'
    and d.metric = 'downloads'
    and d.metric_date between w.window_start and w.window_end
  group by d.dim_value
),
tot as (
  select coalesce(sum(downloads), 0) as total from agg
)
select
  a.dim_value,
  a.downloads,
  case when t.total = 0 then 0
       else round(100.0 * a.downloads / t.total, 1)
  end as share_pct
from agg a, tot t
order by a.downloads desc;

create or replace view public.v_podbean_l30d_countries
with (security_invoker = false)
as
with w as (
  select
    ((now() at time zone 'America/Chicago')::date - 1) as window_end,
    ((now() at time zone 'America/Chicago')::date - 30) as window_start
),
agg as (
  select
    d.dim_value,
    sum(d.value) as downloads
  from public.metrics_daily_dims d, w
  where d.source_id = 'podbean'
    and d.dim_type = 'country'
    and d.metric = 'downloads'
    and d.metric_date between w.window_start and w.window_end
  group by d.dim_value
),
tot as (
  select coalesce(sum(downloads), 0) as total from agg
)
select
  a.dim_value,
  a.downloads,
  case when t.total = 0 then 0
       else round(100.0 * a.downloads / t.total, 1)
  end as share_pct
from agg a, tot t
order by a.downloads desc;

create or replace view public.v_podbean_l30d_platforms
with (security_invoker = false)
as
with w as (
  select
    ((now() at time zone 'America/Chicago')::date - 1) as window_end,
    ((now() at time zone 'America/Chicago')::date - 30) as window_start
),
agg as (
  select
    d.dim_value,
    sum(d.value) as downloads
  from public.metrics_daily_dims d, w
  where d.source_id = 'podbean'
    and d.dim_type = 'platform'
    and d.metric = 'downloads'
    and d.metric_date between w.window_start and w.window_end
  group by d.dim_value
),
tot as (
  select coalesce(sum(downloads), 0) as total from agg
)
select
  a.dim_value,
  a.downloads,
  case when t.total = 0 then 0
       else round(100.0 * a.downloads / t.total, 1)
  end as share_pct
from agg a, tot t
order by a.downloads desc;

revoke all on table public.v_podbean_l30d_apps from anon, authenticated, public;
grant select on table public.v_podbean_l30d_apps to service_role;

revoke all on table public.v_podbean_l30d_countries from anon, authenticated, public;
grant select on table public.v_podbean_l30d_countries to service_role;

revoke all on table public.v_podbean_l30d_platforms from anon, authenticated, public;
grant select on table public.v_podbean_l30d_platforms to service_role;

-- ---------------------------------------------------------------------------
-- Episode delivery (columns kept separate; never summed across platforms)
-- ---------------------------------------------------------------------------
create or replace view public.v_episode_delivery
with (security_invoker = false)
as
with w as (
  select
    ((now() at time zone 'America/Chicago')::date - 1) as window_end,
    ((now() at time zone 'America/Chicago')::date - 30) as window_start
),
pb_life as (
  select episode_id, sum(value) as downloads_lifetime
  from public.metrics_daily
  where source_id = 'podbean'
    and metric = 'downloads'
    and episode_id is not null
  group by episode_id
),
pb_l30 as (
  select m.episode_id, sum(m.value) as downloads_l30d
  from public.metrics_daily m, w
  where m.source_id = 'podbean'
    and m.metric = 'downloads'
    and m.episode_id is not null
    and m.metric_date between w.window_start and w.window_end
  group by m.episode_id
),
yt as (
  select episode_id, sum(value) as youtube_views
  from public.metrics_daily
  where source_id = 'youtube'
    and metric = 'views'
    and episode_id is not null
  group by episode_id
),
x_imp as (
  select episode_id, sum(value) as x_impressions
  from public.metrics_daily
  where source_id = 'x'
    and metric = 'impressions'
    and episode_id is not null
  group by episode_id
),
x_vv as (
  select episode_id, sum(value) as x_video_views
  from public.metrics_daily
  where source_id = 'x'
    and metric = 'video_views'
    and episode_id is not null
  group by episode_id
)
select
  e.podbean_episode_id,
  e.title,
  e.publish_at,
  coalesce(pb_life.downloads_lifetime, 0) as podbean_downloads_lifetime,
  coalesce(pb_l30.downloads_l30d, 0) as podbean_downloads_l30d,
  coalesce(yt.youtube_views, 0) as youtube_views,
  coalesce(x_imp.x_impressions, 0) as x_impressions,
  coalesce(x_vv.x_video_views, 0) as x_video_views
from public.episodes e
left join pb_life on pb_life.episode_id = e.podbean_episode_id
left join pb_l30 on pb_l30.episode_id = e.podbean_episode_id
left join yt on yt.episode_id = e.podbean_episode_id
left join x_imp on x_imp.episode_id = e.podbean_episode_id
left join x_vv on x_vv.episode_id = e.podbean_episode_id;

revoke all on table public.v_episode_delivery from anon, authenticated, public;
grant select on table public.v_episode_delivery to service_role;

-- ---------------------------------------------------------------------------
-- sponsor_sheet_candidate (read-only; does not write sponsor_sheet)
-- ---------------------------------------------------------------------------
create or replace function public.sponsor_sheet_candidate(
  p_end date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_end date;
  v_l30 record;
  v_l12 record;
  v_uniques record;
  v_sheet_rows jsonb;
  v_out_rows jsonb := '[]'::jsonb;
  v_row jsonb;
  v_label text;
  v_value text;
  v_footnote text;
  v_footnotes jsonb := '[]'::jsonb;
  v_flagged date[];
  v_fd date;
  v_dl numeric;
  v_ul numeric;
  v_parts text[] := '{}'::text[];
  v_l30_fmt text;
  v_l12_fmt text;
  v_excl numeric;
  v_as_of date;
  v_l12_start date;
  v_l12_end date;
  v_inserted_l30 boolean := false;
begin
  v_end := coalesce(
    p_end,
    ((now() at time zone 'America/Chicago')::date - 1)
  );
  v_as_of := v_end;

  select *
    into v_l30
  from public.metrics_window(v_end, 30)
  where source_id = 'podbean' and metric = 'downloads'
  limit 1;

  select *
    into v_l12
  from public.metrics_months(null, 12)
  where source_id = 'podbean' and metric = 'downloads'
  limit 1;

  select *
    into v_uniques
  from public.metrics_window(v_end, 30)
  where source_id = 'podbean' and metric = 'unique_listeners_daily'
  limit 1;

  v_l12_start := coalesce(v_l12.window_start, date_trunc('month', v_end - interval '12 months')::date);
  v_l12_end := coalesce(v_l12.window_end, (date_trunc('month', v_end)::date - interval '1 day')::date);

  v_l12_fmt := coalesce(
    trim(to_char(coalesce(v_l12.value, 0), 'FM999,999,999,999')),
    '0'
  );
  v_l30_fmt := coalesce(
    trim(to_char(coalesce(v_l30.value, 0), 'FM999,999,999,999')),
    '0'
  );
  v_excl := coalesce(v_l30.value_excl_flagged, v_l30.value, 0);
  v_flagged := coalesce(v_l30.flagged_dates, '{}'::date[]);

  -- Build footnote from flagged dates
  if array_length(v_flagged, 1) is not null then
    foreach v_fd in array v_flagged loop
      select md.value into v_dl
      from public.metrics_daily md
      where md.source_id = 'podbean'
        and md.metric = 'downloads'
        and md.episode_id is null
        and md.metric_date = v_fd;

      select md.value into v_ul
      from public.metrics_daily md
      where md.source_id = 'podbean'
        and md.metric = 'unique_listeners_daily'
        and md.episode_id is null
        and md.metric_date = v_fd;

      v_parts := v_parts || format(
        '%s had an unusual spike of %s downloads from %s listeners',
        to_char(v_fd, 'Mon FMDD'),
        trim(to_char(coalesce(v_dl, 0), 'FM999,999,999')),
        trim(to_char(coalesce(v_ul, 0), 'FM999,999,999'))
      );
    end loop;

    v_footnote := array_to_string(v_parts, '; ')
      || '; '
      || trim(to_char(v_excl, 'FM999,999,999'))
      || ' without that day';
    v_footnotes := v_footnotes || to_jsonb(v_footnote);
  else
    v_footnote := null;
  end if;

  -- Start from current sponsor_sheet.rows labels in order
  select rows into v_sheet_rows
  from public.sponsor_sheet
  order by id
  limit 1;

  if v_sheet_rows is null then
    v_sheet_rows := '[]'::jsonb;
  end if;

  for v_row in select * from jsonb_array_elements(v_sheet_rows)
  loop
    v_label := v_row ->> 'label';
    v_value := v_row ->> 'value';

    if v_label = 'Downloads, last 12 months' then
      v_out_rows := v_out_rows || jsonb_build_array(
        jsonb_build_object('label', v_label, 'value', v_l12_fmt)
      );
      -- Insert L30d row right after
      if v_footnote is not null then
        v_out_rows := v_out_rows || jsonb_build_array(
          jsonb_build_object(
            'label', 'Downloads, last 30 days',
            'value', v_l30_fmt,
            'footnote', v_footnote
          )
        );
      else
        v_out_rows := v_out_rows || jsonb_build_array(
          jsonb_build_object(
            'label', 'Downloads, last 30 days',
            'value', v_l30_fmt
          )
        );
      end if;
      v_inserted_l30 := true;
    else
      -- Leave every other row (including Unique listeners) exactly as-is
      v_out_rows := v_out_rows || jsonb_build_array(v_row);
    end if;
  end loop;

  if not v_inserted_l30 then
    v_out_rows := v_out_rows || jsonb_build_array(
      jsonb_build_object('label', 'Downloads, last 12 months', 'value', v_l12_fmt)
    );
    if v_footnote is not null then
      v_out_rows := v_out_rows || jsonb_build_array(
        jsonb_build_object(
          'label', 'Downloads, last 30 days',
          'value', v_l30_fmt,
          'footnote', v_footnote
        )
      );
    else
      v_out_rows := v_out_rows || jsonb_build_array(
        jsonb_build_object(
          'label', 'Downloads, last 30 days',
          'value', v_l30_fmt
        )
      );
    end if;
  end if;

  return jsonb_build_object(
    'as_of', v_as_of,
    'window_l30d', jsonb_build_object(
      'start', coalesce(v_l30.window_start, v_end - 29),
      'end', coalesce(v_l30.window_end, v_end)
    ),
    'window_l12m', jsonb_build_object(
      'start', v_l12_start,
      'end', v_l12_end
    ),
    'rows', v_out_rows,
    'footnotes', v_footnotes,
    'checks', jsonb_build_object(
      'podbean_downloads_l30d', coalesce(v_l30.value, 0),
      'podbean_downloads_l30d_excl_flagged', v_excl,
      'podbean_downloads_l12m', coalesce(v_l12.value, 0),
      'avg_daily_uniques_l30d', coalesce(v_uniques.value, 0),
      'flagged_dates', to_jsonb(v_flagged)
    )
  );
end;
$$;

revoke execute on function public.sponsor_sheet_candidate(date) from public, anon, authenticated;
grant execute on function public.sponsor_sheet_candidate(date) to service_role;

create or replace view public.v_sponsor_sheet
with (security_invoker = false)
as
select public.sponsor_sheet_candidate() as candidate;

revoke all on table public.v_sponsor_sheet from anon, authenticated, public;
grant select on table public.v_sponsor_sheet to service_role;

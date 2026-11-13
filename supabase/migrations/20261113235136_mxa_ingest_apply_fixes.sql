-- MxA ingest_apply fixes: real run duration + skip podbean post-steps when no podbean payload
-- Replaces public.ingest_apply only. Does not alter 20261113234411_mxa_ingest_functions.sql.

create or replace function public.ingest_apply(
  p_job text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_run_id bigint;
  v_row public.ingest_runs%rowtype;
  v_window_start date;
  v_window_end date;
  v_meta jsonb;
  v_rows_upserted int := 0;
  v_ep jsonb;
  v_m jsonb;
  v_d jsonb;
  v_unit text;
  v_today_chi date;
  v_flagged date[] := '{}'::date[];
  v_reconciliation jsonb := '{}'::jsonb;
  v_dim_type text;
  v_dims_total numeric;
  v_show_total numeric;
  v_err text;
begin
  v_today_chi := (now() at time zone 'America/Chicago')::date;
  v_window_start := (p_payload ->> 'window_start')::date;
  v_window_end := (p_payload ->> 'window_end')::date;
  v_meta := coalesce(p_payload -> 'meta', '{}'::jsonb);

  insert into public.ingest_runs (job_name, status, window_start, window_end, meta)
  values (p_job, 'running', v_window_start, v_window_end, v_meta)
  returning id into v_run_id;

  begin
    -- Episodes
    for v_ep in
      select * from jsonb_array_elements(coalesce(p_payload -> 'episodes', '[]'::jsonb))
    loop
      insert into public.episodes (
        podbean_episode_id,
        title,
        publish_at,
        season_number,
        episode_number,
        duration_sec,
        permalink_url,
        raw,
        updated_at
      ) values (
        v_ep ->> 'podbean_episode_id',
        v_ep ->> 'title',
        nullif(v_ep ->> 'publish_at', '')::timestamptz,
        nullif(v_ep ->> 'season_number', '')::int,
        nullif(v_ep ->> 'episode_number', '')::int,
        nullif(v_ep ->> 'duration_sec', '')::int,
        v_ep ->> 'permalink_url',
        v_ep -> 'raw',
        now()
      )
      on conflict (podbean_episode_id) do update set
        title = coalesce(excluded.title, public.episodes.title),
        publish_at = coalesce(excluded.publish_at, public.episodes.publish_at),
        season_number = coalesce(excluded.season_number, public.episodes.season_number),
        episode_number = coalesce(excluded.episode_number, public.episodes.episode_number),
        duration_sec = coalesce(excluded.duration_sec, public.episodes.duration_sec),
        permalink_url = coalesce(excluded.permalink_url, public.episodes.permalink_url),
        raw = coalesce(excluded.raw, public.episodes.raw),
        updated_at = now();

      v_rows_upserted := v_rows_upserted + 1;
    end loop;

    -- Metrics
    for v_m in
      select * from jsonb_array_elements(coalesce(p_payload -> 'metrics', '[]'::jsonb))
    loop
      select unit into v_unit
      from public.audience_sources
      where source_id = v_m ->> 'source_id';

      if (v_m ->> 'metric') in ('downloads', 'downloads_monthly')
         and v_unit is distinct from 'download' then
        raise exception
          'unit guard: metric % not allowed for source % (unit %)',
          v_m ->> 'metric',
          v_m ->> 'source_id',
          coalesce(v_unit, 'missing');
      end if;

      -- Complete days only (America/Chicago). downloads_monthly may be current month
      -- and is flagged partial_day instead of rejected.
      if (v_m ->> 'metric') = 'downloads_monthly' then
        null; -- allowed even for current month
      elsif (v_m ->> 'metric_date')::date >= v_today_chi then
        raise exception
          'incomplete day rejected: metric_date % >= today % (America/Chicago)',
          v_m ->> 'metric_date',
          v_today_chi;
      end if;

      insert into public.metrics_daily (
        metric_date,
        source_id,
        episode_id,
        metric,
        value,
        quality_flag,
        raw,
        ingested_at
      ) values (
        (v_m ->> 'metric_date')::date,
        v_m ->> 'source_id',
        nullif(v_m ->> 'episode_id', ''),
        v_m ->> 'metric',
        (v_m ->> 'value')::numeric,
        case
          when (v_m ->> 'metric') = 'downloads_monthly'
               and date_trunc('month', (v_m ->> 'metric_date')::date)::date
                   = date_trunc('month', v_today_chi)::date
            then 'partial_day'
          else null
        end,
        v_m -> 'raw',
        now()
      )
      on conflict (metric_date, source_id, metric, (coalesce(episode_id, '')))
      do update set
        value = excluded.value,
        raw = excluded.raw,
        ingested_at = now(),
        -- Keep existing quality_flag unless this insert supplies a new one
        -- (recompute step below sets suspect_bot / ok for podbean downloads).
        quality_flag = coalesce(excluded.quality_flag, public.metrics_daily.quality_flag);

      v_rows_upserted := v_rows_upserted + 1;
    end loop;

    -- Dims
    for v_d in
      select * from jsonb_array_elements(coalesce(p_payload -> 'dims', '[]'::jsonb))
    loop
      select unit into v_unit
      from public.audience_sources
      where source_id = v_d ->> 'source_id';

      if coalesce(v_d ->> 'metric', 'downloads') = 'downloads'
         and v_unit is distinct from 'download' then
        raise exception
          'unit guard: metric % not allowed for source % (unit %)',
          coalesce(v_d ->> 'metric', 'downloads'),
          v_d ->> 'source_id',
          coalesce(v_unit, 'missing');
      end if;

      if (v_d ->> 'metric_date')::date >= v_today_chi then
        raise exception
          'incomplete day rejected: metric_date % >= today % (America/Chicago)',
          v_d ->> 'metric_date',
          v_today_chi;
      end if;

      insert into public.metrics_daily_dims (
        metric_date,
        source_id,
        metric,
        dim_type,
        dim_value,
        value,
        ingested_at
      ) values (
        (v_d ->> 'metric_date')::date,
        v_d ->> 'source_id',
        coalesce(v_d ->> 'metric', 'downloads'),
        v_d ->> 'dim_type',
        v_d ->> 'dim_value',
        (v_d ->> 'value')::numeric,
        now()
      )
      on conflict (metric_date, source_id, metric, dim_type, dim_value)
      do update set
        value = excluded.value,
        ingested_at = now();

      v_rows_upserted := v_rows_upserted + 1;
    end loop;

    -- Only recompute podbean quality flags / reconciliation when payload has podbean data
    if exists (
          select 1
          from jsonb_array_elements(coalesce(p_payload -> 'metrics', '[]'::jsonb)) m
          where m ->> 'source_id' = 'podbean'
        )
        or exists (
          select 1
          from jsonb_array_elements(coalesce(p_payload -> 'dims', '[]'::jsonb)) d
          where d ->> 'source_id' = 'podbean'
        )
    then
    -- Recompute quality flags for podbean show-level downloads in window
    update public.metrics_daily md
    set quality_flag = case
      when md.value >= 30
           and exists (
             select 1
             from public.metrics_daily ul
             where ul.metric_date = md.metric_date
               and ul.source_id = 'podbean'
               and ul.metric = 'unique_listeners_daily'
               and ul.episode_id is null
           )
           and md.value / greatest((
             select ul.value
             from public.metrics_daily ul
             where ul.metric_date = md.metric_date
               and ul.source_id = 'podbean'
               and ul.metric = 'unique_listeners_daily'
               and ul.episode_id is null
             limit 1
           ), 1) > 10
        then 'suspect_bot'
      else 'ok'
    end
    where md.source_id = 'podbean'
      and md.metric = 'downloads'
      and md.episode_id is null
      and (v_window_start is null or md.metric_date >= v_window_start)
      and (v_window_end is null or md.metric_date <= v_window_end);

    select coalesce(array_agg(md.metric_date order by md.metric_date), '{}'::date[])
      into v_flagged
    from public.metrics_daily md
    where md.source_id = 'podbean'
      and md.metric = 'downloads'
      and md.episode_id is null
      and md.quality_flag = 'suspect_bot'
      and (v_window_start is null or md.metric_date >= v_window_start)
      and (v_window_end is null or md.metric_date <= v_window_end);

    -- Reconciliation: podbean dims vs show-level downloads for dates that have dims
    for v_dim_type in
      select distinct dim_type
      from public.metrics_daily_dims
      where source_id = 'podbean'
        and (v_window_start is null or metric_date >= v_window_start)
        and (v_window_end is null or metric_date <= v_window_end)
    loop
      select coalesce(sum(d.value), 0)
        into v_dims_total
      from public.metrics_daily_dims d
      where d.source_id = 'podbean'
        and d.dim_type = v_dim_type
        and (v_window_start is null or d.metric_date >= v_window_start)
        and (v_window_end is null or d.metric_date <= v_window_end)
        and d.metric_date in (
          select distinct d2.metric_date
          from public.metrics_daily_dims d2
          where d2.source_id = 'podbean'
            and d2.dim_type = v_dim_type
            and (v_window_start is null or d2.metric_date >= v_window_start)
            and (v_window_end is null or d2.metric_date <= v_window_end)
        );

      select coalesce(sum(md.value), 0)
        into v_show_total
      from public.metrics_daily md
      where md.source_id = 'podbean'
        and md.metric = 'downloads'
        and md.episode_id is null
        and md.metric_date in (
          select distinct d2.metric_date
          from public.metrics_daily_dims d2
          where d2.source_id = 'podbean'
            and d2.dim_type = v_dim_type
            and (v_window_start is null or d2.metric_date >= v_window_start)
            and (v_window_end is null or d2.metric_date <= v_window_end)
        );

      v_reconciliation := v_reconciliation || jsonb_build_object(
        v_dim_type,
        jsonb_build_object(
          'dims_total', v_dims_total,
          'show_total', v_show_total,
          'match', v_dims_total = v_show_total
        )
      );
    end loop;
    else
      v_flagged := '{}'::date[];
      v_reconciliation := '{}'::jsonb;
    end if;

    v_meta := v_meta
      || jsonb_build_object(
           'reconciliation', v_reconciliation,
           'flagged_dates', to_jsonb(v_flagged)
         );

    update public.ingest_runs
    set
      status = 'success',
      finished_at = clock_timestamp(),
      rows_upserted = v_rows_upserted,
      window_start = v_window_start,
      window_end = v_window_end,
      meta = v_meta
    where id = v_run_id
    returning * into v_row;

    return to_jsonb(v_row);

  exception when others then
    v_err := SQLERRM;
    -- Record failure on the existing running row if present; else insert a failed row.
    update public.ingest_runs
    set
      status = 'failed',
      finished_at = clock_timestamp(),
      error = v_err,
      window_start = v_window_start,
      window_end = v_window_end,
      meta = v_meta
    where id = v_run_id
    returning * into v_row;

    if not found then
      insert into public.ingest_runs (
        job_name, started_at, finished_at, status, error, window_start, window_end, meta
      ) values (
        p_job, now(), clock_timestamp(), 'failed', v_err, v_window_start, v_window_end, v_meta
      )
      returning * into v_row;
    end if;

    return to_jsonb(v_row);
  end;
end;
$$;

revoke execute on function public.ingest_apply(text, jsonb) from public, anon, authenticated;
grant execute on function public.ingest_apply(text, jsonb) to service_role;

-- MxA Phase 1 self-contained tests.
-- Paste into the Supabase SQL editor. Leaves no fixture rows behind.
-- Uses pg_temp helpers and P0001 rollback_fixture subtransactions.

create or replace function pg_temp.run_phase1_tests()
returns table (test_name text, pass boolean, detail text)
language plpgsql
as $$
declare
  v jsonb;
  v2 jsonb;
  v_flag text;
  v_ok_flag text;
  v_match boolean;
  v_match_bad boolean;
  v_before numeric;
  v_after numeric;
  v_agg text;
  v_t text;
  v_rls boolean;
  v_priv boolean;
  v_fn boolean;
  v_dl numeric;
  v_excl numeric;
  v_m12 numeric;
  v_nov9 text;
  v_all_tables text[] := array[
    'audience_sources',
    'episodes',
    'metrics_daily',
    'metrics_daily_dims',
    'ingest_runs',
    'sponsor_flights',
    'sponsor_webhooks'
  ];
  v_all_views text[] := array[
    'v_metrics_l30d',
    'v_metrics_l12m',
    'v_podbean_l30d_apps',
    'v_podbean_l30d_countries',
    'v_podbean_l30d_platforms',
    'v_episode_delivery',
    'v_sponsor_sheet'
  ];
begin
  -- -----------------------------------------------------------------------
  -- a) Nov 9 flag (2001 fixtures, far from real data)
  -- -----------------------------------------------------------------------
  begin
    begin
      v := public.ingest_apply(
        'test_fixture',
        jsonb_build_object(
          'window_start', '2001-11-07',
          'window_end', '2001-11-10',
          'meta', jsonb_build_object('test', 'nov9_flag'),
          'episodes', '[]'::jsonb,
          'metrics', jsonb_build_array(
            jsonb_build_object(
              'metric_date', '2001-11-09',
              'source_id', 'podbean',
              'episode_id', null,
              'metric', 'downloads',
              'value', 137
            ),
            jsonb_build_object(
              'metric_date', '2001-11-09',
              'source_id', 'podbean',
              'episode_id', null,
              'metric', 'unique_listeners_daily',
              'value', 7
            ),
            jsonb_build_object(
              'metric_date', '2001-11-08',
              'source_id', 'podbean',
              'episode_id', null,
              'metric', 'downloads',
              'value', 40
            ),
            jsonb_build_object(
              'metric_date', '2001-11-08',
              'source_id', 'podbean',
              'episode_id', null,
              'metric', 'unique_listeners_daily',
              'value', 20
            )
          ),
          'dims', '[]'::jsonb
        )
      );

      select quality_flag into v_flag
      from public.metrics_daily
      where source_id = 'podbean'
        and metric = 'downloads'
        and episode_id is null
        and metric_date = '2001-11-09';

      select quality_flag into v_ok_flag
      from public.metrics_daily
      where source_id = 'podbean'
        and metric = 'downloads'
        and episode_id is null
        and metric_date = '2001-11-08';

      raise exception using errcode = 'P0001', message = 'rollback_fixture';
    exception
      when sqlstate 'P0001' then
        null;
    end;

    test_name := 'a_nov9_flag';
    pass := (v_flag = 'suspect_bot' and v_ok_flag = 'ok' and (v ->> 'status') = 'success');
    detail := format('flag=%s ok_day=%s status=%s', v_flag, v_ok_flag, v ->> 'status');
    return next;
  end;

  -- -----------------------------------------------------------------------
  -- b) Reconciliation match / mismatch
  -- -----------------------------------------------------------------------
  begin
    begin
      v := public.ingest_apply(
        'test_fixture',
        jsonb_build_object(
          'window_start', '2001-06-01',
          'window_end', '2001-06-01',
          'meta', '{}'::jsonb,
          'episodes', '[]'::jsonb,
          'metrics', jsonb_build_array(
            jsonb_build_object(
              'metric_date', '2001-06-01',
              'source_id', 'podbean',
              'episode_id', null,
              'metric', 'downloads',
              'value', 100
            )
          ),
          'dims', jsonb_build_array(
            jsonb_build_object(
              'metric_date', '2001-06-01',
              'source_id', 'podbean',
              'metric', 'downloads',
              'dim_type', 'app',
              'dim_value', 'Apple Podcasts',
              'value', 60
            ),
            jsonb_build_object(
              'metric_date', '2001-06-01',
              'source_id', 'podbean',
              'metric', 'downloads',
              'dim_type', 'app',
              'dim_value', 'Spotify',
              'value', 40
            )
          )
        )
      );
      v_match := (v #>> '{meta,reconciliation,app,match}')::boolean;
      raise exception using errcode = 'P0001', message = 'rollback_fixture';
    exception
      when sqlstate 'P0001' then
        null;
    end;

    begin
      v2 := public.ingest_apply(
        'test_fixture',
        jsonb_build_object(
          'window_start', '2001-06-02',
          'window_end', '2001-06-02',
          'meta', '{}'::jsonb,
          'episodes', '[]'::jsonb,
          'metrics', jsonb_build_array(
            jsonb_build_object(
              'metric_date', '2001-06-02',
              'source_id', 'podbean',
              'episode_id', null,
              'metric', 'downloads',
              'value', 100
            )
          ),
          'dims', jsonb_build_array(
            jsonb_build_object(
              'metric_date', '2001-06-02',
              'source_id', 'podbean',
              'metric', 'downloads',
              'dim_type', 'app',
              'dim_value', 'Apple Podcasts',
              'value', 10
            )
          )
        )
      );
      v_match_bad := (v2 #>> '{meta,reconciliation,app,match}')::boolean;
      raise exception using errcode = 'P0001', message = 'rollback_fixture';
    exception
      when sqlstate 'P0001' then
        null;
    end;

    test_name := 'b_reconciliation';
    pass := (v_match is true and v_match_bad is false);
    detail := format('match=%s mismatch=%s', v_match, v_match_bad);
    return next;
  end;

  -- -----------------------------------------------------------------------
  -- c) Unit guard: youtube downloads fails; youtube views never in podbean
  -- -----------------------------------------------------------------------
  begin
    begin
      v := public.ingest_apply(
        'test_fixture',
        jsonb_build_object(
          'window_start', '2001-03-01',
          'window_end', '2001-03-01',
          'meta', '{}'::jsonb,
          'episodes', '[]'::jsonb,
          'metrics', jsonb_build_array(
            jsonb_build_object(
              'metric_date', '2001-03-01',
              'source_id', 'youtube',
              'episode_id', null,
              'metric', 'downloads',
              'value', 999
            )
          ),
          'dims', '[]'::jsonb
        )
      );
      raise exception using errcode = 'P0001', message = 'rollback_fixture';
    exception
      when sqlstate 'P0001' then
        null;
    end;

    begin
      select coalesce(value, 0) into v_before
      from public.metrics_window('2001-03-05', 10)
      where source_id = 'podbean' and metric = 'downloads';
      v_before := coalesce(v_before, 0);

      perform public.ingest_apply(
        'test_fixture',
        jsonb_build_object(
          'window_start', '2001-03-01',
          'window_end', '2001-03-01',
          'meta', '{}'::jsonb,
          'episodes', '[]'::jsonb,
          'metrics', jsonb_build_array(
            jsonb_build_object(
              'metric_date', '2001-03-01',
              'source_id', 'youtube',
              'episode_id', null,
              'metric', 'views',
              'value', 5000
            )
          ),
          'dims', '[]'::jsonb
        )
      );

      -- youtube views must not change podbean downloads in metrics_window
      select coalesce(value, 0) into v_after
      from public.metrics_window('2001-03-05', 10)
      where source_id = 'podbean' and metric = 'downloads';
      v_after := coalesce(v_after, 0);

      raise exception using errcode = 'P0001', message = 'rollback_fixture';
    exception
      when sqlstate 'P0001' then
        null;
    end;

    test_name := 'c_unit_guard';
    pass := ((v ->> 'status') = 'failed' and v_before = v_after);
    detail := format(
      'yt_downloads_status=%s before=%s after=%s err=%s',
      v ->> 'status',
      v_before,
      v_after,
      left(coalesce(v ->> 'error', ''), 80)
    );
    return next;
  end;

  -- -----------------------------------------------------------------------
  -- d) Unique guard: avg_daily not sum
  -- -----------------------------------------------------------------------
  begin
    begin
      perform public.ingest_apply(
        'test_fixture',
        jsonb_build_object(
          'window_start', '2001-01-01',
          'window_end', '2001-01-02',
          'meta', '{}'::jsonb,
          'episodes', '[]'::jsonb,
          'metrics', jsonb_build_array(
            jsonb_build_object(
              'metric_date', '2001-01-01',
              'source_id', 'podbean',
              'episode_id', null,
              'metric', 'unique_listeners_daily',
              'value', 10
            ),
            jsonb_build_object(
              'metric_date', '2001-01-02',
              'source_id', 'podbean',
              'episode_id', null,
              'metric', 'unique_listeners_daily',
              'value', 20
            )
          ),
          'dims', '[]'::jsonb
        )
      );

      select aggregation, value
        into v_agg, v_after
      from public.metrics_window('2001-01-02', 2)
      where source_id = 'podbean' and metric = 'unique_listeners_daily';

      raise exception using errcode = 'P0001', message = 'rollback_fixture';
    exception
      when sqlstate 'P0001' then
        null;
    end;

    test_name := 'd_unique_avg_daily';
    pass := (v_agg = 'avg_daily' and v_after = 15.0);
    detail := format('aggregation=%s value=%s', v_agg, v_after);
    return next;
  end;

  -- -----------------------------------------------------------------------
  -- e) RLS / grants
  -- -----------------------------------------------------------------------
  begin
    v_priv := true;
    v_rls := true;
    foreach v_t in array v_all_tables loop
      if has_table_privilege('anon', 'public.' || v_t, 'select')
         or has_table_privilege('authenticated', 'public.' || v_t, 'select') then
        v_priv := false;
      end if;
      select c.relrowsecurity into v_fn
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = v_t;
      if not coalesce(v_fn, false) then
        v_rls := false;
      end if;
    end loop;

    foreach v_t in array v_all_views loop
      if has_table_privilege('anon', 'public.' || v_t, 'select')
         or has_table_privilege('authenticated', 'public.' || v_t, 'select') then
        v_priv := false;
      end if;
    end loop;

    v_fn :=
      (not has_function_privilege('anon', 'public.ingest_apply(text,jsonb)', 'execute'))
      and (not has_function_privilege('anon', 'public.ingest_secret(text)', 'execute'))
      and (not has_function_privilege('anon', 'public.invoke_ingest(text,boolean)', 'execute'))
      and (not has_function_privilege('anon', 'public.sponsor_sheet_candidate(date)', 'execute'));

    test_name := 'e_rls_grants';
    pass := (v_priv and v_rls and v_fn);
    detail := format('no_select=%s rls=%s no_exec=%s', v_priv, v_rls, v_fn);
    return next;
  end;

  -- -----------------------------------------------------------------------
  -- f) Real-data checks (pass only when data present)
  -- -----------------------------------------------------------------------
  begin
    select value, value_excl_flagged
      into v_dl, v_excl
    from public.metrics_window('2026-11-12', 30)
    where source_id = 'podbean' and metric = 'downloads';

    select value into v_m12
    from public.metrics_months('2026-10-01', 12)
    where source_id = 'podbean' and metric = 'downloads';

    select quality_flag into v_nov9
    from public.metrics_daily
    where source_id = 'podbean'
      and metric = 'downloads'
      and episode_id is null
      and metric_date = '2026-11-09';

    if v_dl is null and v_m12 is null and v_nov9 is null then
      test_name := 'f_real_data';
      pass := true;
      detail := 'skipped: no real data present yet';
      return next;
    else
      test_name := 'f_real_data';
      pass := (
        v_dl = 513
        and v_excl = 376
        and v_m12 = 6331
        and v_nov9 = 'suspect_bot'
      );
      detail := format(
        'l30d=%s excl=%s l12m=%s nov9=%s',
        v_dl, v_excl, v_m12, v_nov9
      );
      return next;
    end if;
  end;
end;
$$;

select * from pg_temp.run_phase1_tests()
order by test_name;

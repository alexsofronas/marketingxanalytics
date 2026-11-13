-- Preview: would-be rows for public.sponsor_sheet id = 1 (no write).
-- Run only after Alexander approves. Not a migration.
select jsonb_agg(x.obj order by x.ord, x.sub) as would_be_rows
from (
  select
    case
      when e.elem ->> 'label' = 'Downloads, last 12 months'
        then jsonb_set(e.elem, '{value}', to_jsonb('6,331'::text))
      else e.elem
    end as obj,
    e.ord,
    0 as sub
  from public.sponsor_sheet s,
       lateral jsonb_array_elements(s.rows) with ordinality as e(elem, ord)
  where s.id = 1
  union all
  select
    jsonb_build_object(
      'label', 'Downloads, last 30 days',
      'value', '513',
      'footnote', 'Nov 9 had an unusual spike of 137 downloads from 7 listeners; 376 without that day'
    ) as obj,
    e.ord,
    1 as sub
  from public.sponsor_sheet s,
       lateral jsonb_array_elements(s.rows) with ordinality as e(elem, ord)
  where s.id = 1
    and e.elem ->> 'label' = 'Downloads, last 12 months'
) x;

-- Apply: idempotent; no-op if 'Downloads, last 30 days' already exists.
with src as (
  select s.id, s.rows
  from public.sponsor_sheet s
  where s.id = 1
    and not exists (
      select 1
      from jsonb_array_elements(s.rows) e
      where e ->> 'label' = 'Downloads, last 30 days'
    )
),
expanded as (
  select src.id, e.elem, e.ord
  from src,
       lateral jsonb_array_elements(src.rows) with ordinality as e(elem, ord)
),
rebuilt as (
  select
    x.id,
    jsonb_agg(x.obj order by x.ord, x.sub) as new_rows
  from (
    select
      expanded.id,
      case
        when expanded.elem ->> 'label' = 'Downloads, last 12 months'
          then jsonb_set(expanded.elem, '{value}', to_jsonb('6,331'::text))
        else expanded.elem
      end as obj,
      expanded.ord,
      0 as sub
    from expanded
    union all
    select
      expanded.id,
      jsonb_build_object(
        'label', 'Downloads, last 30 days',
        'value', '513',
        'footnote', 'Nov 9 had an unusual spike of 137 downloads from 7 listeners; 376 without that day'
      ) as obj,
      expanded.ord,
      1 as sub
    from expanded
    where expanded.elem ->> 'label' = 'Downloads, last 12 months'
  ) x
  group by x.id
)
update public.sponsor_sheet s
set
  rows = r.new_rows,
  updated_at = now()
from rebuilt r
where s.id = r.id;

-- Rollback (restore the 7 PLACEHOLDER rows exactly):
-- update public.sponsor_sheet
-- set
--   rows = '[{"label":"Downloads, last 12 months","value":"PLACEHOLDER"},{"label":"Unique listeners, last 30 days","value":"PLACEHOLDER"},{"label":"Listening apps","value":"PLACEHOLDER"},{"label":"Countries","value":"PLACEHOLDER"},{"label":"Listener job titles and seniority","value":"PLACEHOLDER"},{"label":"Newsletter subscribers","value":"PLACEHOLDER"},{"label":"Rates and open dates","value":"PLACEHOLDER"}]'::jsonb,
--   updated_at = now()
-- where id = 1;

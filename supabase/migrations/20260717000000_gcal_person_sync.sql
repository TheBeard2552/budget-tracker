-- Person tags + Google Calendar event ids for Home Hub sync.

alter table public.calendar_events
  add column if not exists person text not null default 'Family',
  add column if not exists gcal_event_id text;

create index if not exists calendar_events_gcal_event_id_idx
  on public.calendar_events (budget_id, gcal_event_id);

alter table public.budgets
  add column if not exists gcal_calendar_id text;

create or replace function public.unlock_budget(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_weekly numeric;
  v_cats jsonb;
  v_rules jsonb;
  v_aliases jsonb;
  v_events jsonb;
  v_txs jsonb;
  v_gcal text;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  select weekly_budget, categories, merchant_rules, gcal_calendar_id
  into v_weekly, v_cats, v_rules, v_gcal
  from public.budgets
  where id = v_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id,
      'rawKey', a.raw_key,
      'companyName', a.company_name
    ) order by a.company_name, a.raw_key
  ), '[]'::jsonb)
  into v_aliases
  from public.company_aliases a
  where a.budget_id = v_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id,
      'title', e.title,
      'notes', e.notes,
      'startTs', e.start_ts,
      'endTs', e.end_ts,
      'allDay', e.all_day,
      'person', e.person,
      'gcalEventId', e.gcal_event_id
    ) order by e.start_ts, e.title
  ), '[]'::jsonb)
  into v_events
  from public.calendar_events e
  where e.budget_id = v_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'ts', t.ts,
      'source', t.source,
      'card', t.card,
      'categoryOverride', t.category_override
    ) order by t.ts desc
  ), '[]'::jsonb)
  into v_txs
  from public.transactions t
  where t.budget_id = v_id;

  return jsonb_build_object(
    'budget_id', v_id,
    'weekly_budget', v_weekly,
    'categories', coalesce(v_cats, '[]'::jsonb),
    'merchant_rules', coalesce(v_rules, '[]'::jsonb),
    'company_aliases', coalesce(v_aliases, '[]'::jsonb),
    'calendar_events', coalesce(v_events, '[]'::jsonb),
    'gcal_calendar_id', v_gcal,
    'transactions', v_txs
  );
end;
$$;

create or replace function public.replace_calendar_events(p_code text, p_events jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_events jsonb;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  if p_events is null or jsonb_typeof(p_events) <> 'array' then
    raise exception 'events must be a JSON array';
  end if;

  delete from public.calendar_events where budget_id = v_id;

  insert into public.calendar_events (id, budget_id, title, notes, start_ts, end_ts, all_day, person, gcal_event_id)
  select
    coalesce(nullif(trim(elem->>'id'), ''), gen_random_uuid()::text),
    v_id,
    trim(coalesce(elem->>'title', '')),
    coalesce(elem->>'notes', ''),
    (elem->>'startTs')::bigint,
    case when elem->>'endTs' is null or elem->>'endTs' = '' then null else (elem->>'endTs')::bigint end,
    coalesce((elem->>'allDay')::boolean, true),
    coalesce(nullif(trim(elem->>'person'), ''), 'Family'),
    nullif(trim(elem->>'gcalEventId'), '')
  from jsonb_array_elements(p_events) as elem
  where length(trim(coalesce(elem->>'title', ''))) >= 1
    and elem->>'startTs' is not null;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id,
      'title', e.title,
      'notes', e.notes,
      'startTs', e.start_ts,
      'endTs', e.end_ts,
      'allDay', e.all_day,
      'person', e.person,
      'gcalEventId', e.gcal_event_id
    ) order by e.start_ts, e.title
  ), '[]'::jsonb)
  into v_events
  from public.calendar_events e
  where e.budget_id = v_id;

  update public.budgets set updated_at = now() where id = v_id;

  return jsonb_build_object('ok', true, 'calendar_events', v_events);
end;
$$;

create or replace function public.save_gcal_calendar_id(p_code text, p_calendar_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  update public.budgets
  set gcal_calendar_id = nullif(trim(p_calendar_id), ''),
      updated_at = now()
  where id = v_id;

  return jsonb_build_object('ok', true, 'gcal_calendar_id', nullif(trim(p_calendar_id), ''));
end;
$$;

grant execute on function public.unlock_budget(text) to anon, authenticated;
grant execute on function public.replace_calendar_events(text, jsonb) to anon, authenticated;
grant execute on function public.save_gcal_calendar_id(text, text) to anon, authenticated;

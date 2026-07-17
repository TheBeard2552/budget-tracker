-- Home calendar events (sync across devices; open in Google Calendar / Gmail).

create table public.calendar_events (
  id text primary key,
  budget_id uuid not null references public.budgets(id) on delete cascade,
  title text not null,
  notes text not null default '',
  start_ts bigint not null,
  end_ts bigint,
  all_day boolean not null default true,
  created_at timestamptz not null default now()
);

create index calendar_events_budget_id_start_idx
  on public.calendar_events (budget_id, start_ts);

alter table public.calendar_events enable row level security;
revoke all on table public.calendar_events from anon, authenticated, public;

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
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  select weekly_budget, categories, merchant_rules
  into v_weekly, v_cats, v_rules
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
      'allDay', e.all_day
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
    'transactions', v_txs
  );
end;
$$;

create or replace function public.create_budget(p_code text, p_weekly numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_pin text := public._normalize_pin(p_code);
begin
  if public._budget_id_for_code(v_pin) is not null then
    raise exception 'A budget already exists for this PIN';
  end if;

  insert into public.budgets (code_hash, weekly_budget, categories, merchant_rules)
  values (crypt(v_pin, gen_salt('bf')), p_weekly, '[]'::jsonb, '[]'::jsonb)
  returning id into v_id;

  return jsonb_build_object(
    'budget_id', v_id,
    'weekly_budget', p_weekly,
    'categories', '[]'::jsonb,
    'merchant_rules', '[]'::jsonb,
    'company_aliases', '[]'::jsonb,
    'calendar_events', '[]'::jsonb,
    'transactions', '[]'::jsonb
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

  insert into public.calendar_events (id, budget_id, title, notes, start_ts, end_ts, all_day)
  select
    coalesce(nullif(trim(elem->>'id'), ''), gen_random_uuid()::text),
    v_id,
    trim(coalesce(elem->>'title', '')),
    coalesce(elem->>'notes', ''),
    (elem->>'startTs')::bigint,
    case when elem->>'endTs' is null or elem->>'endTs' = '' then null else (elem->>'endTs')::bigint end,
    coalesce((elem->>'allDay')::boolean, true)
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
      'allDay', e.all_day
    ) order by e.start_ts, e.title
  ), '[]'::jsonb)
  into v_events
  from public.calendar_events e
  where e.budget_id = v_id;

  update public.budgets set updated_at = now() where id = v_id;

  return jsonb_build_object('ok', true, 'calendar_events', v_events);
end;
$$;

grant execute on function public.unlock_budget(text) to anon, authenticated;
grant execute on function public.create_budget(text, numeric) to anon, authenticated;
grant execute on function public.replace_calendar_events(text, jsonb) to anon, authenticated;
